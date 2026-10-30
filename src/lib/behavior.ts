import { merchantLabel } from './stats';
import type { Category, Expense, Halalas, ISODate } from './types';

/** الاسترداد والسحب النقدي لا يدخلون في قراءة السلوك */
const spend = (e: Expense) => e.amount > 0 && e.kind !== 'cash';
export const keyOf = (e: Expense) => e.merchant_key ?? (e.description ? e.description.replace(/^[📩🧾]\s*/u, '').trim().toLowerCase() : null);

function median(values: readonly number[]): number {
  const s = [...values].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m]! : Math.round((s[m - 1]! + s[m]!) / 2);
}

export interface RecurringGuess { key: string; label: string; months: number; typical: Halalas; lastDate: ISODate; categoryId: string }

/**
 * مدفوعات تتكرر شهرياً بمبلغ ثابت تقريباً (اشتراك، نادي، خدمة…) وما هي مسجلة كمصروف ثابت.
 * الشرط: نفس المتجر في 3 أشهر مختلفة على الأقل، مرة أو مرتين بالشهر، والمبالغ ضمن ±15% من الوسيط.
 */
export function detectRecurring(expenses: readonly Expense[]): RecurringGuess[] {
  const groups = new Map<string, Expense[]>();
  for (const e of expenses) {
    if (e.recurring_id || e.trip_id || !spend(e)) continue;
    const k = keyOf(e);
    if (!k) continue;
    groups.set(k, [...(groups.get(k) ?? []), e]);
  }
  const out: RecurringGuess[] = [];
  for (const [k, list] of groups) {
    const months = new Set(list.map((e) => e.expense_date.slice(0, 7)));
    if (months.size < 3 || list.length > months.size * 2) continue;
    const typical = median(list.map((e) => e.amount));
    if (!list.every((e) => Math.abs(e.amount - typical) <= typical * 0.15)) continue;
    const last = list.reduce((a, b) => (a.expense_date > b.expense_date ? a : b));
    out.push({ key: k, label: merchantLabel(last) ?? k, months: months.size, typical, lastDate: last.expense_date, categoryId: last.category_id });
  }
  return out.sort((a, b) => b.typical - a.typical);
}

export interface Habit { category: Category; count: number; total: Halalas; perWeek: number; avgTicket: Halalas; prevCount: number }

/** أكثر 3 تصنيفات تكراراً هذا الشهر (العادات) مع المقارنة بالشهر السابق */
export function habits(month: readonly Expense[], previous: readonly Expense[], categories: readonly Category[], days: number): Habit[] {
  const count = (list: readonly Expense[]) => {
    const m = new Map<string, { n: number; total: number }>();
    for (const e of list) {
      if (e.recurring_id || !spend(e)) continue;
      const c = m.get(e.category_id) ?? { n: 0, total: 0 };
      c.n += 1;
      c.total += e.amount;
      m.set(e.category_id, c);
    }
    return m;
  };
  const now = count(month);
  const before = count(previous);
  const byId = new Map(categories.map((c) => [c.id, c]));
  return [...now.entries()]
    .filter(([id, v]) => v.n >= 3 && byId.has(id))
    .sort((a, b) => b[1].n - a[1].n)
    .slice(0, 3)
    .map(([id, v]) => ({
      category: byId.get(id)!, count: v.n, total: v.total, avgTicket: Math.round(v.total / v.n),
      perWeek: Math.round((v.n / Math.max(days, 1)) * 7 * 10) / 10, prevCount: before.get(id)?.n ?? 0,
    }));
}

export const WEEKDAYS = ['الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت'];

/** الصرف حسب يوم الأسبوع (الأحد = 0) */
export function byWeekday(list: readonly Expense[]): { day: number; total: Halalas; count: number }[] {
  const rows = WEEKDAYS.map((_, day) => ({ day, total: 0, count: 0 }));
  for (const e of list) {
    if (e.recurring_id || !spend(e)) continue;
    const d = new Date(`${e.expense_date}T00:00:00Z`).getUTCDay();
    rows[d]!.total += e.amount;
    rows[d]!.count += 1;
  }
  return rows;
}

/** نسبة صرف أول 10 أيام من الشهر (بعد الراتب غالباً) */
export function firstDaysShare(list: readonly Expense[]): number | null {
  const items = list.filter((e) => !e.recurring_id && spend(e));
  const total = items.reduce((a, e) => a + e.amount, 0);
  if (!total) return null;
  const early = items.filter((e) => Number(e.expense_date.slice(8, 10)) <= 10).reduce((a, e) => a + e.amount, 0);
  return early / total;
}

export interface Unusual { expense: Expense; usual: Halalas; ratio: number }

/** عمليات الشهر الأكبر بكثير من المعتاد عند نفس المتجر (history = ما قبل الشهر، 3 عمليات على الأقل) */
export function unusualSpending(month: readonly Expense[], history: readonly Expense[]): Unusual[] {
  const past = new Map<string, number[]>();
  for (const e of history) {
    if (!spend(e)) continue;
    const k = keyOf(e);
    if (k) past.set(k, [...(past.get(k) ?? []), e.amount]);
  }
  const out: Unusual[] = [];
  for (const e of month) {
    if (!spend(e)) continue;
    const k = keyOf(e);
    if (!k) continue;
    const prev = past.get(k) ?? [];
    if (prev.length < 3) continue;
    const usual = median(prev);
    if (usual > 0 && e.amount >= usual * 2.5 && e.amount - usual >= 5000) out.push({ expense: e, usual, ratio: e.amount / usual });
  }
  return out.sort((a, b) => b.ratio - a.ratio).slice(0, 5);
}
