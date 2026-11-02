-- =====================================================================
--  0019: فلوسك اللي تنتقل بين حساباتك، والمبلغ اللي ذكره البنك
--   1) شحن محفظتك أو بنكك الرقمي (مثل «شراء إنترنت 200 SAR … من STC Bank»
--      أو «إضافة أموال لمحفظتك») = تحويل بين حساباتك: ما ينسجل مصروفاً ولا دخلاً
--   2) «مع ادخار 10 SAR في حساب…» ادخار تلقائي لحسابك: مو جزء من المبلغ
--   3) المبلغ الإجمالي اللي ذكره البنك («إجمالى المبلغ المستحق: 250.00 SAR»)
--      هو المرجع: ما يتحوّل من جديد وما تنضاف له الرسوم مرة ثانية،
--      وسعر التحويل اللي ذكره البنك يتقدم على سعر اليوم
--   4) البنك يُعرف من اسم مرسل الرسالة
--   5) «ليست مصروفاً»: تختارون متجراً ما تنسجل عملياته بعد اليوم
-- =====================================================================

-- ---------- المحافظ والبنوك الرقمية (بعد توحيد الإملاء) ----------
create or replace function public.wallet_rx()
returns text language sql immutable as $$
  select 'stc ?bank|stc ?pay|stcpay|بنك ?stc|stc ?بنك|اس ?تي ?سي ?(باي|بنك)|\murpay\M|يور ?باي|\mbarq\M|برق|\md ?360\M|دي ?360|\mtiqmo\M|تيقمو|alinma ?pay|الانماء ?باي|mobily ?pay|موبايلي ?باي|vision ?bank|فيجن ?بنك'
$$;

-- ---------- متاجر اخترتم ما تنسجل عملياتها (تحويل لحسابكم مثلاً) ----------
create table if not exists public.sms_ignored_merchants (
  household_id   uuid not null references public.households(id) on delete cascade,
  merchant_key   text not null check (char_length(merchant_key) between 1 and 120),
  merchant_label text not null check (char_length(merchant_label) between 1 and 120),
  created_by     uuid default auth.uid() references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  primary key (household_id, merchant_key)
);
alter table public.sms_ignored_merchants enable row level security;
drop policy if exists sms_ignored_select on public.sms_ignored_merchants;
create policy sms_ignored_select on public.sms_ignored_merchants for select to authenticated using (public.is_member(household_id));
drop policy if exists sms_ignored_insert on public.sms_ignored_merchants;
create policy sms_ignored_insert on public.sms_ignored_merchants for insert to authenticated with check (public.is_member(household_id));
drop policy if exists sms_ignored_delete on public.sms_ignored_merchants;
create policy sms_ignored_delete on public.sms_ignored_merchants for delete to authenticated using (public.is_member(household_id));
grant select, insert, delete on public.sms_ignored_merchants to authenticated;

-- ---------- قراءة الرسالة ----------
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
  nlow       text;      -- النص بعد توحيد الإملاء (أ/إ/آ ← ا، ة ← ه، ى ← ي)
  local_kind text;
  v_kind     text;
  v_party    text;
  v_inc_kind text;
  v_sender   text;      -- اسم مرسل الرسالة (من الاختصار)
  v_total    numeric;   -- المبلغ الإجمالي اللي ذكره البنك (شامل الرسوم والضريبة)
  v_rate     numeric;   -- سعر التحويل اللي ذكره البنك
  v_base     numeric;
  v_sars     numeric[]; -- المبالغ بالريال المذكورة في الرسالة (بدون سطر الرصيد)
  v_own_ok   boolean;   -- المرسل نفسه ليس محفظة (عشان «من: STC Bank» تعني تحويل لمحفظتك)
