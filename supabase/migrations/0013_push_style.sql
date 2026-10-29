-- =====================================================================
--  0013: شكل الإشعارات
--   - كل سطر يبدأ بعلامة اتجاه عربي (RLM) فيقرأ من اليمين حتى لو المتجر بالإنجليزي
--   - أيقونة لكل تصنيف، والبطاقة وطريقة الدفع، ونسبة الميزانية
-- =====================================================================

-- رمز تعبيري لأيقونة التصنيف
create or replace function public.cat_emoji(p_icon text)
returns text language sql immutable as $$
  select case p_icon
    when 'cart' then '🛒' when 'food' then '🍽️' when 'coffee' then '☕️' when 'bike' then '🛵' when 'receipt' then '🧾'
    when 'bag' then '🛍️' when 'car' then '🚗' when 'fuel' then '⛽️' when 'broom' then '🧹' when 'steering' then '🚘'
    when 'home' then '🏠' when 'power' then '💡' when 'water' then '💧' when 'wifi' then '📶' when 'phone' then '📱'
    when 'tv' then '📺' when 'health' then '💊' when 'pill' then '💊' when 'school' then '🎓' when 'books' then '📚'
    when 'baby' then '🍼' when 'gift' then '🎁' when 'clothes' then '👕' when 'beauty' then '💄' when 'travel' then '✈️'
    when 'sport' then '🏋️' when 'pet' then '🐾' when 'repair' then '🔧' when 'charity' then '🤲'
    else '💳' end
$$;

-- علم الدولة من رمزها (GB ← 🇬🇧)
create or replace function public.country_flag(p_code text)
returns text language sql immutable as $$
  select case when p_code ~ '^[A-Za-z]{2}$' then
    chr(127397 + ascii(upper(substr(p_code, 1, 1)))) || chr(127397 + ascii(upper(substr(p_code, 2, 1)))) end
$$;

create or replace function public.trip_flags(p_codes text[])
returns text language sql immutable as $$
  select coalesce(string_agg(public.country_flag(c), ''), '') from unnest(p_codes) c
$$;

-- «مدى •0253 · Apple Pay» من بيانات رسالة البنك
create or replace function public.push_card_text(m jsonb)
returns text language sql immutable as $$
  select nullif(concat_ws(' · ',
    nullif(concat_ws(' ',
      case m->>'bank' when 'alrajhi' then 'الراجحي' when 'alinma' then 'الإنماء' when 'snb' then 'الأهلي' when 'riyad' then 'الرياض'
        when 'sab' then 'ساب' when 'anb' then 'العربي' when 'albilad' then 'البلاد' when 'aljazira' then 'الجزيرة' when 'bsf' then 'الفرنسي'
        when 'saib' then 'الاستثمار' when 'gib' then 'ميم' when 'stcbank' then 'STC Bank' when 'barq' then 'برق' when 'urpay' then 'urpay'
        when 'd360' then 'D360' when 'vision' then 'Vision' end,
      coalesce(nullif(m->>'card_nickname', ''),
        case m->>'card_type' when 'mada' then 'مدى' when 'visa' then 'فيزا' when 'mastercard' then 'ماستركارد' when 'amex' then 'أمريكان إكسبريس' end),
      '•' || (m->>'card_last4')), ''),
    case m->>'channel' when 'apple_pay' then 'Apple Pay' when 'online' then 'أونلاين' when 'pos' then 'من المحل' when 'bill_payment' then 'سداد' end,
    case when m->>'country' is not null and m->>'country' <> 'SA' then public.country_flag(m->>'country') end), '')
$$;

-- كل سطر يبدأ بعلامة اتجاه عربي
create or replace function public.push_rtl(p text)
returns text language sql immutable as $$
  select regexp_replace(coalesce(p, ''), '(^|\n)', '\1' || chr(8207), 'g')
$$;

create or replace function public.push_to(p_household uuid, p_pref text, p_payload jsonb,
                                          p_only uuid default null, p_except uuid default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
           'payload', p_payload || jsonb_build_object('title', public.push_rtl(p_payload->>'title'),
                                                      'body', public.push_rtl(p_payload->>'body')))), '[]')
  from push_subscriptions s
  join household_members m on m.user_id = s.user_id and m.household_id = s.household_id
  where s.household_id = p_household
    and (p_only is null or s.user_id = p_only)
    and (p_except is null or s.user_id <> p_except)
    and coalesce((m.notify_prefs->>p_pref)::boolean, true)
$$;

