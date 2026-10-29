import { percentages, sumHalalas } from './money';
import { addMonths, daysInMonth, monthEnd, monthOf } from './dates';
import type { Card, Category, Expense, Halalas, ISODate, MonthKey, MonthlyTotal, SmsMeta } from './types';

export interface CategorySlice {
  categoryId: string;
  category: Category | undefined;
  total: Halalas;
  count: number;
  percent: number;
}

/** توزيع المصروفات على التصنيفات، مرتبة تنازلياً */
export function byCategory(expenses: readonly Expense[], categories: readonly Category[]): CategorySlice[] {
  const map = new Map<string, { total: number; count: number }>();
  for (const e of expenses) {
    const cur = map.get(e.category_id) ?? { total: 0, count: 0 };
    cur.total += e.amount;
    cur.count += 1;
    map.set(e.category_id, cur);
  }
  const catById = new Map(categories.map((c) => [c.id, c]));
  const rows = [...map.entries()]
    .map(([categoryId, v]) => ({ categoryId, category: catById.get(categoryId), ...v }))
    .sort((a, b) => b.total - a.total);
  const pct = percentages(rows.map((r) => r.total));
  return rows.map((r, i) => ({ ...r, percent: pct[i] ?? 0 }));
}

export type BudgetLevel = 'none' | 'ok' | 'warn' | 'over';

export interface BudgetStatus {
  budget: Halalas | null;
  spent: Halalas;
  remaining: Halalas | null;
  ratio: number; // 0..1+ نسبة المصروف من الميزانية
  level: BudgetLevel;
  /** المتاح يومياً لبقية الشهر (للشهر الحالي فقط) */
  dailyAllowance: Halalas | null;
}

export function budgetStatus(spent: Halalas, budget: Halalas | null, month: MonthKey, today: ISODate): BudgetStatus {
  if (!budget) return { budget: null, spent, remaining: null, ratio: 0, level: 'none', dailyAllowance: null };
  const remaining = budget - spent;
  const ratio = spent / budget;
  const level: BudgetLevel = ratio > 1 ? 'over' : ratio >= 0.85 ? 'warn' : 'ok';
  let dailyAllowance: Halalas | null = null;
  if (monthOf(today) === month && remaining > 0) {
    const daysLeft = daysInMonth(month) - Number(today.slice(8, 10)) + 1;
    dailyAllowance = Math.floor(remaining / daysLeft);
  }
  return { budget, spent, remaining, ratio, level, dailyAllowance };
}

/** سلسلة إجمالي كل شهر (تملأ الأشهر الفارغة بصفر) */
export function monthlySeries(rows: readonly MonthlyTotal[], months: readonly MonthKey[]) {
  const totals = new Map<MonthKey, number>();
  for (const r of rows) totals.set(r.month, (totals.get(r.month) ?? 0) + r.total);
  return months.map((month) => ({ month, total: totals.get(month) ?? 0 }));
}

/**
 * الفترة التي نقارن بها مصروف الشهر المعروض:
 * - الشهر الحالي (لم ينتهِ): الشهر السابق من أوله حتى نفس اليوم، حتى لا يبدو أول الشهر «أقل بكثير»
 * - شهر منتهٍ: الشهر السابق كاملاً
 */
export function comparisonRange(month: MonthKey, today: ISODate): { from: ISODate; to: ISODate; partial: boolean } {
  const prev = addMonths(month, -1);
  const day = Number(today.slice(8, 10));
  if (monthOf(today) !== month || day >= daysInMonth(month)) return { from: prev, to: monthEnd(prev), partial: false };
  const cutoff = Math.min(day, daysInMonth(prev));
  return { from: prev, to: `${prev.slice(0, 8)}${String(cutoff).padStart(2, '0')}`, partial: true };
}

/** نسبة التغير بين فترتين؛ null إذا لم يكن هناك صرف في الفترة السابقة */
export function changeRatio(current: Halalas, previous: Halalas): number | null {
  if (previous <= 0) return null;
  return (current - previous) / previous;
}

export interface DayGroup {
  date: ISODate;
  total: Halalas;
  items: Expense[];
}

/** تجميع العمليات حسب اليوم (يفترض أنها مرتبة تنازلياً بالتاريخ) */
export function groupByDay(expenses: readonly Expense[]): DayGroup[] {
  const groups: DayGroup[] = [];
  for (const e of expenses) {
    const last = groups[groups.length - 1];
    if (last && last.date === e.expense_date) last.items.push(e);
    else groups.push({ date: e.expense_date, total: 0, items: [e] });
  }
  for (const g of groups) g.total = sumHalalas(g.items.map((i) => i.amount));
  return groups;
}

export interface ExpenseFilter {
  query?: string;
  categoryId?: string | null;
  memberId?: string | null;
}

