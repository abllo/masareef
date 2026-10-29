-- =====================================================================
--  0012: الرحلات ✈️ (تلقائية بالكامل)
--   - Claude يقرأ دولة الشراء من رسالة البنك (والقراءة المحلية احتياط)
--   - شراء من محل خارج السعودية ← رحلة تبدأ تلقائياً باسم الدولة (أو تكمل الرحلة الحالية)
--   - بطاقة الرحلة: مشترياتها من المحلات أثناء الرحلة (والموقع غير معروف) تتبع الرحلة
--   - ترجعون: أول شراء من محل داخل السعودية لصاحب الرحلة يقفلها، أو تنقفل بعد 3 أيام بلا مشتريات من الخارج
--   - مصاريف الرحلة منفصلة: لا تدخل في مصروف الشهر وميزانيته، وتظهر كسفر في التقارير والسنوات
-- =====================================================================

-- ---------- الدول ----------
create table if not exists public.countries (
  iso2     text primary key,
  iso3     text not null,
  name_ar  text not null,
  name_en  text not null,
  currency text,
  aliases  text[] not null default '{}'
);
alter table public.countries enable row level security;
drop policy if exists countries_select on public.countries;
create policy countries_select on public.countries for select to authenticated using (true);
insert into public.countries (iso2, iso3, name_ar, name_en, currency, aliases) values
  ('SA', 'SAU', 'السعودية', 'Saudi Arabia', 'SAR', array['KSA','المملكة العربية السعودية','المملكة']::text[]),
  ('AE', 'ARE', 'الإمارات', 'United Arab Emirates', 'AED', array['UAE','الامارات','دبي','DUBAI','ABU DHABI','ابوظبي','SHARJAH']::text[]),
  ('BH', 'BHR', 'البحرين', 'Bahrain', 'BHD', array['MANAMA','المنامة']::text[]),
  ('KW', 'KWT', 'الكويت', 'Kuwait', 'KWD', '{}'::text[]),
  ('QA', 'QAT', 'قطر', 'Qatar', 'QAR', array['DOHA','الدوحة']::text[]),
  ('OM', 'OMN', 'عُمان', 'Oman', 'OMR', array['عمان','MUSCAT','مسقط']::text[]),
  ('EG', 'EGY', 'مصر', 'Egypt', 'EGP', array['CAIRO','القاهرة']::text[]),
  ('JO', 'JOR', 'الأردن', 'Jordan', 'JOD', array['AMMAN','الاردن']::text[]),
  ('LB', 'LBN', 'لبنان', 'Lebanon', 'LBP', array['BEIRUT']::text[]),
  ('TR', 'TUR', 'تركيا', 'Turkey', 'TRY', array['TURKIYE','TÜRKIYE','ISTANBUL','اسطنبول','إسطنبول']::text[]),
  ('GB', 'GBR', 'بريطانيا', 'United Kingdom', 'GBP', array['UK','ENGLAND','LONDON','لندن','المملكة المتحدة','انجلترا','إنجلترا']::text[]),
  ('US', 'USA', 'أمريكا', 'United States', 'USD', array['UNITED STATES OF AMERICA','امريكا','الولايات المتحدة']::text[]),
  ('FR', 'FRA', 'فرنسا', 'France', 'EUR', array['PARIS','باريس']::text[]),
  ('DE', 'DEU', 'ألمانيا', 'Germany', 'EUR', array['المانيا','MUNICH','BERLIN']::text[]),
  ('IT', 'ITA', 'إيطاليا', 'Italy', 'EUR', array['ايطاليا','ROME','MILAN','ROMA','MILANO']::text[]),
  ('ES', 'ESP', 'إسبانيا', 'Spain', 'EUR', array['اسبانيا','MADRID','BARCELONA','MARBELLA']::text[]),
  ('NL', 'NLD', 'هولندا', 'Netherlands', 'EUR', array['AMSTERDAM']::text[]),
  ('BE', 'BEL', 'بلجيكا', 'Belgium', 'EUR', '{}'::text[]),
  ('CH', 'CHE', 'سويسرا', 'Switzerland', 'CHF', array['GENEVA','ZURICH','GENEVE','جنيف']::text[]),
  ('AT', 'AUT', 'النمسا', 'Austria', 'EUR', array['VIENNA','WIEN']::text[]),
  ('GR', 'GRC', 'اليونان', 'Greece', 'EUR', array['ATHENS']::text[]),
  ('PT', 'PRT', 'البرتغال', 'Portugal', 'EUR', array['LISBON','LISBOA']::text[]),
  ('IE', 'IRL', 'أيرلندا', 'Ireland', 'EUR', array['DUBLIN']::text[]),
  ('SE', 'SWE', 'السويد', 'Sweden', 'SEK', '{}'::text[]),
  ('NO', 'NOR', 'النرويج', 'Norway', 'NOK', '{}'::text[]),
  ('DK', 'DNK', 'الدنمارك', 'Denmark', 'DKK', '{}'::text[]),
  ('FI', 'FIN', 'فنلندا', 'Finland', 'EUR', '{}'::text[]),
  ('PL', 'POL', 'بولندا', 'Poland', 'PLN', '{}'::text[]),
  ('CZ', 'CZE', 'التشيك', 'Czechia', 'CZK', array['CZECH REPUBLIC','PRAGUE']::text[]),
  ('HU', 'HUN', 'المجر', 'Hungary', 'HUF', '{}'::text[]),
  ('RU', 'RUS', 'روسيا', 'Russia', 'RUB', '{}'::text[]),
  ('GE', 'GEO', 'جورجيا', 'Georgia', 'GEL', array['TBILISI','تبليسي']::text[]),
  ('AZ', 'AZE', 'أذربيجان', 'Azerbaijan', 'AZN', array['BAKU','باكو','اذربيجان']::text[]),
  ('UZ', 'UZB', 'أوزبكستان', 'Uzbekistan', 'UZS', '{}'::text[]),
  ('KZ', 'KAZ', 'كازاخستان', 'Kazakhstan', 'KZT', '{}'::text[]),
  ('BA', 'BIH', 'البوسنة', 'Bosnia and Herzegovina', 'BAM', array['SARAJEVO']::text[]),
  ('MA', 'MAR', 'المغرب', 'Morocco', 'MAD', array['MARRAKECH','CASABLANCA']::text[]),
  ('TN', 'TUN', 'تونس', 'Tunisia', 'TND', '{}'::text[]),
  ('IN', 'IND', 'الهند', 'India', 'INR', '{}'::text[]),
  ('PK', 'PAK', 'باكستان', 'Pakistan', 'PKR', '{}'::text[]),
  ('BD', 'BGD', 'بنغلاديش', 'Bangladesh', 'BDT', '{}'::text[]),
  ('LK', 'LKA', 'سريلانكا', 'Sri Lanka', 'LKR', '{}'::text[]),
  ('MV', 'MDV', 'المالديف', 'Maldives', 'MVR', array['MALE']::text[]),
  ('TH', 'THA', 'تايلاند', 'Thailand', 'THB', array['BANGKOK','PHUKET']::text[]),
  ('MY', 'MYS', 'ماليزيا', 'Malaysia', 'MYR', array['KUALA LUMPUR','LANGKAWI']::text[]),
  ('ID', 'IDN', 'إندونيسيا', 'Indonesia', 'IDR', array['BALI','JAKARTA','اندونيسيا']::text[]),
  ('SG', 'SGP', 'سنغافورة', 'Singapore', 'SGD', '{}'::text[]),
  ('PH', 'PHL', 'الفلبين', 'Philippines', 'PHP', '{}'::text[]),
  ('VN', 'VNM', 'فيتنام', 'Vietnam', 'VND', '{}'::text[]),
  ('CN', 'CHN', 'الصين', 'China', 'CNY', '{}'::text[]),
  ('HK', 'HKG', 'هونغ كونغ', 'Hong Kong', 'HKD', '{}'::text[]),
  ('JP', 'JPN', 'اليابان', 'Japan', 'JPY', array['TOKYO']::text[]),
  ('KR', 'KOR', 'كوريا الجنوبية', 'South Korea', 'KRW', array['KOREA','SEOUL']::text[]),
  ('AU', 'AUS', 'أستراليا', 'Australia', 'AUD', '{}'::text[]),
  ('NZ', 'NZL', 'نيوزيلندا', 'New Zealand', 'NZD', '{}'::text[]),
  ('CA', 'CAN', 'كندا', 'Canada', 'CAD', '{}'::text[]),
  ('MX', 'MEX', 'المكسيك', 'Mexico', 'MXN', '{}'::text[]),
  ('BR', 'BRA', 'البرازيل', 'Brazil', 'BRL', '{}'::text[]),
  ('ZA', 'ZAF', 'جنوب أفريقيا', 'South Africa', 'ZAR', '{}'::text[]),
  ('KE', 'KEN', 'كينيا', 'Kenya', 'KES', '{}'::text[]),
  ('TZ', 'TZA', 'تنزانيا', 'Tanzania', 'TZS', array['ZANZIBAR']::text[]),
  ('MU', 'MUS', 'موريشيوس', 'Mauritius', 'MUR', '{}'::text[]),
  ('SC', 'SYC', 'سيشل', 'Seychelles', 'SCR', '{}'::text[]),
  ('IQ', 'IRQ', 'العراق', 'Iraq', 'IQD', '{}'::text[]),
  ('SY', 'SYR', 'سوريا', 'Syria', 'SYP', '{}'::text[]),
  ('YE', 'YEM', 'اليمن', 'Yemen', 'YER', '{}'::text[]),
  ('SD', 'SDN', 'السودان', 'Sudan', 'SDG', '{}'::text[])
