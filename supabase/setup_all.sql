-- =====================================================================
--  ملف الإعداد الكامل لقاعدة البيانات (مشروع Supabase جديد)
--  = 0001 + 0002 + 0003 + 0005 + 0006 + 0007 + 0008 بالترتيب (0004 غير مطلوب لقاعدة جديدة)
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
-- الصق في SQL Editor في Supabase واضغط Run (أو استخدم setup_all.sql)
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
-- يقبل أسماء الحقول حتى لو دخلت معها مسافات من كيبورد الآيفون
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


-- ───────────── 0005_improvements.sql ─────────────
-- =====================================================================
--  0005: تحسينات
--   1) قراءة أدق لرسائل البنك:
--      - تجاهل أسطر الرصيد والمتاح والحد والرسوم قبل البحث عن المبلغ
--      - تجاهل العمليات المرفوضة والملغاة والمعكوسة
--      - العملة الأجنبية: يُسجَّل المبلغ بالريال إن وُجد، وإلا تُتجاهل
--      - التصنيف يُخمَّن من اسم المتجر (وليس من نص الرسالة كاملاً)
--      - ربط التصنيف بالاسم ثم بالأيقونة، فلا يضيع إذا غيّرت اسم التصنيف
--   2) رمز الاختصار من داخل التطبيق (عرض + تجديد) بدل SQL Editor
--   3) المنشئ يزيل عضواً، والعضو يغادر العائلة
--   4) منع تسجيل الاشتراك مرتين (رسالة البنك + «تسجيل الدفع» للمصروف الثابت)
-- =====================================================================

create or replace function public.sms_expense(token text, message text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  t         public.sms_tokens;
  msg       text;
  low       text;
  body      text;      -- الرسالة بعد حذف الرصيد والرسوم
  m         text[];
  sar_amt   text;
  amt_text  text;
  v_amount  bigint;
  merchant  text;
  hay       text;      -- النص الذي يُخمَّن منه التصنيف
  cat_name  text;
  cat_icon  text;
  cat_id    uuid;
  v_id      uuid;
  v_linked  text;
begin
  -- الرمز 64 حرفاً hex: نتجاهل أي مسافة أو سطر جديد أو حروف كبيرة دخلت مع اللصق في الاختصار
  select * into t from sms_tokens s
  where s.token = lower(regexp_replace(coalesce(sms_expense.token, ''), '[^0-9A-Fa-f]', '', 'g'));
  if t.user_id is null
     or not exists (select 1 from household_members hm
                    where hm.user_id = t.user_id and hm.household_id = t.household_id) then
    raise exception 'رمز غير صحيح';
  end if;
  if message is null or btrim(message) = '' or length(message) > 2000 then
    return 'تجاهل: رسالة فارغة';
  end if;

  -- توحيد الأرقام العربية وإزالة فواصل الآلاف
  msg := translate(message, '٠١٢٣٤٥٦٧٨٩٫٬', '0123456789.,');
  msg := regexp_replace(msg, '(\d),(\d)', '\1\2', 'g');
  low := lower(msg);

  -- ليست عملية شراء
  if low ~ '(otp|رمز التحقق|رمز التفعيل|كلمة المرور|كلمة السر|verification|one time|إيداع|ايداع|استرداد|استرجاع|refund|راتب|حوالة واردة|تحويل وارد|incoming|deposit|credited)' then
    return 'تجاهل: ليست عملية شراء';
  end if;
  -- عملية لم تكتمل
  if low ~ '(مرفوض|declined|rejected|غير ناجح|فشل|failed|unsuccessful|insufficient|رصيد غير كاف|ملغا|ملغي|تم إلغاء|تم الغاء|cancelled|canceled|عكس عملية|عملية عكسية|معكوس|reversal|reversed)' then
    return 'تجاهل: عملية مرفوضة أو ملغاة';
  end if;

  -- احذف من كلمة الرصيد/المتاح/الحد/الرسوم إلى آخر السطر حتى لا يُلتقط رقمها كمبلغ
  body := regexp_replace(low, '(الرصيد|رصيد|المتاح|متاح|balance|\mbal\M|avail|limit|الحد|رسوم|عمولة|\mfees?\M)[^\n]*', '', 'g');

  -- أول مبلغ ملاصق للريال (قبل الرقم أو بعده)
  m := regexp_match(body,
    '(?:sar|ر\.?\s?س(?![ء-ي])|ريال)\s*:?\s*([0-9]+(?:\.[0-9]{1,2})?)|([0-9]+(?:\.[0-9]{1,2})?)\s*(?:sar|ر\.?\s?س(?![ء-ي])|ريال)');
  sar_amt := coalesce(m[1], m[2]);

  if body ~ '(\m(usd|eur|gbp|aed|bhd|kwd|qar|egp|omr|jod|inr|cny|jpy)\M|[$€£])' then
    -- عملية بعملة أجنبية: نقبل فقط مبلغاً صريحاً بالريال
    if sar_amt is null then return 'تجاهل: عملة أجنبية، أضفها يدوياً'; end if;
    amt_text := sar_amt;
  else
    amt_text := coalesce(
      substring(body from '(?:مبلغ|amount)[^0-9]{0,20}([0-9]+(?:\.[0-9]{1,2})?)'),
      sar_amt
    );
  end if;
  if amt_text is null then return 'تجاهل: لم أجد المبلغ'; end if;
  v_amount := round(amt_text::numeric * 100)::bigint;
  if v_amount <= 0 then return 'تجاهل: مبلغ صفر'; end if;
  if v_amount > 100000000000 then return 'تجاهل: مبلغ غير منطقي'; end if;

  -- اسم المتجر (بعد «لدى» أو «عند» أو at)
  merchant := trim(substring(msg from '(?i)(?:لدى|عند|التاجر|المتجر|\mat\M|merchant)\s*:?\s*([^\n]{2,60})'));

  -- التصنيف من اسم المتجر فقط؛ وإن لم يوجد فمن الرسالة بعد حذف اسم البنك/المحفظة
  hay := coalesce(nullif(lower(merchant), ''), low);
  hay := regexp_replace(hay, '(stc ?bank|stc ?pay|بنك stc|stc بنك|اس تي سي باي)', '', 'g');

  cat_name := case
    when hay ~ '(هنقر|hunger|جاهز|jahez|مرسول|mrsool|تويو|toyou|نينجا|\mninja\M|كيتا|keeta|chefz|شفز)'
      then 'تطبيقات التوصيل'
    when hay ~ '(كوفي|كافيه|كافي|قهوة|مقهى|cafe|café|coffee|starbucks|ستاربكس|مطعم|مطاعم|restaurant|البيك|albaik|mcdonald|ماكدونالدز|\mkudu\M|كودو|herfy|هرفي|barns|بارنز|dunkin|دانكن|pizza|بيتزا|burger|برجر|شاورما|shawarma|\mkfc\M|كنتاكي|subway|domino|دومينوز|tim hortons|هاف مليون|half million|krispy|كرسبي|مخبز|bakery|حلويات)'
      then 'المطاعم والمقاهي'
    when hay ~ '(دانوب|danube|بنده|\mpanda\M|عثيم|othaim|كارفور|carrefour|تميمي|tamimi|لولو|\mlulu\M|نستو|nesto|ماركت|\mmarket\M|supermarket|hypermarket|هايبر|تموينات|سوبر|بقالة|grocery)'
      then 'البقالة والسوبرماركت'
    when hay ~ '(amazon|امازون|أمازون|noon\.com|\mnoon\M|نون|shein|شي ان|ikea|ايكيا|\mextra\M|اكسترا|jarir|جرير|centrepoint|سنتربوينت|namshi|نمشي|trendyol|ترينديول)'
      then 'التسوق والمشتريات'
    when hay ~ '(\mstc\M|mobily|موبايلي|\mzain\M|كهرباء|electric|\msec\M|المياه|netflix|نتفلكس|shahid|شاهد|spotify|سبوتيفاي|apple\.com|icloud|سداد|sadad|فاتورة|\mosn\M|youtube|anghami|أنغامي|disney|starzplay|chatgpt|openai)'
      then 'الفواتير والاشتراكات'
    when hay ~ '(بنزين|وقود|fuel|petrol|sasco|ساسكو|aldrees|الدريس|petromin|بترومين|نفط|محطة|مغسلة|car wash|ورشة|قطع غيار|إطارات|اطارات|tyres|tires)'
      then 'مصاريف السيارة'
    else 'مصاريف أخرى'
  end;
  cat_icon := case cat_name
    when 'تطبيقات التوصيل'      then 'bike'
    when 'المطاعم والمقاهي'     then 'food'
    when 'البقالة والسوبرماركت' then 'cart'
    when 'التسوق والمشتريات'    then 'bag'
    when 'الفواتير والاشتراكات' then 'receipt'
    when 'مصاريف السيارة'       then 'car'
    else 'circle'
  end;

  -- بالاسم أولاً، ثم بالأيقونة (لو غيّرت الاسم)، ثم «أخرى»، ثم آخر تصنيف نشط
  select c.id, c.name into cat_id, cat_name
  from categories c
  where c.household_id = t.household_id and not c.is_archived
  order by (c.name = cat_name) desc, (c.icon = cat_icon) desc, (c.icon = 'circle') desc, c.sort_order desc
  limit 1;
  if cat_id is null then raise exception 'لا توجد تصنيفات'; end if;

  if exists (select 1 from expenses where source_hash = md5(t.user_id::text || message)) then
    return 'مسجّلة مسبقاً';
  end if;

  -- مصروف ثابت سجّلتم دفعه يدوياً هذا الشهر بنفس المبلغ: نربط الرسالة به بدل تسجيله مرتين
  update expenses e set source_hash = md5(t.user_id::text || message)
  where e.id = (
    select x.id from expenses x
    where x.household_id = t.household_id and x.recurring_id is not null and x.source_hash is null
      and x.amount = v_amount
      and x.recurring_period = date_trunc('month', (now() at time zone 'Asia/Riyadh'))::date
    order by x.created_at
    limit 1
  )
  returning e.description into v_linked;
  if found then return format('مسجّلة مسبقاً كمصروف ثابت: %s', v_linked); end if;

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

-- ---------- تسجيل دفع مصروف ثابت ----------
-- إن وصلت رسالة البنك قبل الضغط على «تسجيل الدفع» (نفس المبلغ ونفس الشهر)
-- نربط تلك العملية بالمصروف الثابت بدل إنشاء عملية ثانية
create or replace function public.mark_recurring_paid(p_recurring_id uuid, p_period date, p_date date default null)
returns uuid
language plpgsql security invoker set search_path = public
as $$
declare
  r public.recurring_expenses;
  v_period date := date_trunc('month', p_period)::date;
  v_id uuid;
begin
  select * into r from recurring_expenses where id = p_recurring_id; -- RLS يحمي القراءة
  if r.id is null then raise exception 'recurring expense not found'; end if;

  select id into v_id from expenses where recurring_id = r.id and recurring_period = v_period;
  if v_id is not null then return v_id; end if;

  select id into v_id from expenses
  where household_id = r.household_id and recurring_id is null and source_hash is not null
    and amount = r.amount and date_trunc('month', expense_date)::date = v_period
  order by expense_date, created_at
  limit 1
  for update;
  if v_id is not null then
    update expenses set recurring_id = r.id, recurring_period = v_period, category_id = r.category_id
    where id = v_id;
    return v_id;
  end if;

  insert into expenses (household_id, category_id, amount, expense_date, description, recurring_id, recurring_period)
  values (
    r.household_id, r.category_id, r.amount,
    coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date),
    r.name, r.id, v_period
  )
  on conflict (recurring_id, recurring_period) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from expenses where recurring_id = r.id and recurring_period = v_period;
  end if;
  return v_id;
end $$;

-- ---------- رمز الاختصار من التطبيق ----------
create or replace function public.my_sms_token()
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_household uuid;
  v_token text;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select household_id into v_household from household_members where user_id = v_uid;
  if v_household is null then raise exception 'not in a household'; end if;
  insert into sms_tokens (user_id, household_id) values (v_uid, v_household)
  on conflict (user_id) do update set household_id = excluded.household_id
  returning sms_tokens.token into v_token;
  return v_token;
end $$;

create or replace function public.regenerate_sms_token()
returns text
language plpgsql security definer set search_path = public
as $$
declare v_token text;
begin
  perform public.my_sms_token();
  update sms_tokens
     set token = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), created_at = now()
   where user_id = auth.uid()
  returning sms_tokens.token into v_token;
  return v_token;
end $$;

-- ---------- إدارة الأعضاء ----------
create or replace function public.remove_member(p_user_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_household uuid;
begin
  select household_id into v_household from household_members where user_id = auth.uid() and role = 'owner';
  if v_household is null then raise exception 'only the owner can do this'; end if;
  if p_user_id = auth.uid() then raise exception 'owner cannot leave'; end if;
  delete from household_members where household_id = v_household and user_id = p_user_id;
  if not found then raise exception 'member not found'; end if;
  delete from sms_tokens where user_id = p_user_id;
end $$;

create or replace function public.leave_household()
returns void
language plpgsql security definer set search_path = public
as $$
declare v_role text;
begin
  select role into v_role from household_members where user_id = auth.uid();
  if v_role is null then raise exception 'not in a household'; end if;
  if v_role = 'owner' then raise exception 'owner cannot leave'; end if;
  delete from household_members where user_id = auth.uid();
  delete from sms_tokens where user_id = auth.uid();
end $$;

revoke execute on function public.my_sms_token()          from anon, public;
revoke execute on function public.regenerate_sms_token()  from anon, public;
revoke execute on function public.remove_member(uuid)     from anon, public;
revoke execute on function public.leave_household()       from anon, public;
grant  execute on function public.my_sms_token()          to authenticated;
grant  execute on function public.regenerate_sms_token()  to authenticated;
grant  execute on function public.remove_member(uuid)     to authenticated;
grant  execute on function public.leave_household()       to authenticated;

notify pgrst, 'reload schema';


-- ───────────── 0006_ai.sql ─────────────
-- =====================================================================
--  0006: الذكاء الاصطناعي (Claude)
--   1) قراءة رسائل البنك وتصنيفها بـ Claude، مع رجوع تلقائي للقراءة المحلية
--      إذا توقف الربط (لا مفتاح / لا رصيد / خطأ / بطء) — لا تضيع أي رسالة
--   2) يتعلّم من تعديلاتك: تغيير تصنيف عملية من رسالة يحفظ قاعدة «متجر ← تصنيف»
--   3) سجل لكل رسالة وصلت ونتيجتها
--   4) تنظيم التصنيفات بالذكاء الاصطناعي (دمج/إعادة تسمية/أرشفة/حذف/إنشاء/توحيد متجر)
--      كل عملية تُسجَّل ويمكن التراجع عنها بالكامل، ولا يُحذف إلا تصنيف فارغ
--  مفتاح Claude في Supabase Vault باسم: anthropic_api_key  (لا يظهر في الكود ولا في الموقع)
-- =====================================================================

