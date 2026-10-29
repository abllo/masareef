import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { useSearchParams } from 'react-router';
import { toast } from 'sonner';
import { useQueryClient } from '@tanstack/react-query';
import { CheckCircle, MagicWand, Plus, ShieldCheck, Sparkle, Trash } from '@phosphor-icons/react';
import { BackButton, Button, ConfirmButton, EmptyState, Field, Select, Sheet, Spinner, cx } from '../components/ui';
import { useCanEdit, useHousehold } from '../hooks/household';
import { useRenewals } from '../hooks/queries';
import { deleteRenewal, fetchExpense, parseRenewal, renewalDone, saveRenewal, type RenewalInput } from '../lib/api';
import { formatDayShort, todayISO } from '../lib/dates';
import { formatSAR, parseAmount, toInputValue } from '../lib/money';
import { KIND_EMOJI, KIND_LABELS, PERIOD_OPTIONS, addMonthsISO, countdown, daysUntil, sortRenewals, urgency } from '../lib/renewals';
import type { Renewal, RenewalKind } from '../lib/types';

type FormState = { item?: Renewal; draft?: Partial<RenewalInput> };

const TONE = {
  overdue: 'bg-danger text-white',
  urgent: 'bg-danger-soft text-danger',
  soon: 'bg-warn-soft text-warn',
  later: 'bg-surface-2 text-muted',
} as const;

export default function RenewalsPage() {
  const today = todayISO();
  const { data = [], isPending } = useRenewals();
  const [form, setForm] = useState<FormState | null>(null);
  const [params, setParams] = useSearchParams();

  // من تفاصيل مصروف: «إضافة ضمان أو تجديد»
  const fromExpense = params.get('expense');
  useEffect(() => {
    if (!fromExpense) return;
    fetchExpense(fromExpense).then((e) => {
      if (!e) return;
      const merchant = e.sms_meta?.merchant ?? e.description?.replace(/^[📩🧾]\s*/u, '') ?? '';
      setForm({ draft: { kind: 'warranty', title: `ضمان ${merchant}`.trim(), expense_id: e.id, amount: e.amount,
        period_months: 24, due_date: addMonthsISO(e.expense_date, 24) } });
    }).catch(() => {}).finally(() => setParams({}, { replace: true }));
  }, [fromExpense, setParams]);

  const active = useMemo(() => sortRenewals(data.filter((r) => r.status === 'active')), [data]);
  const soon = active.filter((r) => r.kind !== 'warranty' && daysUntil(r.due_date, today) <= 30);
  const later = active.filter((r) => r.kind !== 'warranty' && daysUntil(r.due_date, today) > 30);
  const warranties = active.filter((r) => r.kind === 'warranty');
  const done = data.filter((r) => r.status === 'done');

  return (
    <div className="space-y-5 pt-4">
      <header className="flex items-center gap-2">
        <BackButton />
        <h1 className="flex-1 text-xl font-bold">التجديدات والضمانات</h1>
        <Button className="h-10 px-3 text-sm" onClick={() => setForm({})}><Plus className="size-4" weight="bold" /> إضافة</Button>
      </header>

      <SmartAdd onParsed={(draft) => setForm({ draft })} />

      {isPending ? <Spinner /> : data.length === 0 ? (
        <EmptyState icon={ShieldCheck} title="لا توجد تجديدات" />
      ) : (
        <>
          <Section title="قريباً" items={soon} today={today} onOpen={(item) => setForm({ item })} />
          <Section title="لاحقاً" items={later} today={today} onOpen={(item) => setForm({ item })} />
          <Section title="الضمانات" items={warranties} today={today} onOpen={(item) => setForm({ item })} />
          {done.length > 0 && <Section title="منتهية" items={done} today={today} onOpen={(item) => setForm({ item })} muted />}
        </>
      )}

      <Sheet open={form !== null} onOpenChange={(o) => !o && setForm(null)} title={form?.item ? 'تعديل' : 'تجديد جديد'}>
        {form && <RenewalForm key={form.item?.id ?? JSON.stringify(form.draft ?? {})} item={form.item} draft={form.draft} onDone={() => setForm(null)} />}
      </Sheet>
    </div>
  );
}