on conflict (iso2) do update set iso3 = excluded.iso3, name_ar = excluded.name_ar, name_en = excluded.name_en,
  currency = excluded.currency, aliases = excluded.aliases;

-- نص (GB / GBR / United Kingdom / بريطانيا / LONDON) ← رمز الدولة
create or replace function public.country_code(p text)
returns text language sql stable set search_path = public as $$
  with v as (select upper(btrim(regexp_replace(coalesce(p, ''), '[.\-_,،]+', ' ', 'g'))) as u,
                    public.normalize_merchant(p) as n)
  select c.iso2 from public.countries c, v
  where v.u <> '' and (v.u = c.iso2 or v.u = c.iso3 or v.u = upper(c.name_en)
     or (v.n is not null and public.normalize_merchant(c.name_ar) = v.n)
     or exists (select 1 from unnest(c.aliases) a where upper(a) = v.u or (v.n is not null and public.normalize_merchant(a) = v.n)))
  order by (v.u = c.iso2) desc, (v.u = c.iso3) desc
  limit 1
$$;

create or replace function public.country_ar(p_code text)
returns text language sql stable set search_path = public as $$
  select name_ar from public.countries where iso2 = upper(p_code)
$$;

-- الدولة الغالبة لعملة (اليورو لا يحدد دولة)
create or replace function public.currency_country(p_currency text)
returns text language sql stable set search_path = public as $$
  select case upper(p_currency) when 'USD' then 'US' when 'EUR' then null
         else (select iso2 from public.countries where currency = upper(p_currency) and iso2 <> 'SA' order by iso2 limit 1) end
