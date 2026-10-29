import { describe, expect, it } from 'vitest';
import { byWeekday, detectRecurring, firstDaysShare, habits, unusualSpending } from './behavior';
import type { Category, Expense } from './types';

const exp = (id: string, cat: string, amount: number, date: string, key: string | null, extra: Partial<Expense> = {}): Expense => ({
  id, household_id: 'h', category_id: cat, amount, expense_date: date, description: key ? `📩 ${key}` : null, receipt_path: null,
  recurring_id: null, recurring_period: null, created_by: 'u', created_at: '', updated_at: '', merchant_key: key,
  sms_meta: key ? { merchant: key } : null, ...extra,
});
const cat = (id: string, name: string): Category => ({ id, household_id: 'h', name, icon: 'circle', color: '#000', sort_order: 0, is_archived: false });

describe('behavior', () => {
  it('detects monthly payments with a stable amount', () => {
    const list = [
      exp('1', 'o', 9000, '2026-07-03', 'yaqoot'), exp('2', 'o', 9000, '2026-07-31', 'yaqoot'), exp('3', 'o', 9000, '2026-08-28', 'yaqoot'),
      exp('4', 'o', 9000, '2026-09-25', 'yaqoot'),
      exp('5', 'b', 10000, '2026-07-08', 'mobily'), exp('6', 'b', 20000, '2026-08-21', 'mobily'), exp('7', 'b', 10000, '2026-09-08', 'mobily'),
      ...['07', '08', '09'].flatMap((m, i) => [1, 2, 3].map((d) => exp(`h${i}${d}`, 'd', 4000, `2026-${m}-1${d}`, 'hungerstation'))),
    ];
    expect(detectRecurring(list)).toMatchObject([{ key: 'yaqoot', label: 'yaqoot', months: 3, typical: 9000, lastDate: '2026-09-25' }]);
  });
  it('splits spending by weekday and the first 10 days', () => {
    const list = [exp('1', 'a', 1000, '2026-10-29', null), exp('2', 'a', 3000, '2026-10-01', null), exp('3', 'a', 1000, '2026-10-25', null)];
    const w = byWeekday(list);
    expect(w[4]).toEqual({ day: 4, total: 4000, count: 2 }); // الخميس (1 و 29 أكتوبر)
    expect(w[0]).toEqual({ day: 0, total: 1000, count: 1 }); // الأحد
    expect(firstDaysShare(list)).toBe(0.6);
  });
  it('finds habits and unusual spending', () => {
    const cats = [cat('d', 'التوصيل')];
    const month = [1, 2, 3, 4].map((d) => exp(`m${d}`, 'd', 4000, `2026-10-0${d}`, 'hs'));
    const prev = [exp('p1', 'd', 4000, '2026-09-01', 'hs')];
    expect(habits(month, prev, cats, 14)[0]).toMatchObject({ count: 4, perWeek: 2, avgTicket: 4000, prevCount: 1 });
    const history = [3000, 3200, 2800].map((a, i) => exp(`x${i}`, 'd', a, `2026-09-0${i + 1}`, 'noon'));
    const big = exp('big', 'd', 12000, '2026-10-05', 'noon');
    expect(unusualSpending([big, exp('ok', 'd', 3100, '2026-10-06', 'noon')], history)).toMatchObject([{ usual: 3000, ratio: 4 }]);
  });
});
