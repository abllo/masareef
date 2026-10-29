-- =====================================================================
--  0006: الذكاء الاصطناعي (Claude)
--   1) قراءة رسائل البنك وتصنيفها بـ Claude، مع رجوع تلقائي للقراءة المحلية
--      إذا توقف الربط (لا مفتاح / لا رصيد / خطأ / بطء) — لا تضيع أي رسالة
--   2) يتعلّم من تعديلاتك: تغيير تصنيف عملية من رسالة يحفظ قاعدة «متجر ← تصنيف»
--   3) سجل لكل رسالة وصلت ونتيجتها
--   4) تنظيم التصنيفات بالذكاء الاصطناعي (دمج/إعادة تسمية/أرشفة/حذف/إنشاء/توحيد متجر)
--      كل عملية تُسجَّل ويمكن التراجع عنها بالكامل، ولا يُحذف إلا تصنيف فارغ
--  مفتاح Claude في Supabase Vault باسم: anthropic_api_key  (لا يظهر في الكود ولا في الموقع)
-- =====================================================================

create extension if not exists http with schema extensions;

-- ---------- أعمدة إضافية ----------
alter table public.expenses   add column if not exists merchant_key text;
alter table public.expenses   add column if not exists sms_meta jsonb;
alter table public.categories add column if not exists created_by_ai boolean not null default false;
create index if not exists expenses_merchant_idx on public.expenses (household_id, merchant_key) where merchant_key is not null;

-- ---------- قواعد «متجر ← تصنيف» المتعلَّمة ----------
create table if not exists public.merchant_rules (
  household_id   uuid not null references public.households(id) on delete cascade,
  merchant_key   text not null,
  merchant_label text not null,
  category_id    uuid not null,
  created_by     uuid references auth.users(id) on delete set null,
  updated_at     timestamptz not null default now(),
  primary key (household_id, merchant_key),
  foreign key (category_id, household_id) references public.categories(id, household_id) on delete cascade
);
alter table public.merchant_rules enable row level security;
drop policy if exists merchant_rules_all on public.merchant_rules;
create policy merchant_rules_all on public.merchant_rules for all to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));

-- ---------- سجل رسائل البنك ----------
create table if not exists public.sms_log (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id      uuid references auth.users(id) on delete set null,
  received_at  timestamptz not null default now(),
  message      text,      -- رسائل رموز التحقق لا يُحفظ نصها
  status       text not null check (status in ('recorded', 'ignored', 'duplicate', 'linked')),
  reason       text,
  source       text,      -- ai | rules
  expense_id   uuid references public.expenses(id) on delete set null,
  result       jsonb
);
create index if not exists sms_log_household_idx on public.sms_log (household_id, received_at desc);
alter table public.sms_log enable row level security;
drop policy if exists sms_log_select on public.sms_log;
drop policy if exists sms_log_delete on public.sms_log;
create policy sms_log_select on public.sms_log for select to authenticated using (public.is_member(household_id));
create policy sms_log_delete on public.sms_log for delete to authenticated using (public.is_member(household_id));
revoke insert, update on public.sms_log from anon, authenticated;

-- ---------- سجل تغييرات التصنيفات (للتراجع) ----------
create table if not exists public.category_audit (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  batch_id     uuid not null,
  op           text not null,
  details      jsonb not null,
  actor        text not null default 'ai',
  created_at   timestamptz not null default now(),
  undone_at    timestamptz
);
create index if not exists category_audit_batch_idx on public.category_audit (household_id, batch_id);
alter table public.category_audit enable row level security;
drop policy if exists category_audit_select on public.category_audit;
create policy category_audit_select on public.category_audit for select to authenticated using (public.is_member(household_id));
revoke insert, update, delete on public.category_audit from anon, authenticated;

-- ---------- حالة الربط ----------
create table if not exists public.ai_health (
  id            int primary key default 1 check (id = 1),
  last_ok_at    timestamptz,
  last_error_at timestamptz,
  last_error    text
);
insert into public.ai_health (id) values (1) on conflict do nothing;
alter table public.ai_health enable row level security;  -- لا سياسات: يُقرأ عبر ai_status() فقط

do $$ begin
  alter publication supabase_realtime add table public.sms_log;
exception when duplicate_object then null; end $$;

-- =====================================================================
--  أدوات مساعدة
-- =====================================================================

-- مفتاح موحّد لاسم المتجر: «STARBUCKS 1234 JEDDAH SA» و«Starbucks» ← starbucks
create or replace function public.normalize_merchant(p text)
returns text language sql immutable as $$
  select nullif(array_to_string(array(
    select w from regexp_split_to_table(
      regexp_replace(lower(translate(coalesce(p, ''), 'أإآةى', 'ااايه')), '[^a-zء-ي]+', ' ', 'g'), ' ') as w
    where length(w) > 1
      and w <> all (array[
        'sa','ksa','sau','saudi','arabia','jeddah','jiddah','riyadh','dammam','khobar','makkah','mecca','madinah','medina',
        'taif','abha','tabuk','buraidah','jubail','yanbu','com','www','net','pos','mada','store','branch','co','ltd','llc','est',
        'جده','الرياض','الدمام','الخبر','مكه','المدينه','المنوره','السعوديه','المملكه','العربيه','الطايف','ابها','تبوك',
        'فرع','مؤسسه','شركه'])
  ), ' '), '')
$$;

