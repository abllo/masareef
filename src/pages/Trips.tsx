import { useMemo, useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams } from 'react-router';
import { toast } from 'sonner';
import { AirplaneTilt, CalendarBlank, CheckCircle, CreditCard, PencilSimple, Play, Stop, Trash } from '@phosphor-icons/react';
import { ExpenseGroups } from '../components/ExpenseList';
import { BackButton, Button, Card, CategoryIcon, ConfirmButton, EmptyState, Field, Sheet, Spinner, cx } from '../components/ui';
import { useIsOwner, useMemberName } from '../hooks/household';
import { useCards, useCategories, useTripActions, useTripExpenses, useTrips } from '../hooks/queries';
import { countryName, flag } from '../lib/countries';
import { formatDayShort, todayISO } from '../lib/dates';
import { formatSAR, parseAmount, sumHalalas, toInputValue } from '../lib/money';
import { byCategory, byCurrency, byPaymentMethod, groupByDay, tripDays } from '../lib/stats';
import type { Trip } from '../lib/types';

const flags = (t: Trip) => t.countries.map(flag).join(' ');
const places = (t: Trip) => t.countries.map((c) => countryName(c)).join('، ');

function BudgetBar({ spent, budget }: { spent: number; budget: number | null }) {
  if (!budget) return null;
  const ratio = spent / budget;
  return (
    <div className="space-y-1">
      <div className="h-2 overflow-hidden rounded-full bg-surface-2">
        <div className={cx('h-full rounded-full', ratio >= 1 ? 'bg-danger' : ratio >= 0.8 ? 'bg-warn' : 'bg-brand')}
          style={{ width: `${Math.min(100, Math.max(3, ratio * 100))}%` }} />
      </div>
      <p className={cx('text-xs', ratio >= 1 ? 'text-danger' : 'text-muted')}>
        {ratio >= 1 ? `أعلى من الميزانية بـ ${formatSAR(spent - budget)}` : `المتبقي ${formatSAR(budget - spent)} من ${formatSAR(budget)}`}
      </p>
    </div>
  );
}

export default function TripsPage() {
  const { id } = useParams();
  return id ? <TripDetail id={id} /> : <TripList />;
}

function TripList() {
  const { data: trips = [], isPending } = useTrips();
  return (
    <div className="space-y-4 pt-4">
      <header>
        <div className="flex items-center gap-2">
          <BackButton />
          <h1 className="inline-flex items-center gap-2 text-xl font-bold"><AirplaneTilt className="size-6 text-brand" weight="duotone" />الرحلات</h1>
        </div>
      </header>
      {isPending ? <Spinner /> : trips.length === 0 ? (
        <EmptyState icon={AirplaneTilt} title="لا توجد رحلات" />
      ) : (
        <div className="space-y-3">{trips.map((t) => <TripCard key={t.id} trip={t} />)}</div>
      )}
    </div>
  );
}

