import { keyOf, type RecurringGuess } from './behavior';
import type { Expense, Halalas, ISODate, Recurring, Renewal } from './types';

/** أنواع الاشتراكات (لكشف التكرار: أكثر من اشتراك من نفس النوع) */
const TYPES: { type: string; label: string; re: RegExp }[] = [
  { type: 'streaming', label: 'مشاهدة', re: /(netflix|نتفلكس|shahid|شاهد|\bosn\b|disney|starz|youtube|يوتيوب|apple ?tv|\btod\b|prime video|watch it)/i },
  { type: 'music', label: 'موسيقى', re: /(spotify|سبوتيفاي|anghami|أنغامي|انغامي|apple ?music|deezer)/i },
  { type: 'cloud', label: 'تخزين', re: /(icloud|google ?one|dropbox|onedrive)/i },
  { type: 'ai', label: 'ذكاء اصطناعي', re: /(chatgpt|openai|claude|anthropic|gemini|midjourney|copilot)/i },
  { type: 'delivery', label: 'عضويات توصيل', re: /(careem ?plus|jahez ?plus|hungerstation ?pro|noon ?one|amazon ?prime|keeta ?pass)/i },
];
const typeOf = (name: string) => TYPES.find((t) => t.re.test(name));

export interface SubItem {
  key: string;
  name: string;
  monthly: Halalas;
  yearly: Halalas;
  source: 'detected' | 'fixed' | 'renewal';
  categoryId?: string;
  lastDate?: ISODate;
  /** آخر مبلغ أعلى من المعتاد بـ 5% أو أكثر */
  increased?: boolean;
  type?: string;
  guess?: RecurringGuess;
}

export interface SubAudit { items: SubItem[]; monthly: Halalas; yearly: Halalas; duplicates: { label: string; count: number }[] }

/**
 * جرد الاشتراكات: المدفوعات المتكررة المكتشفة، والثابتة اللي تشبه اشتراكاً، والاشتراكات السنوية في التجديدات.
 * مرتبة بالتكلفة السنوية.
 */
export function subscriptionAudit(guesses: readonly RecurringGuess[], expenses: readonly Expense[],
  fixed: readonly Recurring[], renewals: readonly Renewal[]): SubAudit {
  const items: SubItem[] = [];
  for (const g of guesses) {
    const amounts = expenses.filter((e) => keyOf(e) === g.key && e.amount > 0)
      .sort((a, b) => a.expense_date.localeCompare(b.expense_date)).map((e) => e.amount);
    const last = amounts.at(-1) ?? g.typical;
    const before = amounts.slice(0, -1);
    const increased = before.length > 0 && last >= Math.max(...before) * 1.05;
    items.push({ key: `d:${g.key}`, name: g.label, monthly: g.typical, yearly: g.typical * 12, source: 'detected',
      categoryId: g.categoryId, lastDate: g.lastDate, increased, type: typeOf(g.label)?.type, guess: g });
  }
  const taken = new Set(items.map((i) => i.name.trim().toLowerCase()));
  for (const r of fixed) {
    if (!r.is_active || !typeOf(r.name) || taken.has(r.name.trim().toLowerCase())) continue;
    items.push({ key: `f:${r.id}`, name: r.name, monthly: r.amount, yearly: r.amount * 12, source: 'fixed',
      categoryId: r.category_id, type: typeOf(r.name)?.type });
  }
  for (const r of renewals) {
    if (r.kind !== 'subscription' || r.status !== 'active' || !r.amount) continue;
    const months = r.period_months || 12;
    items.push({ key: `r:${r.id}`, name: r.title, monthly: Math.round(r.amount / months), yearly: Math.round((r.amount * 12) / months),
      source: 'renewal', lastDate: r.due_date, type: typeOf(r.title)?.type });
  }
  items.sort((a, b) => b.yearly - a.yearly);
  const duplicates = TYPES.map((t) => ({ label: t.label, count: items.filter((i) => i.type === t.type).length }))
    .filter((d) => d.count > 1);
  return {
    items,
    monthly: items.reduce((a, i) => a + i.monthly, 0),
    yearly: items.reduce((a, i) => a + i.yearly, 0),
    duplicates,
  };
}
