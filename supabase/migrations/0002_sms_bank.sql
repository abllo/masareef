-- =====================================================================
--  تسجيل المصروفات تلقائياً من رسائل البنك (اختصارات الآيفون)
-- (طُبّق مسبقاً) الصق في SQL Editor في Supabase واضغط Run
-- =====================================================================

-- منع تسجيل نفس الرسالة مرتين
alter table public.expenses add column if not exists source_hash text unique;

-- رمز سري لكل شخص يوضع في الاختصار
create table if not exists public.sms_tokens (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete cascade,
  token        text not null unique
               default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  created_at   timestamptz not null default now()
);
alter table public.sms_tokens enable row level security; -- بدون سياسات: لا يُقرأ من الموقع

-- رمز تلقائي لأي عضو جديد ينضم للعائلة
create or replace function public.create_sms_token()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into sms_tokens (user_id, household_id) values (new.user_id, new.household_id)
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists members_sms_token on public.household_members;
create trigger members_sms_token after insert on public.household_members
for each row execute function public.create_sms_token();

-- الدالة التي يستدعيها الاختصار
create or replace function public.sms_expense(token text, message text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  t         public.sms_tokens;
  msg       text;
  low       text;
  amt_text  text;
  v_amount  bigint;
  merchant  text;
  cat_name  text;
  cat_id    uuid;
  v_id      uuid;
begin
  select * into t from sms_tokens s where s.token = sms_expense.token;
  if t.user_id is null then raise exception 'رمز غير صحيح'; end if;
  if message is null or length(message) > 2000 then return 'تجاهل: رسالة فارغة'; end if;

  -- توحيد الأرقام العربية وإزالة فواصل الآلاف
  msg := translate(message, '٠١٢٣٤٥٦٧٨٩٫٬', '0123456789.,');
  msg := regexp_replace(msg, '(\d),(\d)', '\1\2', 'g');
  low := lower(msg);

  -- ليست عملية شراء
  if low ~ '(otp|رمز التحقق|رمز التفعيل|كلمة المرور|verification|إيداع|ايداع|استرداد|refund|راتب|حوالة واردة|incoming|deposit)' then
    return 'تجاهل: ليست عملية شراء';
  end if;
  if low ~ '\m(usd|eur|gbp|aed|bhd|kwd|qar|egp)\M' and low !~ '(sar|ر\.?\s?س|ريال)' then
    return 'تجاهل: عملة أجنبية، أضفها يدوياً';
  end if;

  -- المبلغ
  amt_text := coalesce(
    substring(low from '(?:مبلغ|amount)[^0-9]{0,20}([0-9]+(?:\.[0-9]{1,2})?)'),
    substring(low from '(?:sar|ر\.?\s?س|ريال)\s*:?\s*([0-9]+(?:\.[0-9]{1,2})?)'),
    substring(low from '([0-9]+(?:\.[0-9]{1,2})?)\s*(?:sar|ر\.?\s?س|ريال)')
  );
  if amt_text is null then return 'تجاهل: لم أجد المبلغ'; end if;
  v_amount := round(amt_text::numeric * 100)::bigint;
  if v_amount <= 0 then return 'تجاهل: مبلغ صفر'; end if;

  -- اسم المتجر (السطر بعد «لدى» أو «عند» أو at)
  merchant := trim(substring(msg from '(?i)(?:لدى|عند|التاجر|\mat\M|merchant)\s*:?\s*([^\n]{2,60})'));

  -- تخمين التصنيف
  cat_name := case
    when low ~ '(هنقر|hunger|جاهز|jahez|مرسول|mrsool|تويو|toyou|نينجا|ninja|كيتا|keeta|chefz|شفز)' then 'تطبيقات التوصيل'
    when low ~ '(دانوب|danube|بنده|panda|عثيم|othaim|كارفور|carrefour|تميمي|tamimi|لولو|lulu|نستو|nesto|ماركت|market|تموينات|سوبر)' then 'البقالة والسوبرماركت'
    when low ~ '(كوفي|كافيه|قهوة|cafe|coffee|starbucks|ستاربكس|مطعم|مطاعم|restaurant|البيك|albaik|mcdonald|ماكدونالدز|kudu|كودو|herfy|هرفي|barns|بارنز|dunkin|دانكن|pizza|بيتزا|burger|برجر|شاورما|shawarma)' then 'المطاعم والمقاهي'
    when low ~ '(stc|mobily|موبايلي|zain|كهرباء|electric|المياه|netflix|نتفلكس|shahid|شاهد|spotify|apple\.com|icloud|سداد|فاتورة|osn)' then 'الفواتير والاشتراكات'
    when low ~ '(بنزين|وقود|fuel|sasco|ساسكو|aldrees|الدريس|petromin|بترومين|نفط|محطة|مغسلة|car wash)' then 'مصاريف السيارة'
    when low ~ '(amazon|امازون|أمازون|noon\.com|\mnoon\M|shein|شي ان|ikea|ايكيا|extra|اكسترا|jarir|جرير|centrepoint|سنتربوينت|namshi|نمشي)' then 'التسوق والمشتريات'
    else 'مصاريف أخرى'
  end;

  select id into cat_id from categories
  where household_id = t.household_id and name = cat_name and not is_archived;
  if cat_id is null then -- التصنيف محذوف أو مؤرشف: آخر تصنيف نشط
    select id, name into cat_id, cat_name from categories
    where household_id = t.household_id and not is_archived
    order by sort_order desc limit 1;
  end if;
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

-- رموز للأعضاء الحاليين
insert into public.sms_tokens (user_id, household_id)
select user_id, household_id from public.household_members
on conflict (user_id) do nothing;

-- اعرض الرموز (انسخ رمزك من النتيجة)
select m.display_name as "الاسم", t.token as "الرمز"
from public.sms_tokens t
join public.household_members m using (user_id, household_id);