begin
  msg := translate(p_message, '٠١٢٣٤٥٦٧٨٩٫٬', '0123456789.,');
  msg := regexp_replace(msg, '(\d),(\d)', '\1\2', 'g');
  low := lower(msg);
  nlow := public.ar_norm(msg);
  v_sender := nullif(btrim(current_setting('masareef.sms_sender', true)), '');
  v_own_ok := coalesce(public.bank_from_text(v_sender), '-') not in ('stcbank', 'urpay', 'barq', 'd360', 'vision');

  -- رموز التحقق لا تُرسل لأي جهة ولا يُحفظ نصها
  if low ~ '(otp|رمز التحقق|رمز التفعيل|رمز الدخول|كلمة المرور|كلمة السر|verification|one time|passcode)' then
    return jsonb_build_object('status', 'ignored', 'reason', 'رمز تحقق', 'private', true, 'source', 'rules');
  end if;
  -- رسالة لا تشبه رسائل البنوك أو الفواتير أو أبشر (رسالة شخصية مثلاً): لا تُحفظ ولا تُرسل لأي جهة
  if nlow !~ '[0-9]' or nlow !~ '(sar|ريال|ر\.?\s?س|\*\s?[0-9]{3,4}|بطاقه|حساب|رصيد|مدي|فيزا|ماستر|\mmada\M|visa|master|card|account|iban|ايبان|apple ?pay|ابل ?باي|شراء|ايداع|حواله|تحويل|سحب|سداد|استرداد|مسترد|استرجاع|راتب|اضافه|خصم|debit|credit|purchase|withdraw|transfer|deposit|refund|فاتوره|تنتهي|انتهاء|صلاحيه|تجديد|ابشر|absher|استماره|رخصه|جواز|اقامه|هويه|تامين|وثيقه)' then
    return jsonb_build_object('status', 'ignored', 'reason', 'ليست رسالة بنك', 'private', true, 'silent', true, 'source', 'rules');
  end if;

  -- نوع العملية من النص (احتياط لو تعذّر Claude)
  local_kind := case
    when nlow ~ '(سداد (ال)?بطاقه|تسديد (ال)?بطاقه|سداد مستحقات|بين حساباتك|حساباتك الخاصه|لحسابك الاخر|credit card payment|card payment received|own account|كشف (ال)?حساب|الحد الادني (للسداد|المستحق)|minimum (payment|due))' then 'ignore'
    -- شراء أو تحويل طرفه الثاني محفظة أو بنك رقمي (مثل «من STC Bank»): فلوسك انتقلت من حسابك لمحفظتك
    when v_own_ok and nlow ~ ('(من|لدي|عند|الي|التاجر|المتجر|المستفيد|\mat\M|\mto\M|merchant)\s*[:：]?\s*(sa\s*/\s*)?\*?\s*(' || public.wallet_rx() || ')') then 'own'
    -- «إضافة أموال لمحفظتك» من بطاقتك
    when nlow ~ '(شحن (ال)?محفظ|تعبئه (ال)?محفظ|اضافه اموال|اضافه رصيد (ال)?محفظ|(الي|في|ل) ?محفظتك|wallet top ?-?up|top ?-?up (your |to )?wallet|add(ed)? money)'
         and nlow !~ '(راتب|salary|حواله|تحويل وارد|استلام|استلمت|received from)' then 'own'
    when nlow ~ '(استرداد|استرجاع|مسترد|مسترجع|refund|عكس عمليه|عمليه عكسيه|معكوس|reversal|reversed)' then 'refund'
    when nlow ~ '(راتب|salary|payroll|حواله وارده|حوالات وارده|تحويل وارد|وارده من|اضافه مبلغ|تمت اضافه|تم اضافه|اضيف|ايداع|incoming|deposit|credited|received from)' then 'income'
    when nlow ~ '(سحب نقدي|سحب من الصراف|سحب صراف|صراف الي|\matm\M|cash withdrawal)' then 'cash'
    when nlow ~ '(شراء|purchase|\mpos\M|نقاط البيع)' then 'purchase'
    when regexp_replace(nlow, 'سعر (ال)?تحويل', '', 'g') ~ '(حواله|تحويل|transfer|\msarie\M)' then 'transfer'
    else 'purchase' end;
  if local_kind = 'ignore' then
    return jsonb_build_object('status', 'ignored', 'reason', 'تحويل بين حساباتك أو سداد بطاقة', 'silent', true, 'source', 'rules');
  end if;
  if local_kind = 'own' then
    return jsonb_build_object('status', 'ignored', 'reason', 'تحويل لمحفظتك (بين حساباتك)', 'silent', true, 'source', 'rules');
  end if;
  if low ~ '(مرفوض|declined|rejected|غير ناجح|فشل|failed|unsuccessful|insufficient|رصيد غير كاف|ملغا|ملغي|تم إلغاء|تم الغاء|cancelled|canceled)' then
    return jsonb_build_object('status', 'ignored', 'reason', 'عملية مرفوضة أو ملغاة', 'source', 'rules');
  end if;

  -- ---------- القراءة المحلية: تعمل دائماً وتكون الاحتياط ----------
  body := regexp_replace(low, '(الرصيد|رصيد|المتاح|متاح|balance|\mbal\M|avail|limit|الحد|رسوم|عمولة|\mfees?\M)[^\n]*', '', 'g');
  body := regexp_replace(body, '(مع [اإ]دّ?خار|[اإ]دّ?خار [0-9.]+ ?(sar|ريال|ر\.?\s?س)|round ?-?up)[^\n]*', '', 'g');
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
  -- المبلغ الإجمالي اللي ذكره البنك («إجمالى المبلغ المستحق: 250.00 SAR»): شامل الرسوم والضريبة، وهو المرجع
  m := regexp_match(nlow, '(اجمالي ?(ال)?مبلغ|المبلغ الاجمالي|الاجمالي|اجمالي|المبلغ المخصوم|total amount|total charged|amount charged|\mtotal\M)([^0-9\n]{0,30})([0-9]+(\.[0-9]{1,2})?)[ \t]*(sar|ريال|ر\.?\s?س)?');
  if m is not null and m[3] !~ '(رصيد|balance|limit|الحد|متاح|avail)' and (m[3] ~ '(sar|ريال|ر\.?\s?س)' or m[6] is not null) then
    v_total := m[4]::numeric;
  end if;
  -- سعر التحويل اللي ذكره البنك («سعر تحويل العملات: 3.7550»)
  m := regexp_match(nlow, '(سعر (ال)?(تحويل|صرف|الصرف|التحويل)( العملات| العمله)?|exchange rate|fx rate|conversion rate)[^0-9\n]{0,15}([0-9]+(\.[0-9]+)?)');
  if m is not null and m[5]::numeric > 0 and m[5]::numeric < 10000 then v_rate := m[5]::numeric; end if;
  select array_agg(coalesce(x[1], x[2])::numeric) into v_sars
  from regexp_matches(regexp_replace(low, '(الرصيد|رصيد|المتاح|متاح|balance|\mbal\M|avail|limit|الحد)[^\n]*', '', 'g'),
    '(?:sar|ر\.?\s?س(?![ء-ي])|ريال)\s*:?\s*([0-9]+(?:\.[0-9]{1,2})?)|([0-9]+(?:\.[0-9]{1,2})?)\s*(?:sar|ر\.?\s?س(?![ء-ي])|ريال)', 'g') x;
  v_merchant := trim(substring(msg from '(?i)(?:لدى|عند|التاجر|المتجر|\mat\M|merchant)\s*:?\s*([^\n]{2,60})'));
  -- بعض البنوك تكتب المتجر بعد «من:» (STC Bank)
  if v_merchant is null and local_kind = 'purchase' then
    v_merchant := trim(regexp_replace(substring(msg from '(?:^|\s)من\s*:\s*([^\n]{2,60})'),
                                      '\s+(سعر|ضريبة|رسوم|إجمال|اجمال|الرصيد|الدولة|في|فى)[ :].*$', ''));
  end if;
  v_party := case local_kind
    when 'income' then trim(substring(msg from '(?i)(?:من|المرسل|المحول|from|sender)\s*:?\s*([^\n]{2,60})'))
    when 'transfer' then trim(substring(msg from '(?i)(?:المستفيد|الى|إلى|to|beneficiary)\s*:?\s*([^\n]{2,60})')) end;

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
    when hay ~ '(بنزين|وقود|محروقات|\m[gj][ .-]?oil\M|جي ?[اأإ]ويل|جى ?[اأإ]ويل|\mfuel\M|petrol|بترول|sasco|ساسكو|aldrees|الدريس|\mnaft\M|نفط|محطة|محطه|gas station|oomco|apsco|wafi energy|adnoc|ادنوك|أدنوك)' then 'محطات الوقود'
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
    when 'التسوق والمشتريات' then 'bag' when 'الفواتير والاشتراكات' then 'receipt' when 'مصاريف السيارة' then 'car' when 'محطات الوقود' then 'fuel'
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

