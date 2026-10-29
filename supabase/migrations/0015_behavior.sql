-- =====================================================================
--  0015: السلوك والتنبيهات الذكية
--   - إشعار المصروف ينبّه على: خصم مكرر خلال دقائق، أو مبلغ أعلى بكثير من المعتاد عند نفس المتجر
--   - قراءة Claude الشهرية تشمل السلوك: أكثر يوم صرف، صرف أول الشهر، أكثر العادات تكراراً
-- =====================================================================

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
  v_usual bigint; v_usual_n int;
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

  -- تنبيه ذكي: خصم مكرر خلال دقائق، أو مبلغ أعلى بكثير من المعتاد عند نفس المتجر
  if e.merchant_key is not null then
    if exists (select 1 from expenses x where x.household_id = e.household_id and x.id <> e.id and x.merchant_key = e.merchant_key
                 and x.amount = e.amount and x.created_at between e.created_at - interval '15 minutes' and e.created_at) then
      v_info := v_info || E'\n' || '⚠️ نفس المبلغ ونفس المتجر قبل دقائق، تأكد ما انخصم مرتين';
    else
      select percentile_cont(0.5) within group (order by amount)::bigint, count(*) into v_usual, v_usual_n
        from (select amount from expenses x where x.household_id = e.household_id and x.id <> e.id and x.merchant_key = e.merchant_key
               order by x.expense_date desc limit 12) h;
      if v_usual_n >= 3 and v_usual > 0 and e.amount >= v_usual * 2.5 and e.amount - v_usual >= 5000 then
        v_info := v_info || E'\n' || '⚠️ أعلى من معتادك هنا (عادةً ' || public.fmt_sar(v_usual) || ')';
      end if;
    end if;
  end if;
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
    where x.household_id = p_household and x.trip_id is null
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
    'behavior', jsonb_build_object(
      'by_weekday_sar', (select jsonb_object_agg(d, sar) from (
                           select (array['sun','mon','tue','wed','thu','fri','sat'])[extract(dow from expense_date)::int + 1] as d,
                                  round(sum(amount) / 100.0, 2) as sar from cur where recurring_id is null group by 1) w),
      'first_10_days_share', (select round(coalesce(sum(amount) filter (where extract(day from expense_date) <= 10), 0)::numeric
                                           / nullif(sum(amount), 0), 2) from cur where recurring_id is null),
      'most_frequent', (select coalesce(jsonb_agg(jsonb_build_object('category', cat, 'times', n, 'avg_sar', avg_sar) order by n desc), '[]')
                        from (select cat, count(*) as n, round(avg(amount) / 100.0, 2) as avg_sar from cur where recurring_id is null
                              group by cat having count(*) >= 3 order by 2 desc limit 3) f)),
    'travel', (select jsonb_build_object('sar', round(coalesce(sum(x.amount), 0) / 100.0, 2), 'count', count(*),
                       'trips', coalesce((select jsonb_agg(distinct t.name) from trips t join expenses y on y.trip_id = t.id, p
                                          where y.household_id = p_household and y.expense_date between p.m and p.m_end), '[]'))
               from expenses x, p where x.household_id = p_household and x.trip_id is not null and x.expense_date between p.m and p.m_end),
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
- Travel spending (travel: trips abroad) is tracked separately and is NOT included in total_sar, categories or the budget. If travel.sar > 0, mention it in one short highlight (trip names and amount) without mixing it into the monthly comparison.
- Point out what actually changed (categories that rose or fell notably), the biggest merchants, unusual large transactions, unpaid recurring expenses, and possible subscriptions not yet added as fixed expenses.
- Mention spending in foreign currencies (foreign_currency: original amount and its SAR) when present, and the split by bank (by_bank: alrajhi=الراجحي, alinma=الإنماء, snb=الأهلي, riyad=الرياض, sab=ساب, anb=العربي, albilad=البلاد, aljazira=الجزيرة, bsf=الفرنسي, saib=الاستثمار, gib=ميم, stcbank=STC Bank, barq=برق, urpay, d360, vision; manual = added by hand) when it is informative.
- Behaviour (behavior): when notable, mention in one highlight which weekday they spend most, whether most spending happens in the first 10 days (right after salary), and their most frequent habit (e.g. delivery apps N times, average ticket).
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

revoke all on function public.push_expense_messages(uuid) from public, anon, authenticated;
revoke all on function public.month_facts(uuid, date) from public, anon, authenticated;
revoke all on function public.ai_month_report(date, boolean) from public, anon;
grant execute on function public.ai_month_report(date, boolean) to authenticated;

notify pgrst, 'reload schema';
