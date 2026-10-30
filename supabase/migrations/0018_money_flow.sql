-- =====================================================================
--  0018: الدخل والاسترداد والنقد والفواتير، ورسائل البنوك فقط
--   1) ar_norm: توحيد الإملاء (أ/إ/آ ← ا، ة ← ه، ى ← ي، بدون تشكيل)
--   2) قراءة رسائل البنوك وشركات الفواتير والجهات الحكومية فقط (من اسم المرسل)،
--      وأي رسالة ثانية تُرمى بدون حفظ نصها وبدون إرسالها لأي جهة
--   3) الراتب والحوالة الواردة والإيداع ← جدول «الدخل»، وإشعار يوم الراتب
--   4) الاسترداد ← عملية سالبة مربوطة بالعملية الأصلية
--   5) السحب النقدي ← تصنيف «النقد» وتقسيمه على التصنيفات، وتذكير المساء
--   6) الحوالة الصادرة ← تُسجَّل فقط لو طابقت مصروفاً ثابتاً
--   7) فواتير الشركات ← التجديدات (نوع «فاتورة») وتنقفل لما تنسدد
--   8) ملخص الرحلة اليومي بتوقيت الدولة، وتقويم الآيفون
-- =====================================================================

-- ---------- 1) توحيد الإملاء ----------
create or replace function public.ar_norm(p text)
returns text language sql immutable as $$
  select regexp_replace(translate(lower(coalesce(p, '')), 'أإآٱةىؤئ', 'ااااهيوي'), '[ًٌٍَُِّْـ]', '', 'g')
$$;

-- ---------- الجداول ----------
alter table public.expenses add column if not exists kind text not null default 'purchase';
alter table public.expenses add column if not exists refund_of uuid references public.expenses(id) on delete set null;
alter table public.expenses drop constraint if exists expenses_kind_check;
alter table public.expenses add constraint expenses_kind_check check (kind in ('purchase', 'refund', 'cash'));
alter table public.expenses drop constraint if exists expenses_amount_check;
alter table public.expenses add constraint expenses_amount_check check (
  case when kind = 'refund' then amount < 0 and amount >= -100000000000 else amount > 0 and amount <= 100000000000 end);
create index if not exists expenses_refund_of_idx on public.expenses (refund_of) where refund_of is not null;

create table if not exists public.incomes (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  amount       bigint not null check (amount > 0 and amount <= 100000000000),
  income_date  date not null,
  kind         text not null default 'other' check (kind in ('salary', 'transfer', 'deposit', 'other')),
  payer        text check (payer is null or char_length(payer) <= 80),
  meta         jsonb,
  source_hash  text unique,
  created_at   timestamptz not null default now()
);
create index if not exists incomes_user_date_idx on public.incomes (user_id, income_date);
alter table public.incomes enable row level security;
-- الدخل خاص بصاحبه فقط
drop policy if exists incomes_select on public.incomes;
create policy incomes_select on public.incomes for select to authenticated using (user_id = auth.uid());
drop policy if exists incomes_insert on public.incomes;
create policy incomes_insert on public.incomes for insert to authenticated with check (user_id = auth.uid() and public.is_member(household_id));
drop policy if exists incomes_update on public.incomes;
create policy incomes_update on public.incomes for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists incomes_delete on public.incomes;
create policy incomes_delete on public.incomes for delete to authenticated using (user_id = auth.uid());
grant select, insert, update, delete on public.incomes to authenticated;

alter table public.sms_log drop constraint if exists sms_log_status_check;
alter table public.sms_log add constraint sms_log_status_check check (status in ('recorded', 'ignored', 'duplicate', 'linked', 'income'));
alter table public.sms_log add column if not exists income_id uuid references public.incomes(id) on delete set null;

alter table public.household_members add column if not exists salary_payer text
  check (salary_payer is null or char_length(salary_payer) <= 120);

alter table public.renewals drop constraint if exists renewals_kind_check;
alter table public.renewals add constraint renewals_kind_check check (kind in ('insurance', 'istimara', 'license', 'passport', 'iqama',
  'national_id', 'warranty', 'subscription', 'contract', 'rent', 'school', 'bill', 'other'));

-- مرسلون سمحتم لهم (بنك أو جهة ما عرفها التطبيق)
create table if not exists public.sms_senders (
  household_id uuid not null references public.households(id) on delete cascade,
  sender_key   text not null,
  created_by   uuid default auth.uid() references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  primary key (household_id, sender_key)
);
alter table public.sms_senders enable row level security;
drop policy if exists sms_senders_select on public.sms_senders;
create policy sms_senders_select on public.sms_senders for select to authenticated using (public.is_member(household_id));
drop policy if exists sms_senders_delete on public.sms_senders;
create policy sms_senders_delete on public.sms_senders for delete to authenticated using (public.is_member(household_id));
grant select, delete on public.sms_senders to authenticated;

-- رابط التقويم (للقراءة فقط)
create table if not exists public.calendar_tokens (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete cascade,
  token        text not null unique default encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'utf8')), 'hex'),
  created_at   timestamptz not null default now()
);
alter table public.calendar_tokens enable row level security;

