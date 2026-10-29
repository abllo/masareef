-- =====================================================================
--  0009: الملخص السنوي والأرشفة
--   - ملخص كامل لكل سنة (أشهر، تصنيفات×أشهر، متاجر، بنوك، بطاقات، أشخاص، عملات، ثابتة…)
--   - السنوات غير المؤرشفة تُحسب مباشرة من العمليات، والمؤرشفة من الملخص المحفوظ
--   - أرشفة سنة منتهية (للمنشئ فقط وبتأكيد كتابة السنة): يحفظ الملخص ثم يحذف عملياتها
--     وسجل رسائلها. القواعد المتعلَّمة والبطاقات والتقارير تبقى.
-- =====================================================================

create table if not exists public.year_summaries (
  household_id  uuid not null references public.households(id) on delete cascade,
  year          int  not null check (year between 2000 and 2200),
  data          jsonb not null,
  total         bigint not null,           -- بالهللة
  expense_count int not null,
  built_at      timestamptz not null default now(),
  archived_at   timestamptz,               -- وقت حذف العمليات (null = العمليات موجودة)
  primary key (household_id, year)
);
alter table public.year_summaries enable row level security;
drop policy if exists year_summaries_select on public.year_summaries;
create policy year_summaries_select on public.year_summaries for select to authenticated using (public.is_member(household_id));
revoke insert, update, delete on public.year_summaries from anon, authenticated;

-- كل أرقام السنة (بالهللة للمبالغ) محسوبة من العمليات
create or replace function public.year_facts(p_household uuid, p_year int)
returns jsonb language sql stable security definer set search_path = public as $$
  with e as (
    select x.*, c.name as cat, c.icon as cat_icon, c.color as cat_color,
           extract(month from x.expense_date)::int as mo,
           coalesce(nullif(x.sms_meta->>'merchant', ''), nullif(regexp_replace(coalesce(x.description, ''), '^📩\s*', ''), '')) as label,
           coalesce(x.merchant_key, lower(coalesce(nullif(x.sms_meta->>'merchant', ''), regexp_replace(coalesce(x.description, ''), '^📩\s*', '')))) as mkey
    from expenses x join categories c on c.id = x.category_id
    where x.household_id = p_household
      and x.expense_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31)
  )
  select jsonb_build_object(
    'year', p_year,
    'total', (select coalesce(sum(amount), 0) from e),
    'count', (select count(*) from e),
    'first_date', (select min(expense_date) from e),
    'last_date', (select max(expense_date) from e),
    'months', (select jsonb_agg(jsonb_build_object('month', g, 'total', coalesce(t.total, 0), 'count', coalesce(t.n, 0)) order by g)
               from generate_series(1, 12) g
               left join (select mo, sum(amount) as total, count(*) as n from e group by mo) t on t.mo = g),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', category_id, 'name', cat, 'icon', cat_icon, 'color', cat_color,
                                                              'total', total, 'count', n, 'months', months, 'month_counts', month_counts)
                                             order by total desc), '[]')
                   from (select category_id, cat, cat_icon, cat_color, sum(amount) as total, count(*) as n,
                                (select jsonb_agg(coalesce((select sum(amount) from e e2 where e2.category_id = e1.category_id and e2.mo = g), 0) order by g)
                                 from generate_series(1, 12) g) as months,
                                (select jsonb_agg((select count(*) from e e2 where e2.category_id = e1.category_id and e2.mo = g) order by g)
                                 from generate_series(1, 12) g) as month_counts
                         from e e1 group by category_id, cat, cat_icon, cat_color) t),
    'merchants', (select coalesce(jsonb_agg(jsonb_build_object('merchant', label, 'total', total, 'count', n) order by total desc), '[]')
                  from (select min(label) as label, sum(amount) as total, count(*) as n
                        from e where label is not null group by mkey order by 2 desc limit 40) t),
    'banks', (select coalesce(jsonb_agg(jsonb_build_object('bank', bank, 'total', total, 'count', n) order by total desc), '[]')
              from (select coalesce(sms_meta->>'bank', case when sms_meta is null then 'manual' else 'unknown' end) as bank,
                           sum(amount) as total, count(*) as n from e group by 1) t),
    'cards', (select coalesce(jsonb_agg(jsonb_build_object('card_last4', last4, 'bank', bank, 'card_type', ctype, 'card_kind', ckind,
                                                         'total', total, 'count', n) order by total desc), '[]')
              from (select sms_meta->>'card_last4' as last4, max(sms_meta->>'bank') as bank, max(sms_meta->>'card_type') as ctype,
                           max(sms_meta->>'card_kind') as ckind, sum(amount) as total, count(*) as n
                    from e where sms_meta ? 'card_last4' group by 1) t),
    'channels', (select coalesce(jsonb_agg(jsonb_build_object('channel', ch, 'total', total, 'count', n) order by total desc), '[]')
                 from (select coalesce(sms_meta->>'channel', case when sms_meta is null then 'manual' else 'unknown' end) as ch,
                              sum(amount) as total, count(*) as n from e group by 1) t),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('member', who, 'total', total, 'count', n) order by total desc), '[]')
                from (select coalesce(hm.display_name, 'عضو سابق') as who, sum(e.amount) as total, count(*) as n
                      from e left join household_members hm on hm.user_id = e.created_by and hm.household_id = p_household group by 1) t),
    'foreign', (select coalesce(jsonb_agg(jsonb_build_object('currency', cur, 'original', orig, 'total', total, 'count', n) order by total desc), '[]')
                from (select sms_meta->>'original_currency' as cur, sum((sms_meta->>'original_amount')::numeric) as orig,
                             sum(amount) as total, count(*) as n from e where sms_meta ? 'original_currency' group by 1) t),
    'recurring', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'total', total, 'months_paid', n) order by total desc), '[]')
                  from (select coalesce(r.name, e.description) as name, sum(e.amount) as total, count(distinct e.recurring_period) as n
                        from e left join recurring_expenses r on r.id = e.recurring_id
                        where e.recurring_period is not null group by 1) t),
    'largest', (select coalesce(jsonb_agg(jsonb_build_object('merchant', coalesce(label, cat), 'category', cat, 'total', amount, 'date', expense_date)
                                         order by amount desc), '[]')
                from (select * from e order by amount desc limit 10) t),
    'from_sms', (select count(*) from e where source_hash is not null)
  )