-- يخفي أرقام الرصيد/المتاح/الحد والأرقام الطويلة قبل الإرسال لـ Claude
create or replace function public.sms_mask(p text)
returns text language sql immutable as $$
  select string_agg(
           case when line ~* '(الرصيد|رصيد|المتاح|متاح|balance|avail|limit|الحد)'
                then regexp_replace(line, '[0-9٠-٩]', '•', 'g') else line end,
           E'\n' order by n)
  from regexp_split_to_table(regexp_replace(coalesce(p, ''), '[0-9]{8,}', '########', 'g'), E'\n') with ordinality as t(line, n)
$$;

create or replace function public.ai_model(p_purpose text default 'sms')
returns text language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  begin
    select decrypted_secret into v from vault.decrypted_secrets where name = 'anthropic_model_' || p_purpose limit 1;
  exception when others then v := null; end;
  return coalesce(nullif(v, ''), case p_purpose when 'plan' then 'claude-sonnet-5-5' else 'claude-haiku-5-5' end);
end $$;

create or replace function public.ai_enabled()
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  return exists (select 1 from vault.decrypted_secrets where name = 'anthropic_api_key' and coalesce(decrypted_secret, '') <> '');
exception when others then return false;
end $$;

-- استدعاء Claude بأداة واحدة إجبارية. يعيد مدخلات الأداة، أو null عند أي مشكلة (لا يرمي خطأ أبداً)
create or replace function public.ai_call(p_purpose text, p_system text, p_user text, p_tool jsonb, p_max_tokens int default 600)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_key text;
  v_res extensions.http_response;
  v_out jsonb;
begin
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'anthropic_api_key' limit 1;
  exception when others then v_key := null; end;
  if coalesce(v_key, '') = '' then return null; end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', case p_purpose when 'plan' then '55000' else '20000' end);
  select * into v_res from extensions.http((
    'POST',
    'https://api.anthropic.com/v1/messages',
    array[extensions.http_header('x-api-key', v_key), extensions.http_header('anthropic-version', '2023-06-01')],
    'application/json',
    jsonb_build_object(
      'model', public.ai_model(p_purpose),
      'max_tokens', p_max_tokens,
      'temperature', 0,
      'system', p_system,
      'tools', jsonb_build_array(p_tool),
      'tool_choice', jsonb_build_object('type', 'tool', 'name', p_tool->>'name'),
      'messages', jsonb_build_array(jsonb_build_object('role', 'user', 'content', p_user))
    )::text
  )::extensions.http_request);

  if v_res.status is distinct from 200 then
    update ai_health set last_error_at = now(), last_error = format('HTTP %s: %s', v_res.status, left(v_res.content, 300)) where id = 1;
    return null;
  end if;
  select e->'input' into v_out
  from jsonb_array_elements((v_res.content::jsonb)->'content') e
  where e->>'type' = 'tool_use'
  limit 1;
  if v_out is null then
    update ai_health set last_error_at = now(), last_error = 'رد بدون نتيجة' where id = 1;
    return null;
  end if;
  update ai_health set last_ok_at = now() where id = 1;
  return v_out;
exception when others then
  update ai_health set last_error_at = now(), last_error = left(sqlerrm, 300) where id = 1;
  return null;
end $$;

-- الأيقونات والألوان المسموحة (نفس ما في الواجهة)
create or replace function public.allowed_icons()
returns text[] language sql immutable as $$
  select array['cart','food','coffee','bike','receipt','bag','car','fuel','broom','steering','home','power','water','wifi',
               'phone','tv','health','pill','school','books','baby','gift','clothes','beauty','travel','sport','pet','repair',
               'charity','circle']
$$;

-- اسم تصنيف للمقارنة: بدون «ال» والتشكيل والهمزات
create or replace function public.normalize_category(p text)
returns text language sql immutable as $$
  select array_to_string(array(
    select regexp_replace(w, '^(وال|ال)', '')
    from regexp_split_to_table(regexp_replace(lower(translate(coalesce(p, ''), 'أإآةى', 'ااايه')), '[^a-zء-ي]+', ' ', 'g'), ' ') w
    where w not in ('', 'و')
  ), ' ')
$$;

-- إنشاء تصنيف بضوابط: لا تكرار ولا شبيه، حد أقصى 18 تصنيفاً نشطاً، أيقونة مسموحة
create or replace function public.safe_create_category(p_household uuid, p_name text, p_icon text, p_batch uuid, p_actor text default 'ai')
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_norm text := public.normalize_category(p_name);
  v_id   uuid;
  v_color text;
begin
  if char_length(v_name) not between 2 and 30 or v_norm = '' then return null; end if;

  -- تصنيف نشط بنفس المعنى؟ استخدمه بدل إنشاء جديد
  select id into v_id from categories
  where household_id = p_household and not is_archived
    and (public.normalize_category(name) = v_norm
         or public.normalize_category(name) like '%' || v_norm || '%'
         or v_norm like '%' || public.normalize_category(name) || '%')
  order by sort_order limit 1;
  if v_id is not null then return v_id; end if;
  -- يوجد مؤرشف بنفس الاسم: لا نعيد إنشاءه (أرشفته كانت مقصودة)
  if exists (select 1 from categories where household_id = p_household and public.normalize_category(name) = v_norm) then
    return null;
  end if;
  if (select count(*) from categories where household_id = p_household and not is_archived) >= 18 then return null; end if;

  select c into v_color from unnest(array['#16A34A','#4F46E5','#DC2626','#0891B2','#DB2777','#B45309','#7C3AED','#2563EB','#C2410C','#0E6B58','#475569','#64748B']) c
  where c not in (select color from categories where household_id = p_household and not is_archived)
  limit 1;

  insert into categories (household_id, name, icon, color, sort_order, created_by_ai)
  values (p_household, v_name,
          case when p_icon = any (public.allowed_icons()) then p_icon else 'circle' end,
          coalesce(v_color, '#64748B'),
          coalesce((select max(sort_order) from categories where household_id = p_household), 0) + 1,
          p_actor = 'ai')
  returning id into v_id;

  insert into category_audit (household_id, batch_id, op, details, actor)
  values (p_household, coalesce(p_batch, gen_random_uuid()), 'create', jsonb_build_object('id', v_id, 'name', v_name), p_actor);
  return v_id;