create extension if not exists http with schema extensions;

-- ---------- أعمدة إضافية ----------
alter table public.expenses   add column if not exists merchant_key text;
alter table public.expenses   add column if not exists sms_meta jsonb;
alter table public.categories add column if not exists created_by_ai boolean not null default false;
-- التصنيفات الأساسية مثبّتة: لا يدمجها الذكاء الاصطناعي ولا يؤرشفها ولا يحذفها ولا يغيّر اسمها
alter table public.categories add column if not exists is_core boolean not null default false;
create index if not exists expenses_merchant_idx on public.expenses (household_id, merchant_key) where merchant_key is not null;

-- ---------- قواعد «متجر ← تصنيف» المتعلَّمة ----------
create table if not exists public.merchant_rules (
  household_id   uuid not null references public.households(id) on delete cascade,
  merchant_key   text not null,
  merchant_label text not null,
  category_id    uuid not null,
  created_by     uuid references auth.users(id) on delete set null,
  updated_at     timestamptz not null default now(),
  primary key (household_id, merchant_key),
  foreign key (category_id, household_id) references public.categories(id, household_id) on delete cascade
);
alter table public.merchant_rules enable row level security;
drop policy if exists merchant_rules_all on public.merchant_rules;
create policy merchant_rules_all on public.merchant_rules for all to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));

-- ---------- سجل رسائل البنك ----------
create table if not exists public.sms_log (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id      uuid references auth.users(id) on delete set null,
  received_at  timestamptz not null default now(),
  message      text,      -- رسائل رموز التحقق لا يُحفظ نصها
  status       text not null check (status in ('recorded', 'ignored', 'duplicate', 'linked')),
  reason       text,
  source       text,      -- ai | rules
  expense_id   uuid references public.expenses(id) on delete set null,
  result       jsonb
);
create index if not exists sms_log_household_idx on public.sms_log (household_id, received_at desc);
alter table public.sms_log enable row level security;
drop policy if exists sms_log_select on public.sms_log;
drop policy if exists sms_log_delete on public.sms_log;
create policy sms_log_select on public.sms_log for select to authenticated using (public.is_member(household_id));
create policy sms_log_delete on public.sms_log for delete to authenticated using (public.is_member(household_id));
revoke insert, update on public.sms_log from anon, authenticated;

-- ---------- سجل تغييرات التصنيفات (للتراجع) ----------
create table if not exists public.category_audit (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  batch_id     uuid not null,
  op           text not null,
  details      jsonb not null,
  actor        text not null default 'ai',
  created_at   timestamptz not null default now(),
  undone_at    timestamptz
);
create index if not exists category_audit_batch_idx on public.category_audit (household_id, batch_id);
alter table public.category_audit enable row level security;
drop policy if exists category_audit_select on public.category_audit;
create policy category_audit_select on public.category_audit for select to authenticated using (public.is_member(household_id));
revoke insert, update, delete on public.category_audit from anon, authenticated;

-- ---------- حالة الربط ----------
create table if not exists public.ai_health (
  id            int primary key default 1 check (id = 1),
  last_ok_at    timestamptz,
  last_error_at timestamptz,
  last_error    text
);
insert into public.ai_health (id) values (1) on conflict do nothing;
alter table public.ai_health enable row level security;  -- لا سياسات: يُقرأ عبر ai_status() فقط

do $$ begin
  alter publication supabase_realtime add table public.sms_log;
exception when duplicate_object then null; end $$;

-- =====================================================================
--  أدوات مساعدة
-- =====================================================================

-- مفتاح موحّد لاسم المتجر: «STARBUCKS 1234 JEDDAH SA» و«Starbucks» ← starbucks
create or replace function public.normalize_merchant(p text)
returns text language sql immutable as $$
  select nullif(array_to_string(array(
    select w from regexp_split_to_table(
      regexp_replace(lower(translate(coalesce(p, ''), 'أإآةى', 'اااهي')), '[^a-zء-ي]+', ' ', 'g'), ' ') as w
    where length(w) > 1
      and w <> all (array[
        'sa','ksa','sau','saudi','arabia','jeddah','jiddah','riyadh','dammam','khobar','makkah','mecca','madinah','medina',
        'taif','abha','tabuk','buraidah','jubail','yanbu','com','www','net','pos','mada','store','branch','co','ltd','llc','est',
        'جده','الرياض','الدمام','الخبر','مكه','المدينه','المنوره','السعوديه','المملكه','العربيه','الطايف','ابها','تبوك',
        'فرع','مؤسسه','شركه'])
  ), ' '), '')
$$;

-- يخفي أرقام الرصيد/المتاح/الحد والأرقام الطويلة قبل الإرسال لـ Claude
create or replace function public.sms_mask(p text)
returns text language sql immutable as $$
  select string_agg(
           case when line ~* '(الرصيد|رصيد|المتاح|متاح|balance|avail|limit|الحد)'
                then regexp_replace(line, '[0-9٠-٩]', '•', 'g') else line end,
           E'\n' order by n)
  from regexp_split_to_table(regexp_replace(coalesce(p, ''), '[0-9]{8,}', '########', 'g'), E'\n') with ordinality as t(line, n)
$$;

create or replace function public.ai_model(p_purpose text default 'sms')
returns text language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  begin
    select decrypted_secret into v from vault.decrypted_secrets where name = 'anthropic_model_' || p_purpose limit 1;
  exception when others then v := null; end;
  return coalesce(nullif(v, ''), case p_purpose when 'sms' then 'claude-haiku-5-5' else 'claude-sonnet-5-5' end);
end $$;

create or replace function public.ai_enabled()
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return exists (select 1 from vault.decrypted_secrets where name = 'anthropic_api_key' and coalesce(decrypted_secret, '') <> '');
exception when others then return false;
end $$;

-- استدعاء Claude بأداة واحدة إجبارية. يعيد مدخلات الأداة، أو null عند أي مشكلة (لا يرمي خطأ أبداً)
create or replace function public.ai_call(p_purpose text, p_system text, p_user text, p_tool jsonb, p_max_tokens int default 600)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_key text;
  v_res extensions.http_response;
  v_out jsonb;
begin
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'anthropic_api_key' limit 1;
  exception when others then v_key := null; end;
  if coalesce(v_key, '') = '' then return null; end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', case p_purpose when 'sms' then '20000' else '55000' end);
  select * into v_res from extensions.http((
    'POST',
    'https://api.anthropic.com/v1/messages',
    array[extensions.http_header('x-api-key', v_key), extensions.http_header('anthropic-version', '2023-06-01')],
    'application/json',
    jsonb_build_object(
      'model', public.ai_model(p_purpose),
      'max_tokens', p_max_tokens,
      'system', p_system,
      'tools', jsonb_build_array(p_tool),
      'tool_choice', jsonb_build_object('type', 'tool', 'name', p_tool->>'name'),
      'messages', jsonb_build_array(jsonb_build_object('role', 'user', 'content', p_user))
    )::text
  )::extensions.http_request);

  if v_res.status is distinct from 200 then
    update ai_health set last_error_at = now(), last_error = format('HTTP %s: %s', v_res.status, left(v_res.content, 300)) where id = 1;
    return null;
  end if;
  select e->'input' into v_out
  from jsonb_array_elements((v_res.content::jsonb)->'content') e
  where e->>'type' = 'tool_use'
  limit 1;
  if v_out is null then
    update ai_health set last_error_at = now(), last_error = 'رد بدون نتيجة' where id = 1;
    return null;
  end if;
  update ai_health set last_ok_at = now() where id = 1;
  return v_out;
exception when others then
  update ai_health set last_error_at = now(), last_error = left(sqlerrm, 300) where id = 1;
  return null;
end $$;

-- الأيقونات والألوان المسموحة (نفس ما في الواجهة)
create or replace function public.allowed_icons()
returns text[] language sql immutable as $$
  select array['cart','food','coffee','bike','receipt','bag','car','fuel','broom','steering','home','power','water','wifi',
               'phone','tv','health','pill','school','books','baby','gift','clothes','beauty','travel','sport','pet','repair',
               'charity','circle']
$$;

-- اسم تصنيف للمقارنة: بدون «ال» والتشكيل والهمزات
create or replace function public.normalize_category(p text)
returns text language sql immutable as $$
  select array_to_string(array(
    select regexp_replace(w, '^(وال|ال|و)', '')
    from regexp_split_to_table(regexp_replace(lower(translate(coalesce(p, ''), 'أإآةى', 'اااهي')), '[^a-zء-ي]+', ' ', 'g'), ' ') w
    where w not in ('', 'و')
  ), ' ')
$$;

-- إنشاء تصنيف بضوابط: لا تكرار ولا شبيه، حد أقصى 18 تصنيفاً نشطاً، أيقونة مسموحة
create or replace function public.safe_create_category(p_household uuid, p_name text, p_icon text, p_batch uuid, p_actor text default 'ai')
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_norm text := public.normalize_category(p_name);
  v_id   uuid;
  v_color text;
begin
  if char_length(v_name) not between 2 and 30 or v_norm = '' then return null; end if;

  -- تصنيف نشط بنفس المعنى؟ استخدمه بدل إنشاء جديد
  select id into v_id from categories
  where household_id = p_household and not is_archived
    and (public.normalize_category(name) = v_norm
         or (length(v_norm) >= 4 and length(public.normalize_category(name)) >= 4
             and (public.normalize_category(name) like '%' || v_norm || '%'
                  or v_norm like '%' || public.normalize_category(name) || '%')))
  order by sort_order limit 1;
  if v_id is not null then return v_id; end if;
  -- يوجد مؤرشف بنفس الاسم: لا نعيد إنشاءه (أرشفته كانت مقصودة)
  if exists (select 1 from categories where household_id = p_household and public.normalize_category(name) = v_norm) then
    return null;
  end if;
  if (select count(*) from categories where household_id = p_household and not is_archived) >= 18 then return null; end if;

  select c into v_color from unnest(array['#16A34A','#4F46E5','#DC2626','#0891B2','#DB2777','#B45309','#7C3AED','#2563EB','#C2410C','#0E6B58','#475569','#64748B']) c
  where c not in (select color from categories where household_id = p_household and not is_archived)
  limit 1;

  insert into categories (household_id, name, icon, color, sort_order, created_by_ai)
  values (p_household, v_name,
          case when p_icon = any (public.allowed_icons()) then p_icon else 'circle' end,
          coalesce(v_color, '#64748B'),
          coalesce((select max(sort_order) from categories where household_id = p_household), 0) + 1,
          p_actor = 'ai')
  returning id into v_id;

  insert into category_audit (household_id, batch_id, op, details, actor)
  values (p_household, coalesce(p_batch, gen_random_uuid()), 'create', jsonb_build_object('id', v_id, 'name', v_name), p_actor);
  return v_id;
end $$;