$$;

-- ---------- الرحلات ----------
create table if not exists public.trips (
  id               uuid primary key default gen_random_uuid(),
  household_id     uuid not null references public.households(id) on delete cascade,
  name             text not null check (char_length(btrim(name)) between 1 and 60),
  countries        text[] not null default '{}',
  start_date       date not null,
  end_date         date,
  last_abroad_date date,
  status           text not null default 'active' check (status in ('active', 'closed')),
  budget           bigint check (budget is null or budget > 0),   -- بالهللة
  card_last4       text,
  auto             boolean not null default true,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  unique (id, household_id)
);
create unique index if not exists trips_one_active on public.trips (household_id) where status = 'active';
alter table public.trips enable row level security;
drop policy if exists trips_select on public.trips;
drop policy if exists trips_owner on public.trips;
create policy trips_select on public.trips for select to authenticated using (public.is_member(household_id));
create policy trips_owner on public.trips for all to authenticated
  using (public.is_owner(household_id)) with check (public.is_owner(household_id));

alter table public.expenses add column if not exists trip_id uuid;
do $$ begin
  alter table public.expenses add constraint expenses_trip_fk foreign key (trip_id, household_id)
    references public.trips (id, household_id) on delete set null (trip_id);
exception when duplicate_object then null; end $$;
create index if not exists expenses_trip_idx on public.expenses (trip_id) where trip_id is not null;

