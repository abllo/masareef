import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { AirplaneTilt, CalendarCheck, CaretLeft, ChartBar, Lightning, Plus, Repeat, ShieldCheck, Warning } from '@phosphor-icons/react';
import { AiReportCard, InsightsCard } from '../components/Insights';
import { Button, Card, CategoryIcon, MonthSwitcher, Spinner, cx } from '../components/ui';
import { useIsOwner } from '../hooks/household';
import { useCategories, useExpenses, useRecurring, useSaveRecurring } from '../hooks/queries';
import { WEEKDAYS, byWeekday, detectRecurring, firstDaysShare, habits, unusualSpending } from '../lib/behavior';
import { addMonths, daysInMonth, formatDayShort, monthEnd, monthOf, todayISO } from '../lib/dates';
import { formatSAR, sumHalalas } from '../lib/money';
import { merchantLabel, splitTravel } from '../lib/stats';
import type { Expense, MonthKey } from '../lib/types';

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
          <WhenCard list={inMonth} />
          <RecurringCard list={regular} />
          <HabitsCard list={inMonth} prev={prevMonth} days={days} categories={categories} />
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

/** مدفوعات تتكرر كل شهر وما هي ضمن الثابتة */
function RecurringCard({ list }: { list: Expense[] }) {
  const isOwner = useIsOwner();
  const { data: fixed = [] } = useRecurring();
  const { data: categories = [] } = useCategories();
  const save = useSaveRecurring();
  const [added, setAdded] = useState<Set<string>>(new Set());
  const names = new Set(fixed.map((r) => r.name.trim().toLowerCase()));
  const guesses = detectRecurring(list).filter((g) => !names.has(g.label.trim().toLowerCase()) && !added.has(g.key));
  if (guesses.length === 0) return null;
  return (
    <Card>
      <Title icon={Repeat}>مدفوعات تتكرر كل شهر</Title>
      <ul className="space-y-2">
        {guesses.map((g) => (
          <li key={g.key} className="flex items-center gap-3 rounded-2xl bg-surface-2 px-3 py-2.5">
            <CategoryIcon category={categories.find((c) => c.id === g.categoryId)} size="sm" />
            <span className="min-w-0 flex-1">
              <span className="block truncate font-semibold" dir="auto">{g.label}</span>
              <span className="text-xs text-muted">{formatSAR(g.typical)} · {g.months} أشهر · آخرها {formatDayShort(g.lastDate)}</span>
            </span>
            {isOwner && (
              <Button variant="secondary" className="h-9 shrink-0 px-3 text-xs" loading={save.isPending}
                onClick={() => save.mutate(
                  { input: { name: g.label.slice(0, 60), amount: g.typical, category_id: g.categoryId, day_of_month: Number(g.lastDate.slice(8, 10)), is_active: true } },
                  { onSuccess: () => setAdded((s) => new Set(s).add(g.key)) },
                )}>
                <Plus className="size-4" weight="bold" /> للثابتة
              </Button>
            )}
          </li>
        ))}
      </ul>
    </Card>
  );
}

function HabitsCard({ list, prev, days, categories }: {
  list: Expense[]; prev: Expense[]; days: number; categories: Parameters<typeof habits>[2];
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
            <li key={h.category.id} className="flex items-center gap-3">
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
