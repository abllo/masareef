import { describe, expect, it } from 'vitest';
import { budgetStatus, byCategory, changeRatio, filterExpenses, groupByDay, monthlySeries } from './stats';
import { recurringForMonth } from './recurring';
import type { Category, Expense, Recurring } from './types';

const cat = (id: string, name: string): Category => ({
  id, household_id: 'h', name, icon: 'circle', color: '#000000', sort_order: 0, is_archived: false,
});
const exp = (id: string, category_id: string, amount: number, expense_date: string, extra: Partial<Expense> = {}): Expense => ({
  id, household_id: 'h', category_id, amount, expense_date, description: null, receipt_path: null,
  recurring_id: null, recurring_period: null, created_by: 'u1', created_at: '', updated_at: '', ...extra,
});

const cats = [cat('a', 'بقالة'), cat('b', 'مطاعم')];
const list = [
  exp('1', 'a', 10000, '2026-10-20', { description: 'الدانوب' }),
  exp('2', 'b', 5000, '2026-10-20', { created_by: 'u2' }),
  exp('3', 'a', 2500, '2026-10-18'),
];

describe('byCategory', () => {
  it('sums per category and sorts descending', () => {
    const s = byCategory(list, cats);
    expect(s.map((x) => [x.categoryId, x.total, x.count])).toEqual([['a', 12500, 2], ['b', 5000, 1]]);
    expect(s.reduce((a, x) => a + x.percent, 0)).toBe(100);
  });
});

describe('budgetStatus', () => {
  it('computes remaining and daily allowance for the current month', () => {
    const b = budgetStatus(600000, 1000000, '2026-10-01', '2026-10-25');
    expect(b.remaining).toBe(400000);
    expect(b.level).toBe('ok');
    expect(b.dailyAllowance).toBe(Math.floor(400000 / 7)); // 25..31 = 7 أيام
  });
  it('flags overspending', () => {
    expect(budgetStatus(1100000, 1000000, '2026-09-01', '2026-10-25').level).toBe('over');
    expect(budgetStatus(900000, 1000000, '2026-09-01', '2026-10-25').dailyAllowance).toBeNull();
  });
  it('handles no budget', () => {
    expect(budgetStatus(5, null, '2026-10-01', '2026-10-25').level).toBe('none');
  });
});

describe('series, grouping and filters', () => {
  it('fills empty months with zero', () => {
    const s = monthlySeries([{ month: '2026-09-01', category_id: 'a', total: 100, tx_count: 1 }], ['2026-08-01', '2026-09-01']);
    expect(s).toEqual([{ month: '2026-08-01', total: 0 }, { month: '2026-09-01', total: 100 }]);
    expect(changeRatio(150, 100)).toBe(0.5);
    expect(changeRatio(150, 0)).toBeNull();
  });
  it('groups by day with daily totals', () => {
    const g = groupByDay(list);
    expect(g.map((d) => [d.date, d.total])).toEqual([['2026-10-20', 15000], ['2026-10-18', 2500]]);
  });
  it('filters by text, category and member', () => {
    expect(filterExpenses(list, { query: 'الدانوب' }, cats).map((e) => e.id)).toEqual(['1']);
    expect(filterExpenses(list, { query: 'مطاعم' }, cats).map((e) => e.id)).toEqual(['2']);
    expect(filterExpenses(list, { categoryId: 'a', memberId: 'u1' }, cats)).toHaveLength(2);
    expect(filterExpenses(list, { memberId: 'u2' }, cats)).toHaveLength(1);
  });
});

describe('recurringForMonth', () => {
  const r = (id: string, day: number, extra: Partial<Recurring> = {}): Recurring => ({
    id, household_id: 'h', category_id: 'a', name: id, amount: 150000, day_of_month: day,
    start_month: '2026-01-01', is_active: true, ...extra,
  });
  it('marks paid, due and overdue, clamping day 31', () => {
    const rows = recurringForMonth(
      [r('maid', 1), r('driver', 31), r('net', 20), r('old', 5, { is_active: false })],
      [exp('p', 'a', 150000, '2026-02-02', { recurring_id: 'maid', recurring_period: '2026-02-01' })],
      '2026-02-01',
      '2026-02-25',
    );
    expect(rows.map((x) => [x.item.id, x.dueDate, x.status])).toEqual([
      ['maid', '2026-02-01', 'paid'],
      ['net', '2026-02-20', 'overdue'],
      ['driver', '2026-02-28', 'due'],
    ]);
  });
  it('hides templates that start later', () => {
    expect(recurringForMonth([r('x', 1, { start_month: '2026-05-01' })], [], '2026-04-01', '2026-04-10')).toHaveLength(0);
  });
});