do $$ begin
  alter publication supabase_realtime add table public.trips;
exception when others then null; end $$;

-- ---------- قراءة الدولة من رسالة البنك ----------
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

category: exactly one of the family's categories (the enum). For a merchant listed under "Learned", always use the learned category. Saudi hints: HungerStation, Jahez, Mrsool, ToYou, Keeta, The Chefz, Ninja → delivery apps; Panda, Danube, Othaim, Carrefour, Tamimi, Lulu, Nesto, Farm, Bin Dawood → groceries; cafes, restaurants, bakeries, sweets → restaurants & cafes; STC, Mobily, Zain, SEC electricity, National Water, Netflix, Shahid, Spotify, Apple, Google, iCloud → bills & subscriptions; Aldrees, SASCO, Petromin, Naft, car wash, workshops, tyres → car; Amazon, Noon, Shein, IKEA, Jarir, Extra, Namshi, Centrepoint → shopping; Nahdi, Al-Dawaa, Whites, pharmacies, clinics, hospitals, labs, dentists, opticians → health. Abroad, use the same logic for local merchants (supermarkets → groceries, restaurants → restaurants, etc.): purchases made abroad keep their real category because the app groups them into trips automatically — never put them in a travel category.
Use "__new__" ONLY when the purchase clearly belongs to a common spending area that none of the categories covers (for example education, kids) — never for a single merchant and never for a near-duplicate of an existing category. Then fill new_category with a short Arabic name (2–3 words) and an icon from its enum. When unsure, use the family's "other" category.

bank: the bank or wallet that sent the message / issued the card: alrajhi (الراجحي), alinma (الإنماء), snb (البنك الأهلي), riyad (بنك الرياض), sab (ساب), anb (البنك العربي الوطني), albilad (بنك البلاد), aljazira (بنك الجزيرة), bsf (البنك السعودي الفرنسي), saib (البنك السعودي للاستثمار), gib (بنك الخليج الدولي / ميم), stcbank (STC Bank / stc pay), barq (برق), urpay, d360, vision (Vision Bank), other; null if the message does not say.
date: the transaction date as YYYY-MM-DD if the message states it (Gregorian), else null.
card_last4: last 4 digits of the card if shown.
card_type: the card network — mada (Saudi debit network, مدى), visa, mastercard, amex, or other; null if unknown.
card_kind: debit or credit (ائتمانية/credit = credit; مدى and "حساب" are debit); null if unknown.
channel: apple_pay (Apple Pay / ابل باي / Apple Wallet), pos (in-store / نقاط البيع), online (إنترنت / online / e-commerce), bill_payment (سداد), or other.
country: ISO 3166-1 alpha-2 code of the country where the purchase physically happened, from the message (a country field like دولة/الدولة, a location like "LONDON GB" or "DUBAI AE", or a city name). Use SA for an in-store / Apple Pay purchase charged in SAR with no international marker (Saudi domestic). For online purchases give the merchant country only when the message states it. null when unknown.
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
    v_country := coalesce(public.country_code(v_ai->>'country'), v_country);
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

-- ---------- ربط المصروف بالرحلة تلقائياً ----------
create or replace function public.assign_trip()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m jsonb := new.sms_meta;
  v_country text; v_place text; v_channel text;
  v_online boolean; v_abroad boolean; v_home boolean;
  t trips;