alter table public.countries add column if not exists tz text;
update public.countries c set tz = v.tz from (values
  ('AD', 'Europe/Andorra'),
  ('AE', 'Asia/Dubai'),
  ('AF', 'Asia/Kabul'),
  ('AG', 'America/Antigua'),
  ('AI', 'America/Anguilla'),
  ('AL', 'Europe/Tirane'),
  ('AM', 'Asia/Yerevan'),
  ('AO', 'Africa/Luanda'),
  ('AQ', 'Antarctica/McMurdo'),
  ('AR', 'America/Argentina/Buenos_Aires'),
  ('AS', 'Pacific/Pago_Pago'),
  ('AT', 'Europe/Vienna'),
  ('AU', 'Australia/Sydney'),
  ('AW', 'America/Aruba'),
  ('AX', 'Europe/Mariehamn'),
  ('AZ', 'Asia/Baku'),
  ('BA', 'Europe/Sarajevo'),
  ('BB', 'America/Barbados'),
  ('BD', 'Asia/Dhaka'),
  ('BE', 'Europe/Brussels'),
  ('BF', 'Africa/Ouagadougou'),
  ('BG', 'Europe/Sofia'),
  ('BH', 'Asia/Bahrain'),
  ('BI', 'Africa/Bujumbura'),
  ('BJ', 'Africa/Porto-Novo'),
  ('BL', 'America/St_Barthelemy'),
  ('BM', 'Atlantic/Bermuda'),
  ('BN', 'Asia/Brunei'),
  ('BO', 'America/La_Paz'),
  ('BQ', 'America/Kralendijk'),
  ('BR', 'America/Sao_Paulo'),
  ('BS', 'America/Nassau'),
  ('BT', 'Asia/Thimphu'),
  ('BW', 'Africa/Gaborone'),
  ('BY', 'Europe/Minsk'),
  ('BZ', 'America/Belize'),
  ('CA', 'America/Toronto'),
  ('CC', 'Indian/Cocos'),
  ('CD', 'Africa/Kinshasa'),
  ('CF', 'Africa/Bangui'),
  ('CG', 'Africa/Brazzaville'),
  ('CH', 'Europe/Zurich'),
  ('CI', 'Africa/Abidjan'),
  ('CK', 'Pacific/Rarotonga'),
  ('CL', 'America/Santiago'),
  ('CM', 'Africa/Douala'),
  ('CN', 'Asia/Shanghai'),
  ('CO', 'America/Bogota'),
  ('CR', 'America/Costa_Rica'),
  ('CU', 'America/Havana'),
  ('CV', 'Atlantic/Cape_Verde'),
  ('CW', 'America/Curacao'),
  ('CX', 'Indian/Christmas'),
  ('CY', 'Asia/Nicosia'),
  ('CZ', 'Europe/Prague'),
  ('DE', 'Europe/Berlin'),
  ('DJ', 'Africa/Djibouti'),
  ('DK', 'Europe/Copenhagen'),
  ('DM', 'America/Dominica'),
  ('DO', 'America/Santo_Domingo'),
  ('DZ', 'Africa/Algiers'),
  ('EC', 'America/Guayaquil'),
  ('EE', 'Europe/Tallinn'),
  ('EG', 'Africa/Cairo'),
  ('EH', 'Africa/El_Aaiun'),
  ('ER', 'Africa/Asmara'),
  ('ES', 'Europe/Madrid'),
  ('ET', 'Africa/Addis_Ababa'),
  ('FI', 'Europe/Helsinki'),
  ('FJ', 'Pacific/Fiji'),
  ('FK', 'Atlantic/Stanley'),
  ('FM', 'Pacific/Chuuk'),
  ('FO', 'Atlantic/Faroe'),
  ('FR', 'Europe/Paris'),
  ('GA', 'Africa/Libreville'),
  ('GB', 'Europe/London'),
  ('GD', 'America/Grenada'),
  ('GE', 'Asia/Tbilisi'),
  ('GF', 'America/Cayenne'),
  ('GG', 'Europe/Guernsey'),
  ('GH', 'Africa/Accra'),
  ('GI', 'Europe/Gibraltar'),
  ('GL', 'America/Nuuk'),
  ('GM', 'Africa/Banjul'),
  ('GN', 'Africa/Conakry'),
  ('GP', 'America/Guadeloupe'),
  ('GQ', 'Africa/Malabo'),
  ('GR', 'Europe/Athens'),
  ('GS', 'Atlantic/South_Georgia'),
  ('GT', 'America/Guatemala'),
  ('GU', 'Pacific/Guam'),
  ('GW', 'Africa/Bissau'),
  ('GY', 'America/Guyana'),
  ('HK', 'Asia/Hong_Kong'),
  ('HN', 'America/Tegucigalpa'),
  ('HR', 'Europe/Zagreb'),
  ('HT', 'America/Port-au-Prince'),
  ('HU', 'Europe/Budapest'),
  ('ID', 'Asia/Jakarta'),
  ('IE', 'Europe/Dublin'),
  ('IL', 'Asia/Jerusalem'),
  ('IM', 'Europe/Isle_of_Man'),
  ('IN', 'Asia/Kolkata'),
  ('IO', 'Indian/Chagos'),
  ('IQ', 'Asia/Baghdad'),
  ('IR', 'Asia/Tehran'),
  ('IS', 'Atlantic/Reykjavik'),
  ('IT', 'Europe/Rome'),
  ('JE', 'Europe/Jersey'),
  ('JM', 'America/Jamaica'),
  ('JO', 'Asia/Amman'),
  ('JP', 'Asia/Tokyo'),
  ('KE', 'Africa/Nairobi'),
  ('KG', 'Asia/Bishkek'),
  ('KH', 'Asia/Phnom_Penh'),
  ('KI', 'Pacific/Tarawa'),
  ('KM', 'Indian/Comoro'),
  ('KN', 'America/St_Kitts'),
  ('KP', 'Asia/Pyongyang'),
  ('KR', 'Asia/Seoul'),
  ('KW', 'Asia/Kuwait'),
  ('KY', 'America/Cayman'),
  ('KZ', 'Asia/Almaty'),
  ('LA', 'Asia/Vientiane'),
  ('LB', 'Asia/Beirut'),
  ('LC', 'America/St_Lucia'),
  ('LI', 'Europe/Vaduz'),
  ('LK', 'Asia/Colombo'),
  ('LR', 'Africa/Monrovia'),
  ('LS', 'Africa/Maseru'),
  ('LT', 'Europe/Vilnius'),
  ('LU', 'Europe/Luxembourg'),
  ('LV', 'Europe/Riga'),
  ('LY', 'Africa/Tripoli'),
  ('MA', 'Africa/Casablanca'),
  ('MC', 'Europe/Monaco'),
  ('MD', 'Europe/Chisinau'),
  ('ME', 'Europe/Podgorica'),
  ('MF', 'America/Marigot'),
  ('MG', 'Indian/Antananarivo'),
  ('MH', 'Pacific/Majuro'),
  ('MK', 'Europe/Skopje'),
  ('ML', 'Africa/Bamako'),
  ('MM', 'Asia/Yangon'),
  ('MN', 'Asia/Ulaanbaatar'),
  ('MO', 'Asia/Macau'),
  ('MP', 'Pacific/Saipan'),
  ('MQ', 'America/Martinique'),
  ('MR', 'Africa/Nouakchott'),
  ('MS', 'America/Montserrat'),
  ('MT', 'Europe/Malta'),
  ('MU', 'Indian/Mauritius'),
  ('MV', 'Indian/Maldives'),
  ('MW', 'Africa/Blantyre'),
  ('MX', 'America/Mexico_City'),
  ('MY', 'Asia/Kuala_Lumpur'),
  ('MZ', 'Africa/Maputo'),
  ('NA', 'Africa/Windhoek'),
  ('NC', 'Pacific/Noumea'),
  ('NE', 'Africa/Niamey'),
  ('NF', 'Pacific/Norfolk'),
  ('NG', 'Africa/Lagos'),
  ('NI', 'America/Managua'),
  ('NL', 'Europe/Amsterdam'),
  ('NO', 'Europe/Oslo'),
  ('NP', 'Asia/Kathmandu'),
  ('NR', 'Pacific/Nauru'),
  ('NU', 'Pacific/Niue'),
  ('NZ', 'Pacific/Auckland'),
  ('OM', 'Asia/Muscat'),
  ('PA', 'America/Panama'),
  ('PE', 'America/Lima'),
  ('PF', 'Pacific/Tahiti'),
  ('PG', 'Pacific/Port_Moresby'),
  ('PH', 'Asia/Manila'),
  ('PK', 'Asia/Karachi'),
  ('PL', 'Europe/Warsaw'),
  ('PM', 'America/Miquelon'),
  ('PN', 'Pacific/Pitcairn'),
  ('PR', 'America/Puerto_Rico'),
  ('PS', 'Asia/Gaza'),
  ('PT', 'Europe/Lisbon'),
  ('PW', 'Pacific/Palau'),
  ('PY', 'America/Asuncion'),
  ('QA', 'Asia/Qatar'),
  ('RE', 'Indian/Reunion'),
  ('RO', 'Europe/Bucharest'),
  ('RS', 'Europe/Belgrade'),
  ('RU', 'Europe/Moscow'),
  ('RW', 'Africa/Kigali'),
  ('SA', 'Asia/Riyadh'),
  ('SB', 'Pacific/Guadalcanal'),
  ('SC', 'Indian/Mahe'),
  ('SD', 'Africa/Khartoum'),
  ('SE', 'Europe/Stockholm'),
  ('SG', 'Asia/Singapore'),
  ('SH', 'Atlantic/St_Helena'),
  ('SI', 'Europe/Ljubljana'),
  ('SJ', 'Arctic/Longyearbyen'),
  ('SK', 'Europe/Bratislava'),
  ('SL', 'Africa/Freetown'),
  ('SM', 'Europe/San_Marino'),
  ('SN', 'Africa/Dakar'),
  ('SO', 'Africa/Mogadishu'),
  ('SR', 'America/Paramaribo'),
  ('SS', 'Africa/Juba'),
  ('ST', 'Africa/Sao_Tome'),
  ('SV', 'America/El_Salvador'),
  ('SX', 'America/Lower_Princes'),
  ('SY', 'Asia/Damascus'),
  ('SZ', 'Africa/Mbabane'),
  ('TC', 'America/Grand_Turk'),
  ('TD', 'Africa/Ndjamena'),
  ('TF', 'Indian/Kerguelen'),
  ('TG', 'Africa/Lome'),
  ('TH', 'Asia/Bangkok'),
  ('TJ', 'Asia/Dushanbe'),
  ('TK', 'Pacific/Fakaofo'),
  ('TL', 'Asia/Dili'),
  ('TM', 'Asia/Ashgabat'),
  ('TN', 'Africa/Tunis'),
  ('TO', 'Pacific/Tongatapu'),
  ('TR', 'Europe/Istanbul'),
  ('TT', 'America/Port_of_Spain'),
  ('TV', 'Pacific/Funafuti'),
  ('TW', 'Asia/Taipei'),
  ('TZ', 'Africa/Dar_es_Salaam'),
  ('UA', 'Europe/Kyiv'),
  ('UG', 'Africa/Kampala'),
  ('UM', 'Pacific/Midway'),
  ('US', 'America/New_York'),
  ('UY', 'America/Montevideo'),
  ('UZ', 'Asia/Samarkand'),
  ('VA', 'Europe/Vatican'),
  ('VC', 'America/St_Vincent'),
  ('VE', 'America/Caracas'),
  ('VG', 'America/Tortola'),
  ('VI', 'America/St_Thomas'),
  ('VN', 'Asia/Ho_Chi_Minh'),
  ('VU', 'Pacific/Efate'),
  ('WF', 'Pacific/Wallis'),
  ('WS', 'Pacific/Apia'),
  ('YE', 'Asia/Aden'),
  ('YT', 'Indian/Mayotte'),
  ('ZA', 'Africa/Johannesburg'),
  ('ZM', 'Africa/Lusaka'),
  ('ZW', 'Africa/Harare')
) v(iso2, tz) where c.iso2 = v.iso2;

