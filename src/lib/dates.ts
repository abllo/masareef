import type { ISODate, MonthKey } from './types';

export const TIME_ZONE = 'Asia/Riyadh';
// مهم: ar-SA يستخدم التقويم الهجري افتراضياً، لذلك نحدد الميلادي صراحة.
const LOCALE = 'ar-SA-u-ca-gregory-nu-latn';

const isoFmt = new Intl.DateTimeFormat('en-CA', {
  timeZone: TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit',
});

/** تاريخ اليوم بتوقيت الرياض */
export const todayISO = (now: Date = new Date()): ISODate => isoFmt.format(now);

export const monthOf = (date: ISODate): MonthKey => `${date.slice(0, 7)}-01`;

export function addMonths(month: MonthKey, n: number): MonthKey {
  const y = Number(month.slice(0, 4));
  const m = Number(month.slice(5, 7));
  const idx = y * 12 + (m - 1) + n;
  const ny = Math.floor(idx / 12);
  const nm = (idx % 12) + 1;
  return `${ny}-${String(nm).padStart(2, '0')}-01`;
}

export function addDays(date: ISODate, n: number): ISODate {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function daysInMonth(month: MonthKey): number {
  const y = Number(month.slice(0, 4));
  const m = Number(month.slice(5, 7));
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

export const monthEnd = (month: MonthKey): ISODate =>
  `${month.slice(0, 8)}${String(daysInMonth(month)).padStart(2, '0')}`;

/** آخر `count` أشهر تنتهي بالشهر المعطى، من الأقدم إلى الأحدث */
export const lastMonths = (current: MonthKey, count: number): MonthKey[] =>
  Array.from({ length: count }, (_, i) => addMonths(current, i - count + 1));

const utc = (d: string) => new Date(`${d}T00:00:00Z`);
const monthLong = new Intl.DateTimeFormat(LOCALE, { month: 'long', year: 'numeric', timeZone: 'UTC' });
const monthShort = new Intl.DateTimeFormat(LOCALE, { month: 'short', timeZone: 'UTC' });
const dayLong = new Intl.DateTimeFormat(LOCALE, { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' });
const dayShort = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short', timeZone: 'UTC' });

export const formatMonth = (m: MonthKey) => monthLong.format(utc(m));
export const formatMonthShort = (m: MonthKey) => monthShort.format(utc(m));
export const formatDayShort = (d: ISODate) => dayShort.format(utc(d));

export function formatDayLabel(date: ISODate, today: ISODate = todayISO()): string {
  if (date === today) return 'اليوم';
  if (date === addDays(today, -1)) return 'أمس';
  return dayLong.format(utc(date));
}
