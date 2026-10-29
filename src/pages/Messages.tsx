import { useMemo, useState } from 'react';
import { toast } from 'sonner';
import { ArrowsClockwise, ChatCircleText, CheckCircle, Copy, LinkSimple, PlusCircle, Prohibit, Sparkle, Trash } from '@phosphor-icons/react';
import { useExpenseSheet } from '../components/Layout';
import { Button, EmptyState, IconButton, Spinner, cx } from '../components/ui';
import { useInvalidate, useSmsLog } from '../hooks/queries';
import { deleteSmsLog, fetchExpense } from '../lib/api';
import { formatDayLabel, todayISO } from '../lib/dates';
import { formatSAR, parseAmount } from '../lib/money';
import type { SmsLogEntry } from '../lib/types';

type Filter = 'all' | 'recorded' | 'ignored';

const dayFmt = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Riyadh', year: 'numeric', month: '2-digit', day: '2-digit' });
const timeFmt = new Intl.DateTimeFormat('ar-SA-u-ca-gregory-nu-latn', { timeZone: 'Asia/Riyadh', hour: 'numeric', minute: '2-digit' });

const STATUS: Record<SmsLogEntry['status'], { label: string; icon: typeof CheckCircle; tone: string }> = {
  recorded: { label: 'سُجّلت', icon: CheckCircle, tone: 'bg-brand-soft text-brand' },
  linked: { label: 'رُبطت بمصروف ثابت', icon: LinkSimple, tone: 'bg-brand-soft text-brand' },
  duplicate: { label: 'مكررة', icon: ArrowsClockwise, tone: 'bg-surface-2 text-muted' },
  ignored: { label: 'تجاهلها', icon: Prohibit, tone: 'bg-warn-soft text-warn' },
};

export default function Messages() {
  const { data = [], isPending, refetch, isFetching } = useSmsLog();
  const [filter, setFilter] = useState<Filter>('all');

  const list = useMemo(() => data.filter((m) =>
    filter === 'all' ? true : filter === 'ignored' ? m.status === 'ignored' : m.status !== 'ignored'), [data, filter]);
  const groups = useMemo(() => {
    const map = new Map<string, SmsLogEntry[]>();
    for (const m of list) {
      const d = dayFmt.format(new Date(m.received_at));
      map.set(d, [...(map.get(d) ?? []), m]);
    }
    return [...map.entries()];
  }, [list]);

  const today = todayISO();
  const todays = data.filter((m) => dayFmt.format(new Date(m.received_at)) === today);
  const aiCount = data.filter((m) => m.source === 'ai').length;

  return (
    <div className="space-y-4 pt-4">
      <header className="flex items-center justify-between gap-2">
        <h1 className="text-xl font-bold">رسائل البنك</h1>
        <IconButton label="تحديث" className="bg-surface shadow-sm" onClick={() => refetch()}>
          <ArrowsClockwise className={cx('size-5', isFetching && 'animate-spin')} weight="bold" />
        </IconButton>
      </header>

      <div className="grid grid-cols-3 gap-2 text-center">
        {[
          ['اليوم', todays.length],
          ['سُجّلت', data.filter((m) => m.status === 'recorded' || m.status === 'linked').length],
          ['قرأها Claude', aiCount],
        ].map(([k, v]) => (
          <div key={k} className="rounded-2xl bg-surface px-2 py-3 shadow-[0_1px_2px_rgb(0_0_0/0.04)]">
            <p className="num text-xl font-bold">{v}</p>
            <p className="text-xs text-muted">{k}</p>
          </div>
        ))}
      </div>

      <div className="flex gap-1.5 rounded-full bg-surface p-1 shadow-sm">
        {([['all', 'الكل'], ['recorded', 'المسجّلة'], ['ignored', 'المتجاهلة']] as [Filter, string][]).map(([k, label]) => (
          <button key={k} type="button" onClick={() => setFilter(k)} aria-pressed={filter === k}
            className={cx('h-9 flex-1 rounded-full text-sm font-semibold transition', filter === k ? 'bg-ink text-bg' : 'text-muted')}>
            {label}
          </button>
        ))}
      </div>

      {isPending ? <Spinner /> : list.length === 0 ? (
        <EmptyState icon={ChatCircleText} title={data.length ? 'ما فيه رسائل بهذا التصنيف' : 'ما وصلت رسائل بنك بعد'}>
          {data.length ? null : 'لما يرسل الاختصار رسالة شراء، بتظهر هنا مع وش صار فيها.'}
        </EmptyState>
      ) : (
        <div className="space-y-5">
          {groups.map(([day, items]) => (
            <section key={day}>
              <h2 className="mb-1 px-2 text-sm font-semibold">{formatDayLabel(day, today)}</h2>
              <ul className="space-y-2">
                {items.map((m) => <MessageItem key={m.id} m={m} />)}
              </ul>
            </section>
          ))}
        </div>
      )}
      <p className="px-2 text-center text-xs text-muted">يحتفظ التطبيق بالرسائل 180 يوماً. رسائل رموز التحقق لا يُحفظ نصها.</p>
    </div>
  );
}