-- مصروف جديد: لصاحبه (من رسالة البنك) + للعائلة + الميزانية
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

create or replace function public.push_sms_messages(p_log uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l record;
begin
  select * into l from sms_log where id = p_log;
  if not found or l.status <> 'ignored' or l.message is null or l.user_id is null then return '[]'; end if;
  return public.push_to(l.household_id, 'sms_issue',
    jsonb_build_object(
      'title', case when l.reason ~ 'مرفوضة|ملغاة' then '⛔️ ' || l.reason else '⚠️ رسالة بنك ما سجّلتها' end,
      'body', case when l.reason ~ 'مرفوضة|ملغاة' then '' else coalesce(l.reason, '') || E'\n' end
              || left(regexp_replace(public.sms_mask(l.message), '\s+', ' ', 'g'), 110),
      'tag', 'sms-' || l.id, 'url', './#/messages'),
    p_only => l.user_id);
end $$;

create or replace function public.push_daily_messages(p_today date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := coalesce(p_today, (now() at time zone 'Asia/Riyadh')::date);
  v_month date := date_trunc('month', v_today)::date;
  v_last  int  := extract(day from (v_month + interval '1 month - 1 day'))::int;
  v_out jsonb := '[]';
  h record; r record;
  v_items text[]; v_sum bigint; v_n int; v_first text;
  v_prev date; v_prev2 date; v_t1 bigint; v_t2 bigint; v_top text; v_body text;
  v_y int; v_y1 bigint; v_y2 bigint;
begin
  for h in select distinct household_id as id from push_subscriptions loop
    -- 1) الثابتة المستحقة اليوم ولم تُدفع هذا الشهر
    v_items := '{}'; v_sum := 0; v_n := 0; v_first := null;
    for r in
      select re.name, re.amount from recurring_expenses re
      where re.household_id = h.id and re.is_active and re.start_month <= v_month
        and least(re.day_of_month, v_last) = extract(day from v_today)::int
        and not exists (select 1 from expenses x where x.recurring_id = re.id and x.recurring_period = v_month)
      order by re.amount desc
    loop
      v_items := v_items || (r.name || ' ' || public.fmt_sar(r.amount)); v_sum := v_sum + r.amount; v_n := v_n + 1;
      v_first := coalesce(v_first, r.name || ' ' || public.fmt_sar(r.amount));
    end loop;
    if v_n > 0 then
      v_out := v_out || public.push_to(h.id, 'recurring', jsonb_build_object(
        'title', case when v_n = 1 then '📅 موعد دفع اليوم: ' || v_first else '📅 ' || v_n || ' مصاريف ثابتة موعدها اليوم · ' || public.fmt_sar(v_sum) end,
        'body', case when v_n = 1 then '' else array_to_string(v_items, ' · ') || E'\n' end || 'سجّل الدفع من صفحة الثابتة',
        'tag', 'recurring-' || v_today, 'url', './#/recurring'));
    end if;

    -- 2) ملخص الشهر الماضي (أول يوم في الشهر)
    if extract(day from v_today) = 1 then
      v_prev := (v_month - interval '1 month')::date; v_prev2 := (v_month - interval '2 month')::date;
      select coalesce(sum(total), 0) into v_t1 from monthly_category_totals where household_id = h.id and month = v_prev;
      select coalesce(sum(total), 0) into v_t2 from monthly_category_totals where household_id = h.id and month = v_prev2;
      select c.name || ' ' || public.fmt_sar(sum(t.total)::bigint) into v_top
        from monthly_category_totals t join categories c on c.id = t.category_id
       where t.household_id = h.id and t.month = v_prev group by c.name order by sum(t.total) desc limit 1;
      if v_t1 > 0 then
        v_body := case when v_t2 > 0 then
                    case when v_t1 >= v_t2 then 'أعلى من ' || public.ar_month(v_prev2) || ' بـ ' || round((v_t1 - v_t2) * 100.0 / v_t2) || '%'
                         else 'أقل من ' || public.ar_month(v_prev2) || ' بـ ' || round((v_t2 - v_t1) * 100.0 / v_t2) || '%' end
                  else '' end;
        v_body := concat_ws(' · ', nullif(v_body, ''), 'أعلى تصنيف: ' || v_top,
                    (select '✈️ سفر: ' || public.fmt_sar(sum(amount)::bigint) from expenses
                      where household_id = h.id and trip_id is not null
                        and expense_date >= v_prev and expense_date < v_month having sum(amount) > 0));
        v_out := v_out || public.push_to(h.id, 'monthly', jsonb_build_object(
          'title', '📊 ملخص ' || public.ar_month(v_prev) || ' · ' || public.fmt_sar(v_t1),
          'body', v_body, 'tag', 'month-' || v_prev, 'url', './'));
      end if;
    end if;

    -- 3) ملخص السنة الماضية (1 يناير)
    if extract(month from v_today) = 1 and extract(day from v_today) = 1 then
      v_y := extract(year from v_today)::int - 1;
      v_y1 := coalesce((select total from year_summaries where household_id = h.id and year = v_y and archived_at is not null),
                       (select sum(amount) from expenses where household_id = h.id and expense_date between make_date(v_y, 1, 1) and make_date(v_y, 12, 31)), 0);
      v_y2 := coalesce((select total from year_summaries where household_id = h.id and year = v_y - 1 and archived_at is not null),
                       (select sum(amount) from expenses where household_id = h.id and expense_date between make_date(v_y - 1, 1, 1) and make_date(v_y - 1, 12, 31)), 0);
      if v_y1 > 0 then
        v_out := v_out || public.push_to(h.id, 'monthly', jsonb_build_object(
          'title', '🗓️ ملخص سنة ' || v_y || ' · ' || public.fmt_sar(v_y1),
          'body', case when v_y2 > 0 then
                    case when v_y1 >= v_y2 then 'أعلى من ' || (v_y - 1) || ' بـ ' || round((v_y1 - v_y2) * 100.0 / v_y2) || '%'
                         else 'أقل من ' || (v_y - 1) || ' بـ ' || round((v_y2 - v_y1) * 100.0 / v_y2) || '%' end || ' · '
                  else '' end || 'شوف المقارنة السنوية في التطبيق',
          'tag', 'year-' || v_y, 'url', './#/years'));
      end if;
    end if;
  end loop;
  return v_out;
