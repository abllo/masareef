-- =====================================================================
--  0010: إشعارات التطبيق (Web Push) بدل إشعارات الاختصارات
--   الأنواع (كلها مفعّلة افتراضياً، وكل شخص يتحكم بها من الإعدادات):
--     self       مصروفك المسجّل من رسالة البنك
--     family     مصاريف بقية العائلة
--     budget     الميزانية عند 80% و 100%
--     recurring  المصاريف الثابتة يوم موعدها
--     monthly    ملخص الشهر (أول يوم) وملخص السنة (1 يناير)
--     sms_issue  رسالة بنك ما سُجّلت (مرفوضة، بدون مبلغ، …)
--   - قاعدة البيانات تنادي دالة «push» (Edge Function) بدون انتظار، والدالة تبني الرسائل
--     من الدوال هنا وترسلها مشفّرة للأجهزة
--   - مفاتيح VAPID تولّدها الدالة نفسها أول مرة وتحفظها هنا (لا تمر على أحد)
--   - أي فشل في الإشعار لا يوقف تسجيل المصروف أبداً
-- =====================================================================

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- إعدادات الإرسال (للخادم فقط: لا سياسات RLS = لا وصول للمستخدمين)
create table if not exists public.push_config (
  id            int primary key default 1 check (id = 1),
  vapid_public  text,
  vapid_private jsonb,
  hook_secret   text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  function_url  text,
  subject       text not null default 'https://abllo.github.io/masareef/'
);
insert into public.push_config (id) values (1) on conflict do nothing;
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;

