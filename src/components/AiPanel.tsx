import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { toast } from 'sonner';
import {
  ArrowCounterClockwise, CaretLeft, ChatCircleText, CheckCircle, MagicWand, Sparkle, Trash, WarningCircle,
} from '@phosphor-icons/react';
import { useHousehold } from '../hooks/household';
import { CATEGORY_DEPENDENT, useAiStatus, useCategories, useCategoryAudit, useInvalidate, useRules } from '../hooks/queries';
import { applyCategoryPlan, deleteRule, previewSms, requestCategoryPlan, undoCategoryBatch } from '../lib/api';
import { formatDayShort } from '../lib/dates';
import { formatSAR } from '../lib/money';
import { cardLabel, channelLabel } from '../lib/stats';
import type { CategoryAudit, CategoryPlan, PlanOp, SmsParseResult } from '../lib/types';
import { Button, Card, cx, IconButton } from './ui';

const timeFmt = new Intl.DateTimeFormat('ar-SA-u-ca-gregory-nu-latn', {
  timeZone: 'Asia/Riyadh', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit',
});
const fmtTime = (iso: string) => timeFmt.format(new Date(iso));

export function opLabel(op: PlanOp): string {
  switch (op.op) {
    case 'merge': return `دمج «${op.from}» في «${op.into}»`;
    case 'move_merchant': return `نقل عمليات «${op.merchant}» إلى «${op.into}»`;
    case 'create': return `إنشاء تصنيف «${op.name}»`;
    case 'rename': return `تغيير اسم «${op.from}» إلى «${op.new_name}»`;
    case 'archive': return `أرشفة «${op.from}»`;
    case 'delete': return `حذف «${op.from}» (فارغ)`;
    default: return op.op;
  }
}

function auditLabel(a: CategoryAudit): string {
  const d = a.details as Record<string, string>;
  switch (a.op) {
    case 'merge': return `دمج «${d.from_name}» في «${d.into_name}»`;
    case 'move_merchant': return `نقل «${d.merchant}» إلى «${d.into_name}»`;
    case 'create': return `إنشاء «${d.name}»`;
    case 'rename': return `«${d.old_name}» ← «${d.new_name}»`;
    case 'archive': return `أرشفة «${d.name}»`;
    case 'delete': return 'حذف تصنيف فارغ';
    default: return a.op;
  }
}

export function AiPanel() {
  return (
    <Card className="space-y-5">
      <AiStatusHeader />
      <SmsTester />
      <CategoryOrganizer />
      <RulesList />
    </Card>
  );
}

