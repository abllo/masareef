import { percentages, sumHalalas } from './money';
import { daysInMonth, monthOf } from './dates';
import type { Category, Expense, Halalas, ISODate, MonthKey, MonthlyTotal } from './types';

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

/** نسبة التغير بين شهرين؛ null إذا لم يكن هناك صرف في الشهر السابق */
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
