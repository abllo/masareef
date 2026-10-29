-- =====================================================================
--  ملف الإعداد الكامل لقاعدة البيانات (مشروع Supabase جديد)
--  = 0001_init + 0002_sms_bank + 0003_sms_key_fix بالترتيب
--  الصق الملف كله مرة وحدة في SQL Editor واضغط Run
--  (لا تشغّله مرة ثانية على قاعدة فيها بيانات)
-- =====================================================================


-- ───────────── 0001_init.sql ─────────────
-- =====================================================================
--  مصاريف البيت — مخطط قاعدة البيانات (Supabase / PostgreSQL 15+)
--  المبادئ:
--   * المبالغ تُخزَّن بالهللة كأعداد صحيحة (bigint) لتجنّب أخطاء الكسور العشرية.
--   * كل بيانات العائلة مرتبطة بـ household_id ومحمية بسياسات RLS.
--   * مفاتيح أجنبية مركّبة تمنع ربط مصروف بتصنيف من عائلة أخرى.
--   * قيد فريد يمنع تسجيل دفعة مصروف متكرر مرتين لنفس الشهر.
--   * التصنيفات لا تُحذف إذا عليها عمليات، بل تُؤرشف (حفاظاً على السجل).
-- =====================================================================

-- ---------- العائلة ----------
create table public.households (
  id             uuid primary key default gen_random_uuid(),
  name           text not null default 'عائلتي' check (char_length(trim(name)) between 1 and 60),
  currency       char(3) not null default 'SAR',
  monthly_budget bigint check (monthly_budget is null or monthly_budget > 0), -- بالهللة
  invite_code    text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  created_at     timestamptz not null default now()
);

create table public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 30),
  role         text not null default 'member' check (role in ('owner', 'member')),
  joined_at    timestamptz not null default now(),
  primary key (household_id, user_id),
  unique (user_id) -- كل مستخدم ينتمي لعائلة واحدة
);

-- دالة مساعدة لسياسات RLS (security definer لتجنب التكرار اللانهائي في السياسات)
create or replace function public.is_member(h uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.household_members
    where household_id = h and user_id = (select auth.uid())
  );
$$;

-- ---------- التصنيفات ----------
create table public.categories (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  name         text not null check (char_length(trim(name)) between 1 and 40),
  icon         text not null default 'circle',
  color        text not null default '#64748B' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  sort_order   int  not null default 0,
  is_archived  boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (household_id, name),
  unique (id, household_id) -- هدف للمفاتيح الأجنبية المركّبة
);

-- ---------- المصروفات المتكررة (قوالب) ----------
create table public.recurring_expenses (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  category_id  uuid not null,
  name         text not null check (char_length(trim(name)) between 1 and 60),
  amount       bigint not null check (amount > 0), -- بالهللة
  day_of_month smallint not null default 1 check (day_of_month between 1 and 31),
  start_month  date not null default date_trunc('month', (now() at time zone 'Asia/Riyadh'))::date
               check (extract(day from start_month) = 1),
  is_active    boolean not null default true,
  created_by   uuid not null default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now(),
  unique (id, household_id),
  foreign key (category_id, household_id) references public.categories(id, household_id) on delete restrict
);

-- ---------- المصروفات (دفتر العمليات) ----------
create table public.expenses (
  id               uuid primary key default gen_random_uuid(),
  household_id     uuid not null references public.households(id) on delete cascade,
  category_id      uuid not null,
  amount           bigint not null check (amount > 0 and amount <= 100000000000), -- بالهللة
  expense_date     date not null default (now() at time zone 'Asia/Riyadh')::date,
  description      text check (description is null or char_length(description) <= 200),
  receipt_path     text,
  recurring_id     uuid,
  recurring_period date check (recurring_period is null or extract(day from recurring_period) = 1),
  created_by       uuid not null default auth.uid() references auth.users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (category_id, household_id) references public.categories(id, household_id) on delete restrict,
  -- عند حذف القالب تبقى العملية في السجل (PostgreSQL 15+)
  foreign key (recurring_id, household_id) references public.recurring_expenses(id, household_id) on delete set null (recurring_id),
  -- يمنع دفع نفس المصروف المتكرر مرتين لنفس الشهر
  unique (recurring_id, recurring_period)
);

create index expenses_household_date_idx on public.expenses (household_id, expense_date desc, created_at desc);
create index expenses_category_idx       on public.expenses (category_id);
create index expenses_recurring_idx      on public.expenses (household_id, recurring_period) where recurring_id is not null;
create index categories_household_idx    on public.categories (household_id, sort_order);

-- ---------- محفزات السلامة ----------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  -- حقول لا يجوز تغييرها بعد الإنشاء
  new.household_id := old.household_id;
  new.created_by   := old.created_by;
  new.created_at   := old.created_at;
  return new;