alter table public.household_members alter column notify_prefs
  set default '{"self": true, "family": true, "budget": true, "recurring": true, "monthly": true, "sms_issue": true, "travel": true, "renewals": true, "income": true}';

-- ---------- تصنيف «النقد» (قبل «مصاريف أخرى») ----------
create or replace function public.allowed_icons()
returns text[] language sql immutable as $$
  select array['cart','food','coffee','bike','receipt','bag','car','fuel','broom','steering','home','power','water','wifi',
               'phone','tv','health','pill','school','books','baby','gift','clothes','beauty','travel','sport','pet','repair',
               'charity','cash','circle']
$$;

do $$
declare h record; v_other int;
begin
  for h in select id from public.households loop
    if exists (select 1 from public.categories where household_id = h.id and icon = 'cash') then
      update public.categories set is_core = true, is_archived = false where household_id = h.id and icon = 'cash';
    else
      select sort_order into v_other from public.categories where household_id = h.id and icon = 'circle' order by sort_order desc limit 1;
      update public.categories set sort_order = sort_order + 1 where household_id = h.id and sort_order >= coalesce(v_other, 999);
      insert into public.categories (household_id, name, icon, color, sort_order, is_core)
      values (h.id, 'النقد', 'cash', '#16A34A', coalesce(v_other, 99), true);
    end if;
  end loop;
end $$;

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
    (v_id, 'محطات الوقود',         'fuel',     '#4F46E5', 7,  true),
    (v_id, 'الصحة والصيدليات',     'health',   '#DC2626', 8,  true),
    (v_id, 'راتب العاملة المنزلية','broom',    '#B45309', 9,  true),
    (v_id, 'راتب السائق',          'steering', '#0891B2', 10, true),
    (v_id, 'النقد',                'cash',     '#16A34A', 11, true),
    (v_id, 'مصاريف أخرى',          'circle',   '#64748B', 12, true);
  return v_id;
end $$;

revoke execute on function public.create_household(text, text) from anon, public;
grant  execute on function public.create_household(text, text) to authenticated;

