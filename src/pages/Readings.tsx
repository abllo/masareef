import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { AirplaneTilt, CalendarCheck, CaretLeft, ChartBar, HandCoins, Lightning, Plus, Repeat, ShieldCheck, Trash, Warning } from '@phosphor-icons/react';
import { toast } from 'sonner';
import { AiReportCard, InsightsCard } from '../components/Insights';
import { Button, Card, CategoryIcon, MonthSwitcher, Spinner, cx } from '../components/ui';
import { useIsOwner } from '../hooks/household';
import { useCategories, useExpenses, useIncomes, useInvalidate, useRecurring, useRenewals, useSaveRecurring } from '../hooks/queries';
import { deleteIncome } from '../lib/api';
import { subscriptionAudit } from '../lib/subscriptions';
import { WEEKDAYS, byWeekday, detectRecurring, firstDaysShare, habits, unusualSpending } from '../lib/behavior';
import { addMonths, daysInMonth, formatDayShort, monthEnd, monthOf, todayISO } from '../lib/dates';
import { formatSAR, sumHalalas } from '../lib/money';
import { merchantLabel, splitTravel } from '../lib/stats';
import type { Expense, Income, MonthKey } from '../lib/types';

/** «قراءات»: كل التحليلات في مكان واحد حتى تبقى الرئيسية خفيفة */
export default function ReadingsPage() {
  const today = todayISO();
  const [month, setMonth] = useState<MonthKey>(monthOf(today));
  const { data: categories = [] } = useCategories();
  const { data: all = [], isPending } = useExpenses(addMonths(month, -3), monthEnd(month));

  const regular = useMemo(() => splitTravel(all).regular, [all]);
  const inMonth = useMemo(() => regular.filter((e) => e.expense_date >= month), [regular, month]);
  const prevMonth = useMemo(() => regular.filter((e) => e.expense_date >= addMonths(month, -1) && e.expense_date < month), [regular, month]);
  const history = useMemo(() => regular.filter((e) => e.expense_date < month), [regular, month]);
  const total = sumHalalas(inMonth.map((e) => e.amount));
  const days = monthOf(today) === month ? Number(today.slice(8, 10)) : daysInMonth(month);

  return (
    <div className="space-y-5 pt-4">
      <header className="flex items-center justify-between gap-2">
        <h1 className="text-xl font-bold">قراءات</h1>
        <MonthSwitcher month={month} onChange={setMonth} />
      </header>

      <AiReportCard month={month} />

      {isPending ? <Spinner /> : (
        <>
          <IncomeCard month={month} spent={total} />
          <WhenCard list={inMonth} />
          <SubscriptionsCard list={regular} />
          <HabitsCard list={inMonth} prev={prevMonth} days={days} categories={categories} month={month} />
          <UnusualCard list={inMonth} history={history} />
          {inMonth.length > 0 && <InsightsCard list={inMonth} total={total} month={month} today={today} />}
        </>
      )}

      <div className="grid grid-cols-3 gap-2">
        {[
          { to: '/years', icon: ChartBar, label: 'السنوات' },
          { to: '/trips', icon: AirplaneTilt, label: 'الرحلات' },
          { to: '/renewals', icon: ShieldCheck, label: 'التجديدات' },
        ].map(({ to, icon: LinkIcon, label }) => (
          <Link key={to} to={to} className="flex flex-col items-center gap-1.5 rounded-card bg-surface py-4 text-sm font-semibold shadow-[0_1px_2px_rgb(0_0_0/0.04)]">
            <LinkIcon className="size-6 text-brand" weight="duotone" /> {label}
          </Link>
        ))}
      </div>
    </div>
  );
}

function Title({ icon: TitleIcon, children }: { icon: typeof Lightning; children: string }) {
  return <h2 className="mb-3 inline-flex items-center gap-2 font-bold"><TitleIcon className="size-5 text-brand" weight="duotone" />{children}</h2>;
}