end $$;

create trigger expenses_touch before update on public.expenses
for each row execute function public.touch_updated_at();

create or replace function public.lock_household_id()
returns trigger language plpgsql as $$
begin
  new.household_id := old.household_id;
  return new;
end $$;

create trigger categories_lock before update on public.categories
for each row execute function public.lock_household_id();
create trigger recurring_lock before update on public.recurring_expenses
for each row execute function public.lock_household_id();

-- ---------- ملخص شهري (يحترم RLS عبر security_invoker) ----------
create view public.monthly_category_totals
with (security_invoker = true) as
select
  household_id,
  date_trunc('month', expense_date)::date as month,
  category_id,
  sum(amount)::bigint as total,
  count(*)::int       as tx_count
from public.expenses
group by 1, 2, 3;

-- ---------- سياسات الوصول RLS ----------
alter table public.households         enable row level security;
alter table public.household_members  enable row level security;
alter table public.categories         enable row level security;
alter table public.recurring_expenses enable row level security;
alter table public.expenses           enable row level security;

create policy households_select on public.households for select to authenticated using (public.is_member(id));
create policy households_update on public.households for update to authenticated using (public.is_member(id)) with check (public.is_member(id));

create policy members_select on public.household_members for select to authenticated using (public.is_member(household_id));
create policy members_update_self on public.household_members for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy categories_all on public.categories for all to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));

create policy recurring_all on public.recurring_expenses for all to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));

create policy expenses_select on public.expenses for select to authenticated using (public.is_member(household_id));
create policy expenses_insert on public.expenses for insert to authenticated
  with check (public.is_member(household_id) and created_by = (select auth.uid()));
create policy expenses_update on public.expenses for update to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));
create policy expenses_delete on public.expenses for delete to authenticated using (public.is_member(household_id));

-- صلاحيات على مستوى الأعمدة: العضو يعدّل اسمه فقط، ولا يغيّر رمز الدعوة إلا المنشئ عبر الدالة
revoke update on public.household_members from authenticated;
grant update (display_name) on public.household_members to authenticated;
revoke update on public.households from authenticated;
grant update (name, monthly_budget) on public.households to authenticated;

-- ---------- دوال (RPC) ----------
create or replace function public.create_household(p_name text, p_display_name text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from household_members where user_id = v_uid) then
    raise exception 'already in a household';
  end if;

  insert into households (name) values (coalesce(nullif(trim(p_name), ''), 'عائلتي')) returning id into v_id;
  insert into household_members (household_id, user_id, display_name, role)
    values (v_id, v_uid, trim(p_display_name), 'owner');

  insert into categories (household_id, name, icon, color, sort_order) values
    (v_id, 'البقالة والسوبرماركت', 'cart',     '#0E6B58', 1),
    (v_id, 'المطاعم والمقاهي',     'food',     '#C2410C', 2),
    (v_id, 'تطبيقات التوصيل',      'bike',     '#DB2777', 3),
    (v_id, 'الفواتير والاشتراكات', 'receipt',  '#2563EB', 4),
    (v_id, 'التسوق والمشتريات',    'bag',      '#7C3AED', 5),
    (v_id, 'مصاريف السيارة',       'car',      '#475569', 6),
    (v_id, 'راتب العاملة المنزلية','broom',    '#B45309', 7),
    (v_id, 'راتب السائق',          'steering', '#0891B2', 8),
    (v_id, 'مصاريف أخرى',          'circle',   '#64748B', 9);

  return v_id;
end $$;

create or replace function public.join_household(p_code text, p_display_name text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from household_members where user_id = v_uid) then
    raise exception 'already in a household';
  end if;

  select id into v_id from households where invite_code = upper(trim(p_code));
  if v_id is null then raise exception 'invalid invite code'; end if;

  if (select count(*) from household_members where household_id = v_id) >= 6 then
    raise exception 'household is full';
  end if;

  insert into household_members (household_id, user_id, display_name, role)
    values (v_id, v_uid, trim(p_display_name), 'member');
  return v_id;
end $$;

create or replace function public.regenerate_invite_code()
returns text
language plpgsql security definer set search_path = public
as $$
declare v_code text := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
begin
  update households set invite_code = v_code
  where id = (select household_id from household_members where user_id = auth.uid() and role = 'owner');
  if not found then raise exception 'only the owner can do this'; end if;
  return v_code;
end $$;

-- تسجيل دفع مصروف متكرر لشهر محدد (لا يتكرر بفضل القيد الفريد)
create or replace function public.mark_recurring_paid(p_recurring_id uuid, p_period date, p_date date default null)
returns uuid
language plpgsql security invoker set search_path = public
as $$
declare
  r public.recurring_expenses;
  v_id uuid;
