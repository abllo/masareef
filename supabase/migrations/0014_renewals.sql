-- =====================================================================
--  0014: التجديدات والضمانات 📄
--   - تأمين، استمارة، رخصة، جواز، إقامة، هوية، اشتراكات، إيجار، رسوم مدارس، ضمانات
--   - يتعرف عليها Claude تلقائياً:
--       • من دفعة في رسالة البنك (تأمين، تجديد إقامة…) ← التجديد القادم بعد مدة التغطية
--       • من شراء جهاز (جرير، إكسترا…) ← ضمان سنتين
--       • من رسالة تذكير (أبشر وغيره) ← تاريخ الانتهاء (يحوّل الهجري)
--       • دفع التجديد يحدّث الموعد تلقائياً
--   - إضافة يدوية: تكتب أو تلصق نصاً وClaude يفهمه
--   - تنبيهات قبل الموعد بـ 3 أيام ويوم ويوم الموعد (والمستندات المهمة قبلها بشهر وأسبوع)
-- =====================================================================

create table if not exists public.renewals (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  title         text not null check (char_length(btrim(title)) between 1 and 80),
  kind          text not null default 'other' check (kind in ('insurance', 'istimara', 'license', 'passport', 'iqama', 'national_id',
                                                               'warranty', 'subscription', 'contract', 'rent', 'school', 'other')),
  subject       text check (subject is null or char_length(subject) <= 60),
  due_date      date not null,
  period_months int check (period_months is null or period_months between 1 and 120),
  amount        bigint check (amount is null or amount > 0),
  notes         text check (notes is null or char_length(notes) <= 300),
  source        text not null default 'manual' check (source in ('manual', 'ai', 'sms', 'notice')),
  expense_id    uuid references public.expenses(id) on delete set null,
  merchant_key  text,
  status        text not null default 'active' check (status in ('active', 'done')),
  created_by    uuid default auth.uid() references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists renewals_household_due on public.renewals (household_id, due_date) where status = 'active';
create unique index if not exists renewals_expense on public.renewals (expense_id) where expense_id is not null;
alter table public.renewals enable row level security;
drop policy if exists renewals_select on public.renewals;
drop policy if exists renewals_insert on public.renewals;
drop policy if exists renewals_update on public.renewals;
drop policy if exists renewals_delete on public.renewals;
create policy renewals_select on public.renewals for select to authenticated using (public.is_member(household_id));
create policy renewals_insert on public.renewals for insert to authenticated
  with check (public.is_member(household_id) and created_by = (select auth.uid()));
create policy renewals_update on public.renewals for update to authenticated
  using (public.is_member(household_id) and (created_by = (select auth.uid()) or public.is_owner(household_id)))
  with check (public.is_member(household_id));
create policy renewals_delete on public.renewals for delete to authenticated
  using (public.is_member(household_id) and (created_by = (select auth.uid()) or public.is_owner(household_id)));
do $$ begin alter publication supabase_realtime add table public.renewals; exception when others then null; end $$;

-- «الأحد 2 نوفمبر 2026»
create or replace function public.ar_date(p date)
returns text language sql immutable as $$
  select case when p is null then null else
    (array['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'])[extract(dow from p)::int + 1]
    || ' ' || extract(day from p)::int || ' ' || public.ar_month(p)
    || case when extract(year from p) <> extract(year from (now() at time zone 'Asia/Riyadh')) then ' ' || extract(year from p)::int else '' end end
$$;

create or replace function public.renewal_default_months(p_kind text)
returns int language sql immutable as $$
  select case p_kind when 'warranty' then 24 when 'license' then 120 when 'passport' then 60 when 'national_id' then 120
                     when 'istimara' then 12 when 'insurance' then 12 when 'iqama' then 12 when 'subscription' then 12
                     when 'rent' then 12 when 'school' then 12 when 'contract' then 12 end
$$;

-- يضيف تجديداً أو يحدّث الموجود (دفعة تجديد تمدّ الموعد، وتذكير أبشر يصحّح التاريخ)
create or replace function public.renewal_upsert(p_household uuid, p_user uuid, p_ren jsonb, p_expense uuid default null,
                                                 p_date date default null, p_amount bigint default null, p_merchant_key text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_kind text := case when p_ren->>'kind' in ('insurance', 'istimara', 'license', 'passport', 'iqama', 'national_id', 'warranty',
                                               'subscription', 'contract', 'rent', 'school', 'other') then p_ren->>'kind' else 'other' end;
  v_title text := left(coalesce(nullif(btrim(p_ren->>'title'), ''), 'تجديد'), 80);
  v_subject text := left(nullif(btrim(p_ren->>'subject'), ''), 60);
  v_months int;
  v_due date;
  v_stated date;
  v_base date := coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date);
  r renewals;
begin
  begin
    if coalesce(p_ren->>'period_months', '') ~ '^[0-9]{1,3}$' then v_months := (p_ren->>'period_months')::int; end if;
  exception when others then null; end;
  if v_months is null or v_months not between 1 and 120 then v_months := public.renewal_default_months(v_kind); end if;
  begin
    if coalesce(p_ren->>'due_date', '') ~ '^\d{4}-\d{2}-\d{2}$' then v_stated := (p_ren->>'due_date')::date; end if;
  exception when others then null; end;
  if v_stated is not null and v_stated not between v_base - 365 and v_base + 3700 then v_stated := null; end if;

  -- الموجود: نفس المتجر أو نفس النوع والجهة (الضمانات دائماً جديدة)
  if v_kind not in ('warranty', 'other') then
    select * into r from renewals x
     where x.household_id = p_household and x.status = 'active'
       and ((p_merchant_key is not null and x.merchant_key = p_merchant_key)
            or (x.kind = v_kind and coalesce(x.subject, '') = coalesce(v_subject, '')))
       and x.due_date between v_base - 120 and v_base + 400
     order by abs(x.due_date - v_base) limit 1;
  end if;

  if r.id is not null then
    if p_expense is not null then
      -- دفعة تجديد: من نهاية المدة الحالية إن كانت بعد الدفع، وإلا من تاريخ الدفع
      v_due := coalesce(v_stated, (case when r.due_date >= v_base then r.due_date else v_base end
                                   + make_interval(months => coalesce(r.period_months, v_months)))::date);
      update renewals set due_date = v_due, amount = coalesce(p_amount, amount), period_months = coalesce(period_months, v_months),
             merchant_key = coalesce(merchant_key, p_merchant_key), updated_at = now()
       where id = r.id;
    elsif v_stated is not null then
      update renewals set due_date = v_stated, updated_at = now() where id = r.id;
    end if;
    return r.id;
  end if;

  v_due := coalesce(v_stated, case when p_expense is not null and v_months is not null
                                   then (v_base + make_interval(months => v_months))::date end);
  if v_due is null then return null; end if;
  insert into renewals (household_id, title, kind, subject, due_date, period_months, amount, source, expense_id, merchant_key, created_by)
  values (p_household, v_title, v_kind, v_subject, v_due, v_months, case when p_expense is not null then p_amount end,
          case when p_expense is not null then 'sms' else 'notice' end, p_expense, p_merchant_key, p_user)
  on conflict do nothing
  returning id into r.id;
  return r.id;
end $$;

-- من رسالة البنك: دفعة تجديد أو شراء جهاز
create or replace function public.expenses_renewal_hook()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(new.sms_meta->'renewal') = 'object' then
    perform public.renewal_upsert(new.household_id, new.created_by, new.sms_meta->'renewal', new.id,
                                  new.expense_date, new.amount, new.merchant_key);
  end if;
  return null;
exception when others then
  return null;
end $$;
drop trigger if exists expenses_renewal on public.expenses;
-- اسمه يبدأ بـ «a» حتى يسبق إشعار المصروف (الإشعار يذكر التجديد)
create trigger a_expenses_renewal after insert on public.expenses for each row execute function public.expenses_renewal_hook();

-- من رسالة تذكير (أبشر وغيره)
create or replace function public.sms_log_renewal_hook()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.renewal_upsert(new.household_id, new.user_id, new.result->'renewal', null, (new.received_at at time zone 'Asia/Riyadh')::date);
  return null;
exception when others then
  return null;
end $$;
drop trigger if exists sms_log_renewal on public.sms_log;
create trigger a_sms_log_renewal after insert on public.sms_log for each row
  when (new.status = 'ignored' and jsonb_typeof(new.result->'renewal') = 'object')
  execute function public.sms_log_renewal_hook();

-- «تم التجديد»: يمدّ الموعد بمدة التجديد، أو ينهيه إذا ما يتكرر
create or replace function public.renewal_done(p_id uuid)
returns renewals language plpgsql security definer set search_path = public as $$
declare r renewals;
begin
  select * into r from renewals where id = p_id;
  if r.id is null or not public.is_member(r.household_id)
     or not (r.created_by = auth.uid() or public.is_owner(r.household_id)) then
    raise exception 'only the owner can do this';
  end if;
  if r.period_months is null or r.kind = 'warranty' then
    update renewals set status = 'done', updated_at = now() where id = r.id returning * into r;
  else
    update renewals set due_date = (greatest(due_date, (now() at time zone 'Asia/Riyadh')::date) + make_interval(months => period_months))::date,
           updated_at = now() where id = r.id returning * into r;
  end if;
  return r;
end $$;

-- إضافة بالذكاء: نص حر أو رسالة ← تجديد جاهز للمراجعة (لا يُحفظ)
create or replace function public.ai_parse_renewal(p_text text)
returns jsonb language plpgsql security definer set search_path = public
set statement_timeout to '70s'
as $$
declare v_h uuid := public.my_household(); v jsonb; v_today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  if coalesce(btrim(p_text), '') = '' or length(p_text) > 2000 then raise exception 'empty text'; end if;
  if not public.ai_enabled() then raise exception 'ai not enabled'; end if;
  v := public.ai_call('plan',
    $sys$You extract one renewal / expiry item for a Saudi family's reminder list from Arabic or English text (a note, an Absher/MOI SMS, an insurance or subscription message, a warranty card text). Call save_renewal once.
- kind: insurance, istimara (vehicle registration), license (driving license), passport, iqama (residence permit), national_id, warranty, subscription, contract, rent, school, other.
- title: short Arabic title (e.g. "تأمين السيارة", "جواز سفر محمد", "ضمان الثلاجة").
- subject: whose / which car or device if mentioned.
- due_date: the expiry / renewal date as Gregorian YYYY-MM-DD. Convert Hijri (هـ) dates carefully. Relative dates ("بعد شهرين", "نهاية الشهر") are relative to today. If only a month is given, use its last day; if the year is missing, use the next occurrence.
- period_months: how often it renews if known or usual (insurance 12, iqama 12, istimara 12, subscription 12…), else null.
- amount_sar: the amount if stated.
- confidence 0..1.$sys$,
    format(E'Today: %s
Text:
<<<
%s
>>>', v_today, p_text),
    jsonb_build_object('name', 'save_renewal', 'description', 'The renewal item.',
      'input_schema', jsonb_build_object('type', 'object', 'properties', jsonb_build_object(
        'kind', jsonb_build_object('type', 'string', 'enum', jsonb_build_array('insurance', 'istimara', 'license', 'passport', 'iqama',
                  'national_id', 'warranty', 'subscription', 'contract', 'rent', 'school', 'other')),
        'title', jsonb_build_object('type', 'string'),
        'subject', jsonb_build_object('type', jsonb_build_array('string', 'null')),
        'due_date', jsonb_build_object('type', jsonb_build_array('string', 'null')),
        'period_months', jsonb_build_object('type', jsonb_build_array('integer', 'null')),
        'amount_sar', jsonb_build_object('type', jsonb_build_array('number', 'null')),
        'confidence', jsonb_build_object('type', 'number')),
        'required', jsonb_build_array('kind', 'title', 'confidence'))),
    500);
  if v is null then raise exception 'ai unavailable'; end if;
  return v;
end $$;

-- ---------- الإشعارات ----------
alter table public.household_members alter column notify_prefs
  set default '{"self": true, "family": true, "budget": true, "recurring": true, "monthly": true, "sms_issue": true, "travel": true, "renewals": true}';
update public.household_members set notify_prefs = notify_prefs || '{"renewals": true}' where not notify_prefs ? 'renewals';

create or replace function public.push_set_prefs(p_prefs jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb; k text; v_clean jsonb := '{}';
begin
  foreach k in array array['self', 'family', 'budget', 'recurring', 'monthly', 'sms_issue', 'travel', 'renewals'] loop
    if jsonb_typeof(p_prefs->k) = 'boolean' then v_clean := v_clean || jsonb_build_object(k, p_prefs->k); end if;
  end loop;
  update household_members set notify_prefs = notify_prefs || v_clean where user_id = auth.uid()
  returning notify_prefs into v;
  return v;
end $$;

-- متى ننبّه: المستندات قبل شهر وأسبوع، والباقي قبل 3 أيام ويوم ويوم الموعد، ومرة بعد الانتهاء
create or replace function public.renewal_stages(p_kind text)
returns int[] language sql immutable as $$
  select case
    when p_kind in ('passport', 'iqama', 'national_id', 'license', 'istimara') then array[30, 7, 3, 1, 0, -1]
    when p_kind in ('insurance', 'contract', 'rent', 'school') then array[14, 3, 1, 0, -1]
    when p_kind = 'warranty' then array[30, 3]
    else array[3, 1, 0, -1] end
$$;

create or replace function public.renewal_when(p_days int)
returns text language sql immutable as $$
  select case when p_days < 0 then 'كان الموعد أمس' when p_days = 0 then 'اليوم الموعد' when p_days = 1 then 'بكرة الموعد'
              when p_days = 2 then 'بعد يومين' when p_days <= 10 then 'بعد ' || p_days || ' أيام'
              else 'بعد ' || p_days || ' يوم' end
$$;

create or replace function public.renewal_emoji(p_kind text)
returns text language sql immutable as $$
  select case p_kind when 'insurance' then '🛡️' when 'istimara' then '🚗' when 'license' then '🪪' when 'passport' then '🛂'
                     when 'iqama' then '🪪' when 'national_id' then '🪪' when 'warranty' then '🔧' when 'subscription' then '🔁'
                     when 'contract' then '📝' when 'rent' then '🏠' when 'school' then '🎓' else '📄' end
$$;

create or replace function public.push_renewal_messages(p_today date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := coalesce(p_today, (now() at time zone 'Asia/Riyadh')::date);
  h record; v_items jsonb; v_n int; v_first jsonb; v_out jsonb := '[]';
begin
  for h in select distinct household_id as id from push_subscriptions loop
    select coalesce(jsonb_agg(jsonb_build_object('title', r.title, 'kind', r.kind, 'subject', r.subject, 'due', r.due_date,
                                                 'days', r.due_date - v_today, 'amount', r.amount) order by r.due_date), '[]')
      into v_items
      from renewals r
     where r.household_id = h.id and r.status = 'active'
       and (r.due_date - v_today) = any(public.renewal_stages(r.kind));
    v_n := jsonb_array_length(v_items);
    if v_n = 0 then continue; end if;
    v_first := v_items->0;
    v_out := v_out || public.push_to(h.id, 'renewals', jsonb_build_object(
      'title', case when v_n = 1
                 then case when (v_first->>'days')::int <= 1 then '⏰ ' else '⏳ ' end || (v_first->>'title') || ': ' || public.renewal_when((v_first->>'days')::int)
                 else '⏳ ' || v_n || ' تجديدات قريبة' end,
      'body', case when v_n = 1
                then concat_ws(' · ', public.renewal_emoji(v_first->>'kind') || ' ' || public.ar_date((v_first->>'due')::date),
                               nullif(v_first->>'subject', ''),
                               case when v_first->>'amount' is not null then 'آخر مرة ' || public.fmt_sar((v_first->>'amount')::bigint) end)
                     || case when (v_first->>'days')::int < 0 then E'\n' || 'جدّدته؟ علّمه «تم التجديد» من التطبيق' else '' end
                else (select string_agg(public.renewal_emoji(i->>'kind') || ' ' || (i->>'title') || ': ' || public.renewal_when((i->>'days')::int), E'\n')
                      from jsonb_array_elements(v_items) i) end,
      'tag', 'renewals-' || v_today, 'url', './#/renewals'));
  end loop;
  return v_out;
end $$;

create or replace function public.push_sms_messages(p_log uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l record;
begin
  select * into l from sms_log where id = p_log;
  if not found or l.status <> 'ignored' or l.message is null or l.user_id is null then return '[]'; end if;
  -- تذكير تجديد (أبشر وغيره): انحفظ في التجديدات
  if jsonb_typeof(l.result->'renewal') = 'object' then
    return public.push_to(l.household_id, 'renewals', jsonb_build_object(
      'title', '📄 حفظت تذكير: ' || coalesce(l.result->'renewal'->>'title', 'تجديد'),
      'body', coalesce(nullif(l.result->'renewal'->>'subject', '') || ' · ', '')
              || coalesce('الموعد ' || public.ar_date((l.result->'renewal'->>'due_date')::date), 'أضفته في التجديدات')
              || E'\n' || 'بنبهك قبل الموعد',
      'tag', 'ren-' || l.id, 'url', './#/renewals'), p_only => l.user_id);
  end if;
  return public.push_to(l.household_id, 'sms_issue',
    jsonb_build_object(
      'title', case when l.reason ~ 'مرفوضة|ملغاة' then '⛔️ ' || l.reason else '⚠️ رسالة بنك ما سجّلتها' end,
      'body', case when l.reason ~ 'مرفوضة|ملغاة' then '' else coalesce(l.reason, '') || E'\n' end
              || left(regexp_replace(public.sms_mask(l.message), '\s+', ' ', 'g'), 110),
      'tag', 'sms-' || l.id, 'url', './#/messages'),
    p_only => l.user_id);
end $$;

create or replace function public.push_expense_messages(p_expense uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e record; t trips;
  v_label text; v_amount text; v_by text; v_head text; v_card text; v_info text; v_sum_line text;
  v_month date; v_total bigint; v_before bigint; v_budget bigint;
  v_trip_total bigint; v_trip_n int; v_first boolean := false;
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_out jsonb := '[]';
  v_title text; v_body text; v_url text;
begin
  select x.*, c.name as cat, c.icon as cat_icon into e from expenses x join categories c on c.id = x.category_id where x.id = p_expense;
  if not found then return '[]'; end if;

  v_label  := coalesce(nullif(e.sms_meta->>'merchant', ''), nullif(regexp_replace(coalesce(e.description, ''), '^📩\s*', ''), ''), e.cat);
  v_amount := public.fmt_sar(e.amount)
              || coalesce(' (' || (e.sms_meta->>'original_amount') || ' ' || (e.sms_meta->>'original_currency') || ')', '');
  v_head   := public.cat_emoji(e.cat_icon) || ' ' || v_label || ' · ' || v_amount;
  v_card   := public.push_card_text(e.sms_meta);
  v_info   := e.cat || coalesce(' · ' || v_card, '');
  -- تجديد أو ضمان انحفظ من هذي العملية
  select coalesce(v_info || E'\n', '') || case when r.kind = 'warranty' then '🛡️ ضمان حتى ' else '📄 التجديد القادم: ' end || public.ar_date(r.due_date)
    into v_info from renewals r where r.expense_id = e.id order by r.created_at desc limit 1;
  v_info := coalesce(v_info, e.cat || coalesce(' · ' || v_card, ''));
  select display_name into v_by from household_members where household_id = e.household_id and user_id = e.created_by;
  select monthly_budget into v_budget from households where id = e.household_id;
  v_month := date_trunc('month', e.expense_date)::date;

  if e.trip_id is not null then
    select * into t from trips where id = e.trip_id;
    select coalesce(sum(amount), 0), count(*) into v_trip_total, v_trip_n from expenses where trip_id = t.id;
    v_first := v_trip_n = 1;
    v_sum_line := '✈️ ' || t.name || ': ' || public.fmt_sar(v_trip_total)
                  || coalesce(' من ' || public.fmt_sar(t.budget) || ' (' || round(v_trip_total * 100.0 / t.budget) || '%)', '');
    v_url := './#/trips/' || t.id;
  else
    select coalesce(sum(amount), 0) into v_total from expenses
     where household_id = e.household_id and trip_id is null
       and expense_date >= v_month and expense_date < (v_month + interval '1 month')::date;
    v_before := v_total - e.amount;
    v_sum_line := '📊 ' || public.ar_month(v_month) || ': ' || public.fmt_sar(v_total)
                  || case when v_budget > 0 then ' من ' || public.fmt_sar(v_budget) || ' (' || round(v_total * 100.0 / v_budget) || '%)' else '' end;
    v_url := './#/expenses';
  end if;

  -- 1) صاحب العملية: ما سُجّل تلقائياً من رسالة البنك
  if e.source_hash is not null then
    v_out := v_out || public.push_to(e.household_id, 'self', jsonb_build_object(
      'title', case when v_first then '✈️ بدأت ' || t.name || ' ' || public.trip_flags(t.countries) else v_head end,
      'body', case when v_first then v_head || E'\n' || v_info || E'\n' || 'مصاريف الرحلة منفصلة عن ميزانية الشهر'
                   else v_info || E'\n' || v_sum_line end,
      'tag', 'exp-' || e.id, 'url', v_url), p_only => e.created_by);
  end if;

  -- 2) بقية العائلة
  v_out := v_out || public.push_to(e.household_id, 'family', jsonb_build_object(
    'title', '👤 ' || coalesce(v_by, 'العائلة') || ' · ' || v_head,
    'body', v_info || E'\n' || v_sum_line,
    'tag', 'exp-' || e.id, 'url', v_url), p_except => e.created_by);

  -- 3) الميزانية (الرحلة أو الشهر) عند 80% و100% لأول مرة
  if e.trip_id is not null then
    if t.budget > 0 then
      if v_trip_total - e.amount < t.budget and v_trip_total >= t.budget then
        v_title := '🚨 تجاوزتم ميزانية ' || t.name;
        v_body := 'المصروف ' || public.fmt_sar(v_trip_total) || ' من ' || public.fmt_sar(t.budget)
                  || E'\n' || 'الزيادة ' || public.fmt_sar(v_trip_total - t.budget);
      elsif (v_trip_total - e.amount) * 10 < t.budget * 8 and v_trip_total * 10 >= t.budget * 8 then
        v_title := '⚠️ وصلتم 80% من ميزانية ' || t.name;
        v_body := 'المصروف ' || public.fmt_sar(v_trip_total) || ' من ' || public.fmt_sar(t.budget)
                  || E'\n' || 'المتبقي ' || public.fmt_sar(t.budget - v_trip_total);
      end if;
      if v_title is not null then
        v_out := v_out || public.push_to(e.household_id, 'travel',
          jsonb_build_object('title', v_title, 'body', v_body, 'tag', 'trip-budget-' || t.id, 'url', v_url));
      end if;
    end if;
    return v_out;
  end if;

  if v_budget > 0 and v_month = date_trunc('month', v_today)::date then
    if v_before < v_budget and v_total >= v_budget then
      v_title := '🚨 تجاوزتم ميزانية ' || public.ar_month(v_month);
      v_body  := 'المصروف ' || public.fmt_sar(v_total) || ' من ' || public.fmt_sar(v_budget)
                 || E'\n' || 'الزيادة ' || public.fmt_sar(v_total - v_budget);
    elsif v_before * 10 < v_budget * 8 and v_total * 10 >= v_budget * 8 then
      v_title := '⚠️ وصلتم 80% من ميزانية ' || public.ar_month(v_month);
      v_body  := 'المصروف ' || public.fmt_sar(v_total) || ' من ' || public.fmt_sar(v_budget)
                 || E'\n' || 'المتبقي ' || public.fmt_sar(v_budget - v_total);
    end if;
    if v_title is not null then
      v_out := v_out || public.push_to(e.household_id, 'budget',
        jsonb_build_object('title', v_title, 'body', v_body, 'tag', 'budget-' || v_month, 'url', './'));
    end if;
  end if;
  return v_out;
end $$;

create or replace function public.push_build(p_kind text, p_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return case p_kind
    when 'expense'  then public.push_expense_messages(p_id)
    when 'sms'      then public.push_sms_messages(p_id)
    when 'daily'    then public.push_daily_messages(null) || public.push_renewal_messages(null)
    when 'trip_end' then public.push_trip_end_messages(p_id)
    else '[]'::jsonb end;
end $$;

-- ---------- قراءة رسائل البنك: تتعرف على التجديدات ----------
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
  v_country  text;
  v_intl     boolean;
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
  -- الدولة: حقل صريح في الرسالة، أو رمز الدولة في آخر سطر المتجر (TESCO LONDON GB)
  v_intl := low ~ '(دولي|دولية|international|خارج المملكة|abroad)';
  v_country := public.country_code(substring(msg from '(?i)(?:الدولة|دولة|الدوله|البلد|country)\s*[:：]?\s*([^\n]{2,30})'));
  if v_country is null then
    v_country := public.country_code(substring(coalesce(v_merchant, '') from '\s([A-Z]{2,3})\s*$'));
  end if;

  hay := coalesce(nullif(lower(v_merchant), ''), low);
  hay := regexp_replace(hay, '(stc ?bank|stc ?pay|بنك stc|stc بنك|اس تي سي باي)', '', 'g');
  cat_name := case
    when hay ~ '(هنقر|hunger|جاهز|jahez|مرسول|mrsool|تويو|toyou|نينجا|\mninja\M|كيتا|keeta|chefz|شفز)' then 'تطبيقات التوصيل'
    when hay ~ '(كوفي|كافيه|كافي|قهوة|مقهى|cafe|café|coffee|starbucks|ستاربكس|مطعم|مطاعم|restaurant|البيك|albaik|mcdonald|ماكدونالدز|\mkudu\M|كودو|herfy|هرفي|barns|بارنز|dunkin|دانكن|pizza|بيتزا|burger|برجر|شاورما|shawarma|\mkfc\M|كنتاكي|subway|domino|دومينوز|tim hortons|هاف مليون|half million|krispy|كرسبي|مخبز|bakery|حلويات)' then 'المطاعم والمقاهي'
    when hay ~ '(دانوب|danube|بنده|\mpanda\M|عثيم|othaim|كارفور|carrefour|تميمي|tamimi|لولو|\mlulu\M|نستو|nesto|ماركت|\mmarket\M|supermarket|hypermarket|هايبر|تموينات|سوبر|بقالة|grocery)' then 'البقالة والسوبرماركت'
    when hay ~ '(amazon now|\mnana\M|نانا|نوفا|nova water|berain|بيرين)' then 'البقالة والسوبرماركت'
    when hay ~ '(amazon|امازون|أمازون|noon\.com|\mnoon\M|نون|shein|شي ان|ikea|ايكيا|\mextra\M|اكسترا|jarir|جرير|centrepoint|سنتربوينت|namshi|نمشي|trendyol|ترينديول|tamara|تمارا|tabby|تابي|\mzara\M)' then 'التسوق والمشتريات'
    when hay ~ '(\mstc\M|mobily|موبايلي|\mzain\M|كهرباء|electric|\msec\M|المياه|netflix|نتفلكس|shahid|شاهد|spotify|سبوتيفاي|apple\.com|icloud|سداد|sadad|فاتورة|\mosn\M|youtube|anghami|أنغامي|disney|starzplay|chatgpt|openai)' then 'الفواتير والاشتراكات'
    when hay ~ '(بنزين|وقود|fuel|petrol|sasco|ساسكو|aldrees|الدريس|petromin|بترومين|نفط|محطة|car wash|ورشة|قطع غيار|إطارات|اطارات|tyres|tires|مغسلة سيارات|غسيل سيارات|oomco|apsco|wafi energy|shell|woqoof|وقوف|parking|موقف|careem|كريم|\muber\M|jeeny|acdelco)' then 'مصاريف السيارة'
    when hay ~ '(صيدلي|pharma|nahdi|النهدي|الدواء|dawaa|whites|وايتس|مستشفى|hospital|clinic|عيادة|عيادات|مستوصف|medical|طبي|مختبر|\mlab\M|dental|اسنان|أسنان|بصريات|optic)' then 'الصحة والصيدليات'
    when hay ~ '(almosafer|المسافر|flynas|ناس|flyadeal|saudia|السعودية للطيران|qatar air|emirates|طيران|airline|booking\.com|agoda|airbnb|\mvfs\M|تأشير)' then 'السفر والحجوزات'
    when hay ~ '(ehsan|إحسان|احسان|جود|تبرع|صدقة|charity|donation)' then 'الصدقات والتبرعات'
    when hay ~ '(salon|صالون|حلاق|barber|spa\M|مساج|massage|laundry|مغسلة ملابس|غسيل|gaseel|tailor|خياط)' then 'العناية الشخصية'
    when hay ~ '(smasco|سماسكو|musaned|مساند|استقدام)' then 'راتب العاملة المنزلية'
    else 'مصاريف أخرى'
  end;
  cat_icon := case cat_name
    when 'تطبيقات التوصيل' then 'bike' when 'المطاعم والمقاهي' then 'food' when 'البقالة والسوبرماركت' then 'cart'
    when 'التسوق والمشتريات' then 'bag' when 'الفواتير والاشتراكات' then 'receipt' when 'مصاريف السيارة' then 'car'
    when 'الصحة والصيدليات' then 'health' when 'السفر والحجوزات' then 'travel' when 'الصدقات والتبرعات' then 'charity'
    when 'العناية الشخصية' then 'beauty' when 'راتب العاملة المنزلية' then 'broom'
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

category: exactly one of the family's categories (the enum). For a merchant listed under "Learned", always use the learned category. Saudi hints: HungerStation, Jahez, Mrsool, ToYou, Keeta, The Chefz, Ninja → delivery apps; Panda, Danube, Othaim, Carrefour, Tamimi, Lulu, Nesto, Farm, Bin Dawood → groceries; cafes, restaurants, bakeries, sweets → restaurants & cafes; STC, Mobily, Zain, SEC electricity, National Water, Netflix, Shahid, Spotify, Apple, Google, iCloud → bills & subscriptions; Aldrees, SASCO, Petromin, Naft, car wash, workshops, tyres → car; Amazon, Noon, Shein, Trendyol, IKEA, Jarir, Extra, Namshi, Centrepoint, Max, Zara, Tamara/Tabby instalments → shopping; Amazon Now, Nana, Tamimi, water delivery (Nova, Berain, النبع) → groceries; Nahdi, Al-Dawaa, Whites, pharmacies, clinics, hospitals, labs, dentists, opticians → health; OOMCO, APSCO, Wafi Energy, Aldrees, SASCO, Petromin, Shell, car services (ACDelco), parking (Woqoof, Mawqif), Careem, Uber, Jeeny → car; HiNet, Mobily Pay, STC Pay bills → bills; Smasco, Musaned, recruitment / hourly maid services → the domestic worker category if the family has one; airlines (Saudia, flynas, flyadeal, Qatar Airways, Emirates), Almosafer, Booking.com, Agoda, Airbnb, VFS / visa centres → the travel bookings category if the family has one; Ehsan (إحسان), Jood, charities, donations → the charity category if the family has one; barbers, salons (صالون), spas, massage, laundry (مغسلة ملابس, Gaseel), tailors (خياط) → the personal care category if the family has one. Abroad, use the same logic for local merchants (supermarkets → groceries, restaurants → restaurants, etc.): purchases made abroad keep their real category because the app groups them into trips automatically — never put them in a travel category.
Use "__new__" ONLY when the purchase clearly belongs to a common spending area that none of the categories covers (for example education, kids) — never for a single merchant and never for a near-duplicate of an existing category. Then fill new_category with a short Arabic name (2–3 words) and an icon from its enum. When unsure, use the family's "other" category.

bank: the bank or wallet that sent the message / issued the card: alrajhi (الراجحي), alinma (الإنماء), snb (البنك الأهلي), riyad (بنك الرياض), sab (ساب), anb (البنك العربي الوطني), albilad (بنك البلاد), aljazira (بنك الجزيرة), bsf (البنك السعودي الفرنسي), saib (البنك السعودي للاستثمار), gib (بنك الخليج الدولي / ميم), stcbank (STC Bank / stc pay), barq (برق), urpay, d360, vision (Vision Bank), other; null if the message does not say.
date: the transaction date as YYYY-MM-DD if the message states it (Gregorian), else null.
card_last4: last 4 digits of the card if shown.
card_type: the card network — mada (Saudi debit network, مدى), visa, mastercard, amex, or other; null if unknown.
card_kind: debit or credit (ائتمانية/credit = credit; مدى and "حساب" are debit); null if unknown.
channel: apple_pay (Apple Pay / ابل باي / Apple Wallet), pos (in-store / نقاط البيع), online (إنترنت / online / e-commerce), bill_payment (سداد), or other.
country: ISO 3166-1 alpha-2 code of the country where the purchase physically happened, from the message (a country field like دولة/الدولة, a location like "LONDON GB" or "DUBAI AE", or a city name). Use SA for an in-store / Apple Pay purchase charged in SAR with no international marker (Saudi domestic). For online purchases give the merchant country only when the message states it. null when unknown.
renewal: fill ONLY when the message is about something that renews or expires, otherwise null:
- A payment for a renewable item: car/medical/travel/home insurance (Tawuniya, Bupa, MedGulf, Walaa, Malath, Al Rajhi Takaful, GIG, Najm…), vehicle registration (استمارة), driving license (رخصة قيادة), passport (جواز), iqama / residence permit (إقامة) or its fees, national ID (هوية), annual subscriptions (domain, software, gym, club), rent (إيجار), school fees (رسوم مدرسية). Give kind, a short Arabic title (e.g. "تأمين السيارة", "تجديد الإقامة"), subject if the message says whose / which car, and period_months = how long the payment covers (as stated, else the usual: insurance 12, iqama 12, subscription 12, rent 12, school 12).
- A warranty: a durable electronics / appliance / furniture purchase of 300 SAR or more (Jarir, Extra, Apple, Samsung, IKEA, Panda home appliances…) → kind warranty, title = the store or product, period_months 24.
- An expiry or renewal reminder that is NOT a payment (e.g. Absher / المرور / الجوازات: «ستنتهي صلاحية…», insurance company reminders) → is_purchase false, ignore_reason "تذكير تجديد", and renewal with due_date = the expiry date as Gregorian YYYY-MM-DD (convert Hijri dates such as 1447/05/12 carefully), plus kind, title and subject.
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
            'country',           jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'renewal',           jsonb_build_object('type', jsonb_build_array('object', 'null'), 'properties', jsonb_build_object(
                                   'kind', jsonb_build_object('type', 'string', 'enum', jsonb_build_array(
                                     'insurance', 'istimara', 'license', 'passport', 'iqama', 'national_id', 'warranty',
                                     'subscription', 'contract', 'rent', 'school', 'other')),
                                   'title', jsonb_build_object('type', 'string'),
                                   'subject', jsonb_build_object('type', jsonb_build_array('string', 'null')),
                                   'period_months', jsonb_build_object('type', jsonb_build_array('integer', 'null')),
                                   'due_date', jsonb_build_object('type', jsonb_build_array('string', 'null'))),
                                   'required', jsonb_build_array('kind', 'title')),
            'confidence',        jsonb_build_object('type', 'number')),
          'required', jsonb_build_array('is_purchase', 'category', 'confidence'))),
      600);
    if v_ai is null then v_ai_note := 'تعذّر الذكاء الاصطناعي، استُخدمت القراءة المحلية'; end if;
  end if;

  if v_ai is not null then
    if (v_ai->>'is_purchase') = 'false' then
      return jsonb_build_object('status', 'ignored', 'source', 'ai',
        'reason', coalesce(nullif(btrim(v_ai->>'ignore_reason'), ''), 'ليست عملية شراء'),
        'fallback_amount', coalesce(amt_text, sar_amt),
        'renewal', case when jsonb_typeof(v_ai->'renewal') = 'object' then v_ai->'renewal' end);
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
    v_country := coalesce(public.country_code(v_ai->>'country'), v_country);
    v_meta := v_meta || jsonb_strip_nulls(jsonb_build_object('confidence', v_ai->'confidence'));
    v_new := v_ai->'new_category';
    if jsonb_typeof(v_ai->'renewal') = 'object' then v_meta := v_meta || jsonb_build_object('renewal', v_ai->'renewal'); end if;
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

  -- شراء من محل بالريال بدون أي إشارة دولية = داخل السعودية
  if v_country is null and v_orig_cur is null and not v_intl and v_channel in ('pos', 'apple_pay') then v_country := 'SA'; end if;

  v_meta := v_meta || jsonb_strip_nulls(jsonb_build_object(
    'bank', v_bank, 'card_last4', v_last4, 'card_type', v_ctype, 'card_kind', v_ckind, 'channel', v_channel,
    'country', v_country, 'international', case when v_intl then true end,
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

revoke all on function public.ar_date(date) from public, anon;
revoke all on function public.renewal_default_months(text) from public, anon;
revoke all on function public.renewal_upsert(uuid, uuid, jsonb, uuid, date, bigint, text) from public, anon, authenticated;
revoke all on function public.expenses_renewal_hook() from public, anon, authenticated;
revoke all on function public.sms_log_renewal_hook() from public, anon, authenticated;
revoke all on function public.renewal_done(uuid) from public, anon;
grant execute on function public.renewal_done(uuid) to authenticated;
revoke all on function public.ai_parse_renewal(text) from public, anon;
grant execute on function public.ai_parse_renewal(text) to authenticated;
revoke all on function public.renewal_stages(text) from public, anon;
revoke all on function public.renewal_when(int) from public, anon;
revoke all on function public.renewal_emoji(text) from public, anon;
revoke all on function public.push_renewal_messages(date) from public, anon, authenticated;
revoke all on function public.push_build(text, uuid) from public, anon, authenticated;
grant execute on function public.push_build(text, uuid) to service_role;
revoke all on function public.push_sms_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_expense_messages(uuid) from public, anon, authenticated;
revoke all on function public.sms_parse(uuid, text, boolean, boolean) from public, anon, authenticated;

notify pgrst, 'reload schema';
