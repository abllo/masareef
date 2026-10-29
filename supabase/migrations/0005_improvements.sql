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
begin
  select * into t from sms_tokens s where s.token = sms_expense.token;
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