kind — what the message reports (spelling varies between banks: أ/ا/إ, ة/ه, ى/ي — read the meaning, not the exact spelling):
- purchase: a completed payment that takes money out: card / mada / Apple Pay / POS purchases (in Saudi Arabia or abroad), online purchases, bill payments (سداد/فاتورة), subscriptions, government fees.
- refund: money returned for an earlier purchase (استرداد / استرجاع / مبلغ مسترد / عملية عكسية / reversal). merchant = the shop that refunded; amount_sar = the refunded amount (positive).
- cash_withdrawal: ATM or cash withdrawal (سحب نقدي / صراف آلي).
- transfer_out: money sent to another person or company (حوالة صادرة / تحويل إلى / حوالة محلية أو دولية / سريع). counterparty = the beneficiary name if shown. Transfers between the customer's own accounts and credit-card payments are ignore.
- income: money received into the account: salary (راتب), incoming transfer (حوالة واردة / تحويل وارد), deposit (إيداع), «تمت إضافة مبلغ إلى حسابك». counterparty = the payer (employer, person or company) if shown; income_kind = salary, transfer, deposit or other.
- ignore: OTP/verification codes, declined/failed/cancelled operations, transfers between own accounts, credit-card payments, balance or limit alerts, ads/promotions, card activation or statements, bill-issued notices, loyalty points. Give ignore_reason as a short Arabic phrase.
- Topping up the customer's OWN wallet or digital bank is a transfer between own accounts → ignore with ignore_reason «تحويل لمحفظتك»: a purchase / payment / transfer whose merchant or recipient is a wallet or digital bank — STC Bank, stc pay, urpay, Barq, D360, Tiqmo, Alinma Pay, Mobily Pay, Vision Bank (e.g. «شراء إنترنت 200 SAR … من STC Bank») — and the wallet's own «إضافة أموال / شحن المحفظة» notice funded from the customer's card or account. Purchases made WITH the wallet's card at a real shop are normal purchases.

