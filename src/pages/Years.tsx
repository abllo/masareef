import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { toast } from 'sonner';
import { useQueryClient } from '@tanstack/react-query';
import {
  AirplaneTilt, Archive, Bank, ChartBar, CheckCircle, CreditCard, FileXls, Globe, Storefront, TrendDown, TrendUp, Users, Warning,
} from '@phosphor-icons/react';
import { MonthlyByYear, YearTotalsBars } from '../components/YearCharts';
import { BackButton, Button, Card, CategoryIcon, EmptyState, Field, Sheet, Spinner, cx } from '../components/ui';
import { useHousehold, useIsOwner } from '../hooks/household';
import { EXPENSE_DEPENDENT, useCards, useCategories, useTrips, useYears } from '../hooks/queries';
import { archiveYear, fetchAllExpenses } from '../lib/api';
import { flag } from '../lib/countries';
import { formatDayShort, todayISO } from '../lib/dates';
import { exportExcel } from '../lib/export';
import { formatSAR } from '../lib/money';
import { BANK_LABELS, CARD_TYPE_LABELS } from '../lib/stats';
import type { Category, YearOverview } from '../lib/types';
import { categoryChanges, compareYears, monthlyAverage, periodLabel } from '../lib/years';

function Change({ ratio }: { ratio: number | null }) {
  if (ratio === null || !Number.isFinite(ratio)) return null;
  const pct = Math.round(Math.abs(ratio) * 100);
  if (pct === 0) return <span className="text-xs text-muted">بدون تغيير</span>;
  return (
    <span className={cx('inline-flex items-center gap-0.5 text-xs font-semibold', ratio > 0 ? 'text-danger' : 'text-brand')}>
      {ratio > 0 ? <TrendUp className="size-3.5" weight="bold" /> : <TrendDown className="size-3.5" weight="bold" />}{pct}%
    </span>
  );
}

function Bars({ rows, total }: { rows: { key: string; label: string; total: number; sub?: string }[]; total: number }) {
  return (
    <ul className="space-y-2.5">
      {rows.map((r) => (
        <li key={r.key}>
          <div className="flex justify-between gap-2 text-sm">
            <span className="truncate font-medium" dir="auto">{r.label}</span>
            <span className="num shrink-0 font-semibold">{formatSAR(r.total)}</span>
          </div>
          <div className="mt-1 flex items-center gap-2">
            <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-surface-2">
              <div className="h-full rounded-full bg-brand/70" style={{ width: `${total ? Math.max(3, (r.total / total) * 100) : 0}%` }} />
            </div>
            {r.sub && <span className="num shrink-0 text-xs text-muted" dir="ltr">{r.sub}</span>}
          </div>
        </li>
      ))}
    </ul>
  );
}

export default function YearsPage() {
  const today = todayISO();
  const thisYear = Number(today.slice(0, 4));
  const { data: years = [], isPending } = useYears();
  const [picked, setPicked] = useState<number | null>(null);
  const selected = years.find((y) => y.year === picked) ?? years[0];

  if (isPending) return <Spinner />;
  if (!selected) {
    return (
      <div className="space-y-4 pt-4">
        <header className="flex items-center gap-2"><BackButton /><h1 className="text-xl font-bold">المقارنة السنوية</h1></header>
        <EmptyState icon={ChartBar} title="لا توجد بيانات" />
      </div>
    );
  }
  const prev = years.find((y) => y.year === selected.year - 1);

  return (
    <div className="space-y-5 pt-4">
      <header className="space-y-3">
        <div className="flex items-center gap-2">
          <BackButton />
          <h1 className="text-xl font-bold">المقارنة السنوية</h1>
        </div>
        <div className="flex gap-2 overflow-x-auto pb-1">
          {years.map((y) => (
            <button key={y.year} type="button" onClick={() => setPicked(y.year)} aria-pressed={y.year === selected.year}
              className={cx('h-10 shrink-0 rounded-full px-4 text-sm font-semibold transition',
                y.year === selected.year ? 'bg-ink text-bg' : 'bg-surface shadow-sm')}>
              {y.year}{y.archived && ' 🗄️'}
            </button>
          ))}
        </div>
      </header>

      <YearHero year={selected} prev={prev} today={today} />

      {years.length > 1 && (
        <Card>
          <h2 className="mb-2 font-bold">إجمالي كل سنة</h2>
          <YearTotalsBars rows={years.map((y) => ({ year: y.year, total: y.data.total }))} selected={selected.year} onSelect={setPicked} />
        </Card>
      )}

      <Card>
        <h2 className="mb-3 font-bold">الصرف الشهري{years.length > 1 ? ' مقارنة بالسنوات السابقة' : ''}</h2>
        <MonthlyByYear years={years.filter((y) => y.year <= selected.year).slice(0, 3)} currentYear={thisYear}
          currentMonth={Number(today.slice(5, 7))} />
      </Card>

      <YearDetails year={selected} prev={prev} today={today} />

      {selected.year < thisYear && !selected.archived && selected.data.count > 0 && <ArchiveCard year={selected} />}
    </div>
  );
}

