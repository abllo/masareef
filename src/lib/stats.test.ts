import { describe, expect, it } from 'vitest';
import { budgetStatus, byCategory, byPaymentMethod, changeRatio, comparisonRange, filterExpenses, groupByDay, monthProjection, monthlySeries, topMerchants } from './stats';
import { recurringForMonth } from './recurring';
import type { Category, Expense, Recurring } from './types';

const cat = (id: string, name: string): Category => ({
  id, household_id: 'h', name, icon: 'circle', color: '#000000', sort_order: 0, is_archived: false,
});
const exp = (id: string, category_id: string, amount: number, expense_date: string, extra: Partial<Expense> = {}): Expense => ({
  id, household_id: 'h', category_id, amount, expense_date, description: null, receipt_path: null,
  recurring_id: null, recurring_period: null, created_by: 'u1', created_at: '', updated_at: '',
  merchant_key: null, sms_meta: null, ...extra,
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

describe('comparisonRange', () => {
  it('compares the current month with the same days of the previous month', () => {
    expect(comparisonRange('2026-10-01', '2026-10-05')).toEqual({ from: '2026-09-01', to: '2026-09-05', partial: true });
  });
  it('caps the cut-off day at the end of a shorter previous month', () => {
    expect(comparisonRange('2026-03-01', '2026-03-30')).toEqual({ from: '2026-02-01', to: '2026-02-28', partial: true });
  });
  it('uses the whole previous month for past months and on the last day', () => {
    expect(comparisonRange('2026-08-01', '2026-10-05')).toEqual({ from: '2026-07-01', to: '2026-07-31', partial: false });
    expect(comparisonRange('2026-10-01', '2026-10-31')).toEqual({ from: '2026-09-01', to: '2026-09-30', partial: false });
  });
  it('handles January', () => {
    expect(comparisonRange('2027-01-01', '2027-01-10')).toEqual({ from: '2026-12-01', to: '2026-12-10', partial: true });
  });
});

describe('insights', () => {
  const sms = (merchant: string, card: string, type: 'mada' | 'visa', kind: 'debit' | 'credit') =>
    ({ merchant_key: merchant.toLowerCase(), sms_meta: { merchant, card_last4: card, card_type: type, card_kind: kind, source: 'ai' as const } });
  const list = [
    exp('1', 'c1', 4500, '2026-10-01', { description: '📩 Starbucks', ...sms('Starbucks', '8812', 'visa', 'credit') }),
    exp('2', 'c1', 2500, '2026-10-02', { description: '📩 STARBUCKS', ...sms('Starbucks', '4321', 'mada', 'debit') }),
    exp('3', 'c2', 30000, '2026-10-03', { description: '📩 بنده', ...sms('بنده', '4321', 'mada', 'debit') }),
    exp('4', 'c2', 1000, '2026-10-03', { description: 'خبز' }),
    exp('5', 'c2', 500, '2026-10-03'),
  ];
  it('ranks merchants by total and groups the same merchant', () => {
    expect(topMerchants(list)).toEqual([
      { label: 'بنده', total: 30000, count: 1 },
      { label: 'Starbucks', total: 7000, count: 2 },
      { label: 'خبز', total: 1000, count: 1 },
    ]);
  });
  it('splits spending by payment method and card', () => {
    expect(byPaymentMethod(list).map((m) => [m.label, m.total])).toEqual([
      ['مدى •4321', 32500], ['فيزا ائتمانية •8812', 4500], ['إدخال يدوي', 1500],
    ]);
  });
  it('projects the month from the daily average', () => {
    expect(monthProjection(10000, '2026-10-01', '2026-10-10')).toBe(31000);
    expect(monthProjection(10000, '2026-10-01', '2026-10-02')).toBeNull();
    expect(monthProjection(10000, '2026-09-01', '2026-10-10')).toBeNull();
  });
});