end $$;

-- =====================================================================
--  قراءة الرسالة (مشتركة بين الاختصار وزر «جرّب رسالة»)
-- =====================================================================
create or replace function public.sms_parse(p_household uuid, p_message text, p_allow_ai boolean default true, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  msg       text;
  low       text;
  body      text;
  m         text[];
  sar_amt   text;
  amt_text  text;
  v_foreign boolean;
  v_amount  bigint;
  v_merchant text;
  hay       text;
  cat_name  text;
  cat_icon  text;
  v_cat_id  uuid;
  v_cat_name text;
  v_today   date := (now() at time zone 'Asia/Riyadh')::date;
  v_date    date := (now() at time zone 'Asia/Riyadh')::date;
  v_ai      jsonb;
  v_source  text := 'rules';
  v_meta    jsonb := '{}';
  v_key     text;
  v_cats    text[];
  v_other   text;
  v_learned text;
  v_rate    numeric;
  v_new     jsonb;
  v_new_name text;
  v_ai_note text;
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
  v_foreign := body ~ '(\m(usd|eur|gbp|aed|bhd|kwd|qar|egp|omr|jod|inr|cny|jpy|try)\M|[$€£])';
  amt_text := case when v_foreign then sar_amt
                   else coalesce(substring(body from '(?:مبلغ|amount)[^0-9]{0,20}([0-9]+(?:\.[0-9]{1,2})?)'), sar_amt) end;
  v_merchant := trim(substring(msg from '(?i)(?:لدى|عند|التاجر|المتجر|\mat\M|merchant)\s*:?\s*([^\n]{2,60})'));

  hay := coalesce(nullif(lower(v_merchant), ''), low);
  hay := regexp_replace(hay, '(stc ?bank|stc ?pay|بنك stc|stc بنك|اس تي سي باي)', '', 'g');
  cat_name := case
    when hay ~ '(هنقر|hunger|جاهز|jahez|مرسول|mrsool|تويو|toyou|نينجا|\mninja\M|كيتا|keeta|chefz|شفز)' then 'تطبيقات التوصيل'
    when hay ~ '(كوفي|كافيه|كافي|قهوة|مقهى|cafe|café|coffee|starbucks|ستاربكس|مطعم|مطاعم|restaurant|البيك|albaik|mcdonald|ماكدونالدز|\mkudu\M|كودو|herfy|هرفي|barns|بارنز|dunkin|دانكن|pizza|بيتزا|burger|برجر|شاورما|shawarma|\mkfc\M|كنتاكي|subway|domino|دومينوز|tim hortons|هاف مليون|half million|krispy|كرسبي|مخبز|bakery|حلويات)' then 'المطاعم والمقاهي'
    when hay ~ '(دانوب|danube|بنده|\mpanda\M|عثيم|othaim|كارفور|carrefour|تميمي|tamimi|لولو|\mlulu\M|نستو|nesto|ماركت|\mmarket\M|supermarket|hypermarket|هايبر|تموينات|سوبر|بقالة|grocery)' then 'البقالة والسوبرماركت'
    when hay ~ '(amazon|امازون|أمازون|noon\.com|\mnoon\M|نون|shein|شي ان|ikea|ايكيا|\mextra\M|اكسترا|jarir|جرير|centrepoint|سنتربوينت|namshi|نمشي|trendyol|ترينديول)' then 'التسوق والمشتريات'
    when hay ~ '(\mstc\M|mobily|موبايلي|\mzain\M|كهرباء|electric|\msec\M|المياه|netflix|نتفلكس|shahid|شاهد|spotify|سبوتيفاي|apple\.com|icloud|سداد|sadad|فاتورة|\mosn\M|youtube|anghami|أنغامي|disney|starzplay|chatgpt|openai)' then 'الفواتير والاشتراكات'
    when hay ~ '(بنزين|وقود|fuel|petrol|sasco|ساسكو|aldrees|الدريس|petromin|بترومين|نفط|محطة|مغسلة|car wash|ورشة|قطع غيار|إطارات|اطارات|tyres|tires)' then 'مصاريف السيارة'
    else 'مصاريف أخرى'
  end;
  cat_icon := case cat_name
    when 'تطبيقات التوصيل' then 'bike' when 'المطاعم والمقاهي' then 'food' when 'البقالة والسوبرماركت' then 'cart'
    when 'التسوق والمشتريات' then 'bag' when 'الفواتير والاشتراكات' then 'receipt' when 'مصاريف السيارة' then 'car'
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
- true ONLY for a completed payment that takes money out: card / mada / Apple Pay / POS purchases, online purchases, bill payments (سداد/فاتورة), subscriptions, government fees.
- false for OTP/verification codes, deposits, salary, incoming transfers, refunds/reversals, declined/failed/cancelled operations, balance or limit alerts, ads/promotions, card activation or statements, ATM cash withdrawals, transfers to people or between own accounts. Then give ignore_reason as a short Arabic phrase.

Amounts:
- amount_sar = the amount actually charged in Saudi riyals. If the message shows a foreign amount and its SAR equivalent, use the SAR equivalent. If only a foreign amount is shown, set amount_sar to null and fill original_amount and original_currency (ISO code).
- Never use the balance, available amount, credit limit or fees. Digits shown as • are masked balances.

merchant: the clean shop/brand name a person would write, without branch numbers, city, country or terminal codes ("STARBUCKS 1234 JEDDAH SA" → "Starbucks", "HUNGERSTATION RIYADH" → "HungerStation", "مطعم البيك فرع ٣" → "البيك"). Keep Arabic names in Arabic.

category: exactly one of the family's categories (the enum). For a merchant listed under "Learned", always use the learned category. Saudi hints: HungerStation, Jahez, Mrsool, ToYou, Keeta, The Chefz, Ninja → delivery apps; Panda, Danube, Othaim, Carrefour, Tamimi, Lulu, Nesto, Farm, Bin Dawood → groceries; cafes, restaurants, bakeries, sweets → restaurants & cafes; STC, Mobily, Zain, SEC electricity, National Water, Netflix, Shahid, Spotify, Apple, Google, iCloud → bills & subscriptions; Aldrees, SASCO, Petromin, Naft, car wash, workshops, tyres → car; Amazon, Noon, Shein, IKEA, Jarir, Extra, Namshi, Centrepoint → shopping; Nahdi, Al-Dawaa, pharmacies, clinics, hospitals → health if such a category exists.
Use "__new__" ONLY when the purchase clearly belongs to a common spending area that none of the categories covers (for example health & pharmacies, education, travel, kids) — never for a single merchant and never for a near-duplicate of an existing category. Then fill new_category with a short Arabic name (2–3 words) and an icon from its enum. When unsure, use the family's "other" category.

date: the transaction date as YYYY-MM-DD if the message states it (Gregorian), else null.
card_last4: last 4 digits of the card if shown. payment_method: mada, credit_card, apple_pay, online, bill_payment or other.
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
            'merchant',          jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'category',          jsonb_build_object('type', 'string', 'enum', to_jsonb(coalesce(v_cats, '{}') || '__new__'::text)),
            'new_category',      jsonb_build_object('type', jsonb_build_array('object', 'null'), 'properties', jsonb_build_object(
                                   'name', jsonb_build_object('type', 'string'),
                                   'icon', jsonb_build_object('type', 'string', 'enum', to_jsonb(public.allowed_icons()))),
                                   'required', jsonb_build_array('name', 'icon')),
            'date',              jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'card_last4',        jsonb_build_object('type', jsonb_build_array('string', 'null')),
            'payment_method',    jsonb_build_object('type', jsonb_build_array('string', 'null'),
                                   'enum', jsonb_build_array('mada', 'credit_card', 'apple_pay', 'online', 'bill_payment', 'other', null)),
            'confidence',        jsonb_build_object('type', 'number')),
          'required', jsonb_build_array('is_purchase', 'category', 'confidence'))),
      500);
    if v_ai is null then v_ai_note := 'تعذّر الذكاء الاصطناعي، استُخدمت القراءة المحلية'; end if;
  end if;

  if v_ai is not null then
    if (v_ai->>'is_purchase') = 'false' then
      return jsonb_build_object('status', 'ignored', 'source', 'ai',
        'reason', coalesce(nullif(btrim(v_ai->>'ignore_reason'), ''), 'ليست عملية شراء'),
        'fallback_amount', amt_text);
    end if;
    v_source := 'ai';
    if coalesce(v_ai->>'amount_sar', '') ~ '^[0-9]+(\.[0-9]+)?$' and (v_ai->>'amount_sar')::numeric > 0 then
      amt_text := v_ai->>'amount_sar';
    elsif coalesce(v_ai->>'original_amount', '') ~ '^[0-9]+(\.[0-9]+)?$' then
      -- عملات مربوطة بسعر ثابت: تحويل تقريبي (البنك قد يضيف رسوماً بسيطة)
      v_rate := case upper(v_ai->>'original_currency')
        when 'USD' then 3.75 when 'AED' then 1.0211 when 'BHD' then 9.9734 when 'QAR' then 1.0302
        when 'OMR' then 9.7403 when 'JOD' then 5.2891 when 'SAR' then 1 else null end;
      if v_rate is not null then
        amt_text := round((v_ai->>'original_amount')::numeric * v_rate, 2)::text;
        if v_rate <> 1 then v_meta := v_meta || '{"approx": true}'; end if;
      elsif v_foreign then
        amt_text := null;
      end if;
    end if;
    v_merchant := coalesce(nullif(btrim(v_ai->>'merchant'), ''), v_merchant);
    cat_name := coalesce(v_ai->>'category', cat_name);
    cat_icon := null;
    if coalesce(v_ai->>'date', '') ~ '^\d{4}-\d{2}-\d{2}$' then
      begin
        if (v_ai->>'date')::date between v_today - 30 and v_today then v_date := (v_ai->>'date')::date; end if;
      exception when others then null; end;
    end if;
    v_meta := v_meta || jsonb_strip_nulls(jsonb_build_object(
      'card_last4', nullif(right(regexp_replace(coalesce(v_ai->>'card_last4', ''), '[^0-9]', '', 'g'), 4), ''),
      'payment_method', v_ai->>'payment_method',
      'confidence', v_ai->'confidence',
      'original_amount', v_ai->'original_amount',
      'original_currency', v_ai->>'original_currency'));
    v_new := v_ai->'new_category';
  end if;

  if amt_text is null then
    return jsonb_build_object('status', 'ignored', 'source', v_source,
      'reason', case when v_foreign then 'عملة أجنبية بدون مبلغ بالريال، أضفها يدوياً' else 'لم أجد المبلغ' end);
  end if;
  v_amount := round(amt_text::numeric * 100)::bigint;
  if v_amount <= 0 or v_amount > 100000000000 then
    return jsonb_build_object('status', 'ignored', 'reason', 'مبلغ غير منطقي', 'source', v_source);
  end if;

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

  -- 3) بالاسم، ثم بالأيقونة (لو غيّرتم الاسم)، ثم «أخرى»
  if v_cat_id is null and not (v_meta ? 'new_category') then
    select c.id, c.name into v_cat_id, v_cat_name
    from categories c
    where c.household_id = p_household and not c.is_archived
    order by (c.name = cat_name) desc, (c.icon = coalesce(cat_icon, '-')) desc, (c.icon = 'circle') desc, c.sort_order desc
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