function AiStatusHeader() {
  const { data: status, isPending } = useAiStatus();
  const struggling = status?.enabled && status.last_error_at
    && (!status.last_ok_at || status.last_error_at > status.last_ok_at);

  return (
    <div>
      <div className="flex items-center justify-between gap-2">
        <h2 className="inline-flex items-center gap-2 font-bold"><Sparkle className="size-5 text-brand" weight="duotone" />الذكاء الاصطناعي (Claude)</h2>
        {!isPending && status && (
          <span className={cx('inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold',
            !status.enabled ? 'bg-surface-2 text-muted' : struggling ? 'bg-warn-soft text-warn' : 'bg-brand-soft text-brand')}>
            {!status.enabled ? 'غير مفعّل' : struggling ? <><WarningCircle className="size-4" weight="fill" /> متعثّر</> : <><CheckCircle className="size-4" weight="fill" /> يعمل</>}
          </span>
        )}
      </div>
      <p className="mt-1 text-sm leading-relaxed text-muted">
        يقرأ رسائل البنك: المبلغ، المتجر، التاريخ، البطاقة وطريقة الدفع، ويصنّفها ويتعلّم من تعديلاتكم.
        إذا تعثّر لأي سبب يكمل التطبيق بالقراءة المحلية تلقائياً، فلا تضيع أي رسالة.
      </p>
      {status?.enabled && (
        <p className="mt-2 text-xs text-muted">
          قرأ <span className="num font-semibold text-ink">{status.ai_messages_24h}</span> رسالة آخر 24 ساعة
          {status.last_ok_at && <> · آخر نجاح {fmtTime(status.last_ok_at)}</>}
        </p>
      )}
      {struggling && status?.last_error && (
        <p className="mt-2 rounded-xl bg-warn-soft px-3 py-2 text-xs leading-relaxed text-warn" dir="auto">
          آخر خطأ ({fmtTime(status.last_error_at!)}): {status.last_error.slice(0, 160)}
        </p>
      )}
      {status && !status.enabled && (
        <p className="mt-2 rounded-xl bg-surface-2 px-3 py-2 text-xs leading-relaxed text-muted">
          للتفعيل: أضف مفتاح Claude في Supabase ← Integrations ← Vault باسم <code dir="ltr">anthropic_api_key</code>.
        </p>
      )}
      <Link to="/messages" className="mt-3 flex items-center gap-2 rounded-2xl bg-surface-2 px-4 py-3 text-sm font-medium transition active:opacity-80">
        <ChatCircleText className="size-5 text-brand" weight="duotone" />
        <span className="flex-1">سجل رسائل البنك ووش صار في كل رسالة</span>
        <CaretLeft className="size-4 text-muted" weight="bold" />
      </Link>
    </div>
  );
}

function SmsTester() {
  const [text, setText] = useState('');
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<SmsParseResult | null>(null);

  async function run() {
    if (!text.trim()) return toast.error('الصق رسالة بنك أولاً');
    setLoading(true);
    setResult(null);
    try {
      setResult(await previewSms(text));
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setLoading(false);
    }
  }

  return (
    <section className="border-t border-line pt-4">
      <h3 className="font-semibold">جرّب رسالة</h3>
      <p className="mt-0.5 text-xs text-muted">الصق أي رسالة من بنكك وشوف كيف بيقراها، بدون ما تنسجل.</p>
      <textarea value={text} onChange={(e) => setText(e.target.value)} rows={4} dir="auto"
        placeholder={'شراء عبر نقاط البيع\nمبلغ: SAR 45.50\nلدى: STARBUCKS'}
        className="mt-2 w-full rounded-2xl border border-line bg-surface p-3 text-base outline-none focus:border-brand focus:ring-4 focus:ring-brand/10" />
      <Button variant="secondary" className="mt-2 h-10 text-sm" onClick={run} loading={loading}>
        <MagicWand className="size-4" weight="bold" /> اقرأها
      </Button>
      {result && <ParseResultView result={result} />}
    </section>
  );
}

function ParseResultView({ result }: { result: SmsParseResult }) {
  const m = result.meta;
  if (result.status === 'ignored') {
    return (
      <div className="mt-3 rounded-2xl bg-surface-2 px-4 py-3 text-sm">
        <p className="font-semibold">بيتجاهلها: {result.reason}</p>
        <p className="mt-1 text-xs text-muted">{result.source === 'ai' ? 'قرار Claude' : 'قراءة محلية'}</p>
      </div>
    );
  }
  const rows: [string, string | undefined][] = [
    ['المبلغ', result.amount != null ? `${m?.approx ? '≈ ' : ''}${formatSAR(result.amount)}` : undefined],
    ['المتجر', result.merchant],
    ['التصنيف', m?.new_category ? `«${m.new_category}» (تصنيف جديد بيُنشأ)` : result.category_name],
    ['التاريخ', result.date && formatDayShort(result.date)],
    ['البطاقة', cardLabel(m) ?? undefined],
    ['طريقة الدفع', channelLabel(m) ?? undefined],
    ['المبلغ الأصلي', m?.original_amount && m.original_currency !== 'SAR' ? `${m.original_amount} ${m.original_currency}` : undefined],
  ];
  return (
    <div className="mt-3 rounded-2xl bg-brand-soft/60 px-4 py-3 text-sm">
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5">
        {rows.filter(([, v]) => v).map(([k, v]) => (
          <div key={k} className="contents"><dt className="text-muted">{k}</dt><dd className="font-semibold" dir="auto">{v}</dd></div>
        ))}
      </dl>
      <p className="mt-2 flex items-center gap-1 text-xs text-muted">
        {m?.rule ? 'التصنيف من قاعدة متعلَّمة' : result.source === 'ai' ? <><Sparkle className="size-3.5" weight="fill" /> Claude</> : 'قراءة محلية'}
        {result.note && <> · {result.note}</>}
      </p>
    </div>
  );
}