export function filterExpenses(
  expenses: readonly Expense[],
  filter: ExpenseFilter,
  categories: readonly Category[],
): Expense[] {
  const q = filter.query?.trim().toLowerCase();
  const catName = new Map(categories.map((c) => [c.id, c.name.toLowerCase()]));
  return expenses.filter((e) => {
    if (filter.categoryId && e.category_id !== filter.categoryId) return false;
    if (filter.memberId && e.created_by !== filter.memberId) return false;
    if (q) {
      const hay = `${e.description ?? ''} ${catName.get(e.category_id) ?? ''} ${e.amount / 100}`.toLowerCase();
      if (!hay.includes(q)) return false;
    }
    return true;
  });
}

// ---------- تحليلات ----------

/** اسم المتجر للعرض: ما قرأه التطبيق من رسالة البنك، وإلا الوصف */
export function merchantLabel(e: Pick<Expense, 'description' | 'sms_meta'>): string | null {
  const m = e.sms_meta?.merchant?.trim() || e.description?.replace(/^[📩🧾]\s*/u, '').trim();
  return m || null;
}

export interface MerchantTotal { label: string; total: Halalas; count: number }

/** أكثر المتاجر صرفاً (يجمع نفس المتجر بغض النظر عن حالة الأحرف) */
export function topMerchants(expenses: readonly Expense[], limit = 5): MerchantTotal[] {
  const map = new Map<string, MerchantTotal>();
  for (const e of expenses) {
    const label = merchantLabel(e);
    if (!label) continue;
    const key = e.merchant_key ?? label.toLowerCase();
    const cur = map.get(key) ?? { label, total: 0, count: 0 };
    cur.total += e.amount;
    cur.count += 1;
    map.set(key, cur);
  }
  return [...map.values()].sort((a, b) => b.total - a.total).slice(0, limit);
}

export const CARD_TYPE_LABELS: Record<string, string> = {
  mada: 'مدى', visa: 'فيزا', mastercard: 'ماستركارد', amex: 'أمريكان إكسبريس', other: 'بطاقة',
};
export const CHANNEL_LABELS: Record<string, string> = {
  apple_pay: 'Apple Pay', pos: 'نقاط البيع', online: 'شراء إلكتروني', bill_payment: 'سداد', other: 'أخرى',
};
/** القيم القديمة قبل التفريق بين البطاقة وطريقة الدفع */
export const PAYMENT_LABELS: Record<string, string> = {
  mada: 'مدى', credit_card: 'بطاقة ائتمانية', apple_pay: 'Apple Pay', online: 'شراء إلكتروني',
  bill_payment: 'سداد فواتير', other: 'أخرى',
};

export const BANK_LABELS: Record<string, string> = {
  alrajhi: 'الراجحي', alinma: 'الإنماء', snb: 'الأهلي', riyad: 'الرياض', sab: 'ساب', anb: 'العربي',
  albilad: 'البلاد', aljazira: 'الجزيرة', bsf: 'الفرنسي', saib: 'الاستثمار', gib: 'ميم (الخليج الدولي)',
  stcbank: 'STC Bank', barq: 'برق', urpay: 'urpay', d360: 'D360', vision: 'Vision Bank', other: 'بنك آخر',
};
export const bankLabel = (code?: string | null) => (code ? BANK_LABELS[code] ?? code : null);

/** وصف البطاقة: «الإنماء · مدى •4321» أو «الراجحي · فيزا ائتمانية •8812» (أو اسمها المختصر) */
export function cardLabel(meta: SmsMeta | null | undefined, cards?: ReadonlyMap<string, Card>): string | null {
  if (!meta) return null;
  const known = meta.card_last4 ? cards?.get(meta.card_last4) : undefined;
  const last4 = meta.card_last4 ? ` •${meta.card_last4}` : '';
  const nickname = known?.nickname || meta.card_nickname;
  if (nickname) return `${nickname}${last4}`;
  const bank = bankLabel(known?.bank ?? meta.bank);
  const type = known?.card_type ?? meta.card_type;
  const kind = known?.card_kind ?? meta.card_kind;
  const prefix = bank ? `${bank} · ` : '';
  if (type) {
    const credit = kind === 'credit' && type !== 'mada' ? ' ائتمانية' : '';
    return `${prefix}${CARD_TYPE_LABELS[type] ?? 'بطاقة'}${credit}${last4}`;
  }
  if (bank) return `${bank}${last4}`;
  if (meta.payment_method === 'mada') return `مدى${last4}`;
  if (meta.payment_method === 'credit_card') return `بطاقة ائتمانية${last4}`;
  return last4 ? `بطاقة${last4}` : null;
}

export function channelLabel(meta: SmsMeta | null | undefined): string | null {
  if (!meta) return null;
  if (meta.channel) return CHANNEL_LABELS[meta.channel] ?? null;
  if (meta.payment_method && ['apple_pay', 'online', 'bill_payment'].includes(meta.payment_method)) return PAYMENT_LABELS[meta.payment_method]!;
  return null;
}

