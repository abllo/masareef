import { supabase } from './supabase';
import type {
  AiStatus, Card, Category, CategoryAudit, CategoryPlan, Expense, Household, ISODate, Member, MerchantRule, MonthKey, MonthlyTotal, MonthReport,
  ArchiveResult, NotifyPrefs, PlanOp, PlanResult, PushStatus, Recurring, Renewal, RenewalDraft, SmsLogEntry, SmsParseResult, Trip, YearOverview,
} from './types';

/** يرمي خطأ مقروءاً بالعربية عند فشل الطلب */
function check<T>(res: { data: T; error: { message: string; code?: string } | null }): T {
  if (res.error) throw new Error(translateError(res.error.message, res.error.code));
  return res.data;
}

export function translateError(message: string, code?: string): string {
  if (code === '42501' || /row-level security/i.test(message)) return 'هذا الإجراء لمنشئ العائلة فقط';
  if (code === '23505' && /categories_household_id_name_key/.test(message)) return 'يوجد تصنيف بنفس الاسم';
  if (code === '23505') return 'هذه العملية مسجلة مسبقاً';
  if (code === '23503') return 'لا يمكن الحذف لوجود عمليات مرتبطة. يمكنك أرشفته بدلاً من ذلك';
  if (/invalid invite code/i.test(message)) return 'رمز الدعوة غير صحيح';
  if (/already in a household/i.test(message)) return 'حسابك مرتبط بعائلة بالفعل';
  if (/household is full/i.test(message)) return 'العائلة مكتملة العدد';
  if (/only the owner can do this/i.test(message)) return 'هذا الإجراء لمنشئ العائلة فقط';
  if (/owner cannot leave/i.test(message)) return 'منشئ العائلة لا يمكنه المغادرة';
  if (/member not found/i.test(message)) return 'العضو غير موجود';
  if (/not in a household/i.test(message)) return 'حسابك غير مرتبط بعائلة';
  if (/ai not enabled/i.test(message)) return 'الذكاء الاصطناعي غير مفعّل بعد: أضف مفتاح Claude في Supabase';
  if (/ai unavailable/i.test(message)) return 'تعذّر الوصول لـ Claude الآن، جرّب بعد قليل';
  if (/core category/i.test(message)) return 'هذا تصنيف أساسي مثبّت، لا يمكن حذفه (تقدر تغيّر اسمه أو لونه)';
  if (/year archived/i.test(message)) return 'هذه السنة مؤرشفة: محفوظ ملخصها فقط، فما تقدر تضيف لها عمليات';
  if (/year not finished/i.test(message)) return 'تقدر تأرشف السنوات المنتهية فقط';
  if (/confirmation mismatch/i.test(message)) return 'اكتب رقم السنة بالضبط للتأكيد';
  if (/year already archived/i.test(message)) return 'هذه السنة مؤرشفة من قبل';
  if (/empty text/i.test(message)) return 'اكتب أو الصق النص أولاً';
  if (/invalid subscription/i.test(message)) return 'تعذّر تفعيل الإشعارات على هذا الجهاز';
  if (/year has no expenses/i.test(message)) return 'ما فيه عمليات في هذه السنة';
  if (/no expenses/i.test(message)) return 'ما فيه عمليات في هذا الشهر للتحليل';
  if (/statement timeout|canceling statement/i.test(message)) return 'أخذ وقتاً أطول من المتوقع، جرّب مرة ثانية';
  if (/same_password|different from the old/i.test(message)) return 'كلمة المرور الجديدة مطابقة للقديمة';
  if (/rate limit|too many/i.test(message)) return 'محاولات كثيرة، انتظر قليلاً ثم أعد المحاولة';
  if (/not authorized|Email address .* (is )?invalid|sending .*email/i.test(message))
    return 'تعذّر إرسال الإيميل لهذا البريد. اطلب من منشئ العائلة تغيير كلمة مرورك من لوحة Supabase';
  if (/Invalid login credentials/i.test(message)) return 'البريد أو كلمة المرور غير صحيحة';
  if (/User already registered/i.test(message)) return 'هذا البريد مسجل مسبقاً، سجّل الدخول بدلاً من ذلك';
  if (/Password should be/i.test(message)) return 'كلمة المرور قصيرة، استخدم 6 أحرف أو أرقام على الأقل';
  if (/Email not confirmed/i.test(message)) return 'أكّد بريدك الإلكتروني أولاً من الرسالة المرسلة إليك';
  if (/Failed to fetch|NetworkError/i.test(message)) return 'تعذّر الاتصال بالخادم، تحقق من الإنترنت';
  return message;
}