-- ---------- 2) المرسلون المعروفون: البنوك السعودية وشركات الفواتير والجهات الحكومية ----------
create or replace function public.sms_sender_known(p_household uuid, p_sender text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(btrim(p_sender), '') = ''      -- اختصار قديم ما يرسل المرسل: يكفي فحص النص
      or exists (select 1 from sms_senders s where s.household_id = p_household and s.sender_key = public.ar_norm(btrim(p_sender)))
      or (btrim(p_sender) !~ '^[+0-9 ()-]+$'      -- رقم جوال = رسالة شخصية
          and public.ar_norm(btrim(p_sender)) ~ '(bank|بنك|مصرف|rajhi|راجحي|\msnb\M|ahli|الاهلي|riyad ?bank|riyadbank|بنك الرياض|\msabb?\M|\manb\M|alinma|انماء|bilad|البلاد|jazira|الجزيره|\mbaj\M|\mbsf\M|fransi|الفرنسي|\msaib\M|\mmeem\M|\mgib\M|\mstc|d360|\mbarq\M|urpay|vision ?bank|enbd|\mfab\M|^tamara$|tabby|تابي|\msec\M|^se$|electric|كهرباء|\mnwc\M|المياه|water|mobily|موبايلي|^zain ?(ksa)?$|zainksa|virgin|lebara|sadad|سداد|absher|ابشر|\mmoi\M|muroor|المرور|jawazat|الجوازات|najm|tawuniya|التعاونيه|bupa|medgulf|walaa|malath|ejar|nafath|نفاذ|tawakkalna|توكلنا|\mgosi\M|hrsd|qiwa|mudad|baladi|بلدي|\mspl\M)')
$$;

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
begin
  msg := translate(p_message, '٠١٢٣٤٥٦٧٨٩٫٬', '0123456789.,');
  msg := regexp_replace(msg, '(\d),(\d)', '\1\2', 'g');
  low := lower(msg);
  nlow := public.ar_norm(msg);

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
    when nlow ~ '(سداد (ال)?بطاقه|تسديد (ال)?بطاقه|سداد مستحقات|بين حساباتك|حساباتك الخاصه|لحسابك الاخر|credit card payment|card payment received|own account)' then 'ignore'
    when nlow ~ '(استرداد|استرجاع|مسترد|مسترجع|refund|عكس عمليه|عمليه عكسيه|معكوس|reversal|reversed)' then 'refund'
    when nlow ~ '(راتب|salary|payroll|حواله وارده|حوالات وارده|تحويل وارد|وارده من|اضافه مبلغ|تمت اضافه|تم اضافه|اضيف|ايداع|incoming|deposit|credited|received from)' then 'income'
    when nlow ~ '(سحب نقدي|سحب من الصراف|سحب صراف|صراف الي|\matm\M|cash withdrawal)' then 'cash'
    when nlow ~ '(حواله|تحويل|transfer|\msarie\M)' then 'transfer'
    else 'purchase' end;
  if local_kind = 'ignore' then
    return jsonb_build_object('status', 'ignored', 'reason', 'تحويل بين حساباتك أو سداد بطاقة', 'silent', true, 'source', 'rules');
  end if;
  if low ~ '(مرفوض|declined|rejected|غير ناجح|فشل|failed|unsuccessful|insufficient|رصيد غير كاف|ملغا|ملغي|تم إلغاء|تم الغاء|cancelled|canceled)' then
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

Amounts:
- amount_sar = the amount actually charged in Saudi riyals when the message states it. If the message shows a foreign amount AND its SAR equivalent, use the SAR equivalent. If only a foreign amount is shown, set amount_sar to null and fill original_amount and original_currency (ISO 4217 code, e.g. GBP, EUR, USD, TRY).
- fees_sar = fees or commission for THIS transaction explicitly stated in SAR (e.g. رسوم عملية دولية / international transaction fee), else null. Do not include fees in amount_sar.
- Never use the balance, available amount or credit limit. Digits shown as • are masked balances.

merchant: the clean shop/brand name a person would write, without branch numbers, city, country or terminal codes ("STARBUCKS 1234 JEDDAH SA" → "Starbucks", "HUNGERSTATION RIYADH" → "HungerStation", "TESCO STORES 3214 LONDON GB" → "Tesco", "مطعم البيك فرع ٣" → "البيك"). Keep Arabic names in Arabic.

category: exactly one of the family's categories (the enum). For a merchant listed under "Learned", always use the learned category. Saudi hints: HungerStation, Jahez, Mrsool, ToYou, Keeta, The Chefz, Ninja → delivery apps; Panda, Danube, Othaim, Carrefour, Tamimi, Lulu, Nesto, Farm, Bin Dawood → groceries; cafes, restaurants, bakeries, sweets → restaurants & cafes; STC, Mobily, Zain, SEC electricity, National Water, Netflix, Shahid, Spotify, Apple, Google, iCloud → bills & subscriptions; car wash, workshops, tyres, oil change → car; Amazon, Noon, Shein, Trendyol, IKEA, Jarir, Extra, Namshi, Centrepoint, Max, Zara, Tamara/Tabby instalments → shopping; Amazon Now, Nana, Tamimi, water delivery (Nova, Berain, النبع) → groceries; Nahdi, Al-Dawaa, Whites, pharmacies, clinics, hospitals, labs, dentists, opticians → health; fuel stations — Aldrees (الدريس), SASCO (ساسكو), Naft (نفط), J Oil / JOIL / G Oil (جي أويل), OOMCO, APSCO, Wafi Energy, ADNOC, Petromin stations, or any merchant whose name says محطة / بترول / بنزين / وقود / petrol / fuel / gas station → the fuel category (محطات الوقود) if the family has one, even when the station also sells coffee or snacks (a station name may end with its branch district, e.g. "joil Laban" is a JOIL station in Laban — never classify by the district word); car services (ACDelco, Petromin Express, oil change), parking (Woqoof, Mawqif), Careem, Uber, Jeeny → car; HiNet, Mobily Pay, STC Pay bills → bills; Smasco, Musaned, recruitment / hourly maid services → the domestic worker category if the family has one; airlines (Saudia, flynas, flyadeal, Qatar Airways, Emirates), Almosafer, Booking.com, Agoda, Airbnb, VFS / visa centres → the travel bookings category if the family has one; Ehsan (إحسان), Jood, charities, donations → the charity category if the family has one; barbers, salons (صالون), spas, massage, laundry (مغسلة ملابس, Gaseel), tailors (خياط) → the personal care category if the family has one. Abroad, use the same logic for local merchants (supermarkets → groceries, restaurants → restaurants, etc.): purchases made abroad keep their real category because the app groups them into trips automatically — never put them in a travel category. For cash_withdrawal, transfer_out and income use the family's "other" category (it is not used).
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
- A bill-issued notice from a utility or telecom company (الكهرباء SEC، المياه NWC، STC، موبايلي، زين…: «صدرت فاتورة»، «فاتورتك المستحقة») → kind ignore, ignore_reason «فاتورة صادرة», and renewal kind bill with title (e.g. «فاتورة الكهرباء»), subject = the place or line if stated (e.g. البيت), due_date = the stated due date (Gregorian YYYY-MM-DD) or null, amount_sar = the bill amount.
confidence: 0 to 1.$sys$,
      format(E'Today: %s (Asia/Riyadh)\n"Other" category: %s\nLearned (merchant ← category):\n%s\n\nMessage:\n<<<\n%s\n>>>',
             v_today, coalesce(v_other, '-'), coalesce(v_learned, '- (none yet)'), public.sms_mask(msg)),
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

-- ---------- الاختصار: يستقبل الرسالة (واسم المرسل) ويسجّلها ----------
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

create or replace function public.sms_expense(token text, message text)
returns text language plpgsql security definer set search_path = public
set statement_timeout to '40s'
as $$
begin
  return public.sms_expense(token, message, null);
end $$;

create or replace function public.sms_expense(jsonb)
returns text language plpgsql security definer set search_path = public
set statement_timeout to '40s'
as $$
declare k text; v_token text; v_msg text; v_sender text;
begin
  for k in select jsonb_object_keys($1) loop
    if lower(trim(k)) = 'token' then v_token := $1->>k; end if;
    if lower(trim(k)) = 'message' then v_msg := $1->>k; end if;
    if lower(trim(k)) = 'sender' then v_sender := $1->>k; end if;
  end loop;
  return public.sms_expense(v_token, v_msg, v_sender);
end $$;
grant execute on function public.sms_expense(text, text, text) to anon, authenticated;
grant execute on function public.sms_expense(text, text) to anon, authenticated;
grant execute on function public.sms_expense(jsonb) to anon, authenticated;

-- السماح لمرسل ما عرفه التطبيق (من سجل الرسائل)
create or replace function public.allow_sms_sender(p_log uuid)
returns text language plpgsql security definer set search_path = public as $$
declare l sms_log; v text;
begin
  select * into l from sms_log where id = p_log;
  if l.id is null or not public.is_member(l.household_id) then raise exception 'not found'; end if;
  v := public.ar_norm(btrim(l.result->>'sender'));
  if coalesce(v, '') = '' then raise exception 'no sender'; end if;
  insert into sms_senders (household_id, sender_key) values (l.household_id, v) on conflict do nothing;
  update sms_log set reason = 'مرسل مسموح: ' || (l.result->>'sender')
   where household_id = l.household_id and result->>'sender' = l.result->>'sender' and reason like 'مرسل غير معروف%';
  return v;
end $$;
revoke all on function public.allow_sms_sender(uuid) from public, anon;
grant execute on function public.allow_sms_sender(uuid) to authenticated;

-- جهة الراتب (مثلاً جهة العمل): أي إيداع منها يُعتبر راتباً
create or replace function public.set_salary_payer(p text)
returns text language plpgsql security definer set search_path = public as $$
begin
  update household_members set salary_payer = left(nullif(btrim(p), ''), 120) where user_id = auth.uid();
  return left(nullif(btrim(p), ''), 120);
end $$;
revoke all on function public.set_salary_payer(text) from public, anon;
grant execute on function public.set_salary_payer(text) to authenticated;

-- ---------- 5) تقسيم السحب النقدي على التصنيفات ----------
create or replace function public.split_expense(p_id uuid, p_parts jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare e expenses; p jsonb; v_sum bigint := 0; v_n int := 0; v_amt bigint; v_cat uuid;
begin
  select * into e from expenses where id = p_id for update;
  if e.id is null or not public.is_member(e.household_id)
     or not (e.created_by = auth.uid() or public.is_owner(e.household_id)) then
    raise exception 'only the owner can do this';
  end if;
  if e.kind <> 'cash' or e.amount <= 0 then raise exception 'not cash'; end if;
  perform set_config('masareef.no_push', 'on', true);
  for p in select * from jsonb_array_elements(coalesce(p_parts, '[]')) loop
    v_amt := (p->>'amount')::bigint;
    v_cat := (p->>'category_id')::uuid;
    continue when v_amt is null or v_amt <= 0;
    if not exists (select 1 from categories where id = v_cat and household_id = e.household_id) then raise exception 'category'; end if;
    v_sum := v_sum + v_amt;
    insert into expenses (household_id, category_id, amount, expense_date, description, created_by, kind, trip_id, sms_meta)
    values (e.household_id, v_cat, v_amt, e.expense_date, left(coalesce(nullif(btrim(p->>'description'), ''), 'نقد'), 200),
            e.created_by, 'purchase', e.trip_id, jsonb_build_object('from_cash', e.id));
    v_n := v_n + 1;
  end loop;
  if v_sum > e.amount then raise exception 'split exceeds amount'; end if;
  if v_sum = e.amount then
    delete from expenses where id = e.id;
  elsif v_sum > 0 then
    update expenses set amount = amount - v_sum, sms_meta = coalesce(sms_meta, '{}') || jsonb_build_object('split_at', now()) where id = e.id;
  end if;
  return v_n;
end $$;
revoke all on function public.split_expense(uuid, jsonb) from public, anon;
grant execute on function public.split_expense(uuid, jsonb) to authenticated;

-- ---------- 7) الفواتير والتجديدات ----------
create or replace function public.renewal_upsert(p_household uuid, p_user uuid, p_ren jsonb, p_expense uuid default null,
                                                 p_date date default null, p_amount bigint default null, p_merchant_key text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_kind text := case when p_ren->>'kind' in ('insurance', 'istimara', 'license', 'passport', 'iqama', 'national_id', 'warranty',
                                               'subscription', 'contract', 'rent', 'school', 'bill', 'other') then p_ren->>'kind' else 'other' end;
  v_title text := left(coalesce(nullif(btrim(p_ren->>'title'), ''), 'تجديد'), 80);
  v_subject text := left(nullif(btrim(p_ren->>'subject'), ''), 60);
  v_months int;
  v_due date;
  v_stated date;
  v_base date := coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date);
  r renewals;
  v_bill_amt bigint;
