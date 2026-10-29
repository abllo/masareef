import { daysInMonth } from './dates';
import type { Expense, ISODate, MonthKey, Recurring } from './types';

export interface RecurringRow {
  item: Recurring;
  dueDate: ISODate;
  payment: Expense | undefined;
  status: 'paid' | 'due' | 'overdue';
}

export function dueDateFor(month: MonthKey, dayOfMonth: number): ISODate {
  const day = Math.min(dayOfMonth, daysInMonth(month));
  return `${month.slice(0, 8)}${String(day).padStart(2, '0')}`;
}

/**
 * حالة المصاريف المتكررة لشهر معيّن.
 * `payments` هي العمليات المرتبطة بقوالب متكررة لنفس الشهر (recurring_period = month).
 * القوالب الموقوفة تظهر فقط إذا دُفعت في ذلك الشهر.
 */
export function recurringForMonth(
  items: readonly Recurring[],
  payments: readonly Expense[],
  month: MonthKey,
  today: ISODate,
): RecurringRow[] {
  const paidBy = new Map(
    payments.filter((p) => p.recurring_period === month && p.recurring_id).map((p) => [p.recurring_id!, p]),
  );
  return items
    .filter((r) => r.start_month <= month && (r.is_active || paidBy.has(r.id)))
    .map((item) => {
      const dueDate = dueDateFor(month, item.day_of_month);
      const payment = paidBy.get(item.id);
      const status: RecurringRow['status'] = payment ? 'paid' : today > dueDate ? 'overdue' : 'due';
      return { item, dueDate, payment, status };
    })
    .sort((a, b) => a.dueDate.localeCompare(b.dueDate) || a.item.name.localeCompare(b.item.name, 'ar'));
}
