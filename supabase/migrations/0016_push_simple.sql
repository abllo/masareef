-- =====================================================================
--  0016: إشعار المصروف صار سطر واحد بس
--   «تم إضافة مبلغ 83.78 ر.س من نون» (iOS يكتب تحته from مصاريف)
--   - للعائلة نفس السطر واسم اللي أضافه بين قوسين
--   - بداية الرحلة والخصم المكرر صارت إشعارات مستقلة (تطلع وقتها فقط)
--   - إشعارات الميزانية باقية مثل ما هي
--   - الإشعار بدون نص تحته لو ما فيه body
-- =====================================================================

create or replace function public.push_to(p_household uuid, p_pref text, p_payload jsonb,
                                          p_only uuid default null, p_except uuid default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
           'payload', p_payload || jsonb_build_object('title', public.push_rtl(p_payload->>'title'),
                                                      'body', case when coalesce(p_payload->>'body', '') = '' then null
                                                                   else public.push_rtl(p_payload->>'body') end))), '[]')
  from push_subscriptions s
  join household_members m on m.user_id = s.user_id and m.household_id = s.household_id
  where s.household_id = p_household
    and (p_only is null or s.user_id = p_only)
    and (p_except is null or s.user_id <> p_except)
    and coalesce((m.notify_prefs->>p_pref)::boolean, true)
$$;

create or replace function public.push_expense_messages(p_expense uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e record; t trips;
  v_label text; v_line text; v_by text;
  v_month date; v_total bigint; v_before bigint; v_budget bigint;
  v_trip_total bigint; v_trip_n int;
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_out jsonb := '[]';
  v_title text; v_body text; v_url text;
begin
  select x.*, c.name as cat into e from expenses x join categories c on c.id = x.category_id where x.id = p_expense;
  if not found then return '[]'; end if;

  v_label := coalesce(nullif(btrim(e.sms_meta->>'merchant'), ''),
                      nullif(btrim(regexp_replace(coalesce(e.description, ''), '^[📩🧾]\s*', '')), ''));
  v_line  := 'تم إضافة مبلغ ' || public.fmt_sar(e.amount) || coalesce(' من ' || v_label, '');
  select display_name into v_by from household_members where household_id = e.household_id and user_id = e.created_by;
  select monthly_budget into v_budget from households where id = e.household_id;
  v_month := date_trunc('month', e.expense_date)::date;
  v_url   := case when e.trip_id is not null then './#/trips/' || e.trip_id else './#/expenses' end;

  -- 1) صاحب العملية: ما سُجّل تلقائياً من رسالة البنك
  if e.source_hash is not null then
    v_out := v_out || public.push_to(e.household_id, 'self',
      jsonb_build_object('title', v_line, 'tag', 'exp-' || e.id, 'url', v_url), p_only => e.created_by);

    -- خصم مكرر: نفس المبلغ ونفس المتجر خلال 15 دقيقة (إشعار مستقل يطلع وقتها فقط)
    if e.merchant_key is not null and exists (
         select 1 from expenses x where x.household_id = e.household_id and x.id <> e.id and x.merchant_key = e.merchant_key
            and x.amount = e.amount and x.created_at between e.created_at - interval '15 minutes' and e.created_at) then
      v_out := v_out || public.push_to(e.household_id, 'self', jsonb_build_object(
        'title', '⚠️ انخصم مرتين؟',
        'body', 'نفس المبلغ ' || public.fmt_sar(e.amount) || coalesce(' من ' || v_label, '') || ' قبل دقائق',
        'tag', 'dup-' || e.id, 'url', './#/expenses'), p_only => e.created_by);
    end if;
  end if;

  -- 2) بقية العائلة: نفس السطر واسم اللي أضافه
  v_out := v_out || public.push_to(e.household_id, 'family',
    jsonb_build_object('title', v_line || coalesce(' (' || v_by || ')', ''), 'tag', 'exp-' || e.id, 'url', v_url),
    p_except => e.created_by);

  -- 3) الرحلة: بدايتها، وميزانيتها عند 80% و100%
  if e.trip_id is not null then
    select * into t from trips where id = e.trip_id;
    select coalesce(sum(amount), 0), count(*) into v_trip_total, v_trip_n from expenses where trip_id = t.id;
    if v_trip_n = 1 then
      v_out := v_out || public.push_to(e.household_id, 'travel', jsonb_build_object(
        'title', '✈️ بدأت ' || t.name || ' ' || public.trip_flags(t.countries),
        'body', 'مصاريف الرحلة منفصلة عن ميزانية الشهر',
        'tag', 'trip-' || t.id, 'url', v_url));
    end if;
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

  -- 4) ميزانية الشهر عند 80% و100% لأول مرة
  select coalesce(sum(amount), 0) into v_total from expenses
   where household_id = e.household_id and trip_id is null
     and expense_date >= v_month and expense_date < (v_month + interval '1 month')::date;
  v_before := v_total - e.amount;
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

revoke all on function public.push_to(uuid, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.push_expense_messages(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