$$;

-- نظرة على كل السنوات: المؤرشفة من الملخص، والباقي يُحسب الآن
create or replace function public.years_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_h uuid := public.my_household(); v_out jsonb := '[]'; y int;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  for y in
    select distinct yr from (
      select extract(year from expense_date)::int as yr from expenses where household_id = v_h
      union select year from year_summaries where household_id = v_h) s
    order by yr desc
  loop
    v_out := v_out || jsonb_build_array(
      case when exists (select 1 from year_summaries where household_id = v_h and year = y and archived_at is not null)
           then (select jsonb_build_object('year', y, 'archived', true, 'archived_at', archived_at, 'data', data)
                 from year_summaries where household_id = v_h and year = y)
           else jsonb_build_object('year', y, 'archived', false, 'data', public.year_facts(v_h, y))
      end);
  end loop;
  return v_out;
end $$;

-- أرشفة سنة منتهية: تأكيد بكتابة رقم السنة، والمنشئ فقط. يُرجع عدد العمليات المحذوفة.
create or replace function public.archive_year(p_year int, p_confirm text)
returns jsonb language plpgsql security definer set search_path = public
set statement_timeout to '60s'
as $$
declare
  v_h uuid;
  v_data jsonb;
  v_count int;
  v_receipts text[];
  v_this_year int := extract(year from (now() at time zone 'Asia/Riyadh'))::int;
begin
  select household_id into v_h from household_members where user_id = auth.uid() and role = 'owner';
  if v_h is null then raise exception 'only the owner can do this'; end if;
  if p_year >= v_this_year then raise exception 'year not finished'; end if;
  if coalesce(btrim(p_confirm), '') <> p_year::text then raise exception 'confirmation mismatch'; end if;
  if exists (select 1 from year_summaries where household_id = v_h and year = p_year and archived_at is not null) then
    raise exception 'year already archived';
  end if;

  v_data := public.year_facts(v_h, p_year);
  v_count := (v_data->>'count')::int;
  if v_count = 0 then raise exception 'no expenses'; end if;

  insert into year_summaries (household_id, year, data, total, expense_count, built_at, archived_at)
  values (v_h, p_year, v_data, (v_data->>'total')::bigint, v_count, now(), now())
  on conflict (household_id, year) do update
    set data = excluded.data, total = excluded.total, expense_count = excluded.expense_count,
        built_at = now(), archived_at = now();

  select coalesce(array_agg(receipt_path), '{}') into v_receipts from expenses
  where household_id = v_h and receipt_path is not null
    and expense_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31);

  perform set_config('masareef.no_learn', 'on', true);
  delete from sms_log where household_id = v_h and expense_id in (
    select id from expenses where household_id = v_h and expense_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31));
  delete from expenses where household_id = v_h and expense_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31);
  perform set_config('masareef.no_learn', '', true);

  -- صور الفواتير يحذفها التطبيق من التخزين (لا يُسمح بحذفها من SQL مباشرة)
  return jsonb_build_object('year', p_year, 'deleted', v_count, 'total', v_data->'total', 'receipts', to_jsonb(v_receipts));
end $$;

-- السنة المؤرشفة مقفلة: لا إضافة ولا نقل عمليات إليها (حتى لا تختلف عن ملخصها)
create or replace function public.block_archived_year()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from year_summaries
             where household_id = new.household_id and year = extract(year from new.expense_date)::int
               and archived_at is not null) then
    raise exception 'year archived';
  end if;
  return new;
end $$;
revoke all on function public.block_archived_year() from public, anon, authenticated;
drop trigger if exists expenses_block_archived on public.expenses;
create trigger expenses_block_archived before insert or update of expense_date, household_id on public.expenses
  for each row execute function public.block_archived_year();

-- الرسوم الشهرية في الرئيسية تشمل أشهر السنوات المؤرشفة (من الملخص)
create or replace view public.monthly_category_totals
with (security_invoker = true) as
select household_id, date_trunc('month', expense_date)::date as month, category_id,
       sum(amount)::bigint as total, count(*)::int as tx_count
from public.expenses
group by 1, 2, 3
union all
select ys.household_id, make_date(ys.year, g.m, 1), (c->>'id')::uuid,
       (c->'months'->>(g.m - 1))::bigint, coalesce((c->'month_counts'->>(g.m - 1))::int, 0)
from public.year_summaries ys
cross join lateral jsonb_array_elements(ys.data->'categories') c
cross join generate_series(1, 12) as g(m)
where ys.archived_at is not null and c ? 'id' and (c->'months'->>(g.m - 1))::bigint > 0;

revoke all on function public.year_facts(uuid, int) from public, anon, authenticated;
revoke all on function public.years_overview() from public, anon;
revoke all on function public.archive_year(int, text) from public, anon;
grant execute on function public.years_overview() to authenticated;
grant execute on function public.archive_year(int, text) to authenticated;

notify pgrst, 'reload schema';