function TripCard({ trip }: { trip: Trip }) {
  const { data: list = [] } = useTripExpenses(trip.id);
  const total = sumHalalas(list.map((e) => e.amount));
  const end = trip.end_date ?? todayISO();
  return (
    <Link to={`/trips/${trip.id}`} className="block rounded-card bg-surface p-4 shadow-[0_1px_2px_rgb(0_0_0/0.04)] transition active:scale-[.99]">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate font-bold">{trip.name} <span className="font-normal">{flags(trip)}</span></p>
          <p className="mt-0.5 text-xs text-muted">
            {formatDayShort(trip.start_date)} – {trip.end_date ? formatDayShort(trip.end_date) : 'الآن'} · {tripDays(trip.start_date, end)} يوم · {list.length} عملية
          </p>
        </div>
        <div className="shrink-0 text-end">
          <p className="num font-bold">{formatSAR(total)}</p>
          <span className={cx('mt-1 inline-block rounded-full px-2 py-0.5 text-[11px] font-semibold',
            trip.status === 'active' ? 'bg-brand-soft text-brand' : 'bg-surface-2 text-muted')}>
            {trip.status === 'active' ? 'جارية' : 'انتهت'}
          </span>
        </div>
      </div>
      {trip.budget && <div className="mt-3"><BudgetBar spent={total} budget={trip.budget} /></div>}
    </Link>
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

function TripDetail({ id }: { id: string }) {
  const navigate = useNavigate();
  const isOwner = useIsOwner();
  const memberName = useMemberName();
  const { data: trips = [], isPending } = useTrips();
  const { data: list = [], isPending: loadingList } = useTripExpenses(id);
  const { data: categories = [] } = useCategories();
  const { data: cardRows = [] } = useCards();
  const actions = useTripActions();
  const [editing, setEditing] = useState(false);
  const trip = trips.find((t) => t.id === id);

  const cardMap = useMemo(() => new Map(cardRows.map((c) => [c.card_last4, c])), [cardRows]);
  const total = sumHalalas(list.map((e) => e.amount));
  const slices = useMemo(() => byCategory(list, categories), [list, categories]);
  const currencies = useMemo(() => byCurrency(list), [list]);
  const cards = useMemo(() => byPaymentMethod(list, cardMap), [list, cardMap]);
  const days = useMemo(() => groupByDay(list), [list]);
  const members = useMemo(() => {
    const m = new Map<string, number>();
    for (const e of list) m.set(e.created_by, (m.get(e.created_by) ?? 0) + e.amount);
    return [...m.entries()].sort((a, b) => b[1] - a[1]);
  }, [list]);

  if (isPending) return <Spinner />;
  if (!trip) return <EmptyState icon={AirplaneTilt} title="الرحلة غير موجودة"><Link to="/trips" className="text-brand">كل الرحلات</Link></EmptyState>;

  const end = trip.end_date ?? todayISO();
  const nDays = tripDays(trip.start_date, end);

  return (
    <div className="space-y-4 pt-4">
      <header className="flex items-center justify-between gap-2">
        <BackButton fallback="/trips" />
        {isOwner && (
          <Button variant="secondary" className="h-9 px-3 text-sm" onClick={() => setEditing(true)}>
            <PencilSimple className="size-4" weight="bold" /> تعديل
          </Button>
        )}
      </header>

      <section className="hero relative overflow-hidden rounded-card p-5 text-white shadow-lg shadow-brand/20">
        <p className="text-sm text-white/75">{flags(trip)} {places(trip) || 'خارج السعودية'}</p>
        <h1 className="mt-1 text-2xl font-bold">{trip.name}</h1>
        <p className="num mt-3 text-4xl font-bold tracking-tight">{formatSAR(total)}</p>
        <p className="mt-1 text-sm text-white/80">
          {list.length} عملية · {nDays} يوم · متوسط اليوم {formatSAR(Math.round(total / Math.max(nDays, 1)))}
        </p>
        <p className="mt-2 inline-flex items-center gap-1.5 text-xs text-white/75">
          <CalendarBlank className="size-4" /> {formatDayShort(trip.start_date)} – {trip.end_date ? formatDayShort(trip.end_date) : 'جارية الآن'}
          {trip.card_last4 && <><span aria-hidden>·</span><CreditCard className="size-4" /> بطاقة الرحلة •{trip.card_last4}</>}
        </p>
        {trip.budget && (
          <div className="mt-4 rounded-2xl bg-white/10 p-3 [&_.bg-surface-2]:bg-white/15 [&_.text-muted]:text-white/80">
            <BudgetBar spent={total} budget={trip.budget} />
          </div>
        )}
      </section>

      {isOwner && (
        <div className="flex flex-wrap gap-2">
          {trip.status === 'active' ? (
            <Button variant="secondary" className="h-10 px-4 text-sm" loading={actions.status.isPending}
              onClick={() => actions.status.mutate({ id: trip.id, active: false })}>
              <Stop className="size-4" weight="fill" /> إنهاء الرحلة
            </Button>
          ) : (
            <Button variant="secondary" className="h-10 px-4 text-sm" loading={actions.status.isPending}
              onClick={() => actions.status.mutate({ id: trip.id, active: true })}>
              <Play className="size-4" weight="fill" /> إرجاعها جارية
            </Button>
          )}
          <ConfirmButton className="h-10 px-4 text-sm" confirmText="تأكيد: مصاريفها ترجع للشهر" loading={actions.remove.isPending}
            onConfirm={() => actions.remove.mutate(trip.id, { onSuccess: () => navigate('/trips') })}>
            <Trash className="size-4" weight="bold" /> <span className="text-sm">حذف الرحلة</span>
          </ConfirmButton>
        </div>
      )}

      {loadingList ? <Spinner /> : list.length > 0 && (
        <div className="grid gap-4 md:grid-cols-2">
          <Card>
            <h2 className="mb-3 font-bold">حسب التصنيف</h2>
            <ul className="space-y-2.5">
              {slices.map((s) => (
                <li key={s.categoryId} className="flex items-center gap-3">
                  <CategoryIcon category={s.category} size="sm" />
                  <span className="min-w-0 flex-1 truncate text-sm font-medium">{s.category?.name ?? '—'}</span>
                  <span className="num text-sm font-semibold">{formatSAR(s.total)}</span>
                  <span className="num w-9 text-end text-xs text-muted">{s.percent}%</span>
                </li>
              ))}
            </ul>
          </Card>
          <Card className="space-y-5">
            <section>
              <h2 className="mb-3 font-bold">حسب العملة</h2>
              <Bars total={total} rows={currencies.map((c) => ({
                key: c.currency, label: c.currency === 'SAR' ? 'ريال سعودي' : c.currency, total: c.total,
                sub: c.currency === 'SAR' ? undefined : `${c.original.toLocaleString('en', { maximumFractionDigits: 2 })} ${c.currency}`,
              }))} />
            </section>
            {cards.length > 1 && (
              <section>
                <h2 className="mb-3 font-bold">حسب البطاقة</h2>
                <Bars total={total} rows={cards.map((c) => ({ key: c.key, label: c.label, total: c.total, sub: `${c.count}×` }))} />
              </section>
            )}
            {members.length > 1 && (
              <section>
                <h2 className="mb-3 font-bold">حسب الشخص</h2>
                <Bars total={total} rows={members.map(([uid, t]) => ({ key: uid, label: memberName(uid), total: t }))} />
              </section>
            )}
          </Card>
          <Card className="md:col-span-2">
            <h2 className="mb-3 font-bold">حسب اليوم</h2>
            <Bars total={Math.max(...days.map((d) => d.total))} rows={[...days].reverse().map((d) => ({
              key: d.date, label: formatDayShort(d.date), total: d.total, sub: `${d.items.length}×`,
            }))} />
          </Card>
        </div>
      )}

      <section>
        <h2 className="mb-2 px-2 font-bold">العمليات</h2>
        {list.length === 0 && !loadingList
          ? <p className="px-2 text-sm text-muted">لا توجد عمليات.</p>
          : <ExpenseGroups expenses={list} categories={categories} />}
      </section>

      <Sheet open={editing} onOpenChange={setEditing} title="تعديل الرحلة">
        <TripForm trip={trip} onDone={() => setEditing(false)} />
      </Sheet>
    </div>
  );
}

function TripForm({ trip, onDone }: { trip: Trip; onDone: () => void }) {
  const { update } = useTripActions();
  const [name, setName] = useState(trip.name);
  const [budget, setBudget] = useState(trip.budget ? toInputValue(trip.budget) : '');
  const [card, setCard] = useState(trip.card_last4 ?? '');

  function submit(e: FormEvent) {
    e.preventDefault();
    if (!name.trim()) return toast.error('اكتب اسم الرحلة');
    const b = budget.trim() ? parseAmount(budget) : null;
    if (budget.trim() && !b) return toast.error('أدخل ميزانية صحيحة');
    if (card && !/^\d{4}$/.test(card)) return toast.error('بطاقة الرحلة: آخر 4 أرقام');
    update.mutate({ id: trip.id, patch: { name: name.trim(), budget: b, card_last4: card || null } }, { onSuccess: onDone });
  }

  return (
    <form onSubmit={submit} className="space-y-4 pb-2">
      <Field label="اسم الرحلة" value={name} maxLength={60} onChange={(e) => setName(e.target.value)} />
      <Field label="ميزانية الرحلة (ر.س) — اختياري" inputMode="decimal" dir="ltr" placeholder="15000" value={budget}
        onChange={(e) => setBudget(e.target.value)} />
      <Field label="بطاقة الرحلة (آخر 4 أرقام) — اختياري" inputMode="numeric" dir="ltr" maxLength={4} placeholder="8812" value={card}
        onChange={(e) => setCard(e.target.value.replace(/\D/g, ''))} />
      <Button type="submit" className="w-full" loading={update.isPending}><CheckCircle className="size-5" weight="bold" /> حفظ</Button>
    </form>
  );
}