-- =====================================================================
--  قراءة الرسالة (مشتركة بين الاختصار وزر «جرّب رسالة»)
-- =====================================================================
create or replace function public.sms_parse(p_household uuid, p_message text, p_allow_ai boolean default true, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  msg       text;
  low       text;
  body      text;
  m         text[];
  sar_amt   text;
  amt_text  text;
  v_foreign boolean;
  v_amount  bigint;
  v_merchant text;
  hay       text;
  cat_name  text;
  cat_icon  text;
  v_cat_id  uuid;
  v_cat_name text;
  v_today   date := (now() at time zone 'Asia/Riyadh')::date;
  v_date    date := (now() at time zone 'Asia/Riyadh')::date;
  v_ai      jsonb;
  v_source  text := 'rules';
  v_meta    jsonb := '{}';
  v_key     text;
  v_cats    text[];
  v_other   text;
  v_learned text;
  v_rate    numeric;
  v_new     jsonb;
  v_new_name text;
  v_ai_note text;
begin
  msg := translate(p_message, '٠١٢٣٤٥٦٧٨٩٫٬', '0123456789.,');
  msg := regexp_replace(msg, '(\d),(\d)', '\1\2', 'g');
  low := lower(msg);

  -- رموز التحقق لا تُرسل لأي جهة ولا يُحفظ نصها
  if low ~ '(otp|رمز التحقق|رمز التفعيل|رمز الدخول|كلمة المرور|كلمة السر|verification|one time|passcode)' then
    return jsonb_build_object('status', 'ignored', 'reason', 'رمز تحقق', 'private', true, 'source', 'rules');
  end if;
  if low ~ '(إيداع|ايداع|استرداد|استرجاع|refund|راتب|حوالة واردة|تحويل وارد|incoming|deposit|credited)' then
    return jsonb_build_object('status', 'ignored', 'reason', 'ليست عملية شراء', 'source', 'rules');
  end if;
  if low ~ '(مرفوض|declined|rejected|غير ناجح|فشل|failed|unsuccessful|insufficient|رصيد غير كاف|ملغا|ملغي|تم إلغاء|تم الغاء|cancelled|canceled|عكس عملية|عملية عكسية|معكوس|reversal|reversed)' then
    return jsonb_build_object('status', 'ignored', 'reason', 'عملية مرفوضة أو ملغاة', 'source', 'rules');
  end if;

  -- ---------- القراءة المحلية: تعمل دائماً وتكون الاحتياط ----------
  body := regexp_replace(low, '(الرصيد|رصيد|المتاح|متاح|balance|\mbal\M|avail|limit|الحد|رسوم|عمولة|\mfees?\M)[^\n]*', '', 'g');
  m := regexp_match(body,
    '(?:sar|ر\.?\s?س(?![ء-ي])|ريال)\s*:?\s*([0-9]+(?:\.[0-9]{1,2})?)|([0-9]+(?:\.[0-9]{1,2})?)\s*(?:sar|ر\.?\s?س(?![ء-ي])|ريال)');
  sar_amt := coalesce(m[1], m[2]);
  v_foreign := body ~ '(\m(usd|eur|gbp|aed|bhd|kwd|qar|egp|omr|jod|inr|cny|jpy|try)\M|[$€£])';
  amt_text := case when v_foreign then sar_amt
                   else coalesce(substring(body from '(?:مبلغ|amount)[^0-9]{0,20}([0-9]+(?:\.[0-9]{1,2})?)'), sar_amt) end;
  v_merchant := trim(substring(msg from '(?i)(?:لدى|عند|التاجر|المتجر|\mat\M|merchant)\s*:?\s*([^\n]{2,60})'));

  hay := coalesce(nullif(lower(v_merchant), ''), low);
  hay := regexp_replace(hay, '(stc ?bank|stc ?pay|بنك stc|stc بنك|اس تي سي باي)', '', 'g');
  cat_name := case
    when hay ~ '(هنقر|hunger|جاهز|jahez|مرسول|mrsool|تويو|toyou|نينجا|\mninja\M|كيتا|keeta|chefz|شفز)' then 'تطبيقات التوصيل'
    when hay ~ '(كوفي|كافيه|كافي|قهوة|مقهى|cafe|café|coffee|starbucks|ستاربكس|مطعم|مطاعم|restaurant|البيك|albaik|mcdonald|ماكدونالدز|\mkudu\M|كودو|herfy|هرفي|barns|بارنز|dunkin|دانكن|pizza|بيتزا|burger|برجر|شاورما|shawarma|\mkfc\M|كنتاكي|subway|domino|دومينوز|tim hortons|هاف مليون|half million|krispy|كرسبي|مخبز|bakery|حلويات)' then 'المطاعم والمقاهي'
    when hay ~ '(دانوب|danube|بنده|\mpanda\M|عثيم|othaim|كارفور|carrefour|تميمي|tamimi|لولو|\mlulu\M|نستو|nesto|ماركت|\mmarket\M|supermarket|hypermarket|هايبر|تموينات|سوبر|بقالة|grocery)' then 'البقالة والسوبرماركت'
    when hay ~ '(amazon|امازون|أمازون|noon\.com|\mnoon\M|نون|shein|شي ان|ikea|ايكيا|\mextra\M|اكسترا|jarir|جرير|centrepoint|سنتربوينت|namshi|نمشي|trendyol|ترينديول)' then 'التسوق والمشتريات'
    when hay ~ '(\mstc\M|mobily|موبايلي|\mzain\M|كهرباء|electric|\msec\M|المياه|netflix|نتفلكس|shahid|شاهد|spotify|سبوتيفاي|apple\.com|icloud|سداد|sadad|فاتورة|\mosn\M|youtube|anghami|أنغامي|disney|starzplay|chatgpt|openai)' then 'الفواتير والاشتراكات'
    when hay ~ '(بنزين|وقود|fuel|petrol|sasco|ساسكو|aldrees|الدريس|petromin|بترومين|نفط|محطة|مغسلة|car wash|ورشة|قطع غيار|إطارات|اطارات|tyres|tires)' then 'مصاريف السيارة'
    when hay ~ '(صيدلي|pharma|nahdi|النهدي|الدواء|dawaa|whites|وايتس|مستشفى|hospital|clinic|عيادة|عيادات|مستوصف|medical|طبي|مختبر|\mlab\M|dental|اسنان|أسنان|بصريات|optic)' then 'الصحة والصيدليات'
    else 'مصاريف أخرى'
  end;
  cat_icon := case cat_name
    when 'تطبيقات التوصيل' then 'bike' when 'المطاعم والمقاهي' then 'food' when 'البقالة والسوبرماركت' then 'cart'
    when 'التسوق والمشتريات' then 'bag' when 'الفواتير والاشتراكات' then 'receipt' when 'مصاريف السيارة' then 'car'
    when 'الصحة والصيدليات' then 'health'
    else 'circle' end;

  -- ---------- Claude (إن كان مفعّلاً، وبحد 60 رسالة في الساعة للعائلة) ----------
  if p_allow_ai and public.ai_enabled()
     and (select count(*) from sms_log where household_id = p_household and source = 'ai' and received_at > now() - interval '1 hour') < 60 then
    select array_agg(name order by sort_order) into v_cats from categories where household_id = p_household and not is_archived;
    select name into v_other from categories where household_id = p_household and not is_archived
      order by (icon = 'circle') desc, sort_order desc limit 1;
    select string_agg(format('- %s ← %s', r.merchant_label, c.name), E'\n') into v_learned
    from (select * from merchant_rules where household_id = p_household order by updated_at desc limit 40) r
    join categories c on c.id = r.category_id and not c.is_archived;

    v_ai := public.ai_call('sms',
      $sys$You read Saudi bank and card SMS notifications (Arabic or English) for a family expense tracker and call record_transaction exactly once.

is_purchase:
- true ONLY for a completed payment that takes money out: card / mada / Apple Pay / POS purchases, online purchases, bill payments (سداد/فاتورة), subscriptions, government fees.
- false for OTP/verification codes, deposits, salary, incoming transfers, refunds/reversals, declined/failed/cancelled operations, balance or limit alerts, ads/promotions, card activation or statements, ATM cash withdrawals, transfers to people or between own accounts. Then give ignore_reason as a short Arabic phrase.

Amounts:
- amount_sar = the amount actually charged in Saudi riyals. If the message shows a foreign amount and its SAR equivalent, use the SAR equivalent. If only a foreign amount is shown, set amount_sar to null and fill original_amount and original_currency (ISO code).
- Never use the balance, available amount, credit limit or fees. Digits shown as • are masked balances.

merchant: the clean shop/brand name a person would write, without branch numbers, city, country or terminal codes ("STARBUCKS 1234 JEDDAH SA" → "Starbucks", "HUNGERSTATION RIYADH" → "HungerStation", "مطعم البيك فرع ٣" → "البيك"). Keep Arabic names in Arabic.

category: exactly one of the family's categories (the enum). For a merchant listed under "Learned", always use the learned category. Saudi hints: HungerStation, Jahez, Mrsool, ToYou, Keeta, The Chefz, Ninja → delivery apps; Panda, Danube, Othaim, Carrefour, Tamimi, Lulu, Nesto, Farm, Bin Dawood → groceries; cafes, restaurants, bakeries, sweets → restaurants & cafes; STC, Mobily, Zain, SEC electricity, National Water, Netflix, Shahid, Spotify, Apple, Google, iCloud → bills & subscriptions; Aldrees, SASCO, Petromin, Naft, car wash, workshops, tyres → car; Amazon, Noon, Shein, IKEA, Jarir, Extra, Namshi, Centrepoint → shopping; Nahdi, Al-Dawaa, Whites, pharmacies, clinics, hospitals, labs, dentists, opticians → health.
Use "__new__" ONLY when the purchase clearly belongs to a common spending area that none of the categories covers (for example health & pharmacies, education, travel, kids) — never for a single merchant and never for a near-duplicate of an existing category. Then fill new_category with a short Arabic name (2–3 words) and an icon from its enum. When unsure, use the family's "other" category.

date: the transaction date as YYYY-MM-DD if the message states it (Gregorian), else null.
card_last4: last 4 digits of the card if shown.
card_type: the card network/scheme — mada (Saudi debit network, often written مدى or mada), visa, mastercard, amex, or other; null if unknown.
card_kind: debit or credit (ائتمانية/credit = credit; مدى and "حساب" are debit); null if unknown.
channel: how it was paid — apple_pay (Apple Pay / ابل باي / Apple Wallet), pos (in-store POS / نقاط البيع), online (إنترنت / online / e-commerce), bill_payment (سداد), or other.
confidence: 0 to 1.$sys$,
      format(E'Today: %s (Asia/Riyadh)\n"Other" category: %s\nLearned (merchant ← category):\n%s\n\nMessage:\n<<<\n%s\n>>>',
             v_today, coalesce(v_other, '-'), coalesce(v_learned, '- (none yet)'), public.sms_mask(msg)),
      jsonb_build_object(
        'name', 'record_transaction',
        'description', 'Record what the bank SMS says.',
        'input_schema', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'is_purchase',       jsonb_build_object('type', 'boolean'),
            'ignore_reason',     jsonb_build_object('type', 'string'),
            'amount_sar',        jsonb_build_object('type', jsonb_build_array('number', 'null')),
            'original_amount',   jsonb_build_object('type', jsonb_build_array('number', 'null')),
            'original_currency', jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'merchant',          jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'category',          jsonb_build_object('type', 'string', 'enum', to_jsonb(coalesce(v_cats, '{}') || '__new__'::text)),
            'new_category',      jsonb_build_object('type', jsonb_build_array('object', 'null'), 'properties', jsonb_build_object(
                                   'name', jsonb_build_object('type', 'string'),
                                   'icon', jsonb_build_object('type', 'string', 'enum', to_jsonb(public.allowed_icons()))),
                                   'required', jsonb_build_array('name', 'icon')),
            'date',              jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'card_last4',        jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'card_type',         jsonb_build_object('type', jsonb_build_array('string', 'null'),
                                   'enum', jsonb_build_array('mada', 'visa', 'mastercard', 'amex', 'other', null)),
            'card_kind',         jsonb_build_object('type', jsonb_build_array('string', 'null'), 'enum', jsonb_build_array('debit', 'credit', null)),
            'channel',           jsonb_build_object('type', jsonb_build_array('string', 'null'),
                                   'enum', jsonb_build_array('apple_pay', 'pos', 'online', 'bill_payment', 'other', null)),
            'confidence',        jsonb_build_object('type', 'number')),
          'required', jsonb_build_array('is_purchase', 'category', 'confidence'))),
      500);
    if v_ai is null then v_ai_note := 'تعذّر الذكاء الاصطناعي، استُخدمت القراءة المحلية'; end if;
  end if;

  if v_ai is not null then
    if (v_ai->>'is_purchase') = 'false' then
      return jsonb_build_object('status', 'ignored', 'source', 'ai',
        'reason', coalesce(nullif(btrim(v_ai->>'ignore_reason'), ''), 'ليست عملية شراء'),
        'fallback_amount', amt_text);
    end if;
    v_source := 'ai';
    if coalesce(v_ai->>'amount_sar', '') ~ '^[0-9]+(\.[0-9]+)?$' and (v_ai->>'amount_sar')::numeric > 0 then
      amt_text := v_ai->>'amount_sar';
    elsif coalesce(v_ai->>'original_amount', '') ~ '^[0-9]+(\.[0-9]+)?$' then
      -- عملات مربوطة بسعر ثابت: تحويل تقريبي (البنك قد يضيف رسوماً بسيطة)
      v_rate := case upper(v_ai->>'original_currency')
        when 'USD' then 3.75 when 'AED' then 1.0211 when 'BHD' then 9.9734 when 'QAR' then 1.0302
        when 'OMR' then 9.7403 when 'JOD' then 5.2891 when 'SAR' then 1 else null end;
      if v_rate is not null then
        amt_text := round((v_ai->>'original_amount')::numeric * v_rate, 2)::text;
        if v_rate <> 1 then v_meta := v_meta || '{"approx": true}'; end if;
      elsif v_foreign then
        amt_text := null;
      end if;
    end if;
    v_merchant := coalesce(nullif(btrim(v_ai->>'merchant'), ''), v_merchant);
    cat_name := coalesce(v_ai->>'category', cat_name);
    cat_icon := null;
    if coalesce(v_ai->>'date', '') ~ '^\d{4}-\d{2}-\d{2}$' then
      begin
        if (v_ai->>'date')::date between v_today - 30 and v_today then v_date := (v_ai->>'date')::date; end if;
      exception when others then null; end;
    end if;
    v_meta := v_meta || jsonb_strip_nulls(jsonb_build_object(
      'card_last4', nullif(right(regexp_replace(coalesce(v_ai->>'card_last4', ''), '[^0-9]', '', 'g'), 4), ''),
      'card_type', v_ai->>'card_type',
      'card_kind', case when v_ai->>'card_type' = 'mada' then 'debit' else v_ai->>'card_kind' end,
      'channel', v_ai->>'channel',
      'confidence', v_ai->'confidence',
      'original_amount', v_ai->'original_amount',
      'original_currency', v_ai->>'original_currency'));
    v_new := v_ai->'new_category';
  end if;

  if amt_text is null then
    return jsonb_build_object('status', 'ignored', 'source', v_source,
      'reason', case when v_foreign then 'عملة أجنبية بدون مبلغ بالريال، أضفها يدوياً' else 'لم أجد المبلغ' end);
  end if;
  v_amount := round(amt_text::numeric * 100)::bigint;
  if v_amount <= 0 or v_amount > 100000000000 then
    return jsonb_build_object('status', 'ignored', 'reason', 'مبلغ غير منطقي', 'source', v_source);
  end if;

  v_key := public.normalize_merchant(v_merchant);

  -- 1) قاعدة تعلّمها التطبيق منكم لهذا المتجر: تتقدم على كل شيء
  if v_key is not null then
    select r.category_id, c.name into v_cat_id, v_cat_name
    from merchant_rules r join categories c on c.id = r.category_id
    where r.household_id = p_household and r.merchant_key = v_key and not c.is_archived;
    if v_cat_id is not null then v_meta := v_meta || '{"rule": true}'; end if;
  end if;

  -- 2) تصنيف جديد اقترحه Claude (بضوابط تمنع العشوائية والتكرار)
  if v_cat_id is null and cat_name = '__new__' then
    v_new_name := btrim(v_new->>'name');
    if p_dry_run then
      select id, name into v_cat_id, v_cat_name from categories
      where household_id = p_household and not is_archived
        and public.normalize_category(name) = public.normalize_category(v_new_name) limit 1;
      if v_cat_id is null and v_new_name is not null then v_meta := v_meta || jsonb_build_object('new_category', v_new_name); end if;
    elsif v_new_name is not null and coalesce((v_ai->>'confidence')::numeric, 0) >= 0.7 then
      v_cat_id := public.safe_create_category(p_household, v_new_name, v_new->>'icon', null, 'ai');
      if v_cat_id is not null then
        select name into v_cat_name from categories where id = v_cat_id;
        v_meta := v_meta || jsonb_build_object('created_category', v_cat_name);
      end if;
    end if;
  end if;

  -- 3) بالاسم، ثم بالأيقونة (لو غيّرتم الاسم)، ثم «أخرى»
  if v_cat_id is null and not (v_meta ? 'new_category') then
    select c.id, c.name into v_cat_id, v_cat_name
    from categories c
    where c.household_id = p_household and not c.is_archived
    order by (c.name = cat_name) desc,
             (public.normalize_category(c.name) = public.normalize_category(cat_name)) desc,
             (c.icon = coalesce(cat_icon, '-')) desc, (c.icon = 'circle') desc, c.sort_order desc
    limit 1;
  end if;
  if v_cat_id is null and not (v_meta ? 'new_category') then
    return jsonb_build_object('status', 'ignored', 'reason', 'لا توجد تصنيفات', 'source', v_source);
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'ok',
    'source', v_source,
    'amount', v_amount,
    'merchant', nullif(v_merchant, ''),
    'merchant_key', v_key,
    'category_id', v_cat_id,
    'category_name', coalesce(v_cat_name, v_meta->>'new_category'),
    'date', v_date,
    'meta', v_meta || jsonb_build_object('source', v_source),
    'note', v_ai_note));
