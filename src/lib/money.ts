import type { Halalas } from './types';

const ARABIC_INDIC = '٠١٢٣٤٥٦٧٨٩';
const PERSIAN = '۰۱۲۳۴۵۶۷۸۹';

/** يحوّل الأرقام العربية والفارسية إلى لاتينية ويوحّد الفاصلة العشرية. */
export function normalizeNumeric(input: string): string {
  return input
    .replace(/[٠-٩]/g, (d) => String(ARABIC_INDIC.indexOf(d)))
    .replace(/[۰-۹]/g, (d) => String(PERSIAN.indexOf(d)))
    .replace(/٫/g, '.')
    .replace(/[,،٬\s]/g, '');
}

/**
 * يحوّل نص المبلغ إلى هللات دون المرور بعمليات الكسور العشرية.
 * يعيد null إذا كان النص غير صالح أو المبلغ صفراً.
 */
export function parseAmount(input: string): Halalas | null {
  const s = normalizeNumeric(input);
  const m = /^(\d{1,9})(?:\.(\d{0,2}))?$/.exec(s);
  if (!m) return null;
  const riyals = Number(m[1]);
  const fraction = Number((m[2] ?? '').padEnd(2, '0'));
  const total = riyals * 100 + fraction;
  return total > 0 ? total : null;
}

/** هللات → نص قابل للتعديل في حقل الإدخال (مثل "12.5") */
export function toInputValue(h: Halalas): string {
  const riyals = Math.floor(h / 100);
  const rest = h % 100;
  if (rest === 0) return String(riyals);
  return `${riyals}.${String(rest).padStart(2, '0')}`.replace(/0$/, '');
}

const currencyFmt = new Intl.NumberFormat('ar-SA-u-nu-latn', {
  style: 'currency',
  currency: 'SAR',
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
});
const numberFmt = new Intl.NumberFormat('ar-SA-u-nu-latn', { maximumFractionDigits: 2 });

export const formatSAR = (h: Halalas): string => currencyFmt.format(h / 100);
export const formatAmount = (h: Halalas): string => numberFmt.format(h / 100);
/** للتصدير: رقم بالريال بدقة هللتين */
export const toRiyals = (h: Halalas): number => Math.round(h) / 100;

export const sumHalalas = (values: readonly Halalas[]): Halalas =>
  values.reduce((acc, v) => acc + v, 0);

/**
 * نسب مئوية صحيحة مجموعها 100 بالضبط (طريقة الباقي الأكبر)
 * حتى لا يظهر مجموع النسب 99% أو 101% بسبب التقريب.
 */
export function percentages(values: readonly number[]): number[] {
  const total = values.reduce((a, b) => a + b, 0);
  if (total <= 0) return values.map(() => 0);
  const raw = values.map((v) => (v / total) * 100);
  const floors = raw.map(Math.floor);
  let remaining = 100 - floors.reduce((a, b) => a + b, 0);
  const order = raw
    .map((r, i) => ({ i, frac: r - Math.floor(r) }))
    .sort((a, b) => b.frac - a.frac);
  for (const { i } of order) {
    if (remaining <= 0) break;
    floors[i] = (floors[i] ?? 0) + 1;
    remaining--;
  }
  return floors;
}
