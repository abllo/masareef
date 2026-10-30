import type { ISODate, Renewal, RenewalKind } from './types';

export const KIND_LABELS: Record<RenewalKind, string> = {
  insurance: 'تأمين', istimara: 'استمارة', license: 'رخصة قيادة', passport: 'جواز سفر', iqama: 'إقامة', national_id: 'هوية',
  warranty: 'ضمان', subscription: 'اشتراك', contract: 'عقد', rent: 'إيجار', school: 'رسوم مدرسية', bill: 'فاتورة', other: 'أخرى',
};

export const KIND_EMOJI: Record<RenewalKind, string> = {
  insurance: '🛡️', istimara: '🚗', license: '🪪', passport: '🛂', iqama: '🪪', national_id: '🪪',
  warranty: '🔧', subscription: '🔁', contract: '📝', rent: '🏠', school: '🎓', bill: '🧾', other: '📄',
};

export const PERIOD_OPTIONS = [
  { value: '', label: 'ما يتكرر' }, { value: '1', label: 'كل شهر' }, { value: '3', label: 'كل 3 أشهر' },
  { value: '6', label: 'كل 6 أشهر' }, { value: '12', label: 'كل سنة' }, { value: '24', label: 'كل سنتين' },
  { value: '36', label: 'كل 3 سنوات' }, { value: '60', label: 'كل 5 سنوات' }, { value: '120', label: 'كل 10 سنوات' },
];

export function daysUntil(due: ISODate, today: ISODate): number {
  return Math.round((Date.parse(`${due}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / 86_400_000);
}

export function countdown(days: number): string {
  if (days < -1) return `انتهى من ${-days} يوم`;
  if (days === -1) return 'انتهى أمس';
  if (days === 0) return 'اليوم';
  if (days === 1) return 'بكرة';
  if (days === 2) return 'بعد يومين';
  if (days <= 10) return `بعد ${days} أيام`;
  if (days < 60) return `بعد ${days} يوم`;
  const months = Math.round(days / 30);
  if (months < 24) return months === 2 ? 'بعد شهرين' : months <= 10 ? `بعد ${months} أشهر` : `بعد ${months} شهر`;
  return `بعد ${Math.round(days / 365)} سنوات`;
}

export type Urgency = 'overdue' | 'urgent' | 'soon' | 'later';
export function urgency(days: number): Urgency {
  if (days < 0) return 'overdue';
  if (days <= 3) return 'urgent';
  if (days <= 30) return 'soon';
  return 'later';
}

export function addMonthsISO(date: ISODate, months: number): ISODate {
  const d = new Date(`${date}T00:00:00Z`);
  const day = d.getUTCDate();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() + months);
  const last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
  d.setUTCDate(Math.min(day, last));
  return d.toISOString().slice(0, 10);
}

/** ترتيب: المنتهية ثم الأقرب */
export const sortRenewals = (list: readonly Renewal[]) => [...list].sort((a, b) => a.due_date.localeCompare(b.due_date));