function CategoryOrganizer() {
  const invalidate = useInvalidate();
  const { data: status } = useAiStatus();
  const { data: audit = [] } = useCategoryAudit();
  const [plan, setPlan] = useState<CategoryPlan | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [loading, setLoading] = useState<'plan' | 'apply' | 'undo' | null>(null);

  const batches = useMemo(() => {
    const map = new Map<string, CategoryAudit[]>();
    for (const a of audit) map.set(a.batch_id, [...(map.get(a.batch_id) ?? []), a]);
    return [...map.entries()].slice(0, 5);
  }, [audit]);

  async function ask() {
    setLoading('plan');
    setPlan(null);
    try {
      const p = await requestCategoryPlan();
      setPlan(p);
      setSelected(new Set(p.operations.map((_, i) => i)));
      if (!p.operations.length) toast.success('تصنيفاتك مرتبة، ما يحتاج تغيير');
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setLoading(null);
    }
  }

  async function apply() {
    if (!plan) return;
    setLoading('apply');
    try {
      const ops = plan.operations.filter((_, i) => selected.has(i));
      const res = await applyCategoryPlan(ops, 'ai');
      await invalidate(...CATEGORY_DEPENDENT);
      setPlan(null);
      toast.success(`تم تطبيق ${res.applied.length} تغيير`, {
        description: res.skipped.length ? `تجاهلت ${res.skipped.length} لأنها غير آمنة: ${res.skipped.map((s) => s.why).join('، ')}` : 'تقدر تتراجع عنها من «آخر التغييرات»',
      });
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setLoading(null);
    }
  }

  async function undo(batchId: string) {
    setLoading('undo');
    try {
      const n = await undoCategoryBatch(batchId);
      await invalidate(...CATEGORY_DEPENDENT);
      toast.success(`تم التراجع عن ${n} تغيير، ورجع كل شي مثل ما كان`);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setLoading(null);
    }
  }

  return (
    <section className="border-t border-line pt-4">
      <h3 className="font-semibold">تنظيم التصنيفات</h3>
      <p className="mt-0.5 text-xs leading-relaxed text-muted">
        Claude يراجع تصنيفاتكم ومتاجركم ويقترح: دمج المتشابه، توحيد المتجر في تصنيف واحد، إنشاء تصنيف ناقص، وأرشفة غير المستخدم.
        لا يُحذف إلا تصنيف فارغ، وكل تغيير تقدر تتراجع عنه بالكامل.
      </p>
      <Button variant="secondary" className="mt-2 h-10 text-sm" onClick={ask} loading={loading === 'plan'} disabled={!status?.enabled}>
        <MagicWand className="size-4" weight="bold" /> {loading === 'plan' ? 'Claude يراجع… (قد يأخذ نصف دقيقة)' : 'نظّم تصنيفاتي'}
      </Button>

      {plan && plan.operations.length > 0 && (
        <div className="mt-3 rounded-2xl border border-line p-3">
          <p className="text-sm font-medium">{plan.summary}</p>
          <ul className="mt-2 space-y-1.5">
            {plan.operations.map((op, i) => (
              <li key={i}>
                <label className="flex items-start gap-2 rounded-xl px-2 py-1.5 hover:bg-surface-2">
                  <input type="checkbox" className="mt-1 size-4 accent-[var(--color-brand)]" checked={selected.has(i)}
                    onChange={(e) => setSelected((s) => { const n = new Set(s); if (e.target.checked) n.add(i); else n.delete(i); return n; })} />
                  <span className="text-sm">
                    <span className="font-semibold">{opLabel(op)}</span>
                    {op.reason && <span className="block text-xs text-muted">{op.reason}</span>}
                  </span>
                </label>
              </li>
            ))}
          </ul>
          <div className="mt-2 flex gap-2">
            <Button className="h-10 flex-1 text-sm" onClick={apply} loading={loading === 'apply'} disabled={!selected.size}>
              طبّق {selected.size} تغيير
            </Button>
            <Button variant="ghost" className="h-10 text-sm" onClick={() => setPlan(null)}>إلغاء</Button>
          </div>
        </div>
      )}

      {batches.length > 0 && (
        <div className="mt-3">
          <p className="mb-1 text-xs font-medium text-muted">آخر التغييرات</p>
          <ul className="space-y-1.5">
            {batches.map(([batchId, items]) => {
              const undone = items.every((a) => a.undone_at);
              return (
                <li key={batchId} className="flex items-start gap-2 rounded-xl bg-surface-2 px-3 py-2 text-xs">
                  <span className="min-w-0 flex-1">
                    <span className="block text-muted">{fmtTime(items[0]!.created_at)} · {items[0]!.actor === 'ai' ? 'Claude' : 'يدوي'}{undone && ' · تم التراجع'}</span>
                    <span className={cx('block', undone && 'line-through opacity-60')}>{items.map(auditLabel).join('، ')}</span>
                  </span>
                  {!undone && (
                    <IconButton label="تراجع" className="size-8" disabled={loading === 'undo'} onClick={() => undo(batchId)}>
                      <ArrowCounterClockwise className="size-4" weight="bold" />
                    </IconButton>
                  )}
                </li>
              );
            })}
          </ul>
        </div>
      )}
    </section>
  );
}