-- =====================================================================
--  الاختصار: يستقبل الرسالة ويسجّلها
-- =====================================================================
create or replace function public.sms_expense(token text, message text)
returns text
language plpgsql security definer set search_path = public
set statement_timeout to '40s'
as $$
declare
  t        public.sms_tokens;
  v_hash   text;
  r        jsonb;
  v_amount bigint;
  v_date   date;
  v_label  text;
  v_linked text;
  v_id     uuid;
  v_logmsg text;
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

  v_hash := md5(t.user_id::text || message);
  if exists (select 1 from expenses where source_hash = v_hash) then
    insert into sms_log (household_id, user_id, message, status, reason) values (t.household_id, t.user_id, message, 'duplicate', 'مسجّلة مسبقاً');
    return 'مسجّلة مسبقاً';
  end if;

  r := public.sms_parse(t.household_id, message, true, false);
  v_logmsg := case when (r->>'private') = 'true' then null else message end;

  if r->>'status' = 'ignored' then
    insert into sms_log (household_id, user_id, message, status, reason, source, result)
    values (t.household_id, t.user_id, v_logmsg, 'ignored', r->>'reason', r->>'source', r);
    return 'تجاهل: ' || (r->>'reason');
  end if;

  v_amount := (r->>'amount')::bigint;
  v_date   := (r->>'date')::date;
  v_label  := coalesce(r->>'merchant', 'رسالة البنك');

  -- مصروف ثابت سجّلتم دفعه يدوياً في نفس الشهر بنفس المبلغ: نربط الرسالة به بدل التكرار
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

  insert into expenses (household_id, category_id, amount, expense_date, description, created_by, source_hash, merchant_key, sms_meta)
  values (t.household_id, (r->>'category_id')::uuid, v_amount, v_date, left('📩 ' || v_label, 200), t.user_id, v_hash,
          r->>'merchant_key', (r->'meta') || jsonb_strip_nulls(jsonb_build_object('merchant', r->>'merchant')))
  on conflict (source_hash) do nothing
  returning id into v_id;
  if v_id is null then return 'مسجّلة مسبقاً'; end if;

  insert into sms_log (household_id, user_id, message, status, reason, source, expense_id, result)
  values (t.household_id, t.user_id, v_logmsg, 'recorded', r->>'note', r->>'source', v_id, r);
  delete from sms_log where household_id = t.household_id and received_at < now() - interval '180 days';

  return format('تم تسجيل %s%s ر.س · %s ← %s',
    case when (r->'meta'->>'approx') = 'true' then '≈' else '' end,
    to_char(v_amount / 100.0, 'FM999999990.00'), v_label, r->>'category_name');