function YearHero({ year, prev, today }: { year: YearOverview; prev?: YearOverview; today: string }) {
  const d = year.data;
  const cmp = compareYears(d, prev?.data, today);
  const travel = d.travel_total ?? 0;
  return (
    <section className="hero relative overflow-hidden rounded-card p-5 text-white shadow-lg shadow-brand/20">
      <p className="text-sm text-white/75">
        مصاريف {year.year}{year.archived && ` · مؤرشفة${year.archived_at ? ` ${formatDayShort(year.archived_at.slice(0, 10))}` : ''}`}
      </p>
      <p className="num mt-1 text-4xl font-bold tracking-tight">{formatSAR(d.total)}</p>
      <p className="mt-1 text-sm text-white/80">{d.count.toLocaleString('en')} عملية · متوسط الشهر {formatSAR(monthlyAverage(d))}</p>
      {travel > 0 && (
        <p className="mt-2 inline-flex items-center gap-1.5 rounded-full bg-white/12 px-2.5 py-1 text-xs">
          <AirplaneTilt className="size-4" /> منها سفر {formatSAR(travel)} · مصاريف عادية {formatSAR(d.regular_total ?? d.total - travel)}
        </p>
      )}
      {cmp && cmp.ratio !== null && (
        <p className="mt-3 rounded-2xl bg-white/10 px-3 py-2 text-sm">
          {cmp.ratio >= 0 ? 'أعلى' : 'أقل'} من {prev!.year} بـ <span className="num font-bold">{Math.abs(Math.round(cmp.ratio * 100))}%</span>
          <span className="text-white/75"> ({periodLabel(cmp)}: {formatSAR(cmp.current)} مقابل {formatSAR(cmp.previous)})</span>
        </p>
      )}
    </section>
  );
}