-- اشتراكات الأجهزة
create table if not exists public.push_subscriptions (
  endpoint     text primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  p256dh       text not null,
  auth         text not null,
  device       text,
  created_at   timestamptz not null default now(),
  last_ok_at   timestamptz
);
create index if not exists push_subscriptions_household on public.push_subscriptions (household_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists push_subscriptions_own on public.push_subscriptions;
create policy push_subscriptions_own on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.push_subscriptions from anon, authenticated;

-- تفضيلات كل شخص (تنطبق على كل أجهزته) — الكل مفعّل افتراضياً
alter table public.household_members
  add column if not exists notify_prefs jsonb not null
  default '{"self": true, "family": true, "budget": true, "recurring": true, "monthly": true, "sms_issue": true}';

-- مبلغ مقروء: 3,200 ر.س / 45.50 ر.س
create or replace function public.fmt_sar(h bigint)
returns text language sql immutable as $$
  select regexp_replace(to_char(h / 100.0, 'FM999,999,999,990.00'), '\.00$', '') || ' ر.س'
$$;

create or replace function public.ar_month(p date)
returns text language sql immutable as $$
  select (array['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'])[extract(month from p)::int]
$$;

-- ---------- للتطبيق ----------
create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_device text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_h uuid := public.my_household();
begin
  if v_h is null then raise exception 'not in a household'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'invalid subscription';
  end if;
  insert into push_subscriptions (endpoint, household_id, user_id, p256dh, auth, device)
  values (p_endpoint, v_h, auth.uid(), p_p256dh, p_auth, left(p_device, 120))
  on conflict (endpoint) do update
    set household_id = excluded.household_id, user_id = excluded.user_id, p256dh = excluded.p256dh,
        auth = excluded.auth, device = coalesce(excluded.device, push_subscriptions.device);
end $$;

create or replace function public.push_unsubscribe(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid()
$$;

create or replace function public.push_set_prefs(p_prefs jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb; k text; v_clean jsonb := '{}';
begin
  foreach k in array array['self', 'family', 'budget', 'recurring', 'monthly', 'sms_issue'] loop
    if jsonb_typeof(p_prefs->k) = 'boolean' then v_clean := v_clean || jsonb_build_object(k, p_prefs->k); end if;
  end loop;
  update household_members set notify_prefs = notify_prefs || v_clean where user_id = auth.uid()
  returning notify_prefs into v;
  return v;
end $$;

create or replace function public.my_push_status()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prefs', (select notify_prefs from household_members where user_id = auth.uid()),
    'devices', (select count(*) from push_subscriptions where user_id = auth.uid()),
    'public_key', (select vapid_public from push_config where id = 1))
$$;

-- ---------- للدالة فقط (service_role) ----------
create or replace function public.push_config_get()
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(c) from push_config c where id = 1
$$;

-- يحفظ المفاتيح أول مرة فقط (لو تسابق طلبان يبقى الأول)
create or replace function public.push_config_set(p_public text, p_private jsonb, p_function_url text)
returns jsonb language sql security definer set search_path = public as $$
  update push_config
     set vapid_private = case when vapid_public is null then p_private else vapid_private end,
         vapid_public  = coalesce(vapid_public, p_public),
         function_url  = coalesce(p_function_url, function_url)
   where id = 1
  returning to_jsonb(push_config.*)
$$;

create or replace function public.push_result(p_endpoint text, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_ok then update push_subscriptions set last_ok_at = now() where endpoint = p_endpoint;
  else delete from push_subscriptions where endpoint = p_endpoint; -- الجهاز ألغى الاشتراك
  end if;
end $$;

-- أجهزة المستهدفين مع الرسالة (حسب تفضيل كل شخص)
create or replace function public.push_to(p_household uuid, p_pref text, p_payload jsonb,
                                          p_only uuid default null, p_except uuid default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth, 'payload', p_payload)), '[]')
  from push_subscriptions s
  join household_members m on m.user_id = s.user_id and m.household_id = s.household_id
  where s.household_id = p_household
    and (p_only is null or s.user_id = p_only)
    and (p_except is null or s.user_id <> p_except)
    and coalesce((m.notify_prefs->>p_pref)::boolean, true)
$$;

-- مصروف جديد: لصاحبه (من رسالة البنك) + للعائلة + تنبيه الميزانية
create or replace function public.push_expense_messages(p_expense uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e record;
  v_label text; v_amount text; v_by text; v_line text;
  v_month date; v_total bigint; v_before bigint; v_budget bigint;
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_out jsonb := '[]';
  v_title text; v_body text;
begin
  select x.*, c.name as cat into e from expenses x join categories c on c.id = x.category_id where x.id = p_expense;
  if not found then return '[]'; end if;

  v_label  := coalesce(nullif(e.sms_meta->>'merchant', ''), nullif(regexp_replace(coalesce(e.description, ''), '^📩\s*', ''), ''));
  v_amount := public.fmt_sar(e.amount)
              || coalesce(' (' || (e.sms_meta->>'original_amount') || ' ' || (e.sms_meta->>'original_currency') || ')', '');
  v_month  := date_trunc('month', e.expense_date)::date;
  select coalesce(sum(amount), 0) into v_total from expenses
   where household_id = e.household_id and expense_date >= v_month and expense_date < (v_month + interval '1 month')::date;
  v_before := v_total - e.amount;
  select display_name into v_by from household_members where household_id = e.household_id and user_id = e.created_by;
  v_line := coalesce(v_label || ' ← ', '') || e.cat || E'\n' || 'مجموع ' || public.ar_month(v_month) || ': ' || public.fmt_sar(v_total);

  -- 1) صاحب العملية: ما سُجّل تلقائياً من رسالة البنك
  if e.source_hash is not null then
    v_out := v_out || public.push_to(e.household_id, 'self',
      jsonb_build_object('title', 'تم تسجيل ' || v_amount, 'body', v_line, 'tag', 'exp-' || e.id, 'url', './#/expenses'),
      p_only => e.created_by);
  end if;

  -- 2) بقية العائلة
  v_out := v_out || public.push_to(e.household_id, 'family',
    jsonb_build_object('title', coalesce(v_by, 'العائلة') || ': ' || v_amount, 'body', v_line, 'tag', 'exp-' || e.id, 'url', './#/expenses'),
    p_except => e.created_by);

  -- 3) الميزانية: عند تجاوز 80% أو 100% لأول مرة في الشهر الحالي
  select monthly_budget into v_budget from households where id = e.household_id;
  if v_budget > 0 and v_month = date_trunc('month', v_today)::date then
    if v_before < v_budget and v_total >= v_budget then
      v_title := 'تجاوزتم ميزانية ' || public.ar_month(v_month);
      v_body  := 'المصروف ' || public.fmt_sar(v_total) || ' من ' || public.fmt_sar(v_budget)
                 || ' (زيادة ' || public.fmt_sar(v_total - v_budget) || ')';
    elsif v_before * 10 < v_budget * 8 and v_total * 10 >= v_budget * 8 then
      v_title := 'وصلتم 80% من ميزانية ' || public.ar_month(v_month);
      v_body  := 'المصروف ' || public.fmt_sar(v_total) || ' من ' || public.fmt_sar(v_budget)
                 || ' · المتبقي ' || public.fmt_sar(v_budget - v_total);
    end if;
    if v_title is not null then
      v_out := v_out || public.push_to(e.household_id, 'budget',
        jsonb_build_object('title', v_title, 'body', v_body, 'tag', 'budget-' || v_month, 'url', './'));
    end if;
  end if;
  return v_out;
end $$;