function MessageItem({ m }: { m: SmsLogEntry }) {
  const openSheet = useExpenseSheet();
  const invalidate = useInvalidate();
  const [expanded, setExpanded] = useState(false);
  const s = STATUS[m.status];
  const r = m.result;
  const amount = r?.amount ?? (r?.fallback_amount ? parseAmount(r.fallback_amount) : null);
  const title = r?.merchant ?? (m.status === 'ignored' ? m.reason : null) ?? 'رسالة بنك';

  async function openExpense() {
    if (!m.expense_id) return;
    try {
      const e = await fetchExpense(m.expense_id);
      if (e) openSheet(e); else toast.error('العملية محذوفة');
    } catch (err) {
      toast.error((err as Error).message);
    }
  }

  function recordManually() {
    openSheet(undefined, {
      amount: amount ?? undefined,
      description: r?.merchant ? `📩 ${r.merchant}` : '📩 رسالة البنك',
      date: r?.date,
      categoryId: r?.category_id,
    });
  }

  async function remove() {
    try {
      await deleteSmsLog(m.id);
      await invalidate('sms-log');
    } catch (err) {
      toast.error((err as Error).message);
    }
  }

  return (
    <li className="rounded-card bg-surface p-3 shadow-[0_1px_2px_rgb(0_0_0/0.04)]">
      <div className="flex items-start gap-3">
        <span className={cx('flex size-10 shrink-0 items-center justify-center rounded-2xl', s.tone)}>
          <s.icon className="size-5" weight="duotone" />
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-2">
            <p className="truncate font-semibold" dir="auto">{title}</p>
            {amount != null && <p className="num shrink-0 font-semibold">{r?.meta?.approx && '≈ '}{formatSAR(amount)}</p>}
          </div>
          <p className="mt-0.5 flex flex-wrap items-center gap-x-1.5 text-xs text-muted">
            <span>{timeFmt.format(new Date(m.received_at))}</span>
            <span aria-hidden>•</span>
            <span>{s.label}</span>
            {m.status !== 'ignored' && r?.category_name && <><span aria-hidden>•</span><span>{r.category_name}</span></>}
            {m.status === 'ignored' && m.reason && m.reason !== title && <><span aria-hidden>•</span><span>{m.reason}</span></>}
            {m.source === 'ai' && <Sparkle className="size-3.5 text-brand" weight="fill" aria-label="قرأها Claude" />}
          </p>
          {m.status !== 'ignored' && m.reason && <p className="mt-0.5 text-xs text-muted">{m.reason}</p>}
        </div>
      </div>

      {m.message && (
        <button type="button" onClick={() => setExpanded(!expanded)} dir="auto"
          className={cx('mt-2 w-full whitespace-pre-line rounded-xl bg-surface-2 px-3 py-2 text-start text-xs leading-relaxed text-muted', !expanded && 'line-clamp-2')}>
          {m.message}
        </button>
      )}

      <div className="mt-2 flex items-center gap-1">
        {m.expense_id && (
          <Button variant="ghost" className="h-8 px-2 text-xs" onClick={openExpense}>فتح العملية</Button>
        )}
        {m.status === 'ignored' && m.message && (
          <Button variant="ghost" className="h-8 px-2 text-xs text-brand" onClick={recordManually}>
            <PlusCircle className="size-4" weight="bold" /> سجّلها يدوياً
          </Button>
        )}
        <span className="flex-1" />
        {m.message && (
          <IconButton label="نسخ الرسالة" className="size-8" onClick={() => navigator.clipboard.writeText(m.message!).then(() => toast.success('تم النسخ'), () => {})}>
            <Copy className="size-4" weight="bold" />
          </IconButton>
        )}
        <IconButton label="حذف من السجل" className="size-8" onClick={remove}>
          <Trash className="size-4" weight="bold" />
        </IconButton>
      </div>
    </li>
  );
}