function YearDetails({ year, prev, today }: { year: YearOverview; prev?: YearOverview; today: string }) {
  const d = year.data;
  const { data: categories = [] } = useCategories();
  const cmp = compareYears(d, prev?.data, today);
  const cats = categoryChanges(d, prev?.data, cmp);
  const catOf = (c: (typeof cats)[number]): Category =>
    categories.find((x) => x.id === c.key) ?? { id: c.key, household_id: '', name: c.name, icon: c.icon, color: c.color, sort_order: 0, is_archived: false };

  return (
    <div className="grid gap-5 lg:grid-cols-2">
      <Card>
        <h2 className="mb-1 font-bold">التصنيفات</h2>
        {cmp && <p className="mb-3 text-xs text-muted">التغيّر مقارنة بـ {prev!.year} ({periodLabel(cmp)})</p>}
        <ul className="space-y-3">
          {cats.map((c) => (
            <li key={c.key} className="flex items-center gap-3">
              <CategoryIcon category={catOf(c)} size="sm" />
              <span className="min-w-0 flex-1 truncate text-sm font-medium">{c.name}</span>
              <Change ratio={c.ratio} />
              <span className="num w-24 text-end text-sm font-semibold">{formatSAR(c.total)}</span>
            </li>
          ))}
        </ul>
      </Card>

      <Card className="space-y-5">
        {d.merchants.length > 0 && (
          <section>
            <h2 className="mb-3 inline-flex items-center gap-2 font-bold"><Storefront className="size-5 text-brand" weight="duotone" />أكثر المتاجر</h2>
            <Bars total={d.merchants[0]!.total} rows={d.merchants.slice(0, 8).map((m) => ({ key: m.merchant, label: m.merchant, total: m.total, sub: `${m.count}×` }))} />
          </section>
        )}
        {(d.trips?.length ?? 0) > 0 && (
          <section>
            <h2 className="mb-3 inline-flex items-center gap-2 font-bold"><AirplaneTilt className="size-5 text-brand" weight="duotone" />الرحلات</h2>
            <ul className="space-y-2">
              {d.trips!.map((t) => (
                <li key={t.id}>
                  <Link to={`/trips/${t.id}`} className="flex items-center justify-between gap-2 rounded-2xl bg-surface-2 px-3 py-2 text-sm">
                    <span className="min-w-0 truncate font-medium">{t.name} {t.countries.map(flag).join(' ')}</span>
                    <span className="num shrink-0 font-semibold">{formatSAR(t.total)}</span>
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        )}
      </Card>

      <Card className="space-y-5">
        {d.banks.length > 0 && (
          <section>
            <h2 className="mb-3 inline-flex items-center gap-2 font-bold"><Bank className="size-5 text-brand" weight="duotone" />البنوك</h2>
            <Bars total={d.total} rows={d.banks.map((b) => ({
              key: b.bank, total: b.total, sub: `${b.count}×`,
              label: b.bank === 'manual' ? 'إدخال يدوي' : b.bank === 'unknown' ? 'بنك غير معروف' : BANK_LABELS[b.bank] ?? b.bank,
            }))} />
          </section>
        )}
        {d.cards.length > 0 && (
          <section>
            <h2 className="mb-3 inline-flex items-center gap-2 font-bold"><CreditCard className="size-5 text-brand" weight="duotone" />البطاقات</h2>
            <Bars total={d.total} rows={d.cards.map((c) => ({
              key: c.card_last4, total: c.total, sub: `${c.count}×`,
              label: [c.bank && BANK_LABELS[c.bank], c.card_type && CARD_TYPE_LABELS[c.card_type], `•${c.card_last4}`].filter(Boolean).join(' · '),
            }))} />
          </section>
        )}
      </Card>

      <Card className="space-y-5">
        {d.members.length > 1 && (
          <section>
            <h2 className="mb-3 inline-flex items-center gap-2 font-bold"><Users className="size-5 text-brand" weight="duotone" />حسب الشخص</h2>
            <Bars total={d.total} rows={d.members.map((m) => ({ key: m.member, label: m.member, total: m.total, sub: `${m.count}×` }))} />
          </section>
        )}
        {d.foreign.length > 0 && (
          <section>
            <h2 className="mb-3 inline-flex items-center gap-2 font-bold"><Globe className="size-5 text-brand" weight="duotone" />العملات الأجنبية</h2>
            <Bars total={d.total} rows={d.foreign.map((f) => ({
              key: f.currency, label: f.currency, total: f.total,
              sub: `${Number(f.original).toLocaleString('en', { maximumFractionDigits: 2 })} ${f.currency}`,
            }))} />
          </section>
        )}
        {d.largest.length > 0 && (
          <section>
            <h2 className="mb-3 font-bold">أكبر العمليات</h2>
            <ul className="divide-y divide-line/70 text-sm">
              {d.largest.slice(0, 5).map((l, i) => (
                <li key={i} className="flex items-center justify-between gap-2 py-2">
                  <span className="min-w-0">
                    <span className="block truncate font-medium" dir="auto">{l.merchant}</span>
                    <span className="text-xs text-muted">{l.category} · {formatDayShort(l.date)}</span>
                  </span>
                  <span className="num shrink-0 font-semibold">{formatSAR(l.total)}</span>
                </li>
              ))}
            </ul>
          </section>
        )}
      </Card>
    </div>
  );
}

function ArchiveCard({ year }: { year: YearOverview }) {
  const isOwner = useIsOwner();
  const [open, setOpen] = useState(false);
  if (!isOwner) return null;
  return (
    <Card className="space-y-3">
      <h2 className="inline-flex items-center gap-2 font-bold"><Archive className="size-5 text-brand" weight="duotone" />أرشفة {year.year}</h2>
      <p className="text-sm leading-relaxed text-muted">يحفظ ملخص السنة ويحذف عملياتها وفواتيرها.</p>
      <Button variant="secondary" onClick={() => setOpen(true)}><Archive className="size-5" weight="bold" /> أرشفة {year.year}…</Button>
      <Sheet open={open} onOpenChange={setOpen} title={`أرشفة ${year.year}`}>
        <ArchiveFlow year={year} onDone={() => setOpen(false)} />
      </Sheet>
    </Card>
  );
}

function ArchiveFlow({ year, onDone }: { year: YearOverview; onDone: () => void }) {
  const { household, members } = useHousehold();
  const { data: categories = [] } = useCategories();
  const { data: cardRows = [] } = useCards();
  const { data: trips = [] } = useTrips();
  const qc = useQueryClient();
  const cards = useMemo(() => new Map(cardRows.map((c) => [c.card_last4, c])), [cardRows]);
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState<'excel' | 'archive' | null>(null);
  const [confirm, setConfirm] = useState('');
  const y = year.year;

  async function downloadExcel() {
    setBusy('excel');
    try {
      const expenses = await fetchAllExpenses(household.id, `${y}-01-01`, `${y}-12-31`);
      const result = await exportExcel(
        { title: `مصاريف ${household.name}`, periodLabel: `سنة ${y}`, expenses, categories, members, cards, trips },
        `مصاريف-${y}-كاملة.xlsx`);
      if (result === 'cancelled') return;
      if (typeof result === 'object') {
        toast('ملف Excel جاهز', { duration: 20000, action: { label: 'حفظ / مشاركة', onClick: () => void result.retry().then(() => setSaved(true)) } });
        return;
      }
      setSaved(true);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function archive() {
    setBusy('archive');
    try {
      const r = await archiveYear(y, confirm.trim());
      toast.success(`تمت أرشفة ${y}: حُذفت ${r.deleted.toLocaleString('en')} عملية، والملخص محفوظ`);
      if (r.receiptsLeft > 0) toast.warning(`تعذّر حذف ${r.receiptsLeft} صورة فاتورة من التخزين`);
      await Promise.all(['years', ...EXPENSE_DEPENDENT, 'sms-log'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      onDone();
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="space-y-4 pb-2">
      <div className="grid grid-cols-2 gap-2 text-sm">
        <div className="rounded-2xl bg-surface-2 p-3">
          <p className="font-semibold text-brand">يبقى دائماً ✓</p>
          <p className="mt-1 text-xs leading-relaxed text-muted">ملخص السنة كاملاً في المقارنة السنوية.</p>
        </div>
        <div className="rounded-2xl bg-danger-soft p-3">
          <p className="font-semibold text-danger">يُحذف نهائياً</p>
          <p className="mt-1 text-xs leading-relaxed text-danger/80">{year.data.count.toLocaleString('en')} عملية ({formatSAR(year.data.total)})، وصور فواتيرها، وسجل رسائلها.</p>
        </div>
      </div>

      <div className={cx('flex items-center gap-3 rounded-2xl border p-3', saved ? 'border-brand bg-brand-soft' : 'border-line')}>
        <span className="flex size-8 shrink-0 items-center justify-center rounded-full bg-surface font-bold">١</span>
        <p className="min-w-0 flex-1 text-sm">نسخة Excel كاملة من عمليات {y}</p>
        {saved ? <CheckCircle className="size-6 text-brand" weight="fill" /> : (
          <Button variant="secondary" className="h-10 shrink-0 px-3 text-sm" loading={busy === 'excel'} onClick={downloadExcel}>
            <FileXls className="size-5 text-[#1D7044]" weight="duotone" /> Excel
          </Button>
        )}
      </div>

      <div className={cx('space-y-2 rounded-2xl border p-3', saved ? 'border-line' : 'border-line opacity-50')}>
        <div className="flex items-center gap-3">
          <span className="flex size-8 shrink-0 items-center justify-center rounded-full bg-surface-2 font-bold">٢</span>
          <p className="text-sm">اكتب <span className="num font-bold">{y}</span> للتأكيد</p>
        </div>
        <Field label="رقم السنة" inputMode="numeric" dir="ltr" placeholder={String(y)} value={confirm} disabled={!saved}
          onChange={(e) => setConfirm(e.target.value)} />
      </div>

      <Button variant="danger" className="w-full" loading={busy === 'archive'} disabled={!saved || confirm.trim() !== String(y)} onClick={archive}>
        <Warning className="size-5" weight="bold" /> أرشف {y} واحذف عملياتها
      </Button>
      <p className="text-center text-xs text-muted">لا يمكن التراجع عن الحذف.</p>
    </div>
  );
}