export interface MethodTotal { key: string; label: string; total: Halalas; count: number }

/** وصف بطاقة العملية للتجميع والفلترة */
export const expenseCard = (e: Pick<Expense, 'sms_meta'>, cards?: ReadonlyMap<string, Card>) =>
  e.sms_meta ? (cardLabel(e.sms_meta, cards) ?? 'بطاقة غير معروفة') : 'إدخال يدوي';

/** بنك العملية للتجميع والفلترة */
export function expenseBank(e: Pick<Expense, 'sms_meta'>, cards?: ReadonlyMap<string, Card>): string {
  if (!e.sms_meta) return 'إدخال يدوي';
  const code = (e.sms_meta.card_last4 && cards?.get(e.sms_meta.card_last4)?.bank) || e.sms_meta.bank;
  return bankLabel(code) ?? 'بنك غير معروف';
}

function groupTotals(expenses: readonly Expense[], keyOf: (e: Expense) => string): MethodTotal[] {
  const map = new Map<string, MethodTotal>();
  for (const e of expenses) {
    const label = keyOf(e);
    const cur = map.get(label) ?? { key: label, label, total: 0, count: 0 };
    cur.total += e.amount;
    cur.count += 1;
    map.set(label, cur);
  }
  return [...map.values()].sort((a, b) => b.total - a.total);
}

/** الصرف حسب البنك */
export const byBank = (expenses: readonly Expense[], cards?: ReadonlyMap<string, Card>) =>
  groupTotals(expenses, (e) => expenseBank(e, cards));

/** الصرف حسب البطاقة (مدى / فيزا / …) — كلها مصروفات، لكن كل بطاقة مميزة */
export function byPaymentMethod(expenses: readonly Expense[], cards?: ReadonlyMap<string, Card>): MethodTotal[] {
  const map = new Map<string, MethodTotal>();
  for (const e of expenses) {
    const label = expenseCard(e, cards);
    const cur = map.get(label) ?? { key: label, label, total: 0, count: 0 };
    cur.total += e.amount;
    cur.count += 1;
    map.set(label, cur);
  }
  return [...map.values()].sort((a, b) => b.total - a.total);
}

/** توقع مصروف الشهر الحالي بمعدل الصرف اليومي حتى اليوم؛ null لغير الشهر الحالي أو أول يومين */
export function monthProjection(spent: Halalas, month: MonthKey, today: ISODate): Halalas | null {
  if (monthOf(today) !== month) return null;
  const day = Number(today.slice(8, 10));
  if (day < 3) return null;
  return Math.round((spent / day) * daysInMonth(month));
}

/** شرح تحويل العملة: «12.5 GBP × 4.99 + رسوم 2.5%» */
export function fxLabel(meta: SmsMeta | null | undefined): string | null {
  if (!meta?.original_currency || !meta.original_amount) return null;
  const base = `${meta.original_amount} ${meta.original_currency}`;
  if (!meta.fx_rate) return base;
  const src = meta.fx_source === 'peg' ? 'سعر الربط الثابت' : 'سعر صرف اليوم';
  const fee = meta.fx_fee_pct ? ` + رسوم ${meta.fx_fee_pct}%` : '';
  return `${base} × ${Number(meta.fx_rate).toFixed(4)} (${src})${fee}`;
}

// ---------- السفر ----------
/** يفصل مصاريف الرحلات عن مصاريف الشهر العادية */
export function splitTravel<T extends Pick<Expense, 'trip_id'>>(list: readonly T[]): { regular: T[]; travel: T[] } {
  const regular: T[] = [];
  const travel: T[] = [];
  for (const e of list) (e.trip_id ? travel : regular).push(e);
  return { regular, travel };
}

export interface CurrencyTotal { currency: string; original: number; total: Halalas; count: number }

/** المصروف حسب العملة الأصلية (الريال للعمليات المحلية) */
export function byCurrency(expenses: readonly Expense[]): CurrencyTotal[] {
  const map = new Map<string, CurrencyTotal>();
  for (const e of expenses) {
    const cur = e.sms_meta?.original_currency ?? 'SAR';
    const row = map.get(cur) ?? { currency: cur, original: 0, total: 0, count: 0 };
    row.original += cur === 'SAR' ? e.amount / 100 : Number(e.sms_meta?.original_amount ?? 0);
    row.total += e.amount;
    row.count += 1;
    map.set(cur, row);
  }
  return [...map.values()].sort((a, b) => b.total - a.total);
}

/** عدد أيام الرحلة (شاملة اليومين) */
export function tripDays(start: ISODate, end: ISODate): number {
  return Math.round((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / 86_400_000) + 1;
}
