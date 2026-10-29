import { useMemo, useState } from 'react';
import { toast } from 'sonner';
import { CalendarDots, FilePdf, FileXls, FunnelSimple, MagnifyingGlass, Receipt, Tag, User, X } from '@phosphor-icons/react';
import { ExpenseGroups } from '../components/ExpenseList';
import { Button, EmptyState, IconButton, MonthSwitcher, Select, Spinner } from '../components/ui';
import { useHousehold } from '../hooks/household';
import { useCategories, useExpenses } from '../hooks/queries';
import { exportExcel, printReport } from '../lib/export';
import { formatDayShort, formatMonth, monthEnd, monthOf, todayISO } from '../lib/dates';
import { formatSAR, sumHalalas } from '../lib/money';
import { filterExpenses } from '../lib/stats';
import type { MonthKey } from '../lib/types';

export default function Expenses() {
  const today = todayISO();
  const { household, members } = useHousehold();
  const { data: categories = [] } = useCategories();

  const [month, setMonth] = useState<MonthKey>(monthOf(today));
  const [custom, setCustom] = useState(false);
  const [range, setRange] = useState({ from: month, to: monthEnd(month) });
  const [query, setQuery] = useState('');
  const [categoryId, setCategoryId] = useState('');
  const [memberId, setMemberId] = useState('');
  const [exporting, setExporting] = useState(false);

  const from = custom ? range.from : month;
  const to = custom ? range.to : monthEnd(month);
  const { data = [], isPending } = useExpenses(from, to);

  const filtered = useMemo(
    () => filterExpenses(data, { query, categoryId: categoryId || null, memberId: memberId || null }, categories),
    [data, query, categoryId, memberId, categories],
  );
  const total = sumHalalas(filtered.map((e) => e.amount));
  const periodLabel = custom ? `${formatDayShort(from)} – ${formatDayShort(to)}` : formatMonth(month);
  const hasFilters = Boolean(query || categoryId || memberId);

  const report = () => ({ title: `مصاريف ${household.name}`, periodLabel, expenses: filtered, categories, members });

  async function onExcel() {
    setExporting(true);
    try {
      await exportExcel(report(), `مصاريف-${from}-${to}.xlsx`);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setExporting(false);
    }
  }

  function onPdf() {
    try { printReport(report()); } catch (e) { toast.error((e as Error).message); }
  }

  return (
    <div className="space-y-4 pt-4">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-bold">العمليات</h1>
        <div className="flex items-center gap-1">
          {!custom && <MonthSwitcher month={month} onChange={setMonth} />}
          <IconButton label={custom ? 'العودة للعرض الشهري' : 'نطاق تاريخ مخصص'}
            onClick={() => { setCustom(!custom); setRange({ from: month, to: monthEnd(month) }); }}
            className={custom ? 'bg-brand-soft text-brand' : 'bg-surface shadow-sm'}>
            <CalendarDots className="size-5" weight={custom ? 'fill' : 'regular'} />
          </IconButton>
        </div>
      </header>

      {custom && (
        <div className="grid grid-cols-2 gap-2">
          <label className="text-sm text-muted">من
            <input type="date" value={range.from} max={range.to} onChange={(e) => e.target.value && setRange({ ...range, from: e.target.value })}
              className="mt-1 h-12 w-full rounded-2xl border border-line bg-surface px-3 text-base text-ink" />
          </label>
          <label className="text-sm text-muted">إلى
            <input type="date" value={range.to} min={range.from} onChange={(e) => e.target.value && setRange({ ...range, to: e.target.value })}
              className="mt-1 h-12 w-full rounded-2xl border border-line bg-surface px-3 text-base text-ink" />
          </label>
        </div>
      )}

      <div className="relative">
        <MagnifyingGlass className="pointer-events-none absolute start-4 top-1/2 size-5 -translate-y-1/2 text-muted" />
        <input type="search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="ابحث في الوصف أو التصنيف أو المبلغ"
          className="h-12 w-full rounded-2xl border border-line bg-surface ps-11 pe-4 text-base outline-none focus:border-brand focus:ring-4 focus:ring-brand/10" />
      </div>

      <div className="grid grid-cols-2 gap-2">
        <Select label="التصنيف" icon={Tag} value={categoryId} onChange={setCategoryId}
          options={[{ value: '', label: 'كل التصنيفات' }, ...categories.map((c) => ({ value: c.id, label: c.name }))]} />
        <Select label="الشخص" icon={User} value={memberId} onChange={setMemberId}
          options={[{ value: '', label: 'الجميع' }, ...members.map((m) => ({ value: m.user_id, label: m.display_name }))]} />
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3 rounded-card bg-surface px-5 py-4 shadow-[0_1px_2px_rgb(0_0_0/0.04)]">
        <div>
          <p className="text-sm text-muted">{filtered.length} عملية{hasFilters && ' مطابقة'}</p>
          <p className="num text-2xl font-bold">{formatSAR(total)}</p>
        </div>
        <div className="flex gap-2">
          {hasFilters && (
            <Button variant="ghost" className="h-10 px-3 text-sm"
              onClick={() => { setQuery(''); setCategoryId(''); setMemberId(''); }}>
              <X className="size-4" weight="bold" /> مسح
            </Button>
          )}
          <Button variant="secondary" className="h-10 px-3 text-sm" onClick={onExcel} loading={exporting} disabled={!filtered.length}>
            <FileXls className="size-5 text-[#1D7044]" weight="duotone" /> Excel
          </Button>
          <Button variant="secondary" className="h-10 px-3 text-sm" onClick={onPdf} disabled={!filtered.length}>
            <FilePdf className="size-5 text-[#C2410C]" weight="duotone" /> PDF
          </Button>
        </div>
      </div>

      {isPending ? <Spinner /> : filtered.length === 0
        ? <EmptyState icon={hasFilters ? FunnelSimple : Receipt} title={hasFilters ? 'لا توجد نتائج مطابقة' : 'لا توجد عمليات في هذه الفترة'}>
            {hasFilters ? 'جرّب تغيير كلمات البحث أو التصفية' : 'اضغط زر + لإضافة مصروف'}
          </EmptyState>
        : <ExpenseGroups expenses={filtered} categories={categories} />}
    </div>
  );
}