Amounts (copy numbers exactly as written; never calculate):
- amount_sar = the transaction amount in Saudi riyals as stated, before any separately listed fee. If the message shows a foreign amount AND its SAR equivalent, use the SAR equivalent. If only a foreign amount is shown, set amount_sar to null and fill original_amount and original_currency (ISO 4217 code, e.g. GBP, EUR, USD, TRY).
- total_sar = the final total the bank says was charged in SAR, including fees and VAT (إجمالي المبلغ المستحق / المبلغ الإجمالي / المبلغ المخصوم / Total), else null.
- fees_sar = fees or commission for THIS transaction explicitly stated in SAR (رسوم العملية / رسوم عملية دولية / international transaction fee), else null. VAT of 0.00 is not a fee.
- fx_rate = the exchange rate if the message states it (سعر تحويل العملات / exchange rate), else null.
- «مع ادخار 10 SAR في حساب…» (automatic round-up savings to the customer's own account) is not part of the amount and not a fee — leave it out.
- Never use the balance, available amount or credit limit. Digits shown as • are masked balances.

merchant: the clean shop/brand name a person would write, without branch numbers, city, country or terminal codes ("STARBUCKS 1234 JEDDAH SA" → "Starbucks", "HUNGERSTATION RIYADH" → "HungerStation", "TESCO STORES 3214 LONDON GB" → "Tesco", "مطعم البيك فرع ٣" → "البيك"). Keep Arabic names in Arabic.

category: exactly one of the family's categories (the enum). For a merchant listed under "Learned", always use the learned category. Saudi hints: HungerStation, Jahez, Mrsool, ToYou, Keeta, The Chefz, Ninja → delivery apps; Panda, Danube, Othaim, Carrefour, Tamimi, Lulu, Nesto, Farm, Bin Dawood → groceries; cafes, restaurants, bakeries, sweets → restaurants & cafes; STC, Mobily, Zain, SEC electricity, National Water, Netflix, Shahid, Spotify, Apple, Google, iCloud → bills & subscriptions; car wash, workshops, tyres, oil change → car; Amazon, Noon, Shein, Trendyol, IKEA, Jarir, Extra, Namshi, Centrepoint, Max, Zara, Tamara/Tabby instalments → shopping; Amazon Now, Nana, Tamimi, water delivery (Nova, Berain, النبع) → groceries; Nahdi, Al-Dawaa, Whites, pharmacies, clinics, hospitals, labs, dentists, opticians → health; fuel stations — Aldrees (الدريس), SASCO (ساسكو), Naft (نفط), J Oil / JOIL / G Oil (جي أويل), OOMCO, APSCO, Wafi Energy, ADNOC, Petromin stations, or any merchant whose name says محطة / بترول / بنزين / وقود / petrol / fuel / gas station → the fuel category (محطات الوقود) if the family has one, even when the station also sells coffee or snacks (a station name may end with its branch district, e.g. "joil Laban" is a JOIL station in Laban — never classify by the district word); car services (ACDelco, Petromin Express, oil change), parking (Woqoof, Mawqif), Careem, Uber, Jeeny → car; HiNet → bills; Smasco, Musaned, recruitment / hourly maid services → the domestic worker category if the family has one; airlines (Saudia, flynas, flyadeal, Qatar Airways, Emirates), Almosafer, Booking.com, Agoda, Airbnb, VFS / visa centres → the travel bookings category if the family has one; Ehsan (إحسان), Jood, charities, donations → the charity category if the family has one; barbers, salons (صالون), spas, massage, laundry (مغسلة ملابس, Gaseel), tailors (خياط) → the personal care category if the family has one. Abroad, use the same logic for local merchants (supermarkets → groceries, restaurants → restaurants, etc.): purchases made abroad keep their real category because the app groups them into trips automatically — never put them in a travel category. For cash_withdrawal, transfer_out and income use the family's "other" category (it is not used).
Use "__new__" ONLY when the purchase clearly belongs to a common spending area that none of the categories covers (for example education, kids) — never for a single merchant and never for a near-duplicate of an existing category. Then fill new_category with a short Arabic name (2–3 words) and an icon from its enum. When unsure, use the family's "other" category.

bank: the bank or wallet that sent the message / issued the card (the SMS sender, when given, is that bank): alrajhi (الراجحي), alinma (الإنماء), snb (البنك الأهلي), riyad (بنك الرياض), sab (ساب), anb (البنك العربي الوطني), albilad (بنك البلاد), aljazira (بنك الجزيرة), bsf (البنك السعودي الفرنسي), saib (البنك السعودي للاستثمار), gib (بنك الخليج الدولي / ميم), stcbank (STC Bank / stc pay), barq (برق), urpay, d360, vision (Vision Bank), other; null if the message does not say.
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
- A bill-issued notice from a utility or telecom company (الكهرباء SEC، المياه NWC، STC، موبايلي، زين…: «صدرت فاتورة»، «فاتورتك المستحقة») → kind ignore, ignore_reason «فاتورة صادرة», and renewal kind bill with title (e.g. «فاتورة الكهرباء»), subject = the place or line if stated (e.g. البيت), due_date = the stated due date (Gregorian YYYY-MM-DD) or null, amount_sar = the bill amount.
confidence: 0 to 1.$sys$,
      format(E'Today: %s (Asia/Riyadh)\nSMS sender: %s\n"Other" category: %s\nLearned (merchant ← category):\n%s\n\nMessage:\n<<<\n%s\n>>>',
             v_today, coalesce(v_sender, '-'), coalesce(v_other, '-'), coalesce(v_learned, '- (none yet)'), public.sms_mask(msg)),
      jsonb_build_object(
        'name', 'record_transaction',
        'description', 'Record what the bank SMS says.',
        'input_schema', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'kind',              jsonb_build_object('type', 'string', 'enum', jsonb_build_array('purchase', 'refund', 'cash_withdrawal', 'transfer_out', 'income', 'ignore')),
            'counterparty',      jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'income_kind',       jsonb_build_object('type', jsonb_build_array('string', 'null'), 'enum', jsonb_build_array('salary', 'transfer', 'deposit', 'other', null)),
            'ignore_reason',     jsonb_build_object('type', 'string'),
            'amount_sar',        jsonb_build_object('type', jsonb_build_array('number', 'null')),
            'original_amount',   jsonb_build_object('type', jsonb_build_array('number', 'null')),
            'original_currency', jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'fees_sar',          jsonb_build_object('type', jsonb_build_array('number', 'null')),
            'total_sar',         jsonb_build_object('type', jsonb_build_array('number', 'null')),
            'fx_rate',           jsonb_build_object('type', jsonb_build_array('number', 'null')),
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
                                     'subscription', 'contract', 'rent', 'school', 'bill', 'other')),
                                   'title', jsonb_build_object('type', 'string'),
                                   'subject', jsonb_build_object('type', jsonb_build_array('string', 'null')),
                                   'period_months', jsonb_build_object('type', jsonb_build_array('integer', 'null')),
                                   'due_date', jsonb_build_object('type', jsonb_build_array('string', 'null')),
                                   'amount_sar', jsonb_build_object('type', jsonb_build_array('number', 'null'))),
                                   'required', jsonb_build_array('kind', 'title')),
            'confidence',        jsonb_build_object('type', 'number')),
          'required', jsonb_build_array('kind', 'category', 'confidence'))),
      600);
    if v_ai is null then v_ai_note := 'تعذّر الذكاء الاصطناعي، استُخدمت القراءة المحلية'; end if;
  end if;

  if v_ai is not null then
    v_kind := case v_ai->>'kind' when 'purchase' then 'purchase' when 'refund' then 'refund' when 'cash_withdrawal' then 'cash'
                when 'transfer_out' then 'transfer' when 'income' then 'income' when 'ignore' then 'ignore'
                else case when (v_ai->>'is_purchase') = 'false' then 'ignore' end end;
    v_party := coalesce(nullif(btrim(v_ai->>'counterparty'), ''), v_party);
    v_inc_kind := v_ai->>'income_kind';
    if v_kind = 'ignore' then
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
    if v_total is null and coalesce(v_ai->>'total_sar', '') ~ '^[0-9]+(\.[0-9]+)?$'
       and (v_ai->>'total_sar')::numeric > 0 and (v_ai->>'total_sar')::numeric = any(coalesce(v_sars, '{}')) then
      v_total := (v_ai->>'total_sar')::numeric;
    end if;
    if v_rate is null and coalesce(v_ai->>'fx_rate', '') ~ '^[0-9]+(\.[0-9]+)?$'
       and (v_ai->>'fx_rate')::numeric > 0 and (v_ai->>'fx_rate')::numeric < 10000 then
      v_rate := (v_ai->>'fx_rate')::numeric;
    end if;
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
  v_kind := coalesce(v_kind, local_kind, 'purchase');
  if length(coalesce(v_last4, '')) <> 4 then v_last4 := null; end if;
  -- الطرف الثاني محفظة أو بنك رقمي (STC Bank وأمثاله): تحويل لمحفظتك، مو مصروف ولا دخل
  if v_own_ok and v_kind in ('purchase', 'income', 'transfer')
     and public.ar_norm(coalesce(case when v_kind = 'purchase' then v_merchant else v_party end, '')) ~ public.wallet_rx() then
    return jsonb_build_object('status', 'ignored', 'reason', 'تحويل لمحفظتك (بين حساباتك)', 'silent', true, 'source', v_source);
  end if;
  -- البنك: اسم مرسل الرسالة أدق من النص
  v_bank := coalesce(public.bank_from_text(v_sender), v_bank);

  -- ---------- البطاقة المعروفة: تكمل البنك والنوع إن لم تذكرهما الرسالة ----------
  if v_last4 is not null and v_kind in ('purchase', 'refund', 'cash') then
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

  -- ---------- المبلغ الإجمالي اللي ذكره البنك هو المرجع: ما نحوّل ولا نضيف رسوم ----------
  if v_total is not null and v_total > 0 then
    amt_text := v_total::text;
    v_meta := v_meta || jsonb_build_object('total_stated', true)
      || case when v_fees > 0 and v_fees < v_total then jsonb_build_object('fees_sar', v_fees) else '{}'::jsonb end
      || case when v_rate is not null and v_orig_amt is not null then jsonb_build_object('fx_rate', v_rate, 'fx_source', 'bank') else '{}'::jsonb end;
    v_fees := null;
  -- سعر التحويل اللي ذكره البنك يتقدم على سعر اليوم
  elsif amt_text is null and v_orig_amt is not null and v_orig_amt > 0 and v_rate is not null then
    amt_text := round(v_orig_amt * v_rate, 2)::text;
    v_meta := v_meta || jsonb_build_object('fx_rate', v_rate, 'fx_source', 'bank');
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
  -- الرسوم المذكورة تُضاف للمبلغ، إلا لو كان المبلغ شاملها أصلاً
  -- (المبلغ ناقص الرسوم = المبلغ الأجنبي × سعر البنك، أو مذكور بالريال في الرسالة)
  if v_fees is not null and v_fees > 0 and v_fees < amt_text::numeric then
    v_base := amt_text::numeric - v_fees;
    if not ((v_orig_amt is not null and v_rate is not null and abs(v_base - v_orig_amt * v_rate) <= greatest(0.05, v_base * 0.002))
            or exists (select 1 from unnest(v_sars) s where abs(s - v_base) < 0.005)) then
      amt_text := (amt_text::numeric + v_fees)::text;
    end if;
    v_meta := v_meta || jsonb_build_object('fees_sar', v_fees);
  end if;
  v_amount := round(amt_text::numeric * 100)::bigint;
  if v_amount <= 0 or v_amount > 100000000000 then
    return jsonb_build_object('status', 'ignored', 'reason', 'مبلغ غير منطقي', 'source', v_source);
  end if;

  -- الدخل: راتب أو حوالة واردة أو إيداع (جدول الدخل، بدون تصنيف)
  if v_kind = 'income' then
    return jsonb_strip_nulls(jsonb_build_object('status', 'income', 'source', v_source, 'kind', 'income',
      'amount', v_amount, 'date', v_date, 'payer', left(nullif(btrim(v_party), ''), 80),
      'income_kind', case when v_inc_kind in ('salary', 'transfer', 'deposit', 'other') then v_inc_kind
                          when nlow ~ '(راتب|salary|payroll)' then 'salary'
                          when nlow ~ '(حواله|تحويل|transfer)' then 'transfer'
                          when nlow ~ '(ايداع|deposit)' then 'deposit' else 'other' end,
      'meta', jsonb_strip_nulls(jsonb_build_object('bank', v_bank, 'source', v_source)),
      'note', v_ai_note));
  end if;
  -- الحوالة الصادرة: تُسجَّل فقط لو طابقت مصروفاً ثابتاً (sms_expense)
  if v_kind = 'transfer' then
    return jsonb_strip_nulls(jsonb_build_object('status', 'ok', 'source', v_source, 'kind', 'transfer',
      'amount', v_amount, 'date', v_date, 'merchant', left(nullif(btrim(v_party), ''), 80),
      'meta', jsonb_strip_nulls(jsonb_build_object('bank', v_bank, 'source', v_source)), 'note', v_ai_note));
  end if;

  -- شراء من محل بالريال بدون أي إشارة دولية = داخل السعودية
  if v_country is null and v_orig_cur is null and not v_intl and v_channel in ('pos', 'apple_pay') then v_country := 'SA'; end if;

  v_meta := v_meta || jsonb_strip_nulls(jsonb_build_object(
    'bank', v_bank, 'card_last4', v_last4, 'card_type', v_ctype, 'card_kind', v_ckind, 'channel', v_channel,
    'country', v_country, 'international', case when v_intl then true end,
    'card_nickname', v_card.nickname,
    'original_amount', case when v_orig_cur is not null and v_orig_cur <> 'SAR' then v_orig_amt end,
    'original_currency', case when v_orig_cur is not null and v_orig_cur <> 'SAR' then v_orig_cur end));

  if v_kind = 'cash' then
    v_merchant := 'سحب نقدي';
    select id, name into v_cat_id, v_cat_name from categories
     where household_id = p_household and icon = 'cash' and not is_archived order by sort_order limit 1;
  else
    v_key := public.normalize_merchant(v_merchant);
    if v_key is not null and exists (select 1 from sms_ignored_merchants where household_id = p_household and merchant_key = v_key) then
      return jsonb_build_object('status', 'ignored', 'reason', 'تحويل لحسابك: ' || left(coalesce(v_merchant, v_key), 60), 'silent', true, 'source', v_source);
    end if;
  end if;

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
    'kind', v_kind,
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