/** متى تصرف أكثر: أيام الأسبوع وأول الشهر */
function WhenCard({ list }: { list: Expense[] }) {
  const rows = byWeekday(list);
  const total = sumHalalas(rows.map((r) => r.total));
  if (total === 0) return null;
  const max = Math.max(...rows.map((r) => r.total));
  const top = rows.find((r) => r.total === max)!;
  const weekend = rows[5]!.total + rows[6]!.total;
  const early = firstDaysShare(list);
  return (
    <Card>
      <Title icon={CalendarCheck}>متى تصرف أكثر</Title>
      <div className="flex h-28 items-end gap-1.5">
        {rows.map((r) => (
          <div key={r.day} className="flex flex-1 flex-col items-center gap-1">
            <div className={cx('w-full rounded-md', r.day === top.day ? 'bg-brand' : 'bg-line')}
              style={{ height: `${max ? Math.max(4, (r.total / max) * 88) : 4}px` }} title={formatSAR(r.total)} />
            <span className="text-[10px] text-muted">{WEEKDAYS[r.day]!.replace('ال', '').slice(0, 3)}</span>
          </div>
        ))}
      </div>
      <ul className="mt-3 space-y-1 text-sm">
        <li>أعلى يوم: <b>{WEEKDAYS[top.day]}</b> · {Math.round((top.total / total) * 100)}% من صرفك</li>
        <li>نهاية الأسبوع (الجمعة والسبت): {Math.round((weekend / total) * 100)}%</li>
        {early !== null && (
          <li>أول 10 أيام من الشهر: <b>{Math.round(early * 100)}%</b>
            {early >= 0.45 ? ' · معظم الصرف بعد الراتب' : ''}</li>
        )}
      </ul>
    </Card>
  );
}

const INCOME_LABEL: Record<Income['kind'], string> = { salary: 'راتب', transfer: 'حوالة واردة', deposit: 'إيداع', other: 'إضافة' };

/** دخلك هذا الشهر (خاص بك) والفائض بعد مصاريف البيت */
function IncomeCard({ month, spent }: { month: MonthKey; spent: number }) {
  const { data: rows = [] } = useIncomes(month, monthEnd(month));
  const invalidate = useInvalidate();
  if (rows.length === 0) return null;
  const total = sumHalalas(rows.map((r) => r.amount));
  const salary = sumHalalas(rows.filter((r) => r.kind === 'salary').map((r) => r.amount));
  const surplus = total - spent;

  async function remove(id: string) {
    try {
      await deleteIncome(id);
      await invalidate('incomes');
    } catch (e) {
      toast.error((e as Error).message);
    }
  }

  return (
    <Card>
      <Title icon={HandCoins}>دخلك</Title>
      <div className="grid grid-cols-3 gap-2 text-center">
        {[
          ['الدخل', total, ''],
          ['المصاريف', spent, ''],
          [surplus >= 0 ? 'الفائض' : 'العجز', Math.abs(surplus), surplus >= 0 ? 'text-brand' : 'text-danger'],
        ].map(([label, v, tone]) => (
          <div key={label as string} className="min-w-0 rounded-2xl bg-surface-2 px-1.5 py-3">
            <p className={cx('num break-words text-sm font-bold', tone as string)}>{formatSAR(v as number)}</p>
            <p className="text-xs text-muted">{label}</p>
          </div>
        ))}
      </div>
      {total > 0 && surplus > 0 && (
        <p className="mt-2 text-sm">نسبة الادخار <b className="num">{Math.round((surplus / total) * 100)}%</b>{salary > 0 && salary !== total && <> · الراتب {formatSAR(salary)}</>}</p>
      )}
      <ul className="mt-3 divide-y divide-line/70">
        {rows.map((r) => (
          <li key={r.id} className="flex items-center gap-2 py-2 text-sm">
            <span className="min-w-0 flex-1 truncate">
              <b>{INCOME_LABEL[r.kind]}</b>{r.payer && <span className="text-muted" dir="auto"> · {r.payer}</span>}
              <span className="text-xs text-muted"> · {formatDayShort(r.income_date)}</span>
            </span>
            <span className="num shrink-0 font-semibold">{formatSAR(r.amount)}</span>
            <button type="button" aria-label="حذف" onClick={() => remove(r.id)} className="shrink-0 p-1 text-muted">
              <Trash className="size-4" weight="bold" />
            </button>
          </li>
        ))}
      </ul>
    </Card>
  );
}