// ---------- العائلة ----------
export interface HouseholdContext {
  household: Household;
  me: Member;
  members: Member[];
}

export async function fetchHouseholdContext(userId: string): Promise<HouseholdContext | null> {
  const mine = check(
    await supabase.from('household_members').select('*').eq('user_id', userId).maybeSingle<Member>(),
  );
  if (!mine) return null;
  const [household, members] = await Promise.all([
    supabase.from('households').select('*').eq('id', mine.household_id).single<Household>().then(check),
    supabase.from('household_members').select('*').eq('household_id', mine.household_id).order('joined_at').then(check),
  ]);
  return { household: household as Household, me: mine, members: members as Member[] };
}

export const createHousehold = async (name: string, displayName: string) =>
  check(await supabase.rpc('create_household', { p_name: name, p_display_name: displayName })) as string;

export const joinHousehold = async (code: string, displayName: string) =>
  check(await supabase.rpc('join_household', { p_code: code, p_display_name: displayName })) as string;

export const regenerateInviteCode = async () => check(await supabase.rpc('regenerate_invite_code')) as string;

export const removeMember = async (userId: string) => {
  check(await supabase.rpc('remove_member', { p_user_id: userId }));
};

export const leaveHousehold = async () => {
  check(await supabase.rpc('leave_household'));
};

// ---------- اختصار رسائل البنك ----------
export const fetchSmsToken = async () => check(await supabase.rpc('my_sms_token')) as string;
export const regenerateSmsToken = async () => check(await supabase.rpc('regenerate_sms_token')) as string;

export async function updateHousehold(id: string, patch: Partial<Pick<Household, 'name' | 'monthly_budget' | 'fx_fee_pct'>>) {
  check(await supabase.from('households').update(patch).eq('id', id));
}

export async function updateDisplayName(householdId: string, userId: string, displayName: string) {
  check(
    await supabase.from('household_members').update({ display_name: displayName })
      .eq('household_id', householdId).eq('user_id', userId),
  );
}

// ---------- التصنيفات ----------
export const fetchCategories = async (householdId: string) =>
  check(
    await supabase.from('categories').select('*').eq('household_id', householdId).order('sort_order').order('name'),
  ) as Category[];

export type CategoryInput = Pick<Category, 'name' | 'icon' | 'color'> & Partial<Pick<Category, 'is_archived' | 'sort_order'>>;

export async function saveCategory(householdId: string, input: CategoryInput, id?: string) {
  if (id) check(await supabase.from('categories').update(input).eq('id', id));
  else check(await supabase.from('categories').insert({ ...input, household_id: householdId }));
}

export const deleteCategory = async (id: string) => check(await supabase.from('categories').delete().eq('id', id));

// ---------- المصروفات ----------
const EXPENSE_COLUMNS =
  'id,household_id,category_id,amount,expense_date,description,receipt_path,recurring_id,recurring_period,created_by,created_at,updated_at,merchant_key,sms_meta,trip_id';

export const fetchExpenses = async (householdId: string, from: ISODate, to: ISODate) =>
  check(
    await supabase.from('expenses').select(EXPENSE_COLUMNS).eq('household_id', householdId)
      .gte('expense_date', from).lte('expense_date', to)
      .order('expense_date', { ascending: false }).order('created_at', { ascending: false })
      .limit(5000),
  ) as Expense[];

export const fetchRecurringPayments = async (householdId: string, month: MonthKey) =>
  check(
    await supabase.from('expenses').select(EXPENSE_COLUMNS).eq('household_id', householdId)
      .eq('recurring_period', month).not('recurring_id', 'is', null),
  ) as Expense[];

export const fetchMonthlyTotals = async (householdId: string, fromMonth: MonthKey) =>
  check(
    await supabase.from('monthly_category_totals').select('month,category_id,total,tx_count')
      .eq('household_id', householdId).gte('month', fromMonth),
  ) as MonthlyTotal[];

export interface ExpenseInput {
  amount: number;
  category_id: string;
  expense_date: ISODate;
  description: string | null;
  trip_id?: string | null;
}