begin
  select * into r from recurring_expenses where id = p_recurring_id; -- RLS يحمي القراءة
  if r.id is null then raise exception 'recurring expense not found'; end if;

  insert into expenses (household_id, category_id, amount, expense_date, description, recurring_id, recurring_period)
  values (
    r.household_id, r.category_id, r.amount,
    coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date),
    r.name, r.id, date_trunc('month', p_period)::date
  )
  on conflict (recurring_id, recurring_period) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from expenses
    where recurring_id = r.id and recurring_period = date_trunc('month', p_period)::date;
  end if;
  return v_id;
end $$;

revoke execute on function public.create_household(text, text)      from anon, public;
revoke execute on function public.join_household(text, text)        from anon, public;
revoke execute on function public.regenerate_invite_code()          from anon, public;
revoke execute on function public.mark_recurring_paid(uuid, date, date) from anon, public;
grant  execute on function public.create_household(text, text)      to authenticated;
grant  execute on function public.join_household(text, text)        to authenticated;
grant  execute on function public.regenerate_invite_code()          to authenticated;
grant  execute on function public.mark_recurring_paid(uuid, date, date) to authenticated;

-- ---------- التحديث اللحظي ----------
alter publication supabase_realtime add table public.expenses, public.categories, public.recurring_expenses, public.households;

-- ---------- تخزين صور الفواتير (خاص) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do nothing;

-- المسار: {household_id}/{expense_id}/{file}
create policy receipts_select on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and exists (
    select 1 from public.household_members m
    where m.user_id = (select auth.uid()) and m.household_id::text = (storage.foldername(name))[1]));

create policy receipts_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and exists (
    select 1 from public.household_members m
    where m.user_id = (select auth.uid()) and m.household_id::text = (storage.foldername(name))[1]));

create policy receipts_delete on storage.objects for delete to authenticated
  using (bucket_id = 'receipts' and exists (
    select 1 from public.household_members m
    where m.user_id = (select auth.uid()) and m.household_id::text = (storage.foldername(name))[1]));


-- ───────────── 0002_sms_bank.sql ─────────────
-- =====================================================================
--  تسجيل المصروفات تلقائياً من رسائل البنك (اختصارات الآيفون)
-- (طُبّق مسبقاً) الصق في SQL Editor في Supabase واضغط Run
-- =====================================================================

-- منع تسجيل نفس الرسالة مرتين
alter table public.expenses add column if not exists source_hash text unique;

-- رمز سري لكل شخص يوضع في الاختصار
create table if not exists public.sms_tokens (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete cascade,
  token        text not null unique
               default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  created_at   timestamptz not null default now()
);
alter table public.sms_tokens enable row level security; -- بدون سياسات: لا يُقرأ من الموقع

-- رمز تلقائي لأي عضو جديد ينضم للعائلة
create or replace function public.create_sms_token()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into sms_tokens (user_id, household_id) values (new.user_id, new.household_id)
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists members_sms_token on public.household_members;
create trigger members_sms_token after insert on public.household_members
for each row execute function public.create_sms_token();