end $$;

create or replace function public.push_trip_end_messages(p_trip uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t trips; v_total bigint; v_n int; v_days int; v_top text;
begin
  select * into t from trips where id = p_trip;
  if t.id is null or t.status <> 'closed' then return '[]'; end if;
  select coalesce(sum(amount), 0), count(*) into v_total, v_n from expenses where trip_id = t.id;
  if v_n = 0 then return '[]'; end if;
  v_days := coalesce(t.end_date, t.start_date) - t.start_date + 1;
  select c.name into v_top from expenses x join categories c on c.id = x.category_id
   where x.trip_id = t.id group by c.name order by sum(x.amount) desc limit 1;
  return public.push_to(t.household_id, 'travel', jsonb_build_object(
    'title', '🏠 الحمد لله على السلامة · انتهت ' || t.name || ' ' || public.trip_flags(t.countries),
    'body', 'المجموع ' || public.fmt_sar(v_total) || ' · ' || v_n || ' عملية · ' || v_days || ' يوم'
            || case when t.budget > 0 then
                 case when v_total > t.budget then E'\n' || 'أعلى من ميزانيتها بـ ' || public.fmt_sar(v_total - t.budget)
                      else E'\n' || 'أقل من ميزانيتها بـ ' || public.fmt_sar(t.budget - v_total) end
               else '' end
            || coalesce(E'\n' || 'أكثر صرف: ' || v_top, ''),
    'tag', 'trip-end-' || t.id, 'url', './#/trips'));
end $$;

-- إشعار تجربة لأجهزة شخص واحد
create or replace function public.push_test_messages(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth, 'payload',
           jsonb_build_object('title', public.push_rtl('✅ الإشعارات شغالة'),
                              'body', public.push_rtl('🛒 Noon · 83.78 ر.س' || E'\n' || 'كذا بيوصلك كل مصروف من رسالة البنك'),
                              'tag', 'test', 'url', './'))), '[]')
  from push_subscriptions where user_id = p_user
$$;

revoke all on function public.cat_emoji(text) from public, anon;
revoke all on function public.country_flag(text) from public, anon;
revoke all on function public.trip_flags(text[]) from public, anon;
revoke all on function public.push_card_text(jsonb) from public, anon, authenticated;
revoke all on function public.push_rtl(text) from public, anon, authenticated;
revoke all on function public.push_to(uuid, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.push_expense_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_sms_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_daily_messages(date) from public, anon, authenticated;
revoke all on function public.push_trip_end_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_test_messages(uuid) from public, anon, authenticated;
grant execute on function public.push_test_messages(uuid) to service_role;

notify pgrst, 'reload schema';