function Section({ title, items, today, onOpen, muted }: {
  title: string; items: Renewal[]; today: string; onOpen: (r: Renewal) => void; muted?: boolean;
}) {
  if (items.length === 0) return null;
  return (
    <section>
      <h2 className="mb-1.5 px-2 text-xs font-semibold text-muted">{title}</h2>
      <div className={cx('divide-y divide-line/70 overflow-hidden rounded-card bg-surface shadow-[0_1px_2px_rgb(0_0_0/0.04)]', muted && 'opacity-60')}>
        {items.map((r) => {
          const days = daysUntil(r.due_date, today);
          return (
            <button key={r.id} type="button" onClick={() => onOpen(r)} className="flex w-full items-center gap-3 px-4 py-3 text-start active:bg-surface-2">
              <span className="flex size-10 shrink-0 items-center justify-center rounded-2xl bg-surface-2 text-xl" aria-hidden>{KIND_EMOJI[r.kind]}</span>
              <span className="min-w-0 flex-1">
                <span className="block truncate font-semibold">{r.title}</span>
                <span className="block truncate text-xs text-muted">
                  {[r.subject, formatDayShort(r.due_date), r.amount ? formatSAR(r.amount) : null].filter(Boolean).join(' · ')}
                  {(r.source === 'sms' || r.source === 'notice') && ' · 📩'}
                </span>
              </span>
              {r.status === 'active'
                ? <span className={cx('shrink-0 rounded-full px-2.5 py-1 text-xs font-semibold', TONE[urgency(days)])}>{countdown(days)}</span>
                : <CheckCircle className="size-5 shrink-0 text-brand" weight="fill" />}
            </button>
          );
        })}
      </div>
    </section>
  );
}