/** الاشتراكات والمدفوعات المتكررة: التكلفة الشهرية والسنوية، وما زاد سعره أو تكرر نوعه */
function SubscriptionsCard({ list }: { list: Expense[] }) {
  const isOwner = useIsOwner();
  const { data: fixed = [] } = useRecurring();
  const { data: renewals = [] } = useRenewals();
  const { data: categories = [] } = useCategories();
  const save = useSaveRecurring();
  const [added, setAdded] = useState<Set<string>>(new Set());
  const names = new Set(fixed.map((r) => r.name.trim().toLowerCase()));
  const guesses = detectRecurring(list).filter((g) => !names.has(g.label.trim().toLowerCase()) && !added.has(g.key));
  const audit = useMemo(() => subscriptionAudit(guesses, list, fixed, renewals), [guesses, list, fixed, renewals]);
  if (audit.items.length === 0) return null;
  return (
    <Card>
      <Title icon={Repeat}>الاشتراكات والمدفوعات المتكررة</Title>
      <p className="-mt-1 mb-3 text-sm text-muted">
        شهرياً <b className="num text-ink">{formatSAR(audit.monthly)}</b> · سنوياً <b className="num text-ink">{formatSAR(audit.yearly)}</b>
      </p>
      {audit.duplicates.length > 0 && (
        <div className="mb-3 flex flex-wrap gap-1.5">
          {audit.duplicates.map((d) => (
            <span key={d.label} className="rounded-full bg-warn-soft px-2.5 py-1 text-xs font-semibold text-warn">{d.count} اشتراكات {d.label}</span>
          ))}
        </div>
      )}
      <ul className="space-y-2">
        {audit.items.map((i) => (
          <li key={i.key} className="flex items-center gap-3 rounded-2xl bg-surface-2 px-3 py-2.5">
            <CategoryIcon category={categories.find((c) => c.id === i.categoryId)} size="sm" />
            <span className="min-w-0 flex-1">
              <span className="flex items-center gap-1.5">
                <span className="truncate font-semibold" dir="auto">{i.name}</span>
                {i.increased && <span className="shrink-0 rounded-full bg-danger-soft px-2 py-0.5 text-[10px] font-semibold text-danger">زاد السعر</span>}
                {i.source === 'fixed' && <span className="shrink-0 rounded-full bg-brand-soft px-2 py-0.5 text-[10px] font-semibold text-brand">ثابت</span>}
                {i.source === 'renewal' && <span className="shrink-0 rounded-full bg-brand-soft px-2 py-0.5 text-[10px] font-semibold text-brand">سنوي</span>}
              </span>
              <span className="text-xs text-muted">{formatSAR(i.monthly)} شهرياً · {formatSAR(i.yearly)} سنوياً</span>
            </span>
            {isOwner && i.guess && (
              <Button variant="secondary" className="h-9 shrink-0 px-3 text-xs" loading={save.isPending}
                onClick={() => {
                  const g = i.guess!;
                  save.mutate(
                    { input: { name: g.label.slice(0, 60), amount: g.typical, category_id: g.categoryId, day_of_month: Number(g.lastDate.slice(8, 10)), is_active: true } },
                    { onSuccess: () => setAdded((s) => new Set(s).add(g.key)) },
                  );
                }}>
                <Plus className="size-4" weight="bold" /> للثابتة
              </Button>
            )}
          </li>
        ))}
      </ul>
    </Card>
  );
}

function HabitsCard({ list, prev, days, categories, month }: {
  list: Expense[]; prev: Expense[]; days: number; categories: Parameters<typeof habits>[2]; month: MonthKey;
}) {
  const rows = habits(list, prev, categories, days);
  if (rows.length === 0) return null;
  return (
    <Card>
      <Title icon={Lightning}>عاداتك هذا الشهر</Title>
      <ul className="space-y-3">
        {rows.map((h) => {
          const diff = h.prevCount ? h.count - h.prevCount : null;
          return (
            <li key={h.category.id}>
              <Link to={`/expenses?cat=${h.category.id}&month=${month}&kind=regular`}
                className="-mx-2 flex items-center gap-3 rounded-2xl px-2 py-1 transition hover:bg-surface-2 active:bg-surface-2">
              <CategoryIcon category={h.category} size="sm" />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-sm font-semibold">{h.category.name}</span>
                <span className="text-xs text-muted">{h.count} مرة · {h.perWeek} بالأسبوع · متوسط {formatSAR(h.avgTicket)}</span>
              </span>
              {diff !== null && diff !== 0 && (
                <span className={cx('shrink-0 text-xs font-semibold', diff > 0 ? 'text-danger' : 'text-brand')}>
                  {diff > 0 ? `+${diff}` : diff} عن الشهر الماضي
                </span>
              )}
              </Link>
            </li>
          );
        })}
      </ul>
    </Card>
  );
}

function UnusualCard({ list, history }: { list: Expense[]; history: Expense[] }) {
  const rows = unusualSpending(list, history);
  if (rows.length === 0) return null;
  return (
    <Card>
      <Title icon={Warning}>أعلى من المعتاد</Title>
      <ul className="space-y-2 text-sm">
        {rows.map(({ expense, usual, ratio }) => (
          <li key={expense.id} className="flex items-center justify-between gap-2">
            <span className="min-w-0 truncate" dir="auto">{merchantLabel(expense) ?? "—"} · {formatDayShort(expense.expense_date)}</span>
            <span className="shrink-0 text-xs text-muted">
              <b className="num text-ink">{formatSAR(expense.amount)}</b> · عادةً {formatSAR(usual)} (×{ratio.toFixed(1)})
            </span>
          </li>
        ))}
      </ul>
      <Link to="/expenses" className="mt-3 inline-flex items-center gap-0.5 text-sm font-semibold text-brand">العمليات <CaretLeft className="size-4" weight="bold" /></Link>
    </Card>
  );
}