begin
  begin
    if coalesce(p_ren->>'period_months', '') ~ '^[0-9]{1,3}$' then v_months := (p_ren->>'period_months')::int; end if;
  exception when others then null; end;
  if v_months is null or v_months not between 1 and 120 then v_months := public.renewal_default_months(v_kind); end if;
  begin
    if coalesce(p_ren->>'due_date', '') ~ '^\d{4}-\d{2}-\d{2}$' then v_stated := (p_ren->>'due_date')::date; end if;
  exception when others then null; end;
  if v_stated is not null and v_stated not between v_base - 365 and v_base + 3700 then v_stated := null; end if;
  begin
    if coalesce(p_ren->>'amount_sar', '') ~ '^[0-9]+(\.[0-9]+)?$' then v_bill_amt := round((p_ren->>'amount_sar')::numeric * 100); end if;
  exception when others then null; end;
  if v_bill_amt is not null and v_bill_amt <= 0 then v_bill_amt := null; end if;

  -- الموجود: نفس المتجر أو نفس النوع والجهة (الضمانات دائماً جديدة)
  if v_kind = 'bill' then
    -- الفاتورة: نفس الجهة ونفس الموعد تقريباً = نفس الفاتورة (فاتورة الكهرباء غير المياه)
    select * into r from renewals x
     where x.household_id = p_household and x.status = 'active' and x.kind = 'bill'
       and public.normalize_category(x.title) = public.normalize_category(v_title)
       and coalesce(x.subject, '') = coalesce(v_subject, '')
       and x.due_date between coalesce(v_stated, v_base) - 25 and coalesce(v_stated, v_base) + 25
     order by abs(x.due_date - coalesce(v_stated, v_base)) limit 1;
  elsif v_kind not in ('warranty', 'other') then
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
      update renewals set due_date = v_stated, amount = coalesce(v_bill_amt, amount), updated_at = now() where id = r.id;
    end if;
    return r.id;
  end if;

  v_due := coalesce(v_stated, case when p_expense is not null and v_months is not null
                                   then (v_base + make_interval(months => v_months))::date end,
                   case when v_kind = 'bill' then v_base + 14 end);
  if v_due is null then return null; end if;
  insert into renewals (household_id, title, kind, subject, due_date, period_months, amount, source, expense_id, merchant_key, created_by)
  values (p_household, v_title, v_kind, v_subject, v_due, v_months, coalesce(case when p_expense is not null then p_amount end, v_bill_amt),
          case when p_expense is not null then 'sms' else 'notice' end, p_expense, p_merchant_key, p_user)
  on conflict do nothing
  returning id into r.id;
  return r.id;