function SmartAdd({ onParsed }: { onParsed: (d: Partial<RenewalInput>) => void }) {
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  async function run() {
    setBusy(true);
    try {
      const d = await parseRenewal(text);
      onParsed({
        kind: d.kind, title: d.title, subject: d.subject ?? null, due_date: d.due_date ?? undefined,
        period_months: d.period_months ?? null, amount: d.amount_sar ? Math.round(d.amount_sar * 100) : null, source: 'ai',
      });
      setText('');
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="rounded-card bg-surface p-4 shadow-[0_1px_2px_rgb(0_0_0/0.04)]">
      <p className="mb-2 inline-flex items-center gap-1.5 text-sm font-semibold"><Sparkle className="size-4 text-brand" weight="fill" /> إضافة سريعة</p>
      <textarea value={text} onChange={(e) => setText(e.target.value)} rows={2} dir="auto"
        placeholder="تأمين السيارة ينتهي 15 مارس"
        className="w-full rounded-2xl border border-line bg-surface-2 p-3 text-base outline-none focus:border-brand focus:ring-4 focus:ring-brand/10" />
      <Button variant="secondary" className="mt-2 h-10 text-sm" loading={busy} disabled={!text.trim()} onClick={run}>
        <MagicWand className="size-4" weight="bold" /> افهمها
      </Button>
    </div>
  );
}

function RenewalForm({ item, draft, onDone }: { item?: Renewal; draft?: Partial<RenewalInput>; onDone: () => void }) {
  const { household } = useHousehold();
  const canEdit = useCanEdit();
  const qc = useQueryClient();
  const base = item ?? draft ?? {};
  const [title, setTitle] = useState(base.title ?? '');
  const [kind, setKind] = useState<RenewalKind>(base.kind ?? 'other');
  const [subject, setSubject] = useState(base.subject ?? '');
  const [due, setDue] = useState(base.due_date ?? '');
  const [period, setPeriod] = useState(base.period_months ? String(base.period_months) : '');
  const [amount, setAmount] = useState(base.amount ? toInputValue(base.amount) : '');
  const [notes, setNotes] = useState(base.notes ?? '');
  const [busy, setBusy] = useState<string | null>(null);
  const readOnly = Boolean(item && !canEdit(item.created_by ?? ''));
  const refresh = () => qc.invalidateQueries({ queryKey: ['renewals'] });

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!title.trim()) return toast.error('اكتب العنوان');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(due)) return toast.error('حدّد التاريخ');
    const a = amount.trim() ? parseAmount(amount) : null;
    if (amount.trim() && !a) return toast.error('أدخل مبلغاً صحيحاً');
    setBusy('save');
    try {
      await saveRenewal(household.id, {
        title: title.trim(), kind, subject: subject.trim() || null, due_date: due, period_months: period ? Number(period) : null,
        amount: a, notes: notes.trim() || null,
        ...(item ? {} : { source: draft?.source ?? 'manual', expense_id: draft?.expense_id ?? null }),
      }, item?.id);
      toast.success('تم الحفظ');
      await refresh();
      onDone();
    } catch (err) {
      toast.error((err as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function act(name: string, fn: () => Promise<unknown>, msg: string) {
    setBusy(name);
    try { await fn(); toast.success(msg); await refresh(); onDone(); } catch (err) { toast.error((err as Error).message); } finally { setBusy(null); }
  }

  return (
    <form onSubmit={submit} className="space-y-4 pb-2">
      <fieldset disabled={readOnly} className="min-w-0 space-y-4">
        <Field label="العنوان" value={title} maxLength={80} onChange={(e) => setTitle(e.target.value)} placeholder="تأمين السيارة" />
        <div className="grid grid-cols-2 gap-3">
          <Select label="النوع" showLabel value={kind} onChange={(v) => setKind(v as RenewalKind)}
            options={(Object.keys(KIND_LABELS) as RenewalKind[]).map((k) => ({ value: k, label: `${KIND_EMOJI[k]} ${KIND_LABELS[k]}` }))} />
          <Field label="لمن / لأي شيء" value={subject} maxLength={60} onChange={(e) => setSubject(e.target.value)} placeholder="الكامري، أم محمد…" />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <Field label="تاريخ الانتهاء" type="date" value={due} onChange={(e) => setDue(e.target.value)} />
          <Select label="يتجدد" showLabel value={period} onChange={setPeriod} options={PERIOD_OPTIONS} />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <Field label="المبلغ (اختياري)" inputMode="decimal" dir="ltr" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="ر.س" />
          <Field label="ملاحظة (اختياري)" value={notes} maxLength={300} onChange={(e) => setNotes(e.target.value)} />
        </div>
      </fieldset>
      {readOnly ? (
        null
      ) : (
        <div className="flex flex-wrap gap-2">
          <Button type="submit" className="flex-1" loading={busy === 'save'}>{item ? 'حفظ' : 'إضافة'}</Button>
          {item?.status === 'active' && (
            <Button type="button" variant="secondary" loading={busy === 'done'}
              onClick={() => act('done', () => renewalDone(item.id), item.period_months && item.kind !== 'warranty' ? 'تم التجديد' : 'تم')}>
              <CheckCircle className="size-5" weight="bold" /> {item.period_months && item.kind !== 'warranty' ? 'تم التجديد' : 'انتهى'}
            </Button>
          )}
          {item && (
            <ConfirmButton loading={busy === 'delete'} confirmText="تأكيد الحذف"
              onConfirm={() => act('delete', () => deleteRenewal(item.id), 'تم الحذف')}>
              <Trash className="size-5" weight="bold" /><span className="sr-only">حذف</span>
            </ConfirmButton>
          )}
        </div>
      )}
    </form>
  );
}