end $$;

-- نص إشعار الاختصار (يذكر المبلغ الأصلي عند التحويل من عملة أجنبية)
create or replace function public.sms_notice(r jsonb)
returns text language sql immutable as $$
  select format('تم تسجيل %s%s ر.س · %s ← %s%s',
    case when (r->'meta'->>'approx') = 'true' then '≈' else '' end,
    to_char((r->>'amount')::numeric / 100.0, 'FM999999990.00'),
    coalesce(r->>'merchant', 'رسالة البنك'),
    r->>'category_name',
    case when r->'meta' ? 'original_currency'
         then format(' (%s %s)', r->'meta'->>'original_amount', r->'meta'->>'original_currency') else '' end)
$$;

-- =====================================================================
--  الاختصار: يستقبل الرسالة ويسجّلها
-- =====================================================================
create or replace function public.sms_expense(token text, message text)
returns text
language plpgsql security definer set search_path = public
set statement_timeout to '40s'
as $$
declare
  t        public.sms_tokens;
  v_hash   text;
  r        jsonb;
  v_amount bigint;
  v_date   date;
  v_label  text;
  v_linked text;
  v_id     uuid;
  v_logmsg text;
begin
  -- الرمز 64 حرفاً hex: نتجاهل أي مسافة أو سطر جديد أو حروف كبيرة دخلت مع اللصق
  select * into t from sms_tokens s
  where s.token = lower(regexp_replace(coalesce(sms_expense.token, ''), '[^0-9A-Fa-f]', '', 'g'));
  if t.user_id is null
     or not exists (select 1 from household_members hm where hm.user_id = t.user_id and hm.household_id = t.household_id) then
    raise exception 'رمز غير صحيح';
  end if;
  if message is null or btrim(message) = '' or length(message) > 2000 then
    return 'تجاهل: رسالة فارغة';
  end if;

  v_hash := md5(t.user_id::text || message);
  if exists (select 1 from expenses where source_hash = v_hash) then
    insert into sms_log (household_id, user_id, message, status, reason) values (t.household_id, t.user_id, message, 'duplicate', 'مسجّلة مسبقاً');
    return 'مسجّلة مسبقاً';
  end if;

  r := public.sms_parse(t.household_id, message, true, false);
  v_logmsg := case when (r->>'private') = 'true' then null else message end;

  if r->>'status' = 'ignored' then
    insert into sms_log (household_id, user_id, message, status, reason, source, result)
    values (t.household_id, t.user_id, v_logmsg, 'ignored', r->>'reason', r->>'source', r);
    return 'تجاهل: ' || (r->>'reason');
  end if;

  v_amount := (r->>'amount')::bigint;
  v_date   := (r->>'date')::date;
  v_label  := coalesce(r->>'merchant', 'رسالة البنك');

  -- مصروف ثابت سجّلتم دفعه يدوياً في نفس الشهر بنفس المبلغ: نربط الرسالة به بدل التكرار
  update expenses e set source_hash = v_hash
  where e.id = (
    select x.id from expenses x
    where x.household_id = t.household_id and x.recurring_id is not null and x.source_hash is null
      and x.amount = v_amount and x.recurring_period = date_trunc('month', v_date)::date
    order by x.created_at limit 1)
  returning e.description into v_linked;
  if found then
    insert into sms_log (household_id, user_id, message, status, reason, source, result)
    values (t.household_id, t.user_id, v_logmsg, 'linked', 'مربوطة بمصروف ثابت: ' || v_linked, r->>'source', r);
    return format('مسجّلة مسبقاً كمصروف ثابت: %s', v_linked);
  end if;

  insert into expenses (household_id, category_id, amount, expense_date, description, created_by, source_hash, merchant_key, sms_meta)
  values (t.household_id, (r->>'category_id')::uuid, v_amount, v_date, left('📩 ' || v_label, 200), t.user_id, v_hash,
          r->>'merchant_key', (r->'meta') || jsonb_strip_nulls(jsonb_build_object('merchant', r->>'merchant')))
  on conflict (source_hash) do nothing
  returning id into v_id;
  if v_id is null then return 'مسجّلة مسبقاً'; end if;

  insert into sms_log (household_id, user_id, message, status, reason, source, expense_id, result)
  values (t.household_id, t.user_id, v_logmsg, 'recorded', r->>'note', r->>'source', v_id, r);
  delete from sms_log where household_id = t.household_id and received_at < now() - interval '180 days';

  return public.sms_notice(r);
end $$;

revoke all on function public.sms_expense(text, text) from public;
grant execute on function public.sms_expense(text, text) to anon, authenticated;

-- نسخة تقبل أسماء حقول فيها مسافات من كيبورد الآيفون
create or replace function public.sms_expense(jsonb)
returns text language plpgsql security definer set search_path = public
set statement_timeout to '40s'
as $$
declare k text; v_token text; v_msg text;
begin
  for k in select jsonb_object_keys($1) loop
    if lower(trim(k)) = 'token' then v_token := $1->>k; end if;
    if lower(trim(k)) = 'message' then v_msg := $1->>k; end if;
  end loop;
  return public.sms_expense(v_token, v_msg);
end $$;
revoke all on function public.sms_expense(jsonb) from public;
grant execute on function public.sms_expense(jsonb) to anon, authenticated;

-- =====================================================================
--  للتطبيق
-- =====================================================================
create or replace function public.my_household()
returns uuid language sql stable security definer set search_path = public as $$
  select household_id from household_members where user_id = auth.uid()
$$;

-- «جرّب رسالة»: يقرأ الرسالة كما سيقرؤها الاختصار، بدون تسجيل
create or replace function public.sms_preview(p_message text)
returns jsonb language plpgsql security definer set search_path = public
set statement_timeout to '40s'
as $$
declare v_h uuid := public.my_household();
begin
  if v_h is null then raise exception 'not in a household'; end if;
  if p_message is null or btrim(p_message) = '' then return jsonb_build_object('status', 'ignored', 'reason', 'رسالة فارغة'); end if;
  return public.sms_parse(v_h, left(p_message, 2000), true, true);
end $$;

create or replace function public.ai_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare h ai_health; v_h uuid := public.my_household();
begin
  if v_h is null then raise exception 'not in a household'; end if;
  select * into h from ai_health where id = 1;
  return jsonb_build_object(
    'enabled', public.ai_enabled(),
    'model', public.ai_model('sms'),
    'last_ok_at', h.last_ok_at,
    'last_error_at', h.last_error_at,
    'last_error', h.last_error,
    'ai_messages_24h', (select count(*) from sms_log where household_id = v_h and source = 'ai' and received_at > now() - interval '24 hours'));
end $$;

-- يتعلّم تلقائياً: تغيير تصنيف عملية جاءت من رسالة بنك = قاعدة لهذا المتجر
create or replace function public.learn_merchant_rule()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.merchant_key is not null and new.category_id is distinct from old.category_id and new.recurring_id is null
     and coalesce(current_setting('masareef.no_learn', true), '') <> 'on' then
    insert into merchant_rules (household_id, merchant_key, merchant_label, category_id, created_by)
    values (new.household_id, new.merchant_key,
            coalesce(nullif(new.sms_meta->>'merchant', ''), regexp_replace(coalesce(new.description, new.merchant_key), '^📩\s*', '')),
            new.category_id, auth.uid())
    on conflict (household_id, merchant_key)
    do update set category_id = excluded.category_id, updated_at = now(), created_by = excluded.created_by;
  end if;
  return new;
end $$;
drop trigger if exists expenses_learn on public.expenses;
create trigger expenses_learn after update of category_id on public.expenses
for each row execute function public.learn_merchant_rule();

-- =====================================================================
--  تنظيم التصنيفات بالذكاء الاصطناعي
-- =====================================================================

-- ملخص التصنيفات والمتاجر الذي يُرسل لـ Claude
create or replace function public.category_stats(p_household uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with exp as (
    select e.*, coalesce(nullif(e.sms_meta->>'merchant', ''), regexp_replace(coalesce(e.description, ''), '^📩\s*', '')) as label
    from expenses e where e.household_id = p_household
  )
  select jsonb_build_object(
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', c.name, 'icon', c.icon, 'archived', c.is_archived, 'is_other', c.icon = 'circle', 'is_core', c.is_core,
        'created_by_ai', c.created_by_ai,
        'expenses_total', (select count(*) from exp where exp.category_id = c.id),
        'expenses_90d', (select count(*) from exp where exp.category_id = c.id and exp.expense_date > current_date - 90),
        'amount_90d_sar', (select coalesce(sum(amount), 0) / 100 from exp where exp.category_id = c.id and exp.expense_date > current_date - 90),
        'recurring', (select count(*) from recurring_expenses r where r.category_id = c.id),
        'top_merchants', (select coalesce(jsonb_agg(l), '[]') from (
            select label as l from exp where exp.category_id = c.id and label <> '' group by label order by count(*) desc limit 8) s)
      ) order by c.sort_order)
      from categories c where c.household_id = p_household), '[]'),
    'merchants_in_several_categories', coalesce((
      select jsonb_agg(jsonb_build_object('merchant', m.label, 'categories', m.cats))
      from (select min(label) as label, jsonb_agg(distinct c.name) as cats
            from exp join categories c on c.id = exp.category_id
            where exp.merchant_key is not null
            group by exp.merchant_key having count(distinct exp.category_id) > 1 limit 30) m), '[]')
  )
$$;

-- يطلب من Claude خطة تنظيم (لا يطبّق شيئاً)
create or replace function public.ai_category_plan()
returns jsonb language plpgsql security definer set search_path = public
set statement_timeout to '70s'
as $$
declare v_h uuid := public.my_household(); v_names text[]; v_plan jsonb;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  if not public.ai_enabled() then raise exception 'ai not enabled'; end if;
  select array_agg(name) into v_names from categories where household_id = v_h;

  v_plan := public.ai_call('plan',
    $sys$You organise the expense categories of a Saudi family budget app. Goal: a clean, unified, reasonably small set of clear Arabic categories, without losing any data. You receive every category with its usage and top merchants, plus merchants that appear in several categories.
Propose only changes that clearly help; an empty list of operations is a valid answer. Allowed operations:
- merge (from → into): duplicates or near-duplicates (e.g. "مطاعم" and "المطاعم والمقاهي"). Everything moves into "into" and "from" is archived.
- move_merchant (merchant → into): put all expenses of one merchant into the right category, to unify inconsistent merchants or rescue merchants sitting in the "other" category.
- create (name, icon): only when at least 3 expenses (in "other" or spread elsewhere) clearly form a common spending area with no category; then add move_merchant operations for those merchants.
- rename (from → new_name): only for unclear or awkward names.
- archive (from): family-created categories with no expenses in 90 days and no recurring expenses.
- delete (from): only categories with expenses_total = 0 and recurring = 0.
Core categories (is_core = true) are pinned: never merge them away, rename, archive or delete them — but you may merge other categories INTO them and move merchants into or out of them. Never merge, rename, archive or delete the "other" category (is_other = true). Use the exact existing names. Write summary and reasons in short Arabic.$sys$,
    'Data:' || E'\n' || public.category_stats(v_h)::text,
    jsonb_build_object(
      'name', 'category_plan',
      'description', 'A safe plan to organise the categories.',
      'input_schema', jsonb_build_object(
        'type', 'object',
        'properties', jsonb_build_object(
          'summary', jsonb_build_object('type', 'string'),
          'operations', jsonb_build_object('type', 'array', 'items', jsonb_build_object(
            'type', 'object',
            'properties', jsonb_build_object(
              'op', jsonb_build_object('type', 'string', 'enum', jsonb_build_array('merge', 'move_merchant', 'create', 'rename', 'archive', 'delete')),
              'from', jsonb_build_object('type', 'string', 'enum', to_jsonb(coalesce(v_names, '{}'))),
              'into', jsonb_build_object('type', 'string'),
              'merchant', jsonb_build_object('type', 'string'),
              'name', jsonb_build_object('type', 'string'),
              'new_name', jsonb_build_object('type', 'string'),
              'icon', jsonb_build_object('type', 'string', 'enum', to_jsonb(public.allowed_icons())),
              'reason', jsonb_build_object('type', 'string')),
            'required', jsonb_build_array('op', 'reason')))),
        'required', jsonb_build_array('summary', 'operations'))),
    2500);
  if v_plan is null then raise exception 'ai unavailable'; end if;
  return v_plan;
end $$;

