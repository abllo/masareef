import { describe, expect, it } from 'vitest';
import { detectRecurring } from './behavior';
import { subscriptionAudit } from './subscriptions';
import type { Expense, Recurring, Renewal } from './types';

const exp = (id: string, key: string, amount: number, date: string): Expense => ({
  id, household_id: 'h', category_id: 'c', amount, expense_date: date, description: `📩 ${key}`, receipt_path: null,
  recurring_id: null, recurring_period: null, created_by: 'u', created_at: date, updated_at: date, merchant_key: key, sms_meta: null,
});

describe('subscriptionAudit', () => {
  const list = [
    exp('1', 'netflix', 4900, '2026-07-05'), exp('2', 'netflix', 4900, '2026-08-05'), exp('3', 'netflix', 5400, '2026-09-05'),
    exp('4', 'shahid', 3000, '2026-07-10'), exp('5', 'shahid', 3000, '2026-08-10'), exp('6', 'shahid', 3000, '2026-09-10'),
    exp('7', 'shahid', -3000, '2026-09-12'),
  ];
  const fixed: Recurring[] = [{ id: 'r1', household_id: 'h', category_id: 'c', name: 'Spotify', amount: 2199, day_of_month: 1, start_month: '2026-01-01', is_active: true },
    { id: 'r2', household_id: 'h', category_id: 'c', name: 'الإيجار', amount: 400000, day_of_month: 1, start_month: '2026-01-01', is_active: true }];
  const renewals = [{ id: 'n1', kind: 'subscription', status: 'active', amount: 12000, period_months: 12, title: 'iCloud', due_date: '2027-01-01' }] as Renewal[];

  it('collects detected, fixed subscriptions and annual renewals', () => {
    const a = subscriptionAudit(detectRecurring(list), list, fixed, renewals);
    expect(a.items.map((i) => i.name)).toEqual(['netflix', 'shahid', 'Spotify', 'iCloud']);
    expect(a.items.find((i) => i.name === 'netflix')?.increased).toBe(true);
    expect(a.items.find((i) => i.name === 'shahid')?.increased).toBe(false);
    expect(a.items.find((i) => i.name === 'iCloud')?.monthly).toBe(1000);
    expect(a.duplicates).toEqual([{ label: 'مشاهدة', count: 2 }]);
    expect(a.yearly).toBe(a.items.reduce((s, i) => s + i.yearly, 0));
  });
});