end $$;


create or replace function public.renewal_stages(p_kind text)
returns int[] language sql immutable as $$
  select case
    when p_kind in ('passport', 'iqama', 'national_id', 'license', 'istimara') then array[30, 7, 3, 1, 0, -1]
    when p_kind in ('insurance', 'contract', 'rent', 'school') then array[14, 3, 1, 0, -1]
    when p_kind = 'warranty' then array[30, 3]
    when p_kind = 'bill' then array[3, 1, 0]
    else array[3, 1, 0, -1] end
$$;


create or replace function public.renewal_emoji(p_kind text)
returns text language sql immutable as $$
  select case p_kind when 'insurance' then '🛡️' when 'istimara' then '🚗' when 'license' then '🪪' when 'passport' then '🛂'
                     when 'iqama' then '🪪' when 'national_id' then '🪪' when 'warranty' then '🔧' when 'subscription' then '🔁'
                     when 'contract' then '📝' when 'rent' then '🏠' when 'school' then '🎓' when 'bill' then '🧾' else '📄' end
$$;


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
                  'national_id', 'warranty', 'subscription', 'contract', 'rent', 'school', 'bill', 'other')),
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

revoke all on function public.ai_parse_renewal(text) from public, anon;
grant execute on function public.ai_parse_renewal(text) to authenticated;

-- ---------- الإشعارات ----------
create or replace function public.expenses_push_hook()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('masareef.no_push', true), '') = 'on' then return null; end if;
  perform public.push_call(new.household_id, 'expense', new.id);
  return null;
end $$;

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
  v_line  := case
    when e.kind = 'refund' then '↩️ تم استرداد ' || public.fmt_sar(-e.amount) || coalesce(' من ' || v_label, '')
    when e.kind = 'cash'   then '💵 سحب نقدي ' || public.fmt_sar(e.amount)
    when coalesce(e.sms_meta, '{}') ? 'transfer'
                           then 'تم تسجيل دفع ' || regexp_replace(coalesce(e.description, ''), '^[📩🧾]\s*', '') || ' ' || public.fmt_sar(e.amount)
    else 'تم إضافة مبلغ ' || public.fmt_sar(e.amount) || coalesce(' من ' || v_label, '') end;
  select display_name into v_by from household_members where household_id = e.household_id and user_id = e.created_by;
  select monthly_budget into v_budget from households where id = e.household_id;
  v_month := date_trunc('month', e.expense_date)::date;
  v_url   := case when e.trip_id is not null then './#/trips/' || e.trip_id else './#/expenses' end || '?open=' || e.id;

  -- 1) صاحب العملية: ما سُجّل تلقائياً من رسالة البنك
  if e.source_hash is not null then
    v_out := v_out || public.push_to(e.household_id, 'self',
      jsonb_build_object('title', v_line, 'tag', 'exp-' || e.id, 'url', v_url), p_only => e.created_by);

    -- خصم مكرر: نفس المبلغ ونفس المتجر خلال 15 دقيقة (إشعار مستقل يطلع وقتها فقط)
    if e.kind = 'purchase' and e.merchant_key is not null and exists (
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
                               case when v_first->>'amount' is not null then case when v_first->>'kind' = 'bill' then '' else 'آخر مرة ' end || public.fmt_sar((v_first->>'amount')::bigint) end)
                else (select string_agg(public.renewal_emoji(i->>'kind') || ' ' || (i->>'title') || ': ' || public.renewal_when((i->>'days')::int), E'\n')
                      from jsonb_array_elements(v_items) i) end,
      'tag', 'renewals-' || v_today, 'url', './#/renewals'));
  end loop;
  return v_out;
end $$;