-- تطبيق خطة (من Claude أو من المستخدم) بأمان: كل عملية تُتحقق منها وتُسجَّل للتراجع
create or replace function public.apply_category_plan(p_operations jsonb, p_actor text default 'ai')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_h uuid := public.my_household();
  v_batch uuid := gen_random_uuid();
  op jsonb;
  v_from categories; v_into categories;
  v_ids uuid[]; v_rec uuid[]; v_rules jsonb; v_moves jsonb; v_prev jsonb;
  v_key text; v_new uuid; v_label text;
  v_applied jsonb := '[]'; v_skipped jsonb := '[]';
  v_actor text := case when p_actor = 'user' then 'user' else 'ai' end;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  perform set_config('masareef.no_learn', 'on', true);  -- التنظيم لا يُنشئ قواعد تلقائية من النقل

  for op in select * from jsonb_array_elements(coalesce(p_operations, '[]')) loop
    v_from := null; v_into := null;
    select * into v_from from categories where household_id = v_h and name = op->>'from';
    select * into v_into from categories where household_id = v_h and name = op->>'into';

    case op->>'op'
    when 'create' then
      v_new := public.safe_create_category(v_h, op->>'name', op->>'icon', v_batch, v_actor);
      if v_new is null then v_skipped := v_skipped || jsonb_build_array(op || '{"why":"اسم مكرر أو غير صالح أو وصلنا الحد"}'); continue; end if;

    when 'rename' then
      if v_from.id is null or v_from.icon = 'circle' or v_from.is_core or coalesce(btrim(op->>'new_name'), '') = ''
         or exists (select 1 from categories where household_id = v_h and public.normalize_category(name) = public.normalize_category(op->>'new_name') and id <> v_from.id) then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"غير مسموح أو الاسم مستخدم"}'); continue;
      end if;
      update categories set name = left(btrim(op->>'new_name'), 40) where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'rename', jsonb_build_object('id', v_from.id, 'old_name', v_from.name, 'new_name', btrim(op->>'new_name')), v_actor);

    when 'merge' then
      if v_from.id is null or v_into.id is null or v_from.id = v_into.id or v_from.icon = 'circle' or v_from.is_core or v_into.is_archived then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"غير مسموح (تصنيف أساسي أو غير موجود)"}'); continue;
      end if;
      select coalesce(array_agg(id), '{}') into v_ids from expenses where category_id = v_from.id;
      select coalesce(array_agg(id), '{}') into v_rec from recurring_expenses where category_id = v_from.id;
      select coalesce(jsonb_agg(merchant_key), '[]') into v_rules from merchant_rules where category_id = v_from.id;
      update expenses set category_id = v_into.id where id = any (v_ids);
      update recurring_expenses set category_id = v_into.id where id = any (v_rec);
      update merchant_rules set category_id = v_into.id where category_id = v_from.id;
      update categories set is_archived = true where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'merge', jsonb_build_object('from_id', v_from.id, 'into_id', v_into.id, 'from_name', v_from.name, 'into_name', v_into.name,
              'expense_ids', to_jsonb(v_ids), 'recurring_ids', to_jsonb(v_rec), 'rule_keys', v_rules, 'from_was_archived', v_from.is_archived), v_actor);

    when 'archive' then
      if v_from.id is null or v_from.icon = 'circle' or v_from.is_core or v_from.is_archived then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"غير مسموح (تصنيف أساسي أو غير موجود)"}'); continue;
      end if;
      update categories set is_archived = true where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'archive', jsonb_build_object('id', v_from.id, 'name', v_from.name), v_actor);

    when 'delete' then
      if v_from.id is null or v_from.icon = 'circle' or v_from.is_core then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"تصنيف أساسي مثبّت"}'); continue;
      end if;
      if exists (select 1 from expenses where category_id = v_from.id)
         or exists (select 1 from recurring_expenses where category_id = v_from.id) then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"عليه عمليات، يمكن أرشفته فقط"}'); continue;
      end if;
      select coalesce(jsonb_agg(to_jsonb(r)), '[]') into v_rules from merchant_rules r where category_id = v_from.id;
      delete from categories where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'delete', jsonb_build_object('category', to_jsonb(v_from), 'rules', v_rules), v_actor);

    when 'move_merchant' then
      if v_into.id is not null and v_into.is_archived then v_into := null; end if;
      if v_into.id is null and op ? 'into' then
        -- التصنيف قد يكون أُنشئ في نفس الخطة
        select * into v_into from categories where household_id = v_h and not is_archived
          and public.normalize_category(name) = public.normalize_category(op->>'into');
      end if;
      v_key := public.normalize_merchant(op->>'merchant');
      if v_into.id is null or v_key is null then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"التصنيف أو المتجر غير موجود"}'); continue;
      end if;
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'category_id', category_id)), '[]') into v_moves
      from expenses where household_id = v_h and recurring_id is null and category_id <> v_into.id
        and (merchant_key = v_key or public.normalize_merchant(regexp_replace(coalesce(description, ''), '^📩\s*', '')) = v_key);
      select to_jsonb(r) into v_prev from merchant_rules r where household_id = v_h and merchant_key = v_key;
      update expenses set category_id = v_into.id
      where id in (select (x->>'id')::uuid from jsonb_array_elements(v_moves) x);
      v_label := btrim(op->>'merchant');
      insert into merchant_rules (household_id, merchant_key, merchant_label, category_id, created_by)
      values (v_h, v_key, v_label, v_into.id, auth.uid())
      on conflict (household_id, merchant_key) do update set category_id = excluded.category_id, updated_at = now();
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'move_merchant', jsonb_build_object('merchant_key', v_key, 'merchant', v_label, 'into_id', v_into.id,
              'into_name', v_into.name, 'moves', v_moves, 'previous_rule', v_prev), v_actor);

    else
      v_skipped := v_skipped || jsonb_build_array(op || '{"why":"عملية غير معروفة"}'); continue;
    end case;
    v_applied := v_applied || jsonb_build_array(op);
  end loop;

  perform set_config('masareef.no_learn', '', true);
  return jsonb_build_object('batch_id', case when jsonb_array_length(v_applied) > 0 then v_batch end,
                            'applied', v_applied, 'skipped', v_skipped);
end $$;