begin
  if m is null or new.trip_id is not null or new.recurring_id is not null then return new; end if;
  v_country := upper(nullif(m->>'country', ''));
  v_channel := m->>'channel';
  v_online  := coalesce(v_channel in ('online', 'bill_payment'), false);
  v_abroad  := not v_online and (
                 (v_country is not null and v_country <> 'SA')
                 or (v_country is null and m ? 'original_currency' and coalesce(v_channel in ('pos', 'apple_pay'), false)));
  v_home    := not v_online and v_country = 'SA';
  v_place   := coalesce(nullif(v_country, 'SA'), public.currency_country(m->>'original_currency'));

  select * into t from trips where household_id = new.household_id and status = 'active';

  if v_abroad then
    if t.id is null then
      -- رحلة انقفلت قبل يومين أو أقل: نكملها بدل رحلة جديدة
      select * into t from trips
       where household_id = new.household_id and status = 'closed'
         and greatest(coalesce(last_abroad_date, start_date), coalesce(end_date, start_date)) >= new.expense_date - 2
         and start_date <= new.expense_date
       order by start_date desc limit 1;
      if t.id is not null then
        update trips set status = 'active', end_date = null where id = t.id returning * into t;
      else
        insert into trips (household_id, name, countries, start_date, last_abroad_date, card_last4, created_by)
        values (new.household_id, 'رحلة ' || coalesce(public.country_ar(v_place), 'خارجية'),
                array_remove(array[v_place], null), new.expense_date, new.expense_date, m->>'card_last4', new.created_by)
        returning * into t;
      end if;
    end if;
    update trips
       set last_abroad_date = greatest(coalesce(last_abroad_date, new.expense_date), new.expense_date),
           start_date = least(start_date, new.expense_date),
           countries = case when v_place is null or v_place = any(countries) then countries else countries || v_place end,
           card_last4 = coalesce(card_last4, m->>'card_last4')
     where id = t.id;
    new.trip_id := t.id;
    return new;
  end if;

  if t.id is not null and new.expense_date >= t.start_date then
    if v_home and (new.created_by = t.created_by or (t.card_last4 is not null and m->>'card_last4' = t.card_last4)) then
      -- رجعتوا بالسلامة: أول شراء من محل داخل السعودية
      update trips set status = 'closed',
             end_date = coalesce((select max(expense_date) from expenses where trip_id = t.id), start_date)
       where id = t.id;
      perform public.push_call(new.household_id, 'trip_end', t.id);
    elsif v_country is null and not v_online and t.card_last4 is not null and m->>'card_last4' = t.card_last4 then
      new.trip_id := t.id;  -- بطاقة الرحلة من محل والموقع غير معروف
    end if;
  end if;
  return new;
exception when others then
  return new;  -- الرحلات لا توقف تسجيل أي مصروف
end $$;
drop trigger if exists expenses_assign_trip on public.expenses;
create trigger expenses_assign_trip before insert on public.expenses for each row execute function public.assign_trip();