end $$;

revoke all on function public.sms_expense(text, text) from public;
grant execute on function public.sms_expense(text, text) to anon, authenticated;

-- نسخة تقبل أسماء حقول فيها مسافات من كيبورد الآيفون
create or replace function public.sms_expense(jsonb)
returns text language plpgsql security definer set search_path = public
set statement_timeout to '40s'
as $$
declare k text; v_token text; v_msg text;
begin
  for k in select jsonb_object_keys($1) loop
    if lower(trim(k)) = 'token' then v_token := $1->>k; end if;
    if lower(trim(k)) = 'message' then v_msg := $1->>k; end if;
  end loop;
  return public.sms_expense(v_token, v_msg);
end $$;
revoke all on function public.sms_expense(jsonb) from public;
grant execute on function public.sms_expense(jsonb) to anon, authenticated;

-- =====================================================================
--  للتطبيق
-- =====================================================================
create or replace function public.my_household()
returns uuid language sql stable security definer set search_path = public as $$
  select household_id from household_members where user_id = auth.uid()
$$;

-- «جرّب رسالة»: يقرأ الرسالة كما سيقرؤها الاختصار، بدون تسجيل
create or replace function public.sms_preview(p_message text)
returns jsonb language plpgsql security definer set search_path = public
set statement_timeout to '40s'
as $$
declare v_h uuid := public.my_household();
begin
  if v_h is null then raise exception 'not in a household'; end if;
  if p_message is null or btrim(p_message) = '' then return jsonb_build_object('status', 'ignored', 'reason', 'رسالة فارغة'); end if;
  return public.sms_parse(v_h, left(p_message, 2000), true, true);
end $$;

create or replace function public.ai_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare h ai_health; v_h uuid := public.my_household();
begin
  if v_h is null then raise exception 'not in a household'; end if;
  select * into h from ai_health where id = 1;
  return jsonb_build_object(
    'enabled', public.ai_enabled(),
    'model', public.ai_model('sms'),
    'last_ok_at', h.last_ok_at,
    'last_error_at', h.last_error_at,
    'last_error', h.last_error,
    'ai_messages_24h', (select count(*) from sms_log where household_id = v_h and source = 'ai' and received_at > now() - interval '24 hours'));
