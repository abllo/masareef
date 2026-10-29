import { describe, expect, it } from 'vitest';
import { addDays, addMonths, daysInMonth, formatDayLabel, lastMonths, monthEnd, todayISO } from './dates';

describe('dates', () => {
  it('adds months across years', () => {
    expect(addMonths('2026-01-01', -1)).toBe('2025-12-01');
    expect(addMonths('2026-11-01', 3)).toBe('2027-02-01');
  });
  it('knows month lengths including leap years', () => {
    expect(daysInMonth('2028-02-01')).toBe(29);
    expect(daysInMonth('2026-02-01')).toBe(28);
    expect(monthEnd('2026-04-01')).toBe('2026-04-30');
  });
  it('lists last months oldest first', () => {
    expect(lastMonths('2026-02-01', 3)).toEqual(['2025-12-01', '2026-01-01', '2026-02-01']);
  });
  it('uses Riyadh time zone for today', () => {
    // 22:30 UTC = 01:30 بتوقيت الرياض في اليوم التالي
    expect(todayISO(new Date('2026-10-25T22:30:00Z'))).toBe('2026-10-26');
  });
  it('labels today and yesterday', () => {
    expect(formatDayLabel('2026-10-25', '2026-10-25')).toBe('اليوم');
    expect(formatDayLabel(addDays('2026-10-25', -1), '2026-10-25')).toBe('أمس');
  });
});
