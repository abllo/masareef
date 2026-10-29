import { useState } from 'react';
import { Link } from 'react-router';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { ArrowsClockwise, CaretLeft, ChartLineUp, ChatCircleText, CreditCard, Lightbulb, Sparkle, Storefront, Warning } from '@phosphor-icons/react';
import { useHousehold } from '../hooks/household';
import { useAiStatus } from '../hooks/queries';
import { fetchCachedReport, fetchMonthReport } from '../lib/api';
import { formatMonth } from '../lib/dates';
import { formatSAR } from '../lib/money';
import { byPaymentMethod, monthProjection, topMerchants } from '../lib/stats';
import type { Expense, Halalas, ISODate, MonthKey } from '../lib/types';
import { Button, Card, cx } from './ui';

function Bars({ rows, total }: { rows: { label: string; total: Halalas; count: number }[]; total: Halalas }) {
  return (
    <ul className="space-y-2.5">
      {rows.map((r) => (
        <li key={r.label}>
          <div className="flex justify-between gap-2 text-sm">
            <span className="truncate font-medium" dir="auto">{r.label}</span>
            <span className="num shrink-0 font-semibold">{formatSAR(r.total)}</span>
          </div>
          <div className="mt-1 flex items-center gap-2">
            <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-surface-2">
              <div className="h-full rounded-full bg-brand/70" style={{ width: `${total ? Math.max(3, (r.total / total) * 100) : 0}%` }} />
            </div>
            <span className="num w-10 text-end text-xs text-muted">{r.count}×</span>
          </div>
        </li>
      ))}
    </ul>
  );
}

/** تحليلات محسوبة محلياً من عمليات الشهر (دقيقة 100% لأنها من بياناتكم مباشرة) */
export function InsightsCard({ list, total, month, today }: { list: Expense[]; total: Halalas; month: MonthKey; today: ISODate }) {
  const merchants = topMerchants(list, 5);
  const cards = byPaymentMethod(list);
  const projection = monthProjection(total, month, today);
  const { household } = useHousehold();

  return (
    <Card className="space-y-5">
      <h2 className="inline-flex items-center gap-2 font-bold"><ChartLineUp className="size-5 text-brand" weight="duotone" />تحليلات {formatMonth(month)}</h2>
      {projection !== null && (
        <div className="rounded-2xl bg-surface-2 px-4 py-3">
          <p className="text-xs text-muted">المتوقع لنهاية الشهر بنفس معدل الصرف</p>
          <p className="num mt-0.5 text-xl font-bold">{formatSAR(projection)}</p>
          {household.monthly_budget && (
            <p className={cx('mt-0.5 text-xs font-medium', projection > household.monthly_budget ? 'text-danger' : 'text-brand')}>
              {projection > household.monthly_budget
                ? `أعلى من الميزانية بـ ${formatSAR(projection - household.monthly_budget)}`
                : `أقل من الميزانية بـ ${formatSAR(household.monthly_budget - projection)}`}
            </p>
          )}
        </div>
      )}
      {merchants.length > 0 && (
        <section>
          <h3 className="mb-2 inline-flex items-center gap-1.5 text-sm font-semibold text-muted"><Storefront className="size-4" weight="bold" />أكثر المتاجر صرفاً</h3>
          <Bars rows={merchants} total={total} />
        </section>
      )}
      {cards.length > 0 && (
        <section>
          <h3 className="mb-2 inline-flex items-center gap-1.5 text-sm font-semibold text-muted"><CreditCard className="size-4" weight="bold" />حسب البطاقة</h3>
          <Bars rows={cards} total={total} />
        </section>
      )}
      <Link to="/messages" className="flex items-center gap-2 rounded-2xl bg-surface-2 px-4 py-3 text-sm font-medium transition active:opacity-80">
        <ChatCircleText className="size-5 text-brand" weight="duotone" />
        <span className="flex-1">سجل رسائل البنك</span>
        <CaretLeft className="size-4 text-muted" weight="bold" />
      </Link>
    </Card>
  );
}

/** تقرير الشهر من Claude: الأرقام محسوبة في قاعدة البيانات، وClaude يكتب القراءة فقط */
export function AiReportCard({ month }: { month: MonthKey }) {
  const { household } = useHousehold();
  const qc = useQueryClient();
  const { data: status } = useAiStatus();
  const [loading, setLoading] = useState(false);
  const key = ['ai-report', household.id, month];
  const { data: report } = useQuery({ queryKey: key, queryFn: () => fetchCachedReport(household.id, month) });

  async function generate() {
    setLoading(true);
    try {
      const r = await fetchMonthReport(month, true);
      qc.setQueryData(key, r);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setLoading(false);
    }
  }

  if (!status?.enabled && !report) return null;
  const c = report?.content;

  return (
    <Card className="space-y-4">
      <div className="flex items-center justify-between gap-2">
        <h2 className="inline-flex items-center gap-2 font-bold"><Sparkle className="size-5 text-brand" weight="duotone" />قراءة Claude للشهر</h2>
        {report && status?.enabled && (
          <Button variant="ghost" className="h-9 px-3 text-xs" onClick={generate} loading={loading}>
            <ArrowsClockwise className="size-4" weight="bold" /> حدّث
          </Button>
        )}
      </div>
      {!c ? (
        <div>
          <p className="text-sm leading-relaxed text-muted">
            تحليل لمصاريف {formatMonth(month)}: وش تغيّر، وين راحت الفلوس، تنبيهات، واقتراحات مبنية على أرقامكم الفعلية.
          </p>
          <Button className="mt-3 h-10 text-sm" onClick={generate} loading={loading}>
            <Sparkle className="size-4" weight="fill" /> {loading ? 'Claude يحلل… (نصف دقيقة تقريباً)' : 'حلّل الشهر'}
          </Button>
        </div>
      ) : (
        <div className="space-y-4">
          <p className="font-semibold leading-relaxed">{c.headline}</p>
          {c.highlights.length > 0 && (
            <ul className="space-y-1.5 text-sm leading-relaxed">
              {c.highlights.map((h, i) => <li key={i} className="flex gap-2"><span className="text-brand">•</span><span>{h}</span></li>)}
            </ul>
          )}
          {c.alerts.length > 0 && (
            <div className="space-y-1.5 rounded-2xl bg-warn-soft px-4 py-3 text-sm leading-relaxed">
              {c.alerts.map((a, i) => <p key={i} className="flex gap-2"><Warning className="mt-0.5 size-4 shrink-0 text-warn" weight="fill" />{a}</p>)}
            </div>
          )}
          {c.tips.length > 0 && (
            <div className="space-y-1.5 rounded-2xl bg-brand-soft/60 px-4 py-3 text-sm leading-relaxed">
              {c.tips.map((t, i) => <p key={i} className="flex gap-2"><Lightbulb className="mt-0.5 size-4 shrink-0 text-brand" weight="fill" />{t}</p>)}
            </div>
          )}
          <p className="text-xs text-muted">
            كل الأرقام محسوبة من عملياتكم مباشرة · آخر تحديث {new Date(report!.created_at).toLocaleString('ar-SA-u-ca-gregory-nu-latn', { timeZone: 'Asia/Riyadh', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' })}
          </p>
        </div>
      )}
    </Card>
  );
}
