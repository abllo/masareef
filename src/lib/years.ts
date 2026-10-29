import type { Halalas, ISODate, YearData } from './types';

const MONTHS = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
export const monthName = (m: number) => MONTHS[m - 1] ?? '';
export const monthShortName = (m: number) => MONTHS[m - 1] ?? '';

const firstMonth = (y: YearData) => {
  const i = y.months.findIndex((m) => m.count > 0);
  return i < 0 ? null : i + 1;
};

const sumMonths = (values: readonly number[], from: number, to: number) =>
  values.slice(from - 1, to).reduce((a, b) => a + (b ?? 0), 0);

export interface YearComparison {
  from: number;
  to: number;
  current: Halalas;
  previous: Halalas;
  ratio: number | null;
  /** المقارنة على السنة كاملة */
  full: boolean;
}

/**
 * مقارنة عادلة بين سنتين: نفس الأشهر المكتملة فقط.
 * السنة الحالية تُقارن بأشهرها المكتملة، وتبدأ المقارنة من أول شهر فيه بيانات في السنتين
 * (حتى لا تُقارن سنة كاملة بسنة بدأ فيها استخدام التطبيق في أكتوبر مثلاً).
 */
export function compareYears(cur: YearData, prev: YearData | undefined, today: ISODate): YearComparison | null {
  if (!prev) return null;
  const thisYear = Number(today.slice(0, 4));
  const to = cur.year === thisYear ? Number(today.slice(5, 7)) - 1 : cur.year < thisYear ? 12 : 0;
  const a = firstMonth(cur);
  const b = firstMonth(prev);
  if (a === null || b === null) return null;
  const from = Math.max(a, b);
  if (to < from) return null;
  const current = sumMonths(cur.months.map((m) => m.total), from, to);
  const previous = sumMonths(prev.months.map((m) => m.total), from, to);
  return { from, to, current, previous, ratio: previous > 0 ? (current - previous) / previous : null, full: from === 1 && to === 12 };
}

export const periodLabel = (c: YearComparison) =>
  c.full ? 'السنة كاملة' : c.from === c.to ? monthName(c.from) : `${monthName(c.from)}–${monthName(c.to)}`;

/** متوسط الشهر = إجمالي السنة ÷ الأشهر اللي فيها مصاريف */
export function monthlyAverage(y: YearData): Halalas {
  const n = y.months.filter((m) => m.count > 0).length;
  return n ? Math.round(y.total / n) : 0;
}

export interface CategoryChange { key: string; name: string; icon: string; color: string; total: Halalas; ratio: number | null }

/** تصنيفات السنة مع تغيّرها عن السنة السابقة لنفس الأشهر */
export function categoryChanges(cur: YearData, prev: YearData | undefined, cmp: YearComparison | null): CategoryChange[] {
  return cur.categories.map((c) => {
    const p = prev?.categories.find((x) => (c.id && x.id === c.id) || x.name === c.name);
    let ratio: number | null = null;
    if (cmp && p) {
      const now = sumMonths(c.months, cmp.from, cmp.to);
      const before = sumMonths(p.months, cmp.from, cmp.to);
      ratio = before > 0 ? (now - before) / before : null;
    }
    return { key: c.id ?? c.name, name: c.name, icon: c.icon, color: c.color, total: c.total, ratio };
  });
}

/** لون ثابت لكل سنة (يتبع السنة نفسها لا ترتيبها) */
export const yearColor = (year: number) => `var(--color-y${(((year % 3) + 3) % 3) + 1})`;