create or replace function public.push_sms_messages(p_log uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l record; v_ren jsonb;
begin
  select * into l from sms_log where id = p_log;
  if not found or l.status <> 'ignored' or l.message is null or l.user_id is null then return '[]'; end if;
  if (l.result->>'silent') = 'true' then return '[]'; end if;
  v_ren := case when jsonb_typeof(l.result->'renewal') = 'object' then l.result->'renewal' end;
  -- تذكير تجديد أو فاتورة صادرة: انحفظ في التجديدات
  if v_ren is not null then
    return public.push_to(l.household_id, 'renewals', jsonb_build_object(
      'title', public.renewal_emoji(v_ren->>'kind') || ' ' || coalesce(nullif(btrim(v_ren->>'title'), ''), 'تجديد')
               || case when coalesce(v_ren->>'amount_sar', '') ~ '^[0-9]+(\.[0-9]+)?$'
                       then ' · ' || public.fmt_sar(round((v_ren->>'amount_sar')::numeric * 100)::bigint) else '' end,
      'body', concat_ws(' · ', nullif(btrim(v_ren->>'subject'), ''),
                        case when coalesce(v_ren->>'due_date', '') ~ '^\d{4}-\d{2}-\d{2}$'
                             then 'الموعد ' || public.ar_date((v_ren->>'due_date')::date) end),
      'tag', 'ren-' || l.id, 'url', './#/renewals'), p_only => l.user_id);
  end if;
  -- عملية ربما ضاعت فقط: مرفوضة، أو ما انقرأ مبلغها
  if coalesce(l.reason, '') !~ '(مرفوض|رفض|ملغ|فشل|لم أجد|لم اجد|سعر صرف|غير منطقي)' then return '[]'; end if;
  return public.push_to(l.household_id, 'sms_issue',
    jsonb_build_object(
      'title', case when l.reason ~ '(مرفوض|رفض|ملغ|فشل)' then '⛔️ ' || l.reason else '⚠️ رسالة بنك ما انسجلت' end,
      'body', case when l.reason ~ '(مرفوض|رفض|ملغ|فشل)' then '' else coalesce(l.reason, '') || E'\n' end
              || left(regexp_replace(public.sms_mask(l.message), '\s+', ' ', 'g'), 110),
      'tag', 'sms-' || l.id, 'url', './#/messages'),
    p_only => l.user_id);
end $$;

-- ---------- 3) الدخل ويوم الراتب ----------
create or replace function public.push_income_messages(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  i incomes; v_plan date; v_unpaid int; v_unpaid_amt bigint; v_budget bigint; v_prev bigint; v_ren int;
begin
  select * into i from incomes where id = p_id;
  if not found then return '[]'; end if;
  if i.kind <> 'salary' then
    return public.push_to(i.household_id, 'income', jsonb_build_object(
      'title', '💰 ' || case i.kind when 'transfer' then 'حوالة واردة ' when 'deposit' then 'إيداع ' else 'إضافة ' end
               || public.fmt_sar(i.amount) || coalesce(' من ' || i.payer, ''),
      'tag', 'inc-' || i.id, 'url', './#/readings'), p_only => i.user_id);
  end if;
  -- الراتب بعد يوم 20 = ميزانية الشهر الجاي
  v_plan := (date_trunc('month', i.income_date) + case when extract(day from i.income_date) >= 20 then interval '1 month' else interval '0' end)::date;
  select count(*), coalesce(sum(r.amount), 0) into v_unpaid, v_unpaid_amt from recurring_expenses r
   where r.household_id = i.household_id and r.is_active and (r.start_month is null or r.start_month <= v_plan)
     and not exists (select 1 from expenses x where x.recurring_id = r.id and x.recurring_period = v_plan);
  select monthly_budget into v_budget from households where id = i.household_id;
  select coalesce(sum(amount), 0) into v_prev from expenses
   where household_id = i.household_id and trip_id is null
     and expense_date >= (v_plan - interval '1 month')::date and expense_date < v_plan;
  select count(*) into v_ren from renewals
   where household_id = i.household_id and status = 'active' and due_date between i.income_date and i.income_date + 30;
  return public.push_to(i.household_id, 'income', jsonb_build_object(
    'title', '💰 نزل الراتب ' || public.fmt_sar(i.amount),
    'body', concat_ws(E'\n',
              case when v_unpaid > 0 then '📌 الثابتة: ' || v_unpaid || ' بـ ' || public.fmt_sar(v_unpaid_amt) end,
              case when v_budget > 0 then '🎯 ميزانية ' || public.ar_month(v_plan) || ': ' || public.fmt_sar(v_budget) end,
              '📊 ' || public.ar_month((v_plan - interval '1 month')::date) || ': ' || public.fmt_sar(v_prev),
              case when v_ren > 0 then '📄 تجديدات خلال 30 يوم: ' || v_ren end),
    'tag', 'inc-' || i.id, 'url', './#/readings'), p_only => i.user_id);
end $$;

create or replace function public.incomes_push_hook()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.push_call(new.household_id, 'income', new.id);
  return null;
end $$;
drop trigger if exists incomes_push on public.incomes;
create trigger incomes_push after insert on public.incomes for each row execute function public.incomes_push_hook();

-- ---------- 5) تذكير المساء بالسحب النقدي (9 الليل بتوقيت الرياض) ----------
create or replace function public.push_cash_reminders()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare e record; v_out jsonb := '[]';
begin
  if extract(hour from now() at time zone 'Asia/Riyadh') <> 21 then return '[]'; end if;
  for e in select x.* from expenses x
            where x.kind = 'cash' and x.amount > 0 and not (coalesce(x.sms_meta, '{}') ? 'split_at')
              and (x.created_at at time zone 'Asia/Riyadh')::date = (now() at time zone 'Asia/Riyadh')::date loop
    v_out := v_out || public.push_to(e.household_id, 'self', jsonb_build_object(
      'title', '💵 وش صرفت من ' || public.fmt_sar(e.amount) || '؟',
      'tag', 'cash-' || e.id, 'url', './#/expenses?open=' || e.id), p_only => e.created_by);
  end loop;
  return v_out;
end $$;

-- ---------- 8) ملخص الرحلة اليومي (9 الليل بتوقيت الدولة) ----------
create or replace function public.push_trip_day_messages()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t record; v_tz text; v_local date; v_day bigint; v_n int; v_total bigint; v_out jsonb := '[]';
begin
  for t in select tr.*, (select c.tz from countries c where c.iso2 = tr.countries[array_length(tr.countries, 1)]) as ctz
             from trips tr where tr.status = 'active' loop
    v_tz := coalesce(t.ctz, 'Asia/Riyadh');
    continue when extract(hour from now() at time zone v_tz) <> 21;
    v_local := (now() at time zone v_tz)::date;
    select coalesce(sum(amount), 0), count(*) into v_day, v_n from expenses
     where trip_id = t.id and (created_at at time zone v_tz)::date = v_local;
    continue when v_n = 0;
    select coalesce(sum(amount), 0) into v_total from expenses where trip_id = t.id;
    v_out := v_out || public.push_to(t.household_id, 'travel', jsonb_build_object(
      'title', '✈️ ' || t.name || ' · اليوم ' || public.fmt_sar(v_day),
      'body', 'مجموع الرحلة ' || public.fmt_sar(v_total)
              || coalesce(' من ' || public.fmt_sar(t.budget) || ' (' || round(v_total * 100.0 / nullif(t.budget, 0)) || '%)', ''),
      'tag', 'tripday-' || t.id || '-' || v_local, 'url', './#/trips/' || t.id));
  end loop;
  return v_out;
end $$;

