/** كل المبالغ في التطبيق بالهللة (عدد صحيح). 1 ريال = 100 هللة. */
export type Halalas = number;
/** تاريخ بصيغة YYYY-MM-DD */
export type ISODate = string;
/** بداية شهر بصيغة YYYY-MM-01 */
export type MonthKey = string;

export interface Household {
  id: string;
  name: string;
  currency: string;
  monthly_budget: Halalas | null;
  invite_code: string;
  /** نسبة رسوم العمليات الأجنبية الافتراضية (%) */
  fx_fee_pct?: number;
}

/** بطاقة عرفها التطبيق من رسائل البنك */
export interface Card {
  household_id: string;
  card_last4: string;
  bank: string | null;
  card_type: string | null;
  card_kind: string | null;
  nickname: string | null;
  fx_fee_pct: number | null;
  first_seen: string;
  last_seen: string;
}

export interface Member {
  household_id: string;
  user_id: string;
  display_name: string;
  role: 'owner' | 'member';
}

export interface Category {
  id: string;
  household_id: string;
  name: string;
  icon: string;
  color: string;
  sort_order: number;
  is_archived: boolean;
  /** تصنيف أساسي مثبّت: لا يُحذف ولا يدمجه الذكاء الاصطناعي */
  is_core?: boolean;
  created_by_ai?: boolean;
}

export interface Expense {
  id: string;
  household_id: string;
  category_id: string;
  amount: Halalas;
  expense_date: ISODate;
  description: string | null;
  receipt_path: string | null;
  recurring_id: string | null;
  recurring_period: MonthKey | null;
  created_by: string;
  created_at: string;
  updated_at: string;
  /** مفتاح موحّد لاسم المتجر (للعمليات القادمة من رسائل البنك) */
  merchant_key: string | null;
  sms_meta: SmsMeta | null;
}

export type PaymentMethod = 'mada' | 'credit_card' | 'apple_pay' | 'online' | 'bill_payment' | 'other';

/** تفاصيل قرأها التطبيق من رسالة البنك */
export interface SmsMeta {
  source?: 'ai' | 'rules';
  merchant?: string;
  card_last4?: string;
  /** شبكة البطاقة */
  card_type?: 'mada' | 'visa' | 'mastercard' | 'amex' | 'other';
  card_kind?: 'debit' | 'credit';
  /** طريقة الدفع */
  channel?: 'apple_pay' | 'pos' | 'online' | 'bill_payment' | 'other';
  /** حقل قديم (قبل التفريق بين البطاقة وطريقة الدفع) */
  payment_method?: PaymentMethod;
  bank?: string;
  card_nickname?: string;
  /** تحويل العملة */
  fx_rate?: number;
  fx_source?: 'peg' | 'live' | 'sar';
  fx_provider?: string;
  fx_fee_pct?: number;
  fees_sar?: number;
  confidence?: number;
  approx?: boolean;
  rule?: boolean;
  original_amount?: number;
  original_currency?: string;
  created_category?: string;
}

export interface SmsParseResult {
  status: 'ok' | 'ignored';
  reason?: string;
  source?: 'ai' | 'rules';
  amount?: Halalas;
  merchant?: string;
  merchant_key?: string;
  category_id?: string;
  category_name?: string;
  date?: ISODate;
  meta?: SmsMeta & { new_category?: string };
  note?: string;
  fallback_amount?: string;
}

export interface SmsLogEntry {
  id: string;
  household_id: string;
  user_id: string | null;
  received_at: string;
  message: string | null;
  status: 'recorded' | 'ignored' | 'duplicate' | 'linked';
  reason: string | null;
  source: 'ai' | 'rules' | null;
  expense_id: string | null;
  result: SmsParseResult | null;
}

export interface MerchantRule {
  household_id: string;
  merchant_key: string;
  merchant_label: string;
  category_id: string;
  updated_at: string;
}

export interface AiStatus {
  enabled: boolean;
  model: string;
  last_ok_at: string | null;
  last_error_at: string | null;
  last_error: string | null;
  ai_messages_24h: number;
}

export type PlanOpKind = 'merge' | 'move_merchant' | 'create' | 'rename' | 'archive' | 'delete';
export interface PlanOp {
  op: PlanOpKind;
  from?: string;
  into?: string;
  merchant?: string;
  name?: string;
  new_name?: string;
  icon?: string;
  reason?: string;
  why?: string;
}
export interface CategoryPlan { summary: string; operations: PlanOp[] }
export interface PlanResult { batch_id: string | null; applied: PlanOp[]; skipped: PlanOp[] }

export interface MonthReport {
  content: { headline: string; highlights: string[]; alerts: string[]; tips: string[] };
  facts: Record<string, unknown>;
  created_at: string;
  cached: boolean;
}

export interface CategoryAudit {
  id: string;
  batch_id: string;
  op: PlanOpKind;
  details: Record<string, unknown>;
  actor: 'ai' | 'user';
  created_at: string;
  undone_at: string | null;
}

export interface Recurring {
  id: string;
  household_id: string;
  category_id: string;
  name: string;
  amount: Halalas;
  day_of_month: number;
  start_month: MonthKey;
  is_active: boolean;
}

export interface MonthlyTotal {
  month: MonthKey;
  category_id: string;
  total: Halalas;
  tx_count: number;
}

// ---------- الإشعارات ----------
export type NotifyKey = 'self' | 'family' | 'budget' | 'recurring' | 'monthly' | 'sms_issue';
export type NotifyPrefs = Record<NotifyKey, boolean>;
export interface PushStatus { prefs: NotifyPrefs; devices: number; public_key: string | null }