end $$;

-- يتعلّم تلقائياً: تغيير تصنيف عملية جاءت من رسالة بنك = قاعدة لهذا المتجر
create or replace function public.learn_merchant_rule()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.merchant_key is not null and new.category_id is distinct from old.category_id and new.recurring_id is null
     and coalesce(current_setting('masareef.no_learn', true), '') <> 'on' then
    insert into merchant_rules (household_id, merchant_key, merchant_label, category_id, created_by)
    values (new.household_id, new.merchant_key,
            coalesce(nullif(new.sms_meta->>'merchant', ''), regexp_replace(coalesce(new.description, new.merchant_key), '^📩\s*', '')),
            new.category_id, auth.uid())
    on conflict (household_id, merchant_key)
    do update set category_id = excluded.category_id, updated_at = now(), created_by = excluded.created_by;
  end if;
  return new;
end $$;
drop trigger if exists expenses_learn on public.expenses;
create trigger expenses_learn after update of category_id on public.expenses
for each row execute function public.learn_merchant_rule();

-- =====================================================================
--  تنظيم التصنيفات بالذكاء الاصطناعي
-- =====================================================================

-- ملخص التصنيفات والمتاجر الذي يُرسل لـ Claude
create or replace function public.category_stats(p_household uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with exp as (
    select e.*, coalesce(nullif(e.sms_meta->>'merchant', ''), regexp_replace(coalesce(e.description, ''), '^📩\s*', '')) as label
    from expenses e where e.household_id = p_household
  )
  select jsonb_build_object(
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', c.name, 'icon', c.icon, 'archived', c.is_archived, 'is_other', c.icon = 'circle',
        'created_by_ai', c.created_by_ai,
        'expenses_total', (select count(*) from exp where exp.category_id = c.id),
        'expenses_90d', (select count(*) from exp where exp.category_id = c.id and exp.expense_date > current_date - 90),
        'amount_90d_sar', (select coalesce(sum(amount), 0) / 100 from exp where exp.category_id = c.id and exp.expense_date > current_date - 90),
        'recurring', (select count(*) from recurring_expenses r where r.category_id = c.id),
        'top_merchants', (select coalesce(jsonb_agg(l), '[]') from (
            select label as l from exp where exp.category_id = c.id and label <> '' group by label order by count(*) desc limit 8) s)
      ) order by c.sort_order)
      from categories c where c.household_id = p_household), '[]'),
    'merchants_in_several_categories', coalesce((
      select jsonb_agg(jsonb_build_object('merchant', m.label, 'categories', m.cats))
      from (select min(label) as label, jsonb_agg(distinct c.name) as cats
            from exp join categories c on c.id = exp.category_id
            where exp.merchant_key is not null
            group by exp.merchant_key having count(distinct exp.category_id) > 1 limit 30) m), '[]')
  )
$$;

-- يطلب من Claude خطة تنظيم (لا يطبّق شيئاً)
create or replace function public.ai_category_plan()
returns jsonb language plpgsql security definer set search_path = public
set statement_timeout to '70s'
as $$
declare v_h uuid := public.my_household(); v_names text[]; v_plan jsonb;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  if not public.ai_enabled() then raise exception 'ai not enabled'; end if;
  select array_agg(name) into v_names from categories where household_id = v_h;

  v_plan := public.ai_call('plan',
    $sys$You organise the expense categories of a Saudi family budget app. Goal: a clean, unified, reasonably small set of clear Arabic categories, without losing any data. You receive every category with its usage and top merchants, plus merchants that appear in several categories.
Propose only changes that clearly help; an empty list of operations is a valid answer. Allowed operations:
- merge (from → into): duplicates or near-duplicates (e.g. "مطاعم" and "المطاعم والمقاهي"). Everything moves into "into" and "from" is archived.
- move_merchant (merchant → into): put all expenses of one merchant into the right category, to unify inconsistent merchants or rescue merchants sitting in the "other" category.
- create (name, icon): only when at least 3 expenses (in "other" or spread elsewhere) clearly form a common spending area with no category; then add move_merchant operations for those merchants.
- rename (from → new_name): only for unclear or awkward names.
- archive (from): family-created categories with no expenses in 90 days and no recurring expenses.
- delete (from): only categories with expenses_total = 0 and recurring = 0.
Never merge, rename, archive or delete the "other" category (is_other = true). Use the exact existing names. Write summary and reasons in short Arabic.$sys$,
    'Data:' || E'\n' || public.category_stats(v_h)::text,
    jsonb_build_object(
      'name', 'category_plan',
      'description', 'A safe plan to organise the categories.',
      'input_schema', jsonb_build_object(
        'type', 'object',
        'properties', jsonb_build_object(
          'summary', jsonb_build_object('type', 'string'),
          'operations', jsonb_build_object('type', 'array', 'items', jsonb_build_object(
            'type', 'object',
            'properties', jsonb_build_object(
              'op', jsonb_build_object('type', 'string', 'enum', jsonb_build_array('merge', 'move_merchant', 'create', 'rename', 'archive', 'delete')),
              'from', jsonb_build_object('type', 'string', 'enum', to_jsonb(coalesce(v_names, '{}'))),
              'into', jsonb_build_object('type', 'string'),
              'merchant', jsonb_build_object('type', 'string'),
              'name', jsonb_build_object('type', 'string'),
              'new_name', jsonb_build_object('type', 'string'),
              'icon', jsonb_build_object('type', 'string', 'enum', to_jsonb(public.allowed_icons())),
              'reason', jsonb_build_object('type', 'string')),
            'required', jsonb_build_array('op', 'reason')))),
        'required', jsonb_build_array('summary', 'operations'))),
    2500);
  if v_plan is null then raise exception 'ai unavailable'; end if;
  return v_plan;