-- ---------- الاختصار: يمرر اسم المرسل لقراءة الرسالة ----------
create or replace function public.sms_expense(token text, message text, sender text)
returns text
language plpgsql security definer set search_path = public
set statement_timeout to '40s'
as $$
declare
  t         public.sms_tokens;
  v_hash    text;
  r         jsonb;
  v_amount  bigint;
  v_date    date;
  v_label   text;
  v_linked  text;
  v_id      uuid;
  v_logmsg  text;
  v_kind    text;
  v_orig    expenses;
  v_rec     recurring_expenses;
  v_payer   text;
  v_inc     text;
  v_hints   text;
  v_inc_id  uuid;
  v_sender  text := left(nullif(btrim(sender), ''), 60);
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

  -- ليست من بنك أو جهة معروفة: لا يُحفظ نصها ولا تُرسل لأي جهة (نحفظ اسم المرسل فقط عشان تسمحون له لو كان بنكاً)
  if not public.sms_sender_known(t.household_id, v_sender) then
    if v_sender !~ '^[+0-9 ()-]+$' then
      insert into sms_log (household_id, user_id, message, status, reason, source, result)
      values (t.household_id, t.user_id, null, 'ignored', 'مرسل غير معروف: ' || v_sender, 'rules',
              jsonb_build_object('status', 'ignored', 'sender', v_sender, 'silent', true));
    end if;
    return 'تجاهل: مرسل غير معروف';
  end if;

  v_hash := md5(t.user_id::text || message);
  if exists (select 1 from expenses where source_hash = v_hash) or exists (select 1 from incomes where source_hash = v_hash) then
    insert into sms_log (household_id, user_id, message, status, reason) values (t.household_id, t.user_id, message, 'duplicate', 'مسجّلة مسبقاً');
    return 'مسجّلة مسبقاً';
  end if;

  perform set_config('masareef.sms_sender', coalesce(v_sender, ''), true);
  r := public.sms_parse(t.household_id, message, true, false);
  if v_sender is not null then r := r || jsonb_build_object('sender', v_sender); end if;
  v_logmsg := case when (r->>'private') = 'true' then null else message end;

  if r->>'status' = 'ignored' then
    insert into sms_log (household_id, user_id, message, status, reason, source, result)
    values (t.household_id, t.user_id, v_logmsg, 'ignored', r->>'reason', r->>'source', r);
    return 'تجاهل: ' || (r->>'reason');
  end if;

  v_amount := (r->>'amount')::bigint;
  v_date   := (r->>'date')::date;

  -- ---------- الدخل ----------
  if r->>'status' = 'income' then
    v_payer := nullif(btrim(r->>'payer'), '');
    v_inc := coalesce(r->>'income_kind', 'other');
    -- جهة الراتب اللي حددها العضو (مثل جهة عمله)
    select salary_payer into v_hints from household_members where user_id = t.user_id and household_id = t.household_id;
    if v_inc <> 'salary' and coalesce(btrim(v_hints), '') <> '' and exists (
         select 1 from regexp_split_to_table(v_hints, '[،,;\n]+') k
          where length(btrim(k)) >= 2
            and public.ar_norm(coalesce(v_payer, '') || ' ' || message) like '%' || public.ar_norm(btrim(k)) || '%') then
      v_inc := 'salary';
    end if;
    insert into incomes (household_id, user_id, amount, income_date, kind, payer, meta, source_hash)
    values (t.household_id, t.user_id, v_amount, v_date, v_inc, left(v_payer, 80), r->'meta', v_hash)
    on conflict (source_hash) do nothing
    returning id into v_inc_id;
    if v_inc_id is null then return 'مسجّلة مسبقاً'; end if;
    insert into sms_log (household_id, user_id, message, status, reason, source, result, income_id)
    values (t.household_id, t.user_id, v_logmsg, 'income',
            case v_inc when 'salary' then 'راتب' when 'transfer' then 'حوالة واردة' when 'deposit' then 'إيداع' else 'دخل' end,
            r->>'source', r || jsonb_build_object('income_kind', v_inc), v_inc_id);
    return 'دخل ' || public.fmt_sar(v_amount);
  end if;

  v_kind  := coalesce(r->>'kind', 'purchase');
  v_label := coalesce(r->>'merchant', 'رسالة البنك');

  -- مصروف ثابت سجّلتم دفعه يدوياً في نفس الشهر بنفس المبلغ: نربط الرسالة به بدل التكرار
  if v_kind in ('purchase', 'transfer') then
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
  end if;

  -- ---------- الحوالة الصادرة: تُسجَّل فقط لو طابقت مصروفاً ثابتاً ما انسدد هذا الشهر ----------
  if v_kind = 'transfer' then
    select rx.* into v_rec from recurring_expenses rx
     where rx.household_id = t.household_id and rx.is_active
       and abs(rx.amount - v_amount) <= 100
       and (rx.start_month is null or rx.start_month <= date_trunc('month', v_date)::date)
       and not exists (select 1 from expenses x where x.recurring_id = rx.id and x.recurring_period = date_trunc('month', v_date)::date)
     order by abs(rx.amount - v_amount), rx.day_of_month limit 1;
    if v_rec.id is null then
      insert into sms_log (household_id, user_id, message, status, reason, source, result)
      values (t.household_id, t.user_id, v_logmsg, 'ignored', 'حوالة صادرة', r->>'source', r || '{"silent": true}');
      return 'تجاهل: حوالة صادرة';
    end if;
    insert into expenses (household_id, category_id, amount, expense_date, description, created_by, source_hash,
                          recurring_id, recurring_period, sms_meta)
    values (t.household_id, v_rec.category_id, v_amount, v_date, left('📩 ' || v_rec.name, 200), t.user_id, v_hash,
            v_rec.id, date_trunc('month', v_date)::date,
            (r->'meta') || jsonb_strip_nulls(jsonb_build_object('merchant', r->>'merchant', 'transfer', true)))
    on conflict do nothing
    returning id into v_id;
    if v_id is null then return 'مسجّلة مسبقاً'; end if;
    insert into sms_log (household_id, user_id, message, status, reason, source, expense_id, result)
    values (t.household_id, t.user_id, v_logmsg, 'recorded', 'حوالة: ' || v_rec.name, r->>'source', v_id, r);
    return 'حوالة ' || v_rec.name;
  end if;

  -- ---------- الاسترداد: عملية سالبة مربوطة بالعملية الأصلية ----------
  if v_kind = 'refund' then
    select x.* into v_orig from expenses x
     where x.household_id = t.household_id and x.kind = 'purchase' and x.expense_date between v_date - 120 and v_date
       and x.amount + coalesce((select sum(y.amount) from expenses y where y.refund_of = x.id), 0) >= v_amount
       and (((r->>'merchant_key') is not null and x.merchant_key = r->>'merchant_key')
            or ((r->>'merchant_key') is null and x.amount = v_amount and x.expense_date >= v_date - 60))
     order by (x.amount = v_amount) desc, x.expense_date desc
     limit 1;
    insert into expenses (household_id, category_id, amount, expense_date, description, created_by, source_hash, merchant_key,
                          sms_meta, kind, refund_of, trip_id)
    values (t.household_id, coalesce(v_orig.category_id, (r->>'category_id')::uuid), -v_amount, v_date, left('📩 ' || v_label, 200),
            t.user_id, v_hash, r->>'merchant_key',
            ((r->'meta') - 'country' - 'channel') || jsonb_strip_nulls(jsonb_build_object('merchant', r->>'merchant')),
            'refund', v_orig.id, v_orig.trip_id)
    on conflict (source_hash) do nothing
    returning id into v_id;
    if v_id is null then return 'مسجّلة مسبقاً'; end if;
    insert into sms_log (household_id, user_id, message, status, reason, source, expense_id, result)
    values (t.household_id, t.user_id, v_logmsg, 'recorded', 'استرداد', r->>'source', v_id, r);
    return 'استرداد ' || public.fmt_sar(v_amount);
  end if;

  -- ---------- الشراء والسحب النقدي ----------
  insert into expenses (household_id, category_id, amount, expense_date, description, created_by, source_hash, merchant_key, sms_meta, kind)
  values (t.household_id, (r->>'category_id')::uuid, v_amount, v_date,
          left(case when v_kind = 'cash' then '📩 سحب نقدي' else '📩 ' || v_label end, 200), t.user_id, v_hash,
          r->>'merchant_key', (r->'meta') || jsonb_strip_nulls(jsonb_build_object('merchant', r->>'merchant')),
          case when v_kind = 'cash' then 'cash' else 'purchase' end)
  on conflict (source_hash) do nothing
  returning id into v_id;
  if v_id is null then return 'مسجّلة مسبقاً'; end if;

  -- سداد فاتورة: تنقفل الفاتورة الصادرة بنفس المبلغ
  if v_kind = 'purchase' and ((r->'meta'->>'channel') = 'bill_payment'
       or exists (select 1 from categories c where c.id = (r->>'category_id')::uuid and c.icon = 'receipt')) then
    update renewals set status = 'done', expense_id = v_id, updated_at = now()
     where id = (select x.id from renewals x
                  where x.household_id = t.household_id and x.kind = 'bill' and x.status = 'active'
                    and x.amount is not null and abs(x.amount - v_amount) <= 100
                    and x.due_date between v_date - 60 and v_date + 60
                  order by abs(x.due_date - v_date) limit 1);
  end if;

  insert into sms_log (household_id, user_id, message, status, reason, source, expense_id, result)
  values (t.household_id, t.user_id, v_logmsg, 'recorded', r->>'note', r->>'source', v_id, r);
  delete from sms_log where household_id = t.household_id and received_at < now() - interval '180 days';

  return public.sms_notice(r);
end $$;


grant execute on function public.sms_expense(text, text, text) to anon, authenticated;

-- ---------- سجل الرسائل: شحن المحفظة اللي انسجل قبل وحذفتوه يصير «متجاهل» ----------
update public.sms_log set status = 'ignored', reason = 'تحويل لمحفظتك (بين حساباتك)'
 where status = 'recorded' and expense_id is null and message is not null
   and public.ar_norm(message) ~ ('(من|لدي|عند|الي|التاجر|المتجر)\s*[:：]?\s*(sa\s*/\s*)?\*?\s*(' || public.wallet_rx() || ')');
