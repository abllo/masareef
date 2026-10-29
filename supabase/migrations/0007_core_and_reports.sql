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
                from (select coalesce(nullif(concat_ws(' ', sms_meta->>'card_type', sms_meta->>'card_kind', sms_meta->>'card_last4'), ''),
                                      case when sms_meta is null then 'manual' else 'bank_sms_unknown_card' end) as card,
                             round(sum(amount) / 100.0, 2) as sar, count(*) as n from cur group by 1) t),
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