export async function saveExpense(
  householdId: string,
  input: ExpenseInput,
  options: { id?: string; receipt?: File | null } = {},
): Promise<Expense> {
  const query = options.id
    ? supabase.from('expenses').update(input).eq('id', options.id)
    : supabase.from('expenses').insert({ ...input, household_id: householdId });
  const res = await query.select(EXPENSE_COLUMNS).single();
  if (res.error?.code === 'PGRST116') throw new Error('ما تقدر تعدّل عملية أضافها شخص آخر (لمنشئ العائلة فقط)');
  const saved = check(res) as Expense;

  if (options.receipt) {
    const path = await uploadReceipt(householdId, saved.id, options.receipt);
    const updated = check(
      await supabase.from('expenses').update({ receipt_path: path }).eq('id', saved.id).select(EXPENSE_COLUMNS).single(),
    ) as Expense;
    if (saved.receipt_path) await supabase.storage.from('receipts').remove([saved.receipt_path]);
    return updated;
  }
  return saved;
}

export async function deleteExpense(expense: Pick<Expense, 'id' | 'receipt_path'>) {
  const { error, count } = await supabase.from('expenses').delete({ count: 'exact' }).eq('id', expense.id);
  if (error) throw new Error(translateError(error.message, error.code));
  if (count === 0) throw new Error('ما تقدر تحذف عملية أضافها شخص آخر (لمنشئ العائلة فقط)');
  if (expense.receipt_path) await supabase.storage.from('receipts').remove([expense.receipt_path]);
}

