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
  /** الرحلة التابع لها (مصاريف السفر منفصلة عن مصروف الشهر) */
  trip_id?: string | null;
}

export type PaymentMethod = 'mada' | 'credit_card' | 'apple_pay' | 'online' | 'bill_payment' | 'other';

/** تفاصيل قرأها التطبيق من رسالة البنك */
export interface SmsMeta {
  source?: 'ai' | 'rules' | 'statement';
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
  /** دولة الشراء (ISO) */
  country?: string;
  international?: boolean;
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
export type NotifyKey = 'self' | 'family' | 'budget' | 'recurring' | 'monthly' | 'sms_issue' | 'travel' | 'renewals';
export type NotifyPrefs = Record<NotifyKey, boolean>;
export interface PushStatus { prefs: NotifyPrefs; devices: number; public_key: string | null }

// ---------- الرحلات ----------
export interface Trip {
  id: string;
  household_id: string;
  name: string;
  countries: string[];
  start_date: ISODate;
  end_date: ISODate | null;
  last_abroad_date: ISODate | null;
  status: 'active' | 'closed';
  budget: Halalas | null;
  card_last4: string | null;
  auto: boolean;
  created_by: string | null;
  created_at: string;
}

// ---------- الملخص السنوي ----------
interface Amount { total: Halalas; count: number }
export interface YearData {
  year: number;
  total: Halalas;
  count: number;
  /** مصاريف الشهر العادية (بدون السفر) */
  regular_total?: Halalas;
  travel_total?: Halalas;
  first_date: ISODate | null;
  last_date: ISODate | null;
  months: ({ month: number; regular?: Halalas; travel?: Halalas } & Amount)[];
  categories: ({ id?: string; name: string; icon: string; color: string; months: Halalas[] } & Amount)[];
  merchants: ({ merchant: string } & Amount)[];
  banks: ({ bank: string } & Amount)[];
  cards: ({ card_last4: string; bank: string | null; card_type: string | null; card_kind: string | null } & Amount)[];
  channels: ({ channel: string } & Amount)[];
  members: ({ member: string } & Amount)[];
  foreign: ({ currency: string; original: number } & Amount)[];
  recurring: { name: string; total: Halalas; months_paid: number }[];
  largest: { merchant: string; category: string; total: Halalas; date: ISODate }[];
  from_sms: number;
  trips?: ({ id: string; name: string; countries: string[]; start_date: ISODate; end_date: ISODate | null; budget: Halalas | null } & Amount)[];
}
export interface YearOverview { year: number; archived: boolean; archived_at?: string; data: YearData }
export interface ArchiveResult { year: number; deleted: number; total: Halalas; receipts: string[]; receiptsLeft: number }

// ---------- التجديدات والضمانات ----------
export type RenewalKind = 'insurance' | 'istimara' | 'license' | 'passport' | 'iqama' | 'national_id' | 'warranty'
  | 'subscription' | 'contract' | 'rent' | 'school' | 'other';
export interface Renewal {
  id: string;
  household_id: string;
  title: string;
  kind: RenewalKind;
  subject: string | null;
  due_date: ISODate;
  period_months: number | null;
  amount: Halalas | null;
  notes: string | null;
  source: 'manual' | 'ai' | 'sms' | 'notice';
  expense_id: string | null;
  status: 'active' | 'done';
  created_by: string | null;
  created_at: string;
}
export interface RenewalDraft {
  kind: RenewalKind;
  title: string;
  subject?: string | null;
  due_date?: string | null;
  period_months?: number | null;
  amount_sar?: number | null;
  confidence?: number;
}
