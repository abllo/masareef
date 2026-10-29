import { useState, type FormEvent } from 'react';
import { toast } from 'sonner';
import { ArrowCounterClockwise, CheckCircle, Plus, Repeat } from '@phosphor-icons/react';
import { Button, Card, CategoryIcon, ConfirmButton, EmptyState, Field, MonthSwitcher, Select, Sheet, Spinner, cx } from '../components/ui';
import {
  useCategories, useDeleteExpense, useDeleteRecurring, useMarkPaid, useRecurring, useRecurringPayments, useSaveRecurring,
} from '../hooks/queries';
import { formatDayShort, monthOf, todayISO } from '../lib/dates';
import { formatSAR, parseAmount, sumHalalas, toInputValue } from '../lib/money';
import { recurringForMonth, type RecurringRow } from '../lib/recurring';
import type { Category, Recurring } from '../lib/types';

export default function RecurringPage() {
  const today = todayISO();
  const [month, setMonth] = useState(monthOf(today));
  const [editing, setEditing] = useState<{ open: boolean; item?: Recurring }>({ open: false });

  const { data: categories = [] } = useCategories();
  const recurring = useRecurring();
  const payments = useRecurringPayments(month);
  const rows = recurringForMonth(recurring.data ?? [], payments.data ?? [], month, today);

  const total = sumHalalas(rows.map((r) => r.item.amount));
  const paid = sumHalalas(rows.filter((r) => r.payment).map((r) => r.payment!.amount));

  return (
    <div className="space-y-4 pt-4">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-bold">المصاريف الثابتة</h1>
        <MonthSwitcher month={month} onChange={setMonth} />
      </header>

      <Card className="grid grid-cols-3 gap-2 text-center">
        <Stat label="الإجمالي" value={total} />
        <Stat label="مدفوع" value={paid} tone="text-brand" />
        <Stat label="متبقٍ" value={Math.max(total - paid, 0)} tone={total - paid > 0 ? 'text-warn' : undefined} />
      </Card>

      {recurring.isPending || payments.isPending ? <Spinner /> : rows.length === 0 ? (
        <EmptyState icon={Repeat} title="لا توجد مصاريف ثابتة بعد">
          أضف رواتب العمالة والفواتير والاشتراكات مرة واحدة، ثم سجّل دفعها كل شهر بضغطة.
        </EmptyState>
      ) : (
        <div className="space-y-2">
          {rows.map((row) => (
            <RecurringItem key={row.item.id} row={row} month={month} today={today}
              category={categories.find((c) => c.id === row.item.category_id)}
              onEdit={() => setEditing({ open: true, item: row.item })} />
          ))}
        </div>
      )}

      <Button variant="secondary" className="w-full" onClick={() => setEditing({ open: true })}>
        <Plus className="size-5" weight="bold" /> إضافة مصروف ثابت
      </Button>

      <Sheet open={editing.open} onOpenChange={(o) => setEditing((s) => ({ ...s, open: o }))}
        title={editing.item ? 'تعديل المصروف الثابت' : 'مصروف ثابت جديد'}>
        <RecurringForm key={editing.item?.id ?? 'new'} item={editing.item} onDone={() => setEditing({ open: false })} />
      </Sheet>
    </div>
  );
}

function Stat({ label, value, tone }: { label: string; value: number; tone?: string }) {
  return (
    <div>
      <p className="text-xs text-muted">{label}</p>
      <p className={cx('num mt-1 font-bold', tone)}>{formatSAR(value)}</p>
    </div>
  );
}