end $$;

-- تطبيق خطة (من Claude أو من المستخدم) بأمان: كل عملية تُتحقق منها وتُسجَّل للتراجع
create or replace function public.apply_category_plan(p_operations jsonb, p_actor text default 'ai')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_h uuid := public.my_household();
  v_batch uuid := gen_random_uuid();
  op jsonb;
  v_from categories; v_into categories;
  v_ids uuid[]; v_rec uuid[]; v_rules jsonb; v_moves jsonb; v_prev jsonb;
  v_key text; v_new uuid; v_label text;
  v_applied jsonb := '[]'; v_skipped jsonb := '[]';
  v_actor text := case when p_actor = 'user' then 'user' else 'ai' end;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  perform set_config('masareef.no_learn', 'on', true);  -- التنظيم لا يُنشئ قواعد تلقائية من النقل

  for op in select * from jsonb_array_elements(coalesce(p_operations, '[]')) loop
    v_from := null; v_into := null;
    select * into v_from from categories where household_id = v_h and name = op->>'from';
    select * into v_into from categories where household_id = v_h and name = op->>'into';

    case op->>'op'
    when 'create' then
      v_new := public.safe_create_category(v_h, op->>'name', op->>'icon', v_batch, v_actor);
      if v_new is null then v_skipped := v_skipped || jsonb_build_array(op || '{"why":"اسم مكرر أو غير صالح أو وصلنا الحد"}'); continue; end if;

    when 'rename' then
      if v_from.id is null or v_from.icon = 'circle' or coalesce(btrim(op->>'new_name'), '') = ''
         or exists (select 1 from categories where household_id = v_h and public.normalize_category(name) = public.normalize_category(op->>'new_name') and id <> v_from.id) then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"غير مسموح أو الاسم مستخدم"}'); continue;
      end if;
      update categories set name = left(btrim(op->>'new_name'), 40) where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'rename', jsonb_build_object('id', v_from.id, 'old_name', v_from.name, 'new_name', btrim(op->>'new_name')), v_actor);

    when 'merge' then
      if v_from.id is null or v_into.id is null or v_from.id = v_into.id or v_from.icon = 'circle' or v_into.is_archived then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"غير مسموح"}'); continue;
      end if;
      select coalesce(array_agg(id), '{}') into v_ids from expenses where category_id = v_from.id;
      select coalesce(array_agg(id), '{}') into v_rec from recurring_expenses where category_id = v_from.id;
      select coalesce(jsonb_agg(merchant_key), '[]') into v_rules from merchant_rules where category_id = v_from.id;
      update expenses set category_id = v_into.id where id = any (v_ids);
      update recurring_expenses set category_id = v_into.id where id = any (v_rec);
      update merchant_rules set category_id = v_into.id where category_id = v_from.id;
      update categories set is_archived = true where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'merge', jsonb_build_object('from_id', v_from.id, 'into_id', v_into.id, 'from_name', v_from.name, 'into_name', v_into.name,
              'expense_ids', to_jsonb(v_ids), 'recurring_ids', to_jsonb(v_rec), 'rule_keys', v_rules, 'from_was_archived', v_from.is_archived), v_actor);

    when 'archive' then
      if v_from.id is null or v_from.icon = 'circle' or v_from.is_archived then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"غير مسموح"}'); continue;
      end if;
      update categories set is_archived = true where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'archive', jsonb_build_object('id', v_from.id, 'name', v_from.name), v_actor);

    when 'delete' then
      if v_from.id is null or v_from.icon = 'circle'
         or exists (select 1 from expenses where category_id = v_from.id)
         or exists (select 1 from recurring_expenses where category_id = v_from.id) then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"عليه عمليات، يمكن أرشفته فقط"}'); continue;
      end if;
      select coalesce(jsonb_agg(to_jsonb(r)), '[]') into v_rules from merchant_rules r where category_id = v_from.id;
      delete from categories where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'delete', jsonb_build_object('category', to_jsonb(v_from), 'rules', v_rules), v_actor);

    when 'move_merchant' then
      if v_into.id is not null and v_into.is_archived then v_into := null; end if;
      if v_into.id is null and op ? 'into' then
        -- التصنيف قد يكون أُنشئ في نفس الخطة
        select * into v_into from categories where household_id = v_h and not is_archived
          and public.normalize_category(name) = public.normalize_category(op->>'into');
      end if;
      v_key := public.normalize_merchant(op->>'merchant');
      if v_into.id is null or v_key is null then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"التصنيف أو المتجر غير موجود"}'); continue;
      end if;
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'category_id', category_id)), '[]') into v_moves
      from expenses where household_id = v_h and recurring_id is null and category_id <> v_into.id
        and (merchant_key = v_key or public.normalize_merchant(regexp_replace(coalesce(description, ''), '^📩\s*', '')) = v_key);
      select to_jsonb(r) into v_prev from merchant_rules r where household_id = v_h and merchant_key = v_key;
      update expenses set category_id = v_into.id
      where id in (select (x->>'id')::uuid from jsonb_array_elements(v_moves) x);
      v_label := btrim(op->>'merchant');
      insert into merchant_rules (household_id, merchant_key, merchant_label, category_id, created_by)
      values (v_h, v_key, v_label, v_into.id, auth.uid())
      on conflict (household_id, merchant_key) do update set category_id = excluded.category_id, updated_at = now();
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'move_merchant', jsonb_build_object('merchant_key', v_key, 'merchant', v_label, 'into_id', v_into.id,
              'into_name', v_into.name, 'moves', v_moves, 'previous_rule', v_prev), v_actor);

    else
      v_skipped := v_skipped || jsonb_build_array(op || '{"why":"عملية غير معروفة"}'); continue;
    end case;
    v_applied := v_applied || jsonb_build_array(op);
  end loop;

  perform set_config('masareef.no_learn', '', true);
  return jsonb_build_object('batch_id', case when jsonb_array_length(v_applied) > 0 then v_batch end,
                            'applied', v_applied, 'skipped', v_skipped);