-- الدالة التي يستدعيها الاختصار
create or replace function public.sms_expense(token text, message text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  t         public.sms_tokens;
  msg       text;
  low       text;
  amt_text  text;
  v_amount  bigint;
  merchant  text;
  cat_name  text;
  cat_id    uuid;
  v_id      uuid;
begin
  select * into t from sms_tokens s where s.token = sms_expense.token;
  if t.user_id is null then raise exception 'رمز غير صحيح'; end if;
  if message is null or length(message) > 2000 then return 'تجاهل: رسالة فارغة'; end if;

  -- توحيد الأرقام العربية وإزالة فواصل الآلاف
  msg := translate(message, '٠١٢٣٤٥٦٧٨٩٫٬', '0123456789.,');
  msg := regexp_replace(msg, '(\d),(\d)', '\1\2', 'g');
  low := lower(msg);

  -- ليست عملية شراء
  if low ~ '(otp|رمز التحقق|رمز التفعيل|كلمة المرور|verification|إيداع|ايداع|استرداد|refund|راتب|حوالة واردة|incoming|deposit)' then
    return 'تجاهل: ليست عملية شراء';
  end if;
  if low ~ '\m(usd|eur|gbp|aed|bhd|kwd|qar|egp)\M' and low !~ '(sar|ر\.?\s?س|ريال)' then
    return 'تجاهل: عملة أجنبية، أضفها يدوياً';
  end if;

  -- المبلغ
  amt_text := coalesce(
    substring(low from '(?:مبلغ|amount)[^0-9]{0,20}([0-9]+(?:\.[0-9]{1,2})?)'),
    substring(low from '(?:sar|ر\.?\s?س|ريال)\s*:?\s*([0-9]+(?:\.[0-9]{1,2})?)'),
    substring(low from '([0-9]+(?:\.[0-9]{1,2})?)\s*(?:sar|ر\.?\s?س|ريال)')
  );
  if amt_text is null then return 'تجاهل: لم أجد المبلغ'; end if;
  v_amount := round(amt_text::numeric * 100)::bigint;
  if v_amount <= 0 then return 'تجاهل: مبلغ صفر'; end if;

  -- اسم المتجر (السطر بعد «لدى» أو «عند» أو at)
  merchant := trim(substring(msg from '(?i)(?:لدى|عند|التاجر|\mat\M|merchant)\s*:?\s*([^\n]{2,60})'));

  -- تخمين التصنيف
  cat_name := case
    when low ~ '(هنقر|hunger|جاهز|jahez|مرسول|mrsool|تويو|toyou|نينجا|ninja|كيتا|keeta|chefz|شفز)' then 'تطبيقات التوصيل'
    when low ~ '(دانوب|danube|بنده|panda|عثيم|othaim|كارفور|carrefour|تميمي|tamimi|لولو|lulu|نستو|nesto|ماركت|market|تموينات|سوبر)' then 'البقالة والسوبرماركت'
    when low ~ '(كوفي|كافيه|قهوة|cafe|coffee|starbucks|ستاربكس|مطعم|مطاعم|restaurant|البيك|albaik|mcdonald|ماكدونالدز|kudu|كودو|herfy|هرفي|barns|بارنز|dunkin|دانكن|pizza|بيتزا|burger|برجر|شاورما|shawarma)' then 'المطاعم والمقاهي'
    when low ~ '(stc|mobily|موبايلي|zain|كهرباء|electric|المياه|netflix|نتفلكس|shahid|شاهد|spotify|apple\.com|icloud|سداد|فاتورة|osn)' then 'الفواتير والاشتراكات'
    when low ~ '(بنزين|وقود|fuel|sasco|ساسكو|aldrees|الدريس|petromin|بترومين|نفط|محطة|مغسلة|car wash)' then 'مصاريف السيارة'
    when low ~ '(amazon|امازون|أمازون|noon\.com|\mnoon\M|shein|شي ان|ikea|ايكيا|extra|اكسترا|jarir|جرير|centrepoint|سنتربوينت|namshi|نمشي)' then 'التسوق والمشتريات'
    else 'مصاريف أخرى'
  end;

  select id into cat_id from categories
  where household_id = t.household_id and name = cat_name and not is_archived;
  if cat_id is null then -- التصنيف محذوف أو مؤرشف: آخر تصنيف نشط
    select id, name into cat_id, cat_name from categories
    where household_id = t.household_id and not is_archived
    order by sort_order desc limit 1;
  end if;
  if cat_id is null then raise exception 'لا توجد تصنيفات'; end if;

  insert into expenses (household_id, category_id, amount, expense_date, description, created_by, source_hash)
  values (
    t.household_id, cat_id, v_amount, (now() at time zone 'Asia/Riyadh')::date,
    left('📩 ' || coalesce(nullif(merchant, ''), 'رسالة البنك'), 200),
    t.user_id, md5(t.user_id::text || message)
  )
  on conflict (source_hash) do nothing
  returning id into v_id;

  if v_id is null then return 'مسجّلة مسبقاً'; end if;
  return format('تم تسجيل %s ر.س في %s', to_char(v_amount / 100.0, 'FM999999990.00'), cat_name);
end $$;

revoke all on function public.sms_expense(text, text) from public;
grant execute on function public.sms_expense(text, text) to anon, authenticated;

-- رموز للأعضاء الحاليين
insert into public.sms_tokens (user_id, household_id)
select user_id, household_id from public.household_members
on conflict (user_id) do nothing;

-- اعرض الرموز (انسخ رمزك من النتيجة)
select m.display_name as "الاسم", t.token as "الرمز"
from public.sms_tokens t
join public.household_members m using (user_id, household_id);


-- ───────────── 0003_sms_key_fix.sql ─────────────
-- (طُبّق مسبقاً) يقبل أسماء الحقول حتى لو دخلت معها مسافات من كيبورد الآيفون
create or replace function public.sms_expense(jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare k text; v_token text; v_msg text;
begin
  for k in select jsonb_object_keys($1) loop
    if lower(trim(k)) = 'token' then v_token := $1->>k; end if;
    if lower(trim(k)) = 'message' then v_msg := $1->>k; end if;
  end loop;
  return public.sms_expense(trim(v_token), v_msg);
end $$;
revoke all on function public.sms_expense(jsonb) from public;
grant execute on function public.sms_expense(jsonb) to anon, authenticated;
notify pgrst, 'reload schema';