-- تراجع كامل عن دفعة تنظيم
create or replace function public.undo_category_batch(p_batch uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_h uuid := public.my_household();
  a category_audit;
  n int := 0;
  x jsonb;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  perform set_config('masareef.no_learn', 'on', true);
  for a in select * from category_audit where household_id = v_h and batch_id = p_batch and undone_at is null order by created_at desc, id desc loop
    case a.op
    when 'create' then
      if exists (select 1 from expenses where category_id = (a.details->>'id')::uuid)
         or exists (select 1 from recurring_expenses where category_id = (a.details->>'id')::uuid) then
        update categories set is_archived = true where id = (a.details->>'id')::uuid;
      else
        delete from categories where id = (a.details->>'id')::uuid;
      end if;
    when 'rename' then
      update categories set name = a.details->>'old_name'
      where id = (a.details->>'id')::uuid
        and not exists (select 1 from categories where household_id = v_h and name = a.details->>'old_name' and id <> (a.details->>'id')::uuid);
    when 'merge' then
      update categories set is_archived = coalesce((a.details->>'from_was_archived')::boolean, false) where id = (a.details->>'from_id')::uuid;
      update expenses set category_id = (a.details->>'from_id')::uuid
      where id in (select (v #>> '{}')::uuid from jsonb_array_elements(a.details->'expense_ids') v)
        and category_id = (a.details->>'into_id')::uuid;
      update recurring_expenses set category_id = (a.details->>'from_id')::uuid
      where id in (select (v #>> '{}')::uuid from jsonb_array_elements(a.details->'recurring_ids') v)
        and category_id = (a.details->>'into_id')::uuid;
      update merchant_rules set category_id = (a.details->>'from_id')::uuid
      where household_id = v_h and merchant_key in (select v #>> '{}' from jsonb_array_elements(a.details->'rule_keys') v)
        and category_id = (a.details->>'into_id')::uuid;
    when 'archive' then
      update categories set is_archived = false where id = (a.details->>'id')::uuid;
    when 'delete' then
      insert into categories select * from jsonb_populate_record(null::categories, a.details->'category')
      on conflict do nothing;
      for x in select * from jsonb_array_elements(a.details->'rules') loop
        insert into merchant_rules select * from jsonb_populate_record(null::merchant_rules, x) on conflict do nothing;
      end loop;
    when 'move_merchant' then
      update expenses e set category_id = (m->>'category_id')::uuid
      from jsonb_array_elements(a.details->'moves') m
      where e.id = (m->>'id')::uuid and e.category_id = (a.details->>'into_id')::uuid
        and exists (select 1 from categories c where c.id = (m->>'category_id')::uuid);
      if a.details->'previous_rule' is null or jsonb_typeof(a.details->'previous_rule') = 'null' then
        delete from merchant_rules where household_id = v_h and merchant_key = a.details->>'merchant_key';
      else
        update merchant_rules set category_id = (a.details->'previous_rule'->>'category_id')::uuid,
                                  merchant_label = a.details->'previous_rule'->>'merchant_label'
        where household_id = v_h and merchant_key = a.details->>'merchant_key';
      end if;
    else null;
    end case;
    update category_audit set undone_at = now() where id = a.id;
    n := n + 1;
  end loop;
  perform set_config('masareef.no_learn', '', true);
  return n;
end $$;

-- ---------- الصلاحيات ----------
-- الدوال الداخلية لا تُستدعى من الموقع (Supabase يمنحها تلقائياً لـ anon/authenticated)
revoke all on function public.ai_call(text, text, text, jsonb, int)              from public, anon, authenticated;
revoke all on function public.sms_parse(uuid, text, boolean, boolean)           from public, anon, authenticated;
revoke all on function public.safe_create_category(uuid, text, text, uuid, text) from public, anon, authenticated;
revoke all on function public.category_stats(uuid)                              from public, anon, authenticated;
revoke all on function public.ai_model(text)                                    from public, anon, authenticated;
revoke all on function public.ai_enabled()                                      from public, anon, authenticated;
revoke all on function public.learn_merchant_rule()                             from public, anon, authenticated;
revoke all on function public.sms_preview(text)            from public, anon;
revoke all on function public.ai_status()                  from public, anon;
revoke all on function public.ai_category_plan()           from public, anon;
revoke all on function public.apply_category_plan(jsonb, text) from public, anon;
revoke all on function public.undo_category_batch(uuid)    from public, anon;
revoke all on function public.my_household()               from public, anon;
grant execute on function public.sms_preview(text)             to authenticated;
grant execute on function public.ai_status()                   to authenticated;
grant execute on function public.ai_category_plan()            to authenticated;
grant execute on function public.apply_category_plan(jsonb, text) to authenticated;
grant execute on function public.undo_category_batch(uuid)     to authenticated;
grant execute on function public.my_household()                to authenticated;

notify pgrst, 'reload schema';


-- ───────────── 0007_core_and_reports.sql ─────────────
-- =====================================================================
--  0007: التصنيفات الأساسية المثبّتة + تصنيف الصحة + تقرير الشهر بالذكاء الاصطناعي
-- =====================================================================

-- ---------- إعادة حساب مفاتيح المتاجر بعد تصحيح توحيد الحروف (ة/ى) ----------
update public.expenses
   set merchant_key = public.normalize_merchant(coalesce(nullif(sms_meta->>'merchant', ''), regexp_replace(coalesce(description, ''), '^📩\s*', '')))
 where merchant_key is not null;
do $$
declare r record;
begin
  for r in select * from public.merchant_rules loop
    if public.normalize_merchant(r.merchant_label) is distinct from r.merchant_key then
      begin
        update public.merchant_rules set merchant_key = public.normalize_merchant(r.merchant_label)
        where household_id = r.household_id and merchant_key = r.merchant_key;
      exception when unique_violation then
        delete from public.merchant_rules where household_id = r.household_id and merchant_key = r.merchant_key;
      end;
    end if;
  end loop;
end $$;

-- ---------- التصنيفات الأساسية ----------
update public.categories set is_core = true
where name in ('البقالة والسوبرماركت', 'المطاعم والمقاهي', 'تطبيقات التوصيل', 'الفواتير والاشتراكات',
               'التسوق والمشتريات', 'مصاريف السيارة', 'راتب العاملة المنزلية', 'راتب السائق', 'مصاريف أخرى',
               'الصحة والصيدليات');

-- تصنيف الصحة للعائلات الحالية (قبل «مصاريف أخرى»)
do $$
declare h record; v_other int;
begin
  for h in select id from public.households loop
    if not exists (select 1 from public.categories c where c.household_id = h.id
                   and public.normalize_category(c.name) in ('صحه صيدليات', 'صحه', 'صيدليات', 'صحيه')) then
      select sort_order into v_other from public.categories where household_id = h.id and icon = 'circle' order by sort_order desc limit 1;
      update public.categories set sort_order = sort_order + 1 where household_id = h.id and sort_order >= coalesce(v_other, 999);
      insert into public.categories (household_id, name, icon, color, sort_order, is_core)
      values (h.id, 'الصحة والصيدليات', 'health', '#DC2626', coalesce(v_other, 10), true);
    else
      update public.categories set is_core = true where household_id = h.id
        and public.normalize_category(name) in ('صحه صيدليات', 'صحه', 'صيدليات', 'صحيه');
    end if;
  end loop;
end $$;

-- العائلات الجديدة: نفس التصنيفات الأساسية مثبّتة
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

  insert into categories (household_id, name, icon, color, sort_order, is_core) values
    (v_id, 'البقالة والسوبرماركت', 'cart',     '#0E6B58', 1,  true),
    (v_id, 'المطاعم والمقاهي',     'food',     '#C2410C', 2,  true),
    (v_id, 'تطبيقات التوصيل',      'bike',     '#DB2777', 3,  true),
    (v_id, 'الفواتير والاشتراكات', 'receipt',  '#2563EB', 4,  true),
    (v_id, 'التسوق والمشتريات',    'bag',      '#7C3AED', 5,  true),
    (v_id, 'مصاريف السيارة',       'car',      '#475569', 6,  true),
    (v_id, 'الصحة والصيدليات',     'health',   '#DC2626', 7,  true),
    (v_id, 'راتب العاملة المنزلية','broom',    '#B45309', 8,  true),
    (v_id, 'راتب السائق',          'steering', '#0891B2', 9,  true),
    (v_id, 'مصاريف أخرى',          'circle',   '#64748B', 10, true);
  return v_id;
end $$;
revoke execute on function public.create_household(text, text) from anon, public;
grant  execute on function public.create_household(text, text) to authenticated;

-- التصنيف الأساسي لا يُحذف حتى يدوياً (يمكن تغيير اسمه أو لونه فقط)
create or replace function public.protect_core_category()
returns trigger language plpgsql as $$
begin
  if old.is_core then raise exception 'core category'; end if;
  return old;
end $$;
drop trigger if exists categories_protect_core on public.categories;
create trigger categories_protect_core before delete on public.categories
for each row execute function public.protect_core_category();

-- =====================================================================
--  تقرير الشهر: كل الأرقام تُحسب هنا بدقة، وClaude يكتب القراءة والملاحظات فقط
-- =====================================================================
create table if not exists public.ai_reports (
  household_id uuid not null references public.households(id) on delete cascade,
  month        date not null,
  facts        jsonb not null,
  content      jsonb not null,
  created_at   timestamptz not null default now(),
  primary key (household_id, month)
);
alter table public.ai_reports enable row level security;
drop policy if exists ai_reports_select on public.ai_reports;
create policy ai_reports_select on public.ai_reports for select to authenticated using (public.is_member(household_id));
revoke insert, update, delete on public.ai_reports from anon, authenticated;

-- الحقائق الرقمية للشهر (بالريال)
create or replace function public.month_facts(p_household uuid, p_month date)
returns jsonb language sql stable security definer set search_path = public as $$
  with params as (
    select date_trunc('month', p_month)::date as m,
           (date_trunc('month', p_month) + interval '1 month - 1 day')::date as m_end,
           (now() at time zone 'Asia/Riyadh')::date as today
  ), p as (
    select m, m_end, today,
           least(m_end, today) as upto,
           (m - interval '1 month')::date as pm,
           (m - interval '1 day')::date as pm_end,
           -- نفس الفترة من الشهر السابق
           least((m - interval '1 month')::date + (least(m_end, today) - m), (m - interval '1 day')::date) as pm_same
    from params
  ), e as (
    select x.*, c.name as cat, coalesce(nullif(x.sms_meta->>'merchant', ''), regexp_replace(coalesce(x.description, ''), '^📩\s*', '')) as label
    from expenses x join categories c on c.id = x.category_id
    where x.household_id = p_household
  ), cur as (select e.* from e, p where e.expense_date between p.m and p.m_end),
     prev as (select e.* from e, p where e.expense_date between p.pm and p.pm_end),
     prev_same as (select e.* from e, p where e.expense_date between p.pm and p.pm_same)
  select jsonb_build_object(
    'month', (select m from p),
    'is_current_month', (select today between m and m_end from p),
    'days_elapsed', (select upto - m + 1 from p),
    'days_in_month', (select m_end - m + 1 from p),
    'total_sar', (select round(coalesce(sum(amount), 0) / 100.0, 2) from cur),
    'transactions', (select count(*) from cur),
    'previous_month_total_sar', (select round(coalesce(sum(amount), 0) / 100.0, 2) from prev),
    'previous_month_same_period_sar', (select round(coalesce(sum(amount), 0) / 100.0, 2) from prev_same),
    'daily_average_sar', (select round(coalesce(sum(amount), 0) / 100.0 / greatest((select upto - m + 1 from p), 1), 2) from cur),
    'projected_month_total_sar', (select case when today between m and m_end and (upto - m + 1) >= 3
                                   then round(coalesce((select sum(amount) from cur), 0) / 100.0 / (upto - m + 1) * (m_end - m + 1), 2) end from p),
    'monthly_budget_sar', (select monthly_budget / 100.0 from households where id = p_household),
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', cat, 'sar', sar, 'count', n, 'previous_month_sar', prev_sar) order by sar desc), '[]')
                    from (select coalesce(a.cat, b.cat) as cat, coalesce(a.sar, 0) as sar, coalesce(a.n, 0) as n, coalesce(b.sar, 0) as prev_sar
                          from (select cat, round(sum(amount) / 100.0, 2) as sar, count(*) as n from cur group by cat) a
                          full join (select cat, round(sum(amount) / 100.0, 2) as sar from prev group by cat) b on a.cat = b.cat) t),
    'top_merchants', (select coalesce(jsonb_agg(jsonb_build_object('merchant', label, 'sar', sar, 'count', n) order by sar desc), '[]')
                      from (select label, round(sum(amount) / 100.0, 2) as sar, count(*) as n from cur where label <> '' group by label order by 2 desc limit 8) t),
    'by_card', (select coalesce(jsonb_agg(jsonb_build_object('card', card, 'sar', sar, 'count', n) order by sar desc), '[]')
                from (select coalesce(nullif(concat_ws(' ', sms_meta->>'card_nickname', sms_meta->>'bank', sms_meta->>'card_type', sms_meta->>'card_kind', sms_meta->>'card_last4'), ''),
                                      case when sms_meta is null then 'manual' else 'bank_sms_unknown_card' end) as card,
                             round(sum(amount) / 100.0, 2) as sar, count(*) as n from cur group by 1) t),
    'by_bank', (select coalesce(jsonb_agg(jsonb_build_object('bank', bank, 'sar', sar, 'count', n) order by sar desc), '[]')
                from (select coalesce(sms_meta->>'bank', case when sms_meta is null then 'manual' else 'unknown' end) as bank,
                             round(sum(amount) / 100.0, 2) as sar, count(*) as n from cur group by 1) t),
    'foreign_currency', (select coalesce(jsonb_agg(jsonb_build_object('currency', cur_code, 'original', orig, 'sar', sar, 'count', n)), '[]')
                from (select sms_meta->>'original_currency' as cur_code, sum((sms_meta->>'original_amount')::numeric) as orig,
                             round(sum(amount) / 100.0, 2) as sar, count(*) as n
                      from cur where sms_meta ? 'original_currency' group by 1) t),
    'by_member', (select coalesce(jsonb_agg(jsonb_build_object('member', who, 'sar', sar) order by sar desc), '[]')
                  from (select coalesce(hm.display_name, 'عضو سابق') as who, round(sum(cur.amount) / 100.0, 2) as sar
                        from cur left join household_members hm on hm.user_id = cur.created_by and hm.household_id = p_household group by 1) t),
    'largest', (select coalesce(jsonb_agg(jsonb_build_object('merchant', label, 'category', cat, 'sar', round(amount / 100.0, 2), 'date', expense_date) order by amount desc), '[]')
                from (select * from cur order by amount desc limit 5) t),
    'recurring', (select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'sar', r.amount / 100.0,
                    'paid', exists (select 1 from expenses x, p where x.recurring_id = r.id and x.recurring_period = p.m))), '[]')
                  from recurring_expenses r where r.household_id = p_household and r.is_active),
    'possible_subscriptions', (select coalesce(jsonb_agg(jsonb_build_object('merchant', label, 'months', months, 'last_sar', last_sar)), '[]')
                  from (select min(label) as label, count(distinct date_trunc('month', expense_date)) as months,
                               (array_agg(amount order by expense_date desc))[1] / 100.0 as last_sar
                        from e, p where e.expense_date >= (p.m - interval '3 months') and e.merchant_key is not null and e.recurring_id is null
                        group by e.merchant_key
                        having count(distinct date_trunc('month', expense_date)) >= 2
                           and max(amount) <= min(amount) * 1.15) t),
    'last_6_months', (select coalesce(jsonb_agg(jsonb_build_object('month', mo, 'sar', sar) order by mo), '[]')
                      from (select date_trunc('month', expense_date)::date as mo, round(sum(amount) / 100.0, 2) as sar
                            from e, p where e.expense_date >= (p.m - interval '5 months') and e.expense_date <= p.m_end group by 1) t)
  )
$$;

create or replace function public.ai_month_report(p_month date, p_refresh boolean default false)
returns jsonb language plpgsql security definer set search_path = public
set statement_timeout to '70s'
as $$
declare
  v_h uuid := public.my_household();
  v_m date := date_trunc('month', p_month)::date;
  v_facts jsonb;
  v_content jsonb;
  r ai_reports;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  select * into r from ai_reports where household_id = v_h and month = v_m;
  if r.household_id is not null and not p_refresh then
    return jsonb_build_object('content', r.content, 'facts', r.facts, 'created_at', r.created_at, 'cached', true);
  end if;
  if not public.ai_enabled() then raise exception 'ai not enabled'; end if;

  v_facts := public.month_facts(v_h, v_m);
  if (v_facts->>'transactions')::int = 0 then raise exception 'no expenses'; end if;

  v_content := public.ai_call('report',
    $sys$You are a sharp, friendly family-finance analyst for a Saudi household. You receive exact facts for one month (all amounts in SAR, already computed by the database). Write a short Arabic report (Saudi-friendly, clear, no fluff).
Rules:
- Use ONLY the numbers given. Never invent, estimate or recompute numbers beyond simple differences/percentages of the given values; round to whole riyals in text.
- If is_current_month is true the month is not finished: compare with previous_month_same_period_sar, not the full previous month, and mention projected_month_total_sar when present.
- Compare against the budget when monthly_budget_sar is present.
- Point out what actually changed (categories that rose or fell notably), the biggest merchants, unusual large transactions, unpaid recurring expenses, and possible subscriptions not yet added as fixed expenses.
- Mention spending in foreign currencies (foreign_currency: original amount and its SAR) when present, and the split by bank (by_bank: alrajhi=الراجحي, alinma=الإنماء, snb=الأهلي, riyad=الرياض, sab=ساب, anb=العربي, albilad=البلاد, aljazira=الجزيرة, bsf=الفرنسي, saib=الاستثمار, gib=ميم, stcbank=STC Bank, barq=برق, urpay, d360, vision; manual = added by hand) when it is informative.
- Tips must be practical and specific to this data (2–4 tips). No generic advice.
- headline: one sentence. highlights: 3–5 bullets. alerts: 0–3 bullets (only real issues). tips: 2–4 bullets.$sys$,
    'Facts:' || E'\n' || v_facts::text,
    jsonb_build_object(
      'name', 'month_report',
      'description', 'The monthly report.',
      'input_schema', jsonb_build_object(
        'type', 'object',
        'properties', jsonb_build_object(
          'headline',   jsonb_build_object('type', 'string'),
          'highlights', jsonb_build_object('type', 'array', 'items', jsonb_build_object('type', 'string')),
          'alerts',     jsonb_build_object('type', 'array', 'items', jsonb_build_object('type', 'string')),
          'tips',       jsonb_build_object('type', 'array', 'items', jsonb_build_object('type', 'string'))),
        'required', jsonb_build_array('headline', 'highlights', 'alerts', 'tips'))),
    1500);
  if v_content is null then raise exception 'ai unavailable'; end if;

  insert into ai_reports (household_id, month, facts, content) values (v_h, v_m, v_facts, v_content)
  on conflict (household_id, month) do update set facts = excluded.facts, content = excluded.content, created_at = now();
  return jsonb_build_object('content', v_content, 'facts', v_facts, 'created_at', now(), 'cached', false);
end $$;

revoke all on function public.month_facts(uuid, date) from public, anon, authenticated;
revoke all on function public.ai_month_report(date, boolean) from public, anon;
grant execute on function public.ai_month_report(date, boolean) to authenticated;
revoke all on function public.protect_core_category() from public, anon, authenticated;

notify pgrst, 'reload schema';


-- ───────────── 0008_banks_fx.sql ─────────────
-- =====================================================================
--  0008: البنوك والبطاقات + تحويل العملات بسعر اليوم + الرسوم
--   - يعرف البنك/المحفظة من الرسالة (الراجحي، الإنماء، الأهلي، برق، STC Bank…)
--     ويتذكر كل بطاقة (آخر 4 أرقام ← البنك والنوع) فيعرفها حتى لو لم تذكر الرسالة البنك
--   - أي مبلغ أجنبي بدون مبلغ بالريال: يُحوَّل بسعر صرف اليوم (يتحدث تلقائياً)
--     + نسبة رسوم البطاقة/العائلة إن حُددت، + الرسوم المذكورة في الرسالة
--   - العملات المربوطة (دولار، درهم…) بسعر الربط الثابت
-- =====================================================================

-- نسبة رسوم العمليات الأجنبية الافتراضية للعائلة (%) — تُستخدم لأي بطاقة بدون نسبة خاصة
alter table public.households add column if not exists fx_fee_pct numeric(5,2) not null default 0
  check (fx_fee_pct between 0 and 20);
grant update (fx_fee_pct) on public.households to authenticated;

-- ---------- البطاقات ----------
create table if not exists public.cards (
  household_id uuid not null references public.households(id) on delete cascade,
  card_last4   text not null check (card_last4 ~ '^[0-9]{4}$'),
  bank         text,
  card_type    text,
  card_kind    text,
  nickname     text check (nickname is null or char_length(nickname) <= 30),
  fx_fee_pct   numeric(5,2) check (fx_fee_pct is null or fx_fee_pct between 0 and 20),
  first_seen   timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  primary key (household_id, card_last4)
);
alter table public.cards enable row level security;
drop policy if exists cards_all on public.cards;
create policy cards_all on public.cards for all to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));

-- ---------- أسعار الصرف (ريال لكل وحدة) ----------
create table if not exists public.fx_rates (
  currency     text primary key,
  sar_per_unit numeric not null check (sar_per_unit > 0),
  source       text not null,
  fetched_at   timestamptz not null default now()
);
alter table public.fx_rates enable row level security;
drop policy if exists fx_rates_select on public.fx_rates;
create policy fx_rates_select on public.fx_rates for select to authenticated using (true);
revoke insert, update, delete on public.fx_rates from anon, authenticated;