end $$;

-- تراجع كامل عن دفعة تنظيم
create or replace function public.undo_category_batch(p_batch uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_h uuid := public.my_household();
  a category_audit;
  n int := 0;
  x jsonb;
begin
  if v_h is null then raise exception 'not in a household'; end if;
  perform set_config('masareef.no_learn', 'on', true);
  for a in select * from category_audit where household_id = v_h and batch_id = p_batch and undone_at is null order by created_at desc, id desc loop
    case a.op
    when 'create' then
      if exists (select 1 from expenses where category_id = (a.details->>'id')::uuid)
         or exists (select 1 from recurring_expenses where category_id = (a.details->>'id')::uuid) then
        update categories set is_archived = true where id = (a.details->>'id')::uuid;
      else
        delete from categories where id = (a.details->>'id')::uuid;
      end if;
    when 'rename' then
      update categories set name = a.details->>'old_name'
      where id = (a.details->>'id')::uuid
        and not exists (select 1 from categories where household_id = v_h and name = a.details->>'old_name' and id <> (a.details->>'id')::uuid);
    when 'merge' then
      update categories set is_archived = coalesce((a.details->>'from_was_archived')::boolean, false) where id = (a.details->>'from_id')::uuid;
      update expenses set category_id = (a.details->>'from_id')::uuid
      where id in (select (v #>> '{}')::uuid from jsonb_array_elements(a.details->'expense_ids') v)
        and category_id = (a.details->>'into_id')::uuid;
      update recurring_expenses set category_id = (a.details->>'from_id')::uuid
      where id in (select (v #>> '{}')::uuid from jsonb_array_elements(a.details->'recurring_ids') v)
        and category_id = (a.details->>'into_id')::uuid;
      update merchant_rules set category_id = (a.details->>'from_id')::uuid
      where household_id = v_h and merchant_key in (select v #>> '{}' from jsonb_array_elements(a.details->'rule_keys') v)
        and category_id = (a.details->>'into_id')::uuid;
    when 'archive' then
      update categories set is_archived = false where id = (a.details->>'id')::uuid;
    when 'delete' then
      insert into categories select * from jsonb_populate_record(null::categories, a.details->'category')
      on conflict do nothing;
      for x in select * from jsonb_array_elements(a.details->'rules') loop
        insert into merchant_rules select * from jsonb_populate_record(null::merchant_rules, x) on conflict do nothing;
      end loop;
    when 'move_merchant' then
      update expenses e set category_id = (m->>'category_id')::uuid
      from jsonb_array_elements(a.details->'moves') m
      where e.id = (m->>'id')::uuid and e.category_id = (a.details->>'into_id')::uuid
        and exists (select 1 from categories c where c.id = (m->>'category_id')::uuid);
      if a.details->'previous_rule' is null or jsonb_typeof(a.details->'previous_rule') = 'null' then
        delete from merchant_rules where household_id = v_h and merchant_key = a.details->>'merchant_key';
      else
        update merchant_rules set category_id = (a.details->'previous_rule'->>'category_id')::uuid,
                                  merchant_label = a.details->'previous_rule'->>'merchant_label'
        where household_id = v_h and merchant_key = a.details->>'merchant_key';
      end if;
    else null;
    end case;
    update category_audit set undone_at = now() where id = a.id;
    n := n + 1;
  end loop;
  perform set_config('masareef.no_learn', '', true);
  return n;
end $$;

-- ---------- الصلاحيات ----------
-- الدوال الداخلية لا تُستدعى من الموقع (Supabase يمنحها تلقائياً لـ anon/authenticated)
revoke all on function public.ai_call(text, text, text, jsonb, int)              from public, anon, authenticated;
revoke all on function public.sms_parse(uuid, text, boolean, boolean)           from public, anon, authenticated;
revoke all on function public.safe_create_category(uuid, text, text, uuid, text) from public, anon, authenticated;
revoke all on function public.category_stats(uuid)                              from public, anon, authenticated;
revoke all on function public.ai_model(text)                                    from public, anon, authenticated;
revoke all on function public.ai_enabled()                                      from public, anon, authenticated;
revoke all on function public.learn_merchant_rule()                             from public, anon, authenticated;
revoke all on function public.sms_preview(text)            from public, anon;
revoke all on function public.ai_status()                  from public, anon;
revoke all on function public.ai_category_plan()           from public, anon;
revoke all on function public.apply_category_plan(jsonb, text) from public, anon;
revoke all on function public.undo_category_batch(uuid)    from public, anon;
revoke all on function public.my_household()               from public, anon;
grant execute on function public.sms_preview(text)             to authenticated;
grant execute on function public.ai_status()                   to authenticated;
grant execute on function public.ai_category_plan()            to authenticated;
grant execute on function public.apply_category_plan(jsonb, text) to authenticated;
grant execute on function public.undo_category_batch(uuid)     to authenticated;
grant execute on function public.my_household()                to authenticated;

notify pgrst, 'reload schema';