function RecurringItem({ row, month, today, category, onEdit }: {
  row: RecurringRow; month: string; today: string; category?: Category; onEdit: () => void;
}) {
  const markPaid = useMarkPaid();
  const undo = useDeleteExpense();
  const { item, payment, status, dueDate } = row;
  // الشهر الحالي: تاريخ اليوم. شهر سابق: تاريخ الاستحقاق.
  const payDate = monthOf(today) === month ? today : dueDate;

  return (
    <div className="flex items-center gap-3 rounded-card bg-surface p-3 shadow-[0_1px_2px_rgb(0_0_0/0.04)]">
      <button type="button" onClick={onEdit} className="flex min-w-0 flex-1 items-center gap-3 text-start">
        <CategoryIcon category={category} />
        <span className="min-w-0">
          <span className="block truncate font-medium">{item.name}</span>
          <span className={cx('text-xs', status === 'overdue' ? 'text-danger' : 'text-muted')}>
            {status === 'paid'
              ? `دُفع ${formatDayShort(payment!.expense_date)}`
              : `${status === 'overdue' ? 'متأخر، كان مستحقاً' : 'يستحق'} ${formatDayShort(dueDate)}`}
          </span>
        </span>
      </button>
      <span className="num shrink-0 font-semibold">{formatSAR(payment?.amount ?? item.amount)}</span>
      {payment ? (
        <ConfirmButton className="h-10 gap-1 bg-brand-soft px-3 text-sm text-brand" confirmText="إلغاء الدفع؟" loading={undo.isPending}
          onConfirm={() => undo.mutate(payment)}>
          <CheckCircle className="size-5" weight="fill" /><span className="text-sm">مدفوع</span><ArrowCounterClockwise className="size-3.5 opacity-60" weight="bold" />
        </ConfirmButton>
      ) : (
        <Button className="h-10 px-3 text-sm" loading={markPaid.isPending}
          onClick={() => markPaid.mutate(
            { recurringId: item.id, period: month, date: payDate },
            { onSuccess: () => toast.success(`تم تسجيل دفع ${item.name}`) },
          )}>
          تسجيل الدفع
        </Button>
      )}
    </div>
  );
}

function RecurringForm({ item, onDone }: { item?: Recurring; onDone: () => void }) {
  const { data: categories = [] } = useCategories();
  const save = useSaveRecurring();
  const remove = useDeleteRecurring();
  const [name, setName] = useState(item?.name ?? '');
  const [amountText, setAmountText] = useState(item ? toInputValue(item.amount) : '');
  const [categoryId, setCategoryId] = useState(item?.category_id ?? '');
  const [day, setDay] = useState(String(item?.day_of_month ?? 1));
  const [active, setActive] = useState(item?.is_active ?? true);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const amount = parseAmount(amountText);
    const d = Number(day);
    if (!name.trim()) return toast.error('أدخل اسم المصروف');
    if (!amount) return toast.error('أدخل مبلغاً صحيحاً');
    if (!categoryId) return toast.error('اختر التصنيف');
    if (!(d >= 1 && d <= 31)) return toast.error('يوم الاستحقاق بين 1 و 31');
    await save.mutateAsync({ id: item?.id, input: { name: name.trim(), amount, category_id: categoryId, day_of_month: d, is_active: active } })
      .then(onDone).catch(() => {});
  }

  return (
    <form onSubmit={submit} className="space-y-4 pb-2">
      <Field label="الاسم" value={name} onChange={(e) => setName(e.target.value)} placeholder="راتب العاملة، اشتراك الإنترنت…" maxLength={60} autoFocus={!item} />
      <div className="grid grid-cols-2 gap-3">
        <Field label="المبلغ الشهري (ر.س)" inputMode="decimal" dir="ltr" value={amountText} onChange={(e) => setAmountText(e.target.value)} placeholder="0" />
        <Field label="يوم الاستحقاق" inputMode="numeric" dir="ltr" value={day} onChange={(e) => setDay(e.target.value.replace(/\D/g, ''))}
          hint="إذا كان الشهر أقصر يُعتبر آخر يوم فيه" />
      </div>
      <Select label="التصنيف" showLabel value={categoryId} onChange={setCategoryId}
        options={[
          { value: '', label: 'اختر التصنيف', disabled: true },
          ...categories.filter((c) => !c.is_archived || c.id === item?.category_id).map((c) => ({ value: c.id, label: c.name })),
        ]} />
      {item && (
        <label className="flex items-center justify-between rounded-2xl bg-surface-2 px-4 py-3">
          <span>
            <span className="block font-medium">نشط</span>
            <span className="text-xs text-muted">أوقفه إذا انتهى (يبقى سجل الدفعات السابقة)</span>
          </span>
          <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} className="size-5 accent-[var(--color-brand)]" />
        </label>
      )}
      <div className="flex gap-2">
        <Button type="submit" loading={save.isPending} className="flex-1">{item ? 'حفظ التعديل' : 'إضافة'}</Button>
        {item && (
          <ConfirmButton loading={remove.isPending} confirmText="تأكيد الحذف"
            onConfirm={() => remove.mutate(item.id, { onSuccess: onDone })}>حذف</ConfirmButton>
        )}
      </div>
    </form>
  );
}