-- سعر الريال لعملة: الربط الثابت، أو سعر اليوم (يتحدث كل 6 ساعات)، أو آخر سعر محفوظ
create or replace function public.fx_sar_rate(p_currency text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  c text := upper(btrim(coalesce(p_currency, '')));
  r fx_rates;
  v_res extensions.http_response;
  v_json jsonb;
  k text;
  v text;
  v_peg numeric;
begin
  if c = '' then return null; end if;
  if c = 'SAR' then return jsonb_build_object('rate', 1, 'source', 'sar'); end if;
  v_peg := case c when 'USD' then 3.75 when 'AED' then 1.0211 when 'BHD' then 9.9734 when 'QAR' then 1.0302
                  when 'OMR' then 9.7403 when 'JOD' then 5.2891 else null end;
  if v_peg is not null then return jsonb_build_object('rate', v_peg, 'source', 'peg'); end if;

  select * into r from fx_rates where currency = c;
  if r.currency is null or r.fetched_at < now() - interval '6 hours' then
    -- المصدر الأساسي: ExchangeRate-API (أساسه الريال)
    begin
      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
      select * into v_res from extensions.http_get('https://open.er-api.com/v6/latest/SAR');
      if v_res.status = 200 then
        v_json := v_res.content::jsonb;
        if v_json->>'result' = 'success' then
          for k, v in select key, value from jsonb_each_text(v_json->'rates') loop
            if v ~ '^[0-9.eE+-]+$' and v::numeric > 0 then
              insert into fx_rates (currency, sar_per_unit, source, fetched_at)
              values (k, round(1 / v::numeric, 6), 'ExchangeRate-API', now())
              on conflict (currency) do update set sar_per_unit = excluded.sar_per_unit, source = excluded.source, fetched_at = excluded.fetched_at;
            end if;
          end loop;
        end if;
      end if;
    exception when others then null; end;
    select * into r from fx_rates where currency = c;

    -- احتياطي: البنك المركزي الأوروبي عبر الدولار (الريال مربوط بالدولار 3.75)
    if r.currency is null or r.fetched_at < now() - interval '6 hours' then
      begin
        select * into v_res from extensions.http_get('https://api.frankfurter.app/latest?from=USD');
        if v_res.status = 200 then
          v_json := v_res.content::jsonb;
          for k, v in select key, value from jsonb_each_text(v_json->'rates') loop
            if v::numeric > 0 then
              insert into fx_rates (currency, sar_per_unit, source, fetched_at)
              values (k, round(3.75 / v::numeric, 6), 'ECB (Frankfurter)', now())
              on conflict (currency) do update set sar_per_unit = excluded.sar_per_unit, source = excluded.source, fetched_at = excluded.fetched_at;
            end if;
          end loop;
        end if;
      exception when others then null; end;
      select * into r from fx_rates where currency = c;
    end if;
  end if;

  if r.currency is null then return null; end if;   -- لا سعر ولا اتصال: تُسجّل يدوياً
  return jsonb_build_object('rate', r.sar_per_unit, 'source', 'live', 'provider', r.source, 'fetched_at', r.fetched_at);
end $$;

-- ---------- البنوك ----------
create or replace function public.bank_from_text(p text)
returns text language sql immutable as $$
  select case
    when l ~ '(راجحي|rajhi)' then 'alrajhi'
    when l ~ '(انماء|إنماء|alinma)' then 'alinma'
    when l ~ '(stc ?bank|بنك stc|stc ?pay|اس تي سي)' then 'stcbank'
    when l ~ '(برق|\mbarq\M)' then 'barq'
    when l ~ '(urpay|يور ?باي)' then 'urpay'
    when l ~ '(\md360\M|دال ?360)' then 'd360'
    when l ~ '(vision ?bank|فيجن)' then 'vision'
    when l ~ '(الاهلي|الأهلي|\msnb\M|alahli|\mahli\M)' then 'snb'
    when l ~ '(بنك الرياض|riyad ?bank|\mriyadbank\M)' then 'riyad'
    when l ~ '(بنك ساب|(^|[^ء-ي])ساب([^ء-ي]|$)|\msabb?\M)' then 'sab'
    when l ~ '(العربي الوطني|البنك العربي|\manb\M)' then 'anb'
    when l ~ '(البلاد|albilad)' then 'albilad'
    when l ~ '(بنك الجزيرة|aljazira)' then 'aljazira'
    when l ~ '(الفرنسي|\mbsf\M|fransi)' then 'bsf'
    when l ~ '(للاستثمار|\msaib\M)' then 'saib'
    when l ~ '(\mgib\M|\mmeem\M|بنك ميم)' then 'gib'
    else null end
  from (select lower(coalesce(p, '')) as l) s
$$;

-- =====================================================================
--  قراءة الرسالة (نسخة جديدة كاملة: + البنك + البطاقة + العملات + الرسوم)
-- =====================================================================
create or replace function public.sms_parse(p_household uuid, p_message text, p_allow_ai boolean default true, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  msg        text;
  low        text;
  body       text;
  m          text[];
  sar_amt    text;
  amt_text   text;
  v_foreign  boolean;
  v_amount   bigint;
  v_merchant text;
  hay        text;
  cat_name   text;
  cat_icon   text;
  v_cat_id   uuid;
  v_cat_name text;
  v_today    date := (now() at time zone 'Asia/Riyadh')::date;
  v_date     date := (now() at time zone 'Asia/Riyadh')::date;
  v_ai       jsonb;
  v_source   text := 'rules';
  v_meta     jsonb := '{}';
  v_key      text;
  v_cats     text[];
  v_other    text;
  v_learned  text;
  v_new      jsonb;
  v_new_name text;
  v_ai_note  text;
  -- البطاقة والبنك والعملة
  v_last4    text;
  v_ctype    text;
  v_ckind    text;
  v_channel  text;
  v_bank     text;
  v_card     cards;
  v_orig_amt numeric;
  v_orig_cur text;
  v_fees     numeric;
  v_fx       jsonb;
  v_fee_pct  numeric;
  v_sar      numeric;
begin
  msg := translate(p_message, '٠١٢٣٤٥٦٧٨٩٫٬', '0123456789.,');
  msg := regexp_replace(msg, '(\d),(\d)', '\1\2', 'g');
  low := lower(msg);

  -- رموز التحقق لا تُرسل لأي جهة ولا يُحفظ نصها
  if low ~ '(otp|رمز التحقق|رمز التفعيل|رمز الدخول|كلمة المرور|كلمة السر|verification|one time|passcode)' then
    return jsonb_build_object('status', 'ignored', 'reason', 'رمز تحقق', 'private', true, 'source', 'rules');
  end if;
  if low ~ '(إيداع|ايداع|استرداد|استرجاع|refund|راتب|حوالة واردة|تحويل وارد|incoming|deposit|credited)' then
    return jsonb_build_object('status', 'ignored', 'reason', 'ليست عملية شراء', 'source', 'rules');
  end if;
  if low ~ '(مرفوض|declined|rejected|غير ناجح|فشل|failed|unsuccessful|insufficient|رصيد غير كاف|ملغا|ملغي|تم إلغاء|تم الغاء|cancelled|canceled|عكس عملية|عملية عكسية|معكوس|reversal|reversed)' then
    return jsonb_build_object('status', 'ignored', 'reason', 'عملية مرفوضة أو ملغاة', 'source', 'rules');
  end if;

  -- ---------- القراءة المحلية: تعمل دائماً وتكون الاحتياط ----------
  body := regexp_replace(low, '(الرصيد|رصيد|المتاح|متاح|balance|\mbal\M|avail|limit|الحد|رسوم|عمولة|\mfees?\M)[^\n]*', '', 'g');
  m := regexp_match(body,
    '(?:sar|ر\.?\s?س(?![ء-ي])|ريال)\s*:?\s*([0-9]+(?:\.[0-9]{1,2})?)|([0-9]+(?:\.[0-9]{1,2})?)\s*(?:sar|ر\.?\s?س(?![ء-ي])|ريال)');
  sar_amt := coalesce(m[1], m[2]);
  -- مبلغ بعملة أجنبية
  -- رمز العملة كلمة مستقلة (حتى لا تُقرأ «mada» كـ MAD)، والرقم ليس جزءاً من رقم البطاقة، وعلى نفس السطر
  m := regexp_match(body,
    '(?<![*•x0-9.])([0-9]+(?:\.[0-9]{1,2})?)[ \t]*(usd|eur|gbp|aed|bhd|kwd|qar|egp|omr|jod|inr|cny|jpy|try|chf|cad|aud|myr|idr|thb|pkr|php|sgd|hkd|krw|mad|tnd)\M');
  if m is not null then
    v_orig_amt := m[1]::numeric; v_orig_cur := upper(m[2]);
  else
    m := regexp_match(body,
      '\m(usd|eur|gbp|aed|bhd|kwd|qar|egp|omr|jod|inr|cny|jpy|try|chf|cad|aud|myr|idr|thb|pkr|php|sgd|hkd|krw|mad|tnd)[ \t]*:?[ \t]*([0-9]+(?:\.[0-9]{1,2})?)');
    if m is not null then
      v_orig_amt := m[2]::numeric; v_orig_cur := upper(m[1]);
    else
      m := regexp_match(body, '([$€£])[ \t]*([0-9]+(?:\.[0-9]{1,2})?)|(?<![*•x0-9.])([0-9]+(?:\.[0-9]{1,2})?)[ \t]*([$€£])');
      if m is not null then
        v_orig_amt := coalesce(m[2], m[3])::numeric;
        v_orig_cur := case coalesce(m[1], m[4]) when '$' then 'USD' when '€' then 'EUR' when '£' then 'GBP' end;
      end if;
    end if;
  end if;
  v_foreign := v_orig_cur is not null;
  amt_text := case when v_foreign then sar_amt
                   else coalesce(substring(body from '(?:مبلغ|amount)[^0-9]{0,20}([0-9]+(?:\.[0-9]{1,2})?)'), sar_amt) end;
  -- رسوم مذكورة بالريال في الرسالة
  v_fees := substring(low from '(?:رسوم|عمولة|\mfees?\M)[^\n0-9]{0,25}([0-9]+(?:\.[0-9]{1,2})?)\s*(?:sar|ر\.?\s?س|ريال)')::numeric;
  v_merchant := trim(substring(msg from '(?i)(?:لدى|عند|التاجر|المتجر|\mat\M|merchant)\s*:?\s*([^\n]{2,60})'));

  -- البطاقة والبنك وطريقة الدفع
  v_last4 := substring(low from '(?:\*+|•+|x{2,}|card[^0-9\n]{0,15}|بطاقة[^0-9\n]{0,20}|مدى[^0-9\n]{0,15})([0-9]{4})(?![0-9])');
  v_ctype := case when low ~ '(مدى|\mmada\M)' then 'mada' when low ~ '(فيزا|visa)' then 'visa'
                  when low ~ '(ماستر|master)' then 'mastercard' when low ~ '(امريكان|أمريكان|amex|american express)' then 'amex' end;
  v_ckind := case when v_ctype = 'mada' then 'debit' when low ~ '(ائتمان|credit)' then 'credit' end;
  v_channel := case when low ~ '(apple ?pay|ابل ?باي|أبل ?باي|apple wallet)' then 'apple_pay'
                    when low ~ '(انترنت|إنترنت|online|e-?commerce)' then 'online'
                    when low ~ '(نقاط البيع|\mpos\M)' then 'pos'
                    when low ~ '(سداد|sadad)' then 'bill_payment' end;
  v_bank := public.bank_from_text(low);

  hay := coalesce(nullif(lower(v_merchant), ''), low);
  hay := regexp_replace(hay, '(stc ?bank|stc ?pay|بنك stc|stc بنك|اس تي سي باي)', '', 'g');
  cat_name := case
    when hay ~ '(هنقر|hunger|جاهز|jahez|مرسول|mrsool|تويو|toyou|نينجا|\mninja\M|كيتا|keeta|chefz|شفز)' then 'تطبيقات التوصيل'
    when hay ~ '(كوفي|كافيه|كافي|قهوة|مقهى|cafe|café|coffee|starbucks|ستاربكس|مطعم|مطاعم|restaurant|البيك|albaik|mcdonald|ماكدونالدز|\mkudu\M|كودو|herfy|هرفي|barns|بارنز|dunkin|دانكن|pizza|بيتزا|burger|برجر|شاورما|shawarma|\mkfc\M|كنتاكي|subway|domino|دومينوز|tim hortons|هاف مليون|half million|krispy|كرسبي|مخبز|bakery|حلويات)' then 'المطاعم والمقاهي'
    when hay ~ '(دانوب|danube|بنده|\mpanda\M|عثيم|othaim|كارفور|carrefour|تميمي|tamimi|لولو|\mlulu\M|نستو|nesto|ماركت|\mmarket\M|supermarket|hypermarket|هايبر|تموينات|سوبر|بقالة|grocery)' then 'البقالة والسوبرماركت'
    when hay ~ '(amazon|امازون|أمازون|noon\.com|\mnoon\M|نون|shein|شي ان|ikea|ايكيا|\mextra\M|اكسترا|jarir|جرير|centrepoint|سنتربوينت|namshi|نمشي|trendyol|ترينديول)' then 'التسوق والمشتريات'
    when hay ~ '(\mstc\M|mobily|موبايلي|\mzain\M|كهرباء|electric|\msec\M|المياه|netflix|نتفلكس|shahid|شاهد|spotify|سبوتيفاي|apple\.com|icloud|سداد|sadad|فاتورة|\mosn\M|youtube|anghami|أنغامي|disney|starzplay|chatgpt|openai)' then 'الفواتير والاشتراكات'
    when hay ~ '(بنزين|وقود|fuel|petrol|sasco|ساسكو|aldrees|الدريس|petromin|بترومين|نفط|محطة|مغسلة|car wash|ورشة|قطع غيار|إطارات|اطارات|tyres|tires)' then 'مصاريف السيارة'
    when hay ~ '(صيدلي|pharma|nahdi|النهدي|الدواء|dawaa|whites|وايتس|مستشفى|hospital|clinic|عيادة|عيادات|مستوصف|medical|طبي|مختبر|\mlab\M|dental|اسنان|أسنان|بصريات|optic)' then 'الصحة والصيدليات'
    else 'مصاريف أخرى'
  end;
  cat_icon := case cat_name
    when 'تطبيقات التوصيل' then 'bike' when 'المطاعم والمقاهي' then 'food' when 'البقالة والسوبرماركت' then 'cart'
    when 'التسوق والمشتريات' then 'bag' when 'الفواتير والاشتراكات' then 'receipt' when 'مصاريف السيارة' then 'car'
    when 'الصحة والصيدليات' then 'health'
    else 'circle' end;

  -- ---------- Claude (إن كان مفعّلاً، وبحد 60 رسالة في الساعة للعائلة) ----------
  if p_allow_ai and public.ai_enabled()
     and (select count(*) from sms_log where household_id = p_household and source = 'ai' and received_at > now() - interval '1 hour') < 60 then
    select array_agg(name order by sort_order) into v_cats from categories where household_id = p_household and not is_archived;
    select name into v_other from categories where household_id = p_household and not is_archived
      order by (icon = 'circle') desc, sort_order desc limit 1;
    select string_agg(format('- %s ← %s', r.merchant_label, c.name), E'\n') into v_learned
    from (select * from merchant_rules where household_id = p_household order by updated_at desc limit 40) r
    join categories c on c.id = r.category_id and not c.is_archived;

    v_ai := public.ai_call('sms',
      $sys$You read Saudi bank and card SMS notifications (Arabic or English) for a family expense tracker and call record_transaction exactly once.

is_purchase:
- true ONLY for a completed payment that takes money out: card / mada / Apple Pay / POS purchases (in Saudi Arabia or abroad), online purchases, bill payments (سداد/فاتورة), subscriptions, government fees.
- false for OTP/verification codes, deposits, salary, incoming transfers, refunds/reversals, declined/failed/cancelled operations, balance or limit alerts, ads/promotions, card activation or statements, ATM cash withdrawals, transfers to people or between own accounts. Then give ignore_reason as a short Arabic phrase.

Amounts:
- amount_sar = the amount actually charged in Saudi riyals when the message states it. If the message shows a foreign amount AND its SAR equivalent, use the SAR equivalent. If only a foreign amount is shown, set amount_sar to null and fill original_amount and original_currency (ISO 4217 code, e.g. GBP, EUR, USD, TRY).
- fees_sar = fees or commission for THIS transaction explicitly stated in SAR (e.g. رسوم عملية دولية / international transaction fee), else null. Do not include fees in amount_sar.
- Never use the balance, available amount or credit limit. Digits shown as • are masked balances.

merchant: the clean shop/brand name a person would write, without branch numbers, city, country or terminal codes ("STARBUCKS 1234 JEDDAH SA" → "Starbucks", "HUNGERSTATION RIYADH" → "HungerStation", "TESCO STORES 3214 LONDON GB" → "Tesco", "مطعم البيك فرع ٣" → "البيك"). Keep Arabic names in Arabic.

category: exactly one of the family's categories (the enum). For a merchant listed under "Learned", always use the learned category. Saudi hints: HungerStation, Jahez, Mrsool, ToYou, Keeta, The Chefz, Ninja → delivery apps; Panda, Danube, Othaim, Carrefour, Tamimi, Lulu, Nesto, Farm, Bin Dawood → groceries; cafes, restaurants, bakeries, sweets → restaurants & cafes; STC, Mobily, Zain, SEC electricity, National Water, Netflix, Shahid, Spotify, Apple, Google, iCloud → bills & subscriptions; Aldrees, SASCO, Petromin, Naft, car wash, workshops, tyres → car; Amazon, Noon, Shein, IKEA, Jarir, Extra, Namshi, Centrepoint → shopping; Nahdi, Al-Dawaa, Whites, pharmacies, clinics, hospitals, labs, dentists, opticians → health. Abroad, use the same logic for local merchants (supermarkets → groceries, restaurants → restaurants, etc.).
Use "__new__" ONLY when the purchase clearly belongs to a common spending area that none of the categories covers (for example education, travel, kids) — never for a single merchant and never for a near-duplicate of an existing category. Then fill new_category with a short Arabic name (2–3 words) and an icon from its enum. When unsure, use the family's "other" category.

bank: the bank or wallet that sent the message / issued the card: alrajhi (الراجحي), alinma (الإنماء), snb (البنك الأهلي), riyad (بنك الرياض), sab (ساب), anb (البنك العربي الوطني), albilad (بنك البلاد), aljazira (بنك الجزيرة), bsf (البنك السعودي الفرنسي), saib (البنك السعودي للاستثمار), gib (بنك الخليج الدولي / ميم), stcbank (STC Bank / stc pay), barq (برق), urpay, d360, vision (Vision Bank), other; null if the message does not say.
date: the transaction date as YYYY-MM-DD if the message states it (Gregorian), else null.
card_last4: last 4 digits of the card if shown.
card_type: the card network — mada (Saudi debit network, مدى), visa, mastercard, amex, or other; null if unknown.
card_kind: debit or credit (ائتمانية/credit = credit; مدى and "حساب" are debit); null if unknown.
channel: apple_pay (Apple Pay / ابل باي / Apple Wallet), pos (in-store / نقاط البيع), online (إنترنت / online / e-commerce), bill_payment (سداد), or other.
confidence: 0 to 1.$sys$,
      format(E'Today: %s (Asia/Riyadh)\n"Other" category: %s\nLearned (merchant ← category):\n%s\n\nMessage:\n<<<\n%s\n>>>',
             v_today, coalesce(v_other, '-'), coalesce(v_learned, '- (none yet)'), public.sms_mask(msg)),
      jsonb_build_object(
        'name', 'record_transaction',
        'description', 'Record what the bank SMS says.',
        'input_schema', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'is_purchase',       jsonb_build_object('type', 'boolean'),
            'ignore_reason',     jsonb_build_object('type', 'string'),
            'amount_sar',        jsonb_build_object('type', jsonb_build_array('number', 'null')),
            'original_amount',   jsonb_build_object('type', jsonb_build_array('number', 'null')),
            'original_currency', jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'fees_sar',          jsonb_build_object('type', jsonb_build_array('number', 'null')),
            'merchant',          jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'category',          jsonb_build_object('type', 'string', 'enum', to_jsonb(coalesce(v_cats, '{}') || '__new__'::text)),
            'new_category',      jsonb_build_object('type', jsonb_build_array('object', 'null'), 'properties', jsonb_build_object(
                                   'name', jsonb_build_object('type', 'string'),
                                   'icon', jsonb_build_object('type', 'string', 'enum', to_jsonb(public.allowed_icons()))),
                                   'required', jsonb_build_array('name', 'icon')),
            'bank',              jsonb_build_object('type', jsonb_build_array('string', 'null'),
                                   'enum', jsonb_build_array('alrajhi', 'alinma', 'snb', 'riyad', 'sab', 'anb', 'albilad', 'aljazira', 'bsf',
                                                             'saib', 'gib', 'stcbank', 'barq', 'urpay', 'd360', 'vision', 'other', null)),
            'date',              jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'card_last4',        jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'card_type',         jsonb_build_object('type', jsonb_build_array('string', 'null'),
                                   'enum', jsonb_build_array('mada', 'visa', 'mastercard', 'amex', 'other', null)),
            'card_kind',         jsonb_build_object('type', jsonb_build_array('string', 'null'), 'enum', jsonb_build_array('debit', 'credit', null)),
            'channel',           jsonb_build_object('type', jsonb_build_array('string', 'null'),
                                   'enum', jsonb_build_array('apple_pay', 'pos', 'online', 'bill_payment', 'other', null)),
            'confidence',        jsonb_build_object('type', 'number')),
          'required', jsonb_build_array('is_purchase', 'category', 'confidence'))),
      600);
    if v_ai is null then v_ai_note := 'تعذّر الذكاء الاصطناعي، استُخدمت القراءة المحلية'; end if;
  end if;

  if v_ai is not null then
    if (v_ai->>'is_purchase') = 'false' then
      return jsonb_build_object('status', 'ignored', 'source', 'ai',
        'reason', coalesce(nullif(btrim(v_ai->>'ignore_reason'), ''), 'ليست عملية شراء'),
        'fallback_amount', coalesce(amt_text, sar_amt));
    end if;
    v_source := 'ai';
    if coalesce(v_ai->>'amount_sar', '') ~ '^[0-9]+(\.[0-9]+)?$' and (v_ai->>'amount_sar')::numeric > 0 then
      amt_text := v_ai->>'amount_sar';
    elsif coalesce(v_ai->>'original_amount', '') ~ '^[0-9]+(\.[0-9]+)?$' and coalesce(v_ai->>'original_currency', '') <> '' then
      amt_text := null;  -- يُحوَّل بالأسفل
    end if;
    if coalesce(v_ai->>'original_amount', '') ~ '^[0-9]+(\.[0-9]+)?$' and coalesce(v_ai->>'original_currency', '') ~* '^[a-z]{3}$' then
      v_orig_amt := (v_ai->>'original_amount')::numeric;
      v_orig_cur := upper(v_ai->>'original_currency');
    end if;
    if coalesce(v_ai->>'fees_sar', '') ~ '^[0-9]+(\.[0-9]+)?$' then v_fees := (v_ai->>'fees_sar')::numeric; end if;
    v_merchant := coalesce(nullif(btrim(v_ai->>'merchant'), ''), v_merchant);
    cat_name := coalesce(v_ai->>'category', cat_name);
    cat_icon := null;
    if coalesce(v_ai->>'date', '') ~ '^\d{4}-\d{2}-\d{2}$' then
      begin
        if (v_ai->>'date')::date between v_today - 30 and v_today then v_date := (v_ai->>'date')::date; end if;
      exception when others then null; end;
    end if;
    v_last4   := coalesce(nullif(right(regexp_replace(coalesce(v_ai->>'card_last4', ''), '[^0-9]', '', 'g'), 4), ''), v_last4);
    v_ctype   := coalesce(v_ai->>'card_type', v_ctype);
    v_ckind   := case when v_ctype = 'mada' then 'debit' else coalesce(v_ai->>'card_kind', v_ckind) end;
    v_channel := coalesce(v_ai->>'channel', v_channel);
    v_bank    := coalesce(nullif(v_ai->>'bank', 'other'), v_bank, nullif(v_ai->>'bank', ''));
    v_meta := v_meta || jsonb_strip_nulls(jsonb_build_object('confidence', v_ai->'confidence'));
    v_new := v_ai->'new_category';
  end if;
  if length(coalesce(v_last4, '')) <> 4 then v_last4 := null; end if;

  -- ---------- البطاقة المعروفة: تكمل البنك والنوع إن لم تذكرهما الرسالة ----------
  if v_last4 is not null then
    select * into v_card from cards where household_id = p_household and card_last4 = v_last4;
    v_bank  := coalesce(v_bank, v_card.bank);
    v_ctype := coalesce(v_ctype, v_card.card_type);
    v_ckind := coalesce(v_ckind, v_card.card_kind);
    if not p_dry_run then
      insert into cards (household_id, card_last4, bank, card_type, card_kind)
      values (p_household, v_last4, v_bank, v_ctype, v_ckind)
      on conflict (household_id, card_last4) do update
        set bank = coalesce(cards.bank, excluded.bank),
            card_type = coalesce(cards.card_type, excluded.card_type),
            card_kind = coalesce(cards.card_kind, excluded.card_kind),
            last_seen = now();
    end if;
  end if;

  -- ---------- تحويل المبلغ الأجنبي للريال (إن لم تذكر الرسالة المبلغ بالريال) ----------
  if amt_text is null and v_orig_amt is not null and v_orig_amt > 0 then
    v_fx := public.fx_sar_rate(v_orig_cur);
    if v_fx is not null then
      v_fee_pct := coalesce(v_card.fx_fee_pct, (select fx_fee_pct from households where id = p_household), 0);
      v_sar := round(v_orig_amt * (v_fx->>'rate')::numeric * (1 + v_fee_pct / 100), 2);
      amt_text := v_sar::text;
      v_meta := v_meta || jsonb_strip_nulls(jsonb_build_object(
        'approx', (v_fx->>'source') <> 'sar',
        'fx_rate', (v_fx->>'rate')::numeric,
        'fx_source', v_fx->>'source',
        'fx_provider', v_fx->>'provider',
        'fx_fee_pct', nullif(v_fee_pct, 0)));
    end if;
  end if;

  if amt_text is null then
    return jsonb_build_object('status', 'ignored', 'source', v_source,
      'reason', case when v_orig_cur is not null then format('عملة %s بدون سعر صرف متاح الآن، سجّلها يدوياً', v_orig_cur) else 'لم أجد المبلغ' end);
  end if;
  -- الرسوم المذكورة في الرسالة تُضاف للمبلغ
  if v_fees is not null and v_fees > 0 and v_fees < amt_text::numeric then
    amt_text := (amt_text::numeric + v_fees)::text;
    v_meta := v_meta || jsonb_build_object('fees_sar', v_fees);
  end if;
  v_amount := round(amt_text::numeric * 100)::bigint;
  if v_amount <= 0 or v_amount > 100000000000 then
    return jsonb_build_object('status', 'ignored', 'reason', 'مبلغ غير منطقي', 'source', v_source);
  end if;

  v_meta := v_meta || jsonb_strip_nulls(jsonb_build_object(
    'bank', v_bank, 'card_last4', v_last4, 'card_type', v_ctype, 'card_kind', v_ckind, 'channel', v_channel,
    'card_nickname', v_card.nickname,
    'original_amount', case when v_orig_cur is not null and v_orig_cur <> 'SAR' then v_orig_amt end,
    'original_currency', case when v_orig_cur is not null and v_orig_cur <> 'SAR' then v_orig_cur end));

  v_key := public.normalize_merchant(v_merchant);

  -- 1) قاعدة تعلّمها التطبيق منكم لهذا المتجر: تتقدم على كل شيء
  if v_key is not null then
    select r.category_id, c.name into v_cat_id, v_cat_name
    from merchant_rules r join categories c on c.id = r.category_id
    where r.household_id = p_household and r.merchant_key = v_key and not c.is_archived;
    if v_cat_id is not null then v_meta := v_meta || '{"rule": true}'; end if;
  end if;

  -- 2) تصنيف جديد اقترحه Claude (بضوابط تمنع العشوائية والتكرار)
  if v_cat_id is null and cat_name = '__new__' then
    v_new_name := btrim(v_new->>'name');
    if p_dry_run then
      select id, name into v_cat_id, v_cat_name from categories
      where household_id = p_household and not is_archived
        and public.normalize_category(name) = public.normalize_category(v_new_name) limit 1;
      if v_cat_id is null and v_new_name is not null then v_meta := v_meta || jsonb_build_object('new_category', v_new_name); end if;
    elsif v_new_name is not null and coalesce((v_ai->>'confidence')::numeric, 0) >= 0.7 then
      v_cat_id := public.safe_create_category(p_household, v_new_name, v_new->>'icon', null, 'ai');
      if v_cat_id is not null then
        select name into v_cat_name from categories where id = v_cat_id;
        v_meta := v_meta || jsonb_build_object('created_category', v_cat_name);
      end if;
    end if;
  end if;

  -- 3) بالاسم، ثم الاسم المقارب، ثم بالأيقونة، ثم «أخرى»
  if v_cat_id is null and not (v_meta ? 'new_category') then
    select c.id, c.name into v_cat_id, v_cat_name
    from categories c
    where c.household_id = p_household and not c.is_archived
    order by (c.name = cat_name) desc,
             (public.normalize_category(c.name) = public.normalize_category(cat_name)) desc,
             (c.icon = coalesce(cat_icon, '-')) desc, (c.icon = 'circle') desc, c.sort_order desc
    limit 1;
  end if;
  if v_cat_id is null and not (v_meta ? 'new_category') then
    return jsonb_build_object('status', 'ignored', 'reason', 'لا توجد تصنيفات', 'source', v_source);
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'ok',
    'source', v_source,
    'amount', v_amount,
    'merchant', nullif(v_merchant, ''),
    'merchant_key', v_key,
    'category_id', v_cat_id,
    'category_name', coalesce(v_cat_name, v_meta->>'new_category'),
    'date', v_date,
    'meta', v_meta || jsonb_build_object('source', v_source),
    'note', v_ai_note));
end $$;

revoke all on function public.sms_parse(uuid, text, boolean, boolean) from public, anon, authenticated;
revoke all on function public.fx_sar_rate(text) from public, anon, authenticated;

notify pgrst, 'reload schema';