create or replace function public.push_build(p_kind text, p_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return case p_kind
    when 'expense'  then public.push_expense_messages(p_id)
    when 'sms'      then public.push_sms_messages(p_id)
    when 'income'   then public.push_income_messages(p_id)
    when 'daily'    then public.push_daily_messages(null) || public.push_renewal_messages(null)
    when 'hourly'   then public.push_cash_reminders() || public.push_trip_day_messages()
    when 'trip_end' then public.push_trip_end_messages(p_id)
    else '[]'::jsonb end;
end $$;

create or replace function public.push_set_prefs(p_prefs jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb; k text; v_clean jsonb := '{}';
begin
  foreach k in array array['self', 'family', 'budget', 'recurring', 'monthly', 'sms_issue', 'travel', 'renewals', 'income'] loop
    if jsonb_typeof(p_prefs->k) = 'boolean' then v_clean := v_clean || jsonb_build_object(k, p_prefs->k); end if;
  end loop;
  update household_members set notify_prefs = notify_prefs || v_clean where user_id = auth.uid()
  returning notify_prefs into v;
  return v;
end $$;

-- كل ساعة: يتصل بدالة الإشعارات فقط لو فيه شي يرسله
select cron.unschedule(jobid) from cron.job where jobname = 'masareef-hourly';
select cron.schedule('masareef-hourly', '0 * * * *',
  'select public.push_call(null, ''hourly'') where jsonb_array_length(public.push_build(''hourly'', null)) > 0');

-- ---------- 8) تقويم الآيفون (اشتراك للقراءة فقط) ----------
create or replace function public.my_calendar_token()
returns text language plpgsql security definer set search_path = public as $$
declare v_h uuid := public.my_household(); v text;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  insert into calendar_tokens (user_id, household_id) values (auth.uid(), v_h)
  on conflict (user_id) do update set household_id = excluded.household_id
  returning token into v;
  return v;
end $$;
revoke all on function public.my_calendar_token() from public, anon;
grant execute on function public.my_calendar_token() to authenticated;

create or replace function public.ics_text(p text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(p, ''), '\', '\\'), ';', '\;'), ',', '\,'), E'\r', ''), E'\n', '\n')
$$;

-- سطور ICS لا تتجاوز 75 بايت (العربي بايتين للحرف)
create or replace function public.ics_fold(p text)
returns text language plpgsql immutable as $$
declare v_out text := ''; cur text := ''; ch text; i int;
begin
  for i in 1..char_length(p) loop
    ch := substr(p, i, 1);
    if octet_length(cur || ch) > 73 then v_out := v_out || cur || E'\r\n '; cur := ch; else cur := cur || ch; end if;
  end loop;
  return v_out || cur;
end $$;

create or replace function public.ics_event(p_uid text, p_day date, p_summary text)
returns text language sql immutable as $$
  select 'BEGIN:VEVENT' || E'\r\n'
      || 'UID:' || p_uid || '@masareef' || E'\r\n'
      || 'DTSTAMP:' || to_char(p_day, 'YYYYMMDD') || 'T060000Z' || E'\r\n'
      || 'DTSTART;VALUE=DATE:' || to_char(p_day, 'YYYYMMDD') || E'\r\n'
      || 'DTEND;VALUE=DATE:' || to_char(p_day + 1, 'YYYYMMDD') || E'\r\n'
      || public.ics_fold('SUMMARY:' || public.ics_text(p_summary)) || E'\r\n'
      || 'TRANSP:TRANSPARENT' || E'\r\n'
      || 'END:VEVENT' || E'\r\n'
$$;

create or replace function public.calendar_ics(p_token text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  c calendar_tokens; v text; e record; r record; m date; d date; i int;
  v_month date := date_trunc('month', now() at time zone 'Asia/Riyadh')::date;
begin
  select * into c from calendar_tokens where token = p_token;
  if c.user_id is null or not exists (select 1 from household_members where user_id = c.user_id and household_id = c.household_id) then
    return null;
  end if;
  v := 'BEGIN:VCALENDAR' || E'\r\n' || 'VERSION:2.0' || E'\r\n' || 'PRODID:-//masareef//ar' || E'\r\n'
    || 'CALSCALE:GREGORIAN' || E'\r\n' || 'METHOD:PUBLISH' || E'\r\n'
    || public.ics_fold('X-WR-CALNAME:' || public.ics_text('مصاريف')) || E'\r\n'
    || 'X-WR-TIMEZONE:Asia/Riyadh' || E'\r\n'
    || 'REFRESH-INTERVAL;VALUE=DURATION:PT6H' || E'\r\n' || 'X-PUBLISHED-TTL:PT6H' || E'\r\n';
  -- التجديدات والضمانات والفواتير
  for e in select * from renewals where household_id = c.household_id and status = 'active'
             and due_date >= current_date - 30 order by due_date loop
    v := v || public.ics_event('ren-' || e.id, e.due_date,
           concat_ws(' · ', public.renewal_emoji(e.kind) || ' ' || e.title, nullif(e.subject, ''),
                     case when e.amount is not null then public.fmt_sar(e.amount) end));
  end loop;
  -- المصاريف الثابتة للأشهر الستة الجاية (اللي ما انسددت)
  for r in select * from recurring_expenses where household_id = c.household_id and is_active loop
    for i in 0..5 loop
      m := (v_month + make_interval(months => i))::date;
      continue when r.start_month is not null and m < r.start_month;
      continue when exists (select 1 from expenses x where x.recurring_id = r.id and x.recurring_period = m);
      d := least(m + (r.day_of_month - 1), (m + interval '1 month - 1 day')::date);
      v := v || public.ics_event('rec-' || r.id || '-' || to_char(m, 'YYYYMM'), d, '🔁 ' || r.name || ' · ' || public.fmt_sar(r.amount));
    end loop;
  end loop;
  return v || 'END:VCALENDAR' || E'\r\n';
end $$;
revoke all on function public.calendar_ics(text) from public, anon, authenticated;
grant execute on function public.calendar_ics(text) to service_role;

-- ---------- الصلاحيات ----------
revoke all on function public.push_expense_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_sms_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_income_messages(uuid) from public, anon, authenticated;
revoke all on function public.push_cash_reminders() from public, anon, authenticated;
revoke all on function public.push_trip_day_messages() from public, anon, authenticated;
revoke all on function public.push_renewal_messages(date) from public, anon, authenticated;
revoke all on function public.push_build(text, uuid) from public, anon, authenticated;
revoke all on function public.incomes_push_hook() from public, anon, authenticated;
revoke all on function public.expenses_push_hook() from public, anon, authenticated;
revoke all on function public.sms_sender_known(uuid, text) from public, anon, authenticated;
revoke all on function public.renewal_upsert(uuid, uuid, jsonb, uuid, date, bigint, text) from public, anon, authenticated;
grant execute on function public.push_build(text, uuid) to service_role;
grant execute on function public.push_set_prefs(jsonb) to authenticated;

notify pgrst, 'reload schema';