-- رسالة بنك ما سُجّلت: لمن أرسلها
create or replace function public.push_sms_messages(p_log uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l record;
begin
  select * into l from sms_log where id = p_log;
  if not found or l.status <> 'ignored' or l.message is null or l.user_id is null then return '[]'; end if;
  return public.push_to(l.household_id, 'sms_issue',
    jsonb_build_object(
      'title', case when l.reason ~ 'مرفوضة|ملغاة' then '⚠️ ' || l.reason else 'رسالة بنك ما سجّلتها' end,
      'body', case when l.reason ~ 'مرفوضة|ملغاة' then '' else coalesce(l.reason, '') || E'\n' end
              || left(regexp_replace(public.sms_mask(l.message), '\s+', ' ', 'g'), 110),
      'tag', 'sms-' || l.id, 'url', './#/messages'),
    p_only => l.user_id);
end $$;

-- يومياً 9 الصبح: الثابتة المستحقة اليوم + ملخص الشهر (يوم 1) + ملخص السنة (1 يناير)
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
        'title', case when v_n = 1 then 'موعد دفع اليوم: ' || v_first else v_n || ' مصاريف ثابتة موعدها اليوم (' || public.fmt_sar(v_sum) || ')' end,
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
        v_body := concat_ws(' · ', nullif(v_body, ''), 'أعلى تصنيف: ' || v_top);
        v_out := v_out || public.push_to(h.id, 'monthly', jsonb_build_object(
          'title', 'ملخص ' || public.ar_month(v_prev) || ': ' || public.fmt_sar(v_t1),
          'body', v_body, 'tag', 'month-' || v_prev, 'url', './'));
      end if;
    end if;

    -- 3) ملخص السنة الماضية (1 يناير)
    if extract(month from v_today) = 1 and extract(day from v_today) = 1 then
      v_y := extract(year from v_today)::int - 1;
      select coalesce(sum(total), 0) into v_y1 from monthly_category_totals
       where household_id = h.id and month between make_date(v_y, 1, 1) and make_date(v_y, 12, 1);
      select coalesce(sum(total), 0) into v_y2 from monthly_category_totals
       where household_id = h.id and month between make_date(v_y - 1, 1, 1) and make_date(v_y - 1, 12, 1);
      if v_y1 > 0 then
        v_out := v_out || public.push_to(h.id, 'monthly', jsonb_build_object(
          'title', 'ملخص سنة ' || v_y || ': ' || public.fmt_sar(v_y1),
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

-- إشعار تجربة لأجهزة شخص واحد
create or replace function public.push_test_messages(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth, 'payload',
           jsonb_build_object('title', 'الإشعارات شغالة ✅', 'body', 'بيوصلك إشعار مثل هذا كل ما تسجّل رسالة بنك مصروفاً', 'tag', 'test', 'url', './'))), '[]')
  from push_subscriptions where user_id = p_user
$$;

-- نداء غير متزامن للدالة (لا يؤخر شيئاً ولا يوقفه)
create or replace function public.push_call(p_household uuid, p_kind text, p_id uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text;
begin
  if not exists (select 1 from push_subscriptions where p_household is null or household_id = p_household) then return; end if;
  select function_url, hook_secret into v_url, v_secret from push_config where id = 1;
  if v_url is null then return; end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('secret', v_secret, 'kind', p_kind, 'id', p_id),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 15000);
exception when others then
  null; -- الإشعار لا يوقف أي عملية
end $$;

create or replace function public.expenses_push_hook()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.push_call(new.household_id, 'expense', new.id);
  return null;
end $$;
drop trigger if exists expenses_push on public.expenses;
create trigger expenses_push after insert on public.expenses for each row execute function public.expenses_push_hook();

create or replace function public.sms_log_push_hook()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.push_call(new.household_id, 'sms', new.id);
  return null;
end $$;
drop trigger if exists sms_log_push on public.sms_log;
create trigger sms_log_push after insert on public.sms_log for each row
  when (new.status = 'ignored' and new.message is not null)
  execute function public.sms_log_push_hook();

-- الجدولة اليومية: 6:00 UTC = 9:00 الصبح بتوقيت الرياض
select cron.unschedule(jobid) from cron.job where jobname = 'masareef-daily';
select cron.schedule('masareef-daily', '0 6 * * *', 'select public.push_call(null, ''daily'')');

revoke all on function public.fmt_sar(bigint) from public, anon;
revoke all on function public.ar_month(date) from public, anon;
revoke all on function public.push_subscribe(text, text, text, text) from public, anon;
revoke all on function public.push_unsubscribe(text) from public, anon;
revoke all on function public.push_set_prefs(jsonb) from public, anon;
revoke all on function public.my_push_status() from public, anon;
grant execute on function public.push_subscribe(text, text, text, text) to authenticated;
grant execute on function public.push_unsubscribe(text) to authenticated;
grant execute on function public.push_set_prefs(jsonb) to authenticated;
grant execute on function public.my_push_status() to authenticated;

revoke all on function public.push_config_get() from public, anon, authenticated;
revoke all on function public.push_config_set(text, jsonb, text) from public, anon, authenticated;
revoke all on function public.push_result(text, boolean) from public, anon, authenticated;
revoke all on function public.push_to(uuid, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.push_expense_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_sms_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_daily_messages(date) from public, anon, authenticated;
revoke all on function public.push_test_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_call(uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.expenses_push_hook() from public, anon, authenticated;
revoke all on function public.sms_log_push_hook() from public, anon, authenticated;
grant execute on function public.push_config_get() to service_role;
grant execute on function public.push_config_set(text, jsonb, text) to service_role;
grant execute on function public.push_result(text, boolean) to service_role;
grant execute on function public.push_expense_messages(uuid) to service_role;
grant execute on function public.push_sms_messages(uuid) to service_role;
grant execute on function public.push_daily_messages(date) to service_role;
grant execute on function public.push_test_messages(uuid) to service_role;

notify pgrst, 'reload schema';
