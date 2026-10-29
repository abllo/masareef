import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { Alarm, CaretLeft, ChartPieSlice, Receipt, Target, TrendDown, TrendUp } from '@phosphor-icons/react';
import { CategoryDonut, MonthlyBars } from '../components/Charts';
import { ExpenseRow } from '../components/ExpenseList';
import { useExpenseSheet } from '../components/Layout';
import { Logo } from '../components/Logo';
import { AnimatedAmount, Button, Card, CategoryIcon, EmptyState, MonthSwitcher, SectionTitle, Spinner, cx } from '../components/ui';
import { useHousehold } from '../hooks/household';
import { useCategories, useMonthExpenses, useMonthlyTotals, useRecurring, useRecurringPayments } from '../hooks/queries';
import { addMonths, formatMonth, lastMonths, monthOf, todayISO } from '../lib/dates';
import { formatSAR, sumHalalas } from '../lib/money';
import { recurringForMonth } from '../lib/recurring';
import { budgetStatus, byCategory, changeRatio, monthlySeries } from '../lib/stats';

export default function Dashboard() {
  const today = todayISO();
  const [month, setMonth] = useState(monthOf(today));
  const { household, me } = useHousehold();
  const openSheet = useExpenseSheet();

  const { data: categories = [] } = useCategories();
  const expenses = useMonthExpenses(month);
  const monthly = useMonthlyTotals(monthOf(today), 6);
  const recurring = useRecurring();
  const payments = useRecurringPayments(month);

  const list = expenses.data ?? [];
  const total = sumHalalas(list.map((e) => e.amount));
  const slices = useMemo(() => byCategory(list, categories), [list, categories]);
  const series = monthlySeries(monthly.data ?? [], lastMonths(monthOf(today), 6));
  const previous = series.find((s) => s.month === addMonths(month, -1))?.total ?? 0;
  const change = changeRatio(total, previous);
  const budget = budgetStatus(total, household.monthly_budget, month, today);
  const unpaid = recurringForMonth(recurring.data ?? [], payments.data ?? [], month, today).filter((r) => r.status !== 'paid');

  return (
    <div className="space-y-5 pt-4">
      <header className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2.5">
          <Logo className="size-10 md:hidden" />
          <div>
            <p className="text-xs text-muted">أهلاً</p>
            <p className="font-bold leading-tight">{me.display_name}</p>
          </div>
        </div>
        <MonthSwitcher month={month} onChange={setMonth} />
      </header>

      {/* البطاقة الرئيسية: إجمالي الشهر والميزانية */}
      <section className="hero relative overflow-hidden rounded-card p-5 shadow-lg shadow-brand/20">
        <div className="pointer-events-none absolute -left-10 -top-16 size-48 rounded-full bg-white/5" />
        <div className="pointer-events-none absolute -bottom-20 left-16 size-40 rounded-full bg-white/5" />

        <div className="relative">
          <p className="text-sm text-white/75">مصروف {formatMonth(month)}</p>
          <AnimatedAmount value={total} className="mt-1 block text-4xl font-bold tracking-tight md:text-5xl" />
          {change !== null && (
            <p className="mt-2 inline-flex items-center gap-1 rounded-full bg-white/12 px-2.5 py-1 text-xs font-medium">
              {change > 0 ? <TrendUp className="size-4" weight="bold" /> : <TrendDown className="size-4" weight="bold" />}
              {change > 0 ? 'أكثر' : 'أقل'} من الشهر السابق بـ {Math.abs(Math.round(change * 100))}%
            </p>
          )}

          {budget.level === 'none' ? (
            <Link to="/settings"
              className="mt-5 flex items-center gap-2 rounded-2xl bg-white/12 px-4 py-3 text-sm font-medium transition active:bg-white/20">
              <Target className="size-5" weight="duotone" />
              <span className="flex-1">حدّد ميزانية شهرية لمتابعة المتبقي</span>
              <CaretLeft className="size-4" weight="bold" />
            </Link>
          ) : (
            <div className="mt-5">
              <div className="mb-2 flex items-end justify-between gap-3">
                <div>
                  <p className="text-xs text-white/70">{budget.remaining! >= 0 ? 'المتبقي' : 'تجاوزتم الميزانية بـ'}</p>
                  <p className={cx('num text-xl font-bold', budget.level === 'over' && 'text-[#FFC9C2]')}>
                    {formatSAR(Math.abs(budget.remaining!))}
                  </p>
                </div>
                <p className="text-xs text-white/70">من <span className="num">{formatSAR(budget.budget!)}</span></p>
              </div>
              <div className="h-2.5 overflow-hidden rounded-full bg-white/15" role="progressbar"
                aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(Math.min(budget.ratio, 1) * 100)}>
                <div
                  className={cx('h-full rounded-full transition-[width] duration-700',
                    budget.level === 'over' ? 'bg-[#FF8A7A]' : budget.level === 'warn' ? 'bg-gold' : 'bg-white')}
                  style={{ width: `${Math.min(budget.ratio, 1) * 100}%` }}
                />
              </div>
              {budget.dailyAllowance !== null && (
                <p className="mt-2.5 text-xs text-white/80">
                  تقدرون تصرفون <span className="num font-semibold text-white">{formatSAR(budget.dailyAllowance)}</span> يومياً حتى آخر الشهر
                </p>
              )}
            </div>
          )}
        </div>
      </section>

      {unpaid.length > 0 && (
        <Link to="/recurring"
          className="flex items-center gap-3 rounded-card bg-warn-soft px-4 py-3.5 text-sm transition active:opacity-80">
          <span className="flex size-10 items-center justify-center rounded-2xl bg-warn/15 text-warn">
            <Alarm className="size-6" weight="duotone" />
          </span>
          <span className="flex-1 font-medium">
            {unpaid.length === 1 ? 'مصروف ثابت واحد لم يُدفع' : `${unpaid.length} مصاريف ثابتة لم تُدفع`}
          </span>
          <span className="num font-bold">{formatSAR(sumHalalas(unpaid.map((u) => u.item.amount)))}</span>
          <CaretLeft className="size-4 text-muted" weight="bold" />
        </Link>
      )}

      {expenses.isPending ? <Spinner /> : list.length === 0 ? (
        <EmptyState icon={Receipt} title={`لا توجد مصروفات في ${formatMonth(month)}`}>
          سجّلوا أول مصروف، وستظهر هنا الإحصائيات والرسوم.
          <div className="mt-4"><Button onClick={() => openSheet()}>إضافة مصروف</Button></div>
        </EmptyState>
      ) : (
        <div className="grid gap-5 lg:grid-cols-2">
          <Card>
            <SectionTitle><span className="inline-flex items-center gap-2"><ChartPieSlice className="size-5 text-brand" weight="duotone" />حسب التصنيف</span></SectionTitle>
            <CategoryDonut slices={slices} total={total} />
            <ul className="mt-5 space-y-3.5">
              {slices.map((s) => (
                <li key={s.categoryId} className="flex items-center gap-3">
                  <CategoryIcon category={s.category} size="sm" />
                  <div className="min-w-0 flex-1">
                    <div className="flex justify-between gap-2 text-sm">
                      <span className="truncate font-semibold">{s.category?.name ?? '—'}</span>
                      <span className="num shrink-0 font-bold">{formatSAR(s.total)}</span>
                    </div>
                    <div className="mt-1.5 flex items-center gap-2">
                      <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-surface-2">
                        <div className="h-full rounded-full transition-[width] duration-700" style={{ width: `${s.percent}%`, background: s.category?.color }} />
                      </div>
                      <span className="num w-9 text-end text-xs text-muted">{s.percent}%</span>
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          </Card>

          <div className="space-y-5">
            <Card>
              <SectionTitle>آخر 6 أشهر</SectionTitle>
              <MonthlyBars data={series} selected={month} onSelect={setMonth} />
            </Card>
            <Card className="p-3">
              <div className="flex items-center justify-between px-2 pb-1 pt-2">
                <h2 className="font-bold">أحدث العمليات</h2>
                <Link to="/expenses" className="inline-flex items-center gap-0.5 text-sm font-semibold text-brand">
                  الكل <CaretLeft className="size-4" weight="bold" />
                </Link>
              </div>
              {list.slice(0, 6).map((e) => (
                <ExpenseRow key={e.id} expense={e} category={categories.find((c) => c.id === e.category_id)} />
              ))}
            </Card>
          </div>
        </div>
      )}
    </div>
  );
}