function RulesList() {
  const { household } = useHousehold();
  const { data: rules = [] } = useRules();
  const { data: categories = [] } = useCategories();
  const invalidate = useInvalidate();
  const catName = new Map(categories.map((c) => [c.id, c.name]));

  async function remove(key: string, label: string) {
    try {
      await deleteRule(household.id, key);
      await invalidate('rules');
      toast.success(`نسيت قاعدة «${label}»`);
    } catch (e) {
      toast.error((e as Error).message);
    }
  }

  return (
    <section className="border-t border-line pt-4">
      <h3 className="font-semibold">ما تعلّمه التطبيق منكم</h3>
      <p className="mt-0.5 text-xs text-muted">
        لما تغيّرون تصنيف عملية من رسالة بنك، يتذكر المتجر ويصنّفه كذا دائماً. تتقدم هذي القواعد على أي شيء آخر.
      </p>
      {rules.length === 0 ? (
        <p className="mt-2 rounded-xl bg-surface-2 px-3 py-2.5 text-xs text-muted">ما فيه قواعد بعد.</p>
      ) : (
        <ul className="mt-2 divide-y divide-line rounded-2xl bg-surface-2">
          {rules.map((r) => (
            <li key={r.merchant_key} className="flex items-center gap-2 px-3 py-1.5 text-sm">
              <span className="min-w-0 flex-1 truncate" dir="auto">{r.merchant_label}</span>
              <span className="shrink-0 text-xs text-muted">← {catName.get(r.category_id) ?? '—'}</span>
              <IconButton label={`حذف قاعدة ${r.merchant_label}`} className="size-8" onClick={() => remove(r.merchant_key, r.merchant_label)}>
                <Trash className="size-4" weight="bold" />
              </IconButton>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