-- يومياً: الرحلة اللي ما فيها مشتريات من الخارج من 3 أيام تنقفل
create or replace function public.trips_autoclose()
returns int language plpgsql security definer set search_path = public as $$
declare t record; n int := 0; v_today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  for t in select tr.* from trips tr where tr.status = 'active'
             and greatest(coalesce(tr.last_abroad_date, tr.start_date),
                          coalesce((select max(expense_date) from expenses where trip_id = tr.id), tr.start_date)) < v_today - 3 loop
    update trips set status = 'closed',
           end_date = coalesce((select max(expense_date) from expenses where trip_id = t.id), t.start_date)
     where id = t.id;
    perform public.push_call(t.household_id, 'trip_end', t.id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- إغلاق/فتح يدوي (للمنشئ)
create or replace function public.set_trip_status(p_trip uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare t trips;
begin
  select * into t from trips where id = p_trip;
  if t.id is null or not public.is_owner(t.household_id) then raise exception 'only the owner can do this'; end if;
  if p_active then
    update trips tr set status = 'closed',
           end_date = coalesce((select max(expense_date) from expenses where trip_id = tr.id), tr.start_date)
     where tr.household_id = t.household_id and tr.status = 'active' and tr.id <> t.id;
    update trips set status = 'active', end_date = null where id = t.id;
  else
    update trips set status = 'closed',
           end_date = coalesce((select max(expense_date) from expenses where trip_id = t.id), t.start_date)
     where id = t.id;
  end if;
end $$;

-- ---------- الإشعارات ----------
alter table public.household_members alter column notify_prefs
  set default '{"self": true, "family": true, "budget": true, "recurring": true, "monthly": true, "sms_issue": true, "travel": true}';
update public.household_members set notify_prefs = notify_prefs || '{"travel": true}' where not notify_prefs ? 'travel';

create or replace function public.push_set_prefs(p_prefs jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb; k text; v_clean jsonb := '{}';
begin
  foreach k in array array['self', 'family', 'budget', 'recurring', 'monthly', 'sms_issue', 'travel'] loop
    if jsonb_typeof(p_prefs->k) = 'boolean' then v_clean := v_clean || jsonb_build_object(k, p_prefs->k); end if;
  end loop;
  update household_members set notify_prefs = notify_prefs || v_clean where user_id = auth.uid()
  returning notify_prefs into v;
  return v;
end $$;

create or replace function public.push_expense_messages(p_expense uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e record;
  v_label text; v_amount text; v_by text; v_line text;
  v_month date; v_total bigint; v_before bigint; v_budget bigint;
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_out jsonb := '[]';
  v_title text; v_body text;
  t trips; v_trip_total bigint; v_trip_n int; v_first boolean := false;
begin
  select x.*, c.name as cat into e from expenses x join categories c on c.id = x.category_id where x.id = p_expense;
  if not found then return '[]'; end if;

  v_label  := coalesce(nullif(e.sms_meta->>'merchant', ''), nullif(regexp_replace(coalesce(e.description, ''), '^📩\s*', ''), ''));
  v_amount := public.fmt_sar(e.amount)
              || coalesce(' (' || (e.sms_meta->>'original_amount') || ' ' || (e.sms_meta->>'original_currency') || ')', '');
  v_month  := date_trunc('month', e.expense_date)::date;
  select coalesce(sum(amount), 0) into v_total from expenses
   where household_id = e.household_id and trip_id is null
     and expense_date >= v_month and expense_date < (v_month + interval '1 month')::date;
  v_before := v_total - e.amount;
  select display_name into v_by from household_members where household_id = e.household_id and user_id = e.created_by;
  v_line := coalesce(v_label || ' ← ', '') || e.cat || E'\n' || 'مجموع ' || public.ar_month(v_month) || ': ' || public.fmt_sar(v_total);
  -- مصروف رحلة: مجموع الرحلة بدل الشهر (ولا يدخل في ميزانية الشهر)
  if e.trip_id is not null then
    select * into t from trips where id = e.trip_id;
    select coalesce(sum(amount), 0), count(*) into v_trip_total, v_trip_n from expenses where trip_id = t.id;
    v_first := v_trip_n = 1;
    v_line := coalesce(v_label || ' ← ', '') || e.cat || E'\n' || '✈️ ' || t.name || ': ' || public.fmt_sar(v_trip_total)
              || coalesce(' من ' || public.fmt_sar(t.budget), '');
    if v_first then
      v_line := 'تم تسجيل ' || v_amount || ' · ' || coalesce(v_label || ' ← ', '') || e.cat || E'\n'
                || 'مصاريف الرحلة منفصلة عن ميزانية الشهر';
    end if;
  end if;

  -- 1) صاحب العملية: ما سُجّل تلقائياً من رسالة البنك
  if e.source_hash is not null then
    v_out := v_out || public.push_to(e.household_id, 'self',
      jsonb_build_object('title', case when v_first then '✈️ بدأت ' || t.name else 'تم تسجيل ' || v_amount end,
                         'body', v_line, 'tag', 'exp-' || e.id, 'url', case when e.trip_id is null then './#/expenses' else './#/trips' end),
      p_only => e.created_by);
  end if;

  -- 2) بقية العائلة
  v_out := v_out || public.push_to(e.household_id, 'family',
    jsonb_build_object('title', case when v_first then '✈️ بدأت ' || t.name || ' (' || coalesce(v_by, 'العائلة') || ')' else coalesce(v_by, 'العائلة') || ': ' || v_amount end,
                       'body', v_line, 'tag', 'exp-' || e.id, 'url', case when e.trip_id is null then './#/expenses' else './#/trips' end),
    p_except => e.created_by);

  -- 3) الميزانية: عند تجاوز 80% أو 100% لأول مرة في الشهر الحالي
  select monthly_budget into v_budget from households where id = e.household_id;
  -- ميزانية الرحلة
  if e.trip_id is not null and t.budget > 0 then
    if v_trip_total - e.amount < t.budget and v_trip_total >= t.budget then
      v_title := 'تجاوزتم ميزانية ' || t.name;
      v_body := 'المصروف ' || public.fmt_sar(v_trip_total) || ' من ' || public.fmt_sar(t.budget);
    elsif (v_trip_total - e.amount) * 10 < t.budget * 8 and v_trip_total * 10 >= t.budget * 8 then
      v_title := 'وصلتم 80% من ميزانية ' || t.name;
      v_body := 'المصروف ' || public.fmt_sar(v_trip_total) || ' من ' || public.fmt_sar(t.budget) || ' · المتبقي ' || public.fmt_sar(t.budget - v_trip_total);
    end if;
    if v_title is not null then
      v_out := v_out || public.push_to(e.household_id, 'travel',
        jsonb_build_object('title', v_title, 'body', v_body, 'tag', 'trip-budget-' || t.id, 'url', './#/trips'));
    end if;
    return v_out;
  end if;

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

-- انتهت الرحلة: ملخصها للعائلة
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
    'title', '🏠 الحمد لله على السلامة · انتهت ' || t.name,
    'body', 'المجموع ' || public.fmt_sar(v_total) || ' · ' || v_n || ' عملية · ' || v_days || ' يوم'
            || case when t.budget > 0 then
                 case when v_total > t.budget then E'\n' || 'أعلى من ميزانيتها بـ ' || public.fmt_sar(v_total - t.budget)
                      else E'\n' || 'أقل من ميزانيتها بـ ' || public.fmt_sar(t.budget - v_total) end
               else '' end
            || coalesce(E'\n' || 'أكثر صرف: ' || v_top, ''),
    'tag', 'trip-end-' || t.id, 'url', './#/trips'));
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
        v_body := concat_ws(' · ', nullif(v_body, ''), 'أعلى تصنيف: ' || v_top,
                    (select '✈️ سفر: ' || public.fmt_sar(sum(amount)::bigint) from expenses
                      where household_id = h.id and trip_id is not null
                        and expense_date >= v_prev and expense_date < v_month having sum(amount) > 0));
        v_out := v_out || public.push_to(h.id, 'monthly', jsonb_build_object(
          'title', 'ملخص ' || public.ar_month(v_prev) || ': ' || public.fmt_sar(v_t1),
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

-- كل أنواع الإشعارات من مكان واحد (الدالة تنادي هذه فقط)
create or replace function public.push_build(p_kind text, p_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return case p_kind
    when 'expense'  then public.push_expense_messages(p_id)
    when 'sms'      then public.push_sms_messages(p_id)
    when 'daily'    then public.push_daily_messages(null)
    when 'trip_end' then public.push_trip_end_messages(p_id)
    else '[]'::jsonb end;
end $$;

-- الجدولة اليومية: قفل الرحلات المنتهية ثم إشعارات اليوم
select cron.unschedule(jobid) from cron.job where jobname = 'masareef-daily';
select cron.schedule('masareef-daily', '0 6 * * *', 'select public.trips_autoclose(); select public.push_call(null, ''daily'');');

-- ---------- التقارير: السفر منفصل عن مصروف الشهر ----------
create or replace view public.monthly_category_totals
with (security_invoker = true) as
select household_id, date_trunc('month', expense_date)::date as month, category_id,
       sum(amount)::bigint as total, count(*)::int as tx_count
from public.expenses
where trip_id is null
group by 1, 2, 3
union all
select ys.household_id, make_date(ys.year, g.m, 1), (c->>'id')::uuid,
       (c->'months'->>(g.m - 1))::bigint, coalesce((c->'month_counts'->>(g.m - 1))::int, 0)
from public.year_summaries ys
cross join lateral jsonb_array_elements(ys.data->'categories') c
cross join generate_series(1, 12) as g(m)
where ys.archived_at is not null and c ? 'id' and (c->'months'->>(g.m - 1))::bigint > 0;

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
    'regular_total', (select coalesce(sum(amount), 0) from e where trip_id is null),
    'travel_total', (select coalesce(sum(amount), 0) from e where trip_id is not null),
    'count', (select count(*) from e),
    'first_date', (select min(expense_date) from e),
    'last_date', (select max(expense_date) from e),
    'months', (select jsonb_agg(jsonb_build_object('month', g, 'total', coalesce(t.total, 0), 'count', coalesce(t.n, 0),
                                                 'regular', coalesce(t.regular, 0), 'travel', coalesce(t.travel, 0)) order by g)
               from generate_series(1, 12) g
               left join (select mo, sum(amount) as total, count(*) as n,
                                 coalesce(sum(amount) filter (where trip_id is null), 0) as regular,
                                 coalesce(sum(amount) filter (where trip_id is not null), 0) as travel
                          from e group by mo) t on t.mo = g),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', category_id, 'name', cat, 'icon', cat_icon, 'color', cat_color,
                                                              'total', total, 'count', n, 'months', months, 'month_counts', month_counts)
                                             order by total desc), '[]')
                   from (select category_id, cat, cat_icon, cat_color, sum(amount) as total, count(*) as n,
                                (select jsonb_agg(coalesce((select sum(amount) from e e2 where e2.category_id = e1.category_id and e2.mo = g and e2.trip_id is null), 0) order by g)
                                 from generate_series(1, 12) g) as months,
                                (select jsonb_agg((select count(*) from e e2 where e2.category_id = e1.category_id and e2.mo = g and e2.trip_id is null) order by g)
                                 from generate_series(1, 12) g) as month_counts
                         from e e1 where trip_id is null group by category_id, cat, cat_icon, cat_color) t),
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
    'from_sms', (select count(*) from e where source_hash is not null),
    'trips', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'countries', t.countries, 'start_date', t.start_date,
                                                         'end_date', t.end_date, 'budget', t.budget, 'total', s.total, 'count', s.n)
                                       order by t.start_date), '[]')
              from trips t join (select trip_id, sum(amount) as total, count(*) as n from e where trip_id is not null group by trip_id) s
                on s.trip_id = t.id)
  )
$$;

revoke all on function public.country_code(text) from public, anon;
revoke all on function public.country_ar(text) from public, anon;
revoke all on function public.currency_country(text) from public, anon;
grant execute on function public.country_code(text) to authenticated;
grant execute on function public.country_ar(text) to authenticated;
revoke all on function public.assign_trip() from public, anon, authenticated;
revoke all on function public.trips_autoclose() from public, anon, authenticated;
revoke all on function public.set_trip_status(uuid, boolean) from public, anon;
grant execute on function public.set_trip_status(uuid, boolean) to authenticated;
revoke all on function public.push_trip_end_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_build(text, uuid) from public, anon, authenticated;
grant execute on function public.push_build(text, uuid) to service_role;
revoke all on function public.sms_parse(uuid, text, boolean, boolean) from public, anon, authenticated;

notify pgrst, 'reload schema';