// ---------- الفواتير ----------
async function uploadReceipt(householdId: string, expenseId: string, file: File): Promise<string> {
  let body: File | Blob = file;
  let ext = file.name.split('.').pop()?.toLowerCase() ?? 'jpg';
  if (file.type.startsWith('image/') && file.type !== 'image/heic') {
    // ضغط صور الجوال الكبيرة قبل الرفع (أسرع وأوفر)
    const { default: imageCompression } = await import('browser-image-compression'); // تحميل عند الحاجة
    body = await imageCompression(file, { maxSizeMB: 0.8, maxWidthOrHeight: 1800, useWebWorker: true, fileType: 'image/webp' });
    ext = 'webp';
  }
  const path = `${householdId}/${expenseId}/${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from('receipts').upload(path, body, {
    contentType: body.type || file.type, upsert: false,
  });
  if (error) throw new Error(`تم حفظ المصروف لكن تعذّر رفع الفاتورة: ${error.message}`);
  return path;
}

export async function receiptUrl(path: string): Promise<string> {
  const { data, error } = await supabase.storage.from('receipts').createSignedUrl(path, 60 * 10);
  if (error) throw new Error(error.message);
  return data.signedUrl;
}

// ---------- المتكررة ----------
export const fetchRecurring = async (householdId: string) =>
  check(
    await supabase.from('recurring_expenses')
      .select('id,household_id,category_id,name,amount,day_of_month,start_month,is_active')
      .eq('household_id', householdId).order('day_of_month'),
  ) as Recurring[];

export type RecurringInput = Pick<Recurring, 'name' | 'amount' | 'category_id' | 'day_of_month' | 'is_active'>;

export async function saveRecurring(householdId: string, input: RecurringInput, id?: string) {
  if (id) check(await supabase.from('recurring_expenses').update(input).eq('id', id));
  else check(await supabase.from('recurring_expenses').insert({ ...input, household_id: householdId }));
}

export const deleteRecurring = async (id: string) =>
  check(await supabase.from('recurring_expenses').delete().eq('id', id));

export const markRecurringPaid = async (recurringId: string, period: MonthKey, date: ISODate) =>
  check(await supabase.rpc('mark_recurring_paid', { p_recurring_id: recurringId, p_period: period, p_date: date })) as string;

// ---------- الذكاء الاصطناعي ورسائل البنك ----------
export const fetchAiStatus = async () => check(await supabase.rpc('ai_status')) as AiStatus;

export const previewSms = async (message: string) =>
  check(await supabase.rpc('sms_preview', { p_message: message })) as SmsParseResult;

export const fetchSmsLog = async (householdId: string, limit = 200) =>
  check(
    await supabase.from('sms_log').select('*').eq('household_id', householdId)
      .order('received_at', { ascending: false }).limit(limit),
  ) as SmsLogEntry[];

export const deleteSmsLog = async (id: string) => {
  const { error, count } = await supabase.from('sms_log').delete({ count: 'exact' }).eq('id', id);
  if (error) throw new Error(translateError(error.message, error.code));
  if (count === 0) throw new Error('هذي رسالة شخص آخر، حذفها لمنشئ العائلة فقط');
};

export const fetchRules = async (householdId: string) =>
  check(
    await supabase.from('merchant_rules').select('*').eq('household_id', householdId).order('merchant_label'),
  ) as MerchantRule[];

export const deleteRule = async (householdId: string, merchantKey: string) => {
  check(await supabase.from('merchant_rules').delete().eq('household_id', householdId).eq('merchant_key', merchantKey));
};

export const fetchRule = async (householdId: string, merchantKey: string) =>
  check(
    await supabase.from('merchant_rules').select('*').eq('household_id', householdId).eq('merchant_key', merchantKey).maybeSingle(),
  ) as MerchantRule | null;

export const requestCategoryPlan = async () => check(await supabase.rpc('ai_category_plan')) as CategoryPlan;

export const applyCategoryPlan = async (operations: PlanOp[], actor: 'ai' | 'user' = 'ai') =>
  check(await supabase.rpc('apply_category_plan', { p_operations: operations, p_actor: actor })) as PlanResult;

export const undoCategoryBatch = async (batchId: string) =>
  check(await supabase.rpc('undo_category_batch', { p_batch: batchId })) as number;

export const fetchCategoryAudit = async (householdId: string) =>
  check(
    await supabase.from('category_audit').select('id,batch_id,op,details,actor,created_at,undone_at')
      .eq('household_id', householdId).order('created_at', { ascending: false }).limit(100),
  ) as CategoryAudit[];

export const fetchExpense = async (id: string) =>
  check(await supabase.from('expenses').select(EXPENSE_COLUMNS).eq('id', id).maybeSingle()) as Expense | null;

export const fetchMonthReport = async (month: MonthKey, refresh = false) =>
  check(await supabase.rpc('ai_month_report', { p_month: month, p_refresh: refresh })) as MonthReport;

export async function fetchCachedReport(householdId: string, month: MonthKey): Promise<MonthReport | null> {
  const row = check(
    await supabase.from('ai_reports').select('content,facts,created_at').eq('household_id', householdId).eq('month', month).maybeSingle(),
  ) as { content: MonthReport['content']; facts: MonthReport['facts']; created_at: string } | null;
  return row ? { ...row, cached: true } : null;
}

// ---------- البطاقات ----------
export const fetchCards = async (householdId: string) =>
  check(await supabase.from('cards').select('*').eq('household_id', householdId).order('last_seen', { ascending: false })) as Card[];

export async function saveCard(householdId: string, last4: string, patch: Partial<Pick<Card, 'bank' | 'nickname' | 'fx_fee_pct'>>) {
  check(await supabase.from('cards').update(patch).eq('household_id', householdId).eq('card_last4', last4));
}

export const deleteCard = async (householdId: string, last4: string) => {
  check(await supabase.from('cards').delete().eq('household_id', householdId).eq('card_last4', last4));
};

// ---------- الإشعارات ----------
export const fetchPushStatus = async () => check(await supabase.rpc('my_push_status')) as PushStatus;

export async function pushSubscribe(sub: PushSubscriptionJSON, device: string) {
  check(await supabase.rpc('push_subscribe', {
    p_endpoint: sub.endpoint, p_p256dh: sub.keys?.p256dh, p_auth: sub.keys?.auth, p_device: device,
  }));
}

export const pushUnsubscribe = async (endpoint: string) => {
  check(await supabase.rpc('push_unsubscribe', { p_endpoint: endpoint }));
};

export const setPushPrefs = async (prefs: Partial<NotifyPrefs>) =>
  check(await supabase.rpc('push_set_prefs', { p_prefs: prefs })) as NotifyPrefs;

async function callPush<T>(action: 'init' | 'test'): Promise<T> {
  const { data, error } = await supabase.functions.invoke('push', { body: { action } });
  if (error) {
    const status = (error as { context?: Response }).context?.status;
    throw new Error(status === 404 ? 'خدمة الإشعارات غير مفعّلة بعد في Supabase' : 'تعذّر الوصول لخدمة الإشعارات، جرّب بعد قليل');
  }
  return data as T;
}
export const initPush = () => callPush<{ publicKey: string }>('init');
export const sendTestPush = () => callPush<{ sent: number; failed: unknown[] }>('test');

// ---------- الرحلات ----------
export const fetchTrips = async (householdId: string) =>
  check(await supabase.from('trips').select('*').eq('household_id', householdId).order('start_date', { ascending: false })) as Trip[];

export const fetchTripExpenses = async (tripId: string) =>
  check(
    await supabase.from('expenses').select(EXPENSE_COLUMNS).eq('trip_id', tripId)
      .order('expense_date', { ascending: false }).order('created_at', { ascending: false }).limit(1000),
  ) as Expense[];

export async function updateTrip(id: string, patch: Partial<Pick<Trip, 'name' | 'budget' | 'card_last4'>>) {
  const { error, count } = await supabase.from('trips').update(patch, { count: 'exact' }).eq('id', id);
  if (error) throw new Error(translateError(error.message, error.code));
  if (count === 0) throw new Error('هذا الإجراء لمنشئ العائلة فقط');
}

export const setTripStatus = async (id: string, active: boolean) => {
  check(await supabase.rpc('set_trip_status', { p_trip: id, p_active: active }));
};

export async function deleteTrip(id: string) {
  const { error, count } = await supabase.from('trips').delete({ count: 'exact' }).eq('id', id);
  if (error) throw new Error(translateError(error.message, error.code));
  if (count === 0) throw new Error('هذا الإجراء لمنشئ العائلة فقط');
}

// ---------- السنوات والأرشفة ----------
export const fetchYearsOverview = async () => check(await supabase.rpc('years_overview')) as YearOverview[];

/** كل عمليات فترة (على دفعات، بدون حد 1000 صف) */
export async function fetchAllExpenses(householdId: string, from: ISODate, to: ISODate): Promise<Expense[]> {
  const out: Expense[] = [];
  for (let page = 0; ; page++) {
    const rows = check(
      await supabase.from('expenses').select(EXPENSE_COLUMNS).eq('household_id', householdId)
        .gte('expense_date', from).lte('expense_date', to)
        .order('expense_date').order('created_at').order('id')
        .range(page * 1000, page * 1000 + 999),
    ) as Expense[];
    out.push(...rows);
    if (rows.length < 1000) return out;
  }
}

/** يأرشف سنة منتهية: يحفظ ملخصها ثم يحذف عملياتها، ثم يحذف صور فواتيرها من التخزين */
export async function archiveYear(year: number, confirm: string): Promise<ArchiveResult> {
  const res = check(await supabase.rpc('archive_year', { p_year: year, p_confirm: confirm })) as Omit<ArchiveResult, 'receiptsLeft'>;
  let receiptsLeft = 0;
  const paths = res.receipts ?? [];
  for (let i = 0; i < paths.length; i += 100) {
    const chunk = paths.slice(i, i + 100);
    const { error } = await supabase.storage.from('receipts').remove(chunk);
    if (error) receiptsLeft += chunk.length;
  }
  return { ...res, receipts: paths, receiptsLeft };
}

// ---------- التجديدات والضمانات ----------
export const fetchRenewals = async (householdId: string) =>
  check(await supabase.from('renewals').select('*').eq('household_id', householdId).order('due_date')) as Renewal[];

export type RenewalInput = Pick<Renewal, 'title' | 'kind' | 'subject' | 'due_date' | 'period_months' | 'amount' | 'notes'>
  & Partial<Pick<Renewal, 'expense_id' | 'source' | 'status'>>;

export async function saveRenewal(householdId: string, input: RenewalInput, id?: string) {
  const res = id
    ? await supabase.from('renewals').update({ ...input, updated_at: new Date().toISOString() }).eq('id', id).select('id')
    : await supabase.from('renewals').insert({ ...input, household_id: householdId }).select('id');
  const rows = check(res) as { id: string }[];
  if (id && rows.length === 0) throw new Error('هذا الإجراء لصاحبه أو لمنشئ العائلة');
}

export async function deleteRenewal(id: string) {
  const { error, count } = await supabase.from('renewals').delete({ count: 'exact' }).eq('id', id);
  if (error) throw new Error(translateError(error.message, error.code));
  if (count === 0) throw new Error('هذا الإجراء لصاحبه أو لمنشئ العائلة');
}

export const renewalDone = async (id: string) => check(await supabase.rpc('renewal_done', { p_id: id })) as Renewal;

export const parseRenewal = async (text: string) => check(await supabase.rpc('ai_parse_renewal', { p_text: text })) as RenewalDraft;
