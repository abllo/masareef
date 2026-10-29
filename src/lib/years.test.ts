import { describe, expect, it } from 'vitest';
import { categoryChanges, compareYears, monthlyAverage, periodLabel } from './years';
import type { YearData } from './types';

const year = (y: number, monthly: number[], cats: { id: string; months: number[] }[] = []): YearData => ({
  year: y,
  total: monthly.reduce((a, b) => a + b, 0),
  count: monthly.filter((v) => v > 0).length,
  first_date: null, last_date: null,
  months: monthly.map((t, i) => ({ month: i + 1, total: t, count: t > 0 ? 1 : 0 })),
  categories: cats.map((c) => ({ id: c.id, name: c.id, icon: 'circle', color: '#000', months: c.months, total: c.months.reduce((a, b) => a + b, 0), count: 1 })),
  merchants: [], banks: [], cards: [], channels: [], members: [], foreign: [], recurring: [], largest: [], from_sms: 0,
});

describe('compareYears', () => {
  const full = Array(12).fill(1000);
  it('compares whole past years', () => {
    const c = compareYears(year(2025, full.map((v) => v * 2)), year(2024, full), '2026-10-29')!;
    expect(c).toMatchObject({ from: 1, to: 12, full: true, ratio: 1 });
    expect(periodLabel(c)).toBe('السنة كاملة');
  });
  it('uses only completed months of the current year', () => {
    const c = compareYears(year(2026, [...Array(10).fill(1500), 0, 0]), year(2025, full), '2026-10-29')!;
    expect(c).toMatchObject({ from: 1, to: 9, current: 13500, previous: 9000, full: false });
    expect(periodLabel(c)).toBe('يناير–سبتمبر');
  });
  it('starts from the first month both years have data', () => {
    const started = [...Array(9).fill(0), 1000, 1000, 1000];
    const c = compareYears(year(2026, full), year(2025, started), '2027-03-01')!;
    expect(c).toMatchObject({ from: 10, to: 12, current: 3000, previous: 3000, ratio: 0 });
  });
  it('returns null without a previous year or completed months', () => {
    expect(compareYears(year(2026, full), undefined, '2026-10-29')).toBeNull();
    expect(compareYears(year(2026, full), year(2025, full), '2026-01-15')).toBeNull();
  });
});

describe('year helpers', () => {
  it('averages over months with spending', () => {
    expect(monthlyAverage(year(2025, [...Array(9).fill(0), 3000, 3000, 6000]))).toBe(4000);
  });
  it('computes category change on the same months', () => {
    const cur = year(2026, Array(12).fill(0), [{ id: 'a', months: [200, 200, ...Array(10).fill(0)] }]);
    const prev = year(2025, Array(12).fill(0), [{ id: 'a', months: [100, 100, ...Array(10).fill(500)] }]);
    const cmp = { from: 1, to: 2, current: 0, previous: 0, ratio: 0, full: false };
    expect(categoryChanges(cur, prev, cmp)[0]!.ratio).toBe(1);
  });
});
