import { useMemo, useRef, useState, type FormEvent } from 'react';
import { toast } from 'sonner';
import { ArrowSquareOut, Camera, CheckCircle, Trash } from '@phosphor-icons/react';
import { useCategories, useDeleteExpense, useSaveExpense } from '../hooks/queries';
import { useMemberName } from '../hooks/household';
import { receiptUrl } from '../lib/api';
import { addDays, formatDayLabel, todayISO } from '../lib/dates';
import { formatSAR, parseAmount, toInputValue } from '../lib/money';
import type { Expense } from '../lib/types';
import { Button, CategoryIcon, ConfirmButton, Sheet, cx } from './ui';

export function ExpenseSheet({ open, onOpenChange, expense }: {
  open: boolean; onOpenChange: (o: boolean) => void; expense?: Expense;
}) {
  return (
    <Sheet open={open} onOpenChange={onOpenChange} title={expense ? 'تعديل المصروف' : 'مصروف جديد'}>
      <ExpenseForm key={expense?.id ?? 'new'} expense={expense} onDone={() => onOpenChange(false)} />
    </Sheet>
  );
}

function ExpenseForm({ expense, onDone }: { expense?: Expense; onDone: () => void }) {
  const today = todayISO();
  const { data: categories = [] } = useCategories();
  const save = useSaveExpense();
  const remove = useDeleteExpense();
  const memberName = useMemberName();
  const fileRef = useRef<HTMLInputElement>(null);

  const [amountText, setAmountText] = useState(expense ? toInputValue(expense.amount) : '');
  const [categoryId, setCategoryId] = useState(expense?.category_id ?? '');
  const [date, setDate] = useState(expense?.expense_date ?? today);
  const [description, setDescription] = useState(expense?.description ?? '');
  const [receipt, setReceipt] = useState<File | null>(null);
  const [touched, setTouched] = useState(false);

  const amount = parseAmount(amountText);
  const visible = useMemo(
    () => categories.filter((c) => !c.is_archived || c.id === expense?.category_id),
    [categories, expense?.category_id],
  );

  async function submit(e: FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!amount) return toast.error('أدخل مبلغاً صحيحاً');
    if (!categoryId) return toast.error('اختر التصنيف');
    if (date > today) return toast.error('لا يمكن تسجيل مصروف بتاريخ مستقبلي');
    const saved = await save.mutateAsync({
      id: expense?.id,
      receipt,
      input: { amount, category_id: categoryId, expense_date: date, description: description.trim() || null },
    }).catch(() => null);
    if (!saved) return;
    toast.success(expense ? 'تم حفظ التعديل' : `تمت إضافة ${formatSAR(amount)}`);
    onDone();
  }

  async function openReceipt() {
    if (!expense?.receipt_path) return;
    const win = window.open('', '_blank'); // تُفتح مباشرة حتى لا يحجبها المتصفح
    try {
      const url = await receiptUrl(expense.receipt_path);
      if (win) win.location.href = url;
    } catch (err) {
      win?.close();
      toast.error((err as Error).message);
    }
  }

  const dateChips = [today, addDays(today, -1)];

  return (
    <form onSubmit={submit} className="space-y-5 pb-2">
      {/* المبلغ: أكبر عنصر في الشاشة لأنه أول ما يُكتب */}
      <label className="block rounded-3xl bg-surface-2 px-4 py-5 text-center">
        <span className="sr-only">المبلغ بالريال</span>
        <div className="flex items-baseline justify-center gap-2" dir="ltr">
          <input
            autoFocus={!expense}
            inputMode="decimal"
            enterKeyHint="done"
            placeholder="0"
            value={amountText}
            onChange={(e) => setAmountText(e.target.value)}
            className={cx(
              'num w-full max-w-[12ch] bg-transparent text-center text-5xl font-bold tracking-tight outline-none placeholder:text-line',
              touched && !amount && 'text-danger',
            )}
          />
          <span className="text-lg font-semibold text-muted">ر.س</span>
        </div>
      </label>

      <fieldset>
        <legend className="mb-2 text-sm font-medium text-muted">التصنيف</legend>
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-4">
          {visible.map((c) => (
            <button key={c.id} type="button" onClick={() => setCategoryId(c.id)} aria-pressed={categoryId === c.id}
              className={cx(
                'flex flex-col items-center gap-1.5 rounded-2xl border-2 px-1 py-2.5 text-center text-xs font-semibold leading-tight transition active:scale-95',
                categoryId === c.id ? 'border-brand bg-brand-soft text-brand' : 'border-transparent bg-surface-2 hover:border-line',
              )}>
              <CategoryIcon category={c} size="sm" />
              <span className="line-clamp-2">{c.name}</span>
            </button>
          ))}
        </div>
      </fieldset>

      <div className="flex flex-wrap items-center gap-2">
        {dateChips.map((d) => (
          <button key={d} type="button" onClick={() => setDate(d)}
            className={cx('h-10 rounded-full px-4 text-sm font-semibold transition', date === d ? 'bg-ink text-bg' : 'bg-surface-2')}>
            {formatDayLabel(d, today)}
          </button>
        ))}
        <label className="relative">
          <span className="sr-only">تاريخ آخر</span>
          <input type="date" value={date} max={today} onChange={(e) => e.target.value && setDate(e.target.value)}
            className={cx('h-10 rounded-full px-4 text-base', !dateChips.includes(date) ? 'bg-ink text-bg' : 'bg-surface-2')} />
        </label>
      </div>

      <div className="flex gap-2">
        <input
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          maxLength={200}
          placeholder="وصف (اختياري): الدانوب، فاتورة الكهرباء…"
          className="h-12 min-w-0 flex-1 rounded-2xl border border-line bg-surface px-4 text-base outline-none focus:border-brand focus:ring-4 focus:ring-brand/10"
        />
        <button type="button" onClick={() => fileRef.current?.click()}
          aria-label={receipt ? 'تم إرفاق الفاتورة' : 'إرفاق صورة الفاتورة'}
          className={cx('flex size-12 shrink-0 items-center justify-center rounded-2xl', receipt ? 'bg-brand-soft text-brand' : 'bg-surface-2 text-muted')}>
          {receipt ? <CheckCircle className="size-6" weight="fill" /> : <Camera className="size-6" weight="duotone" />}
        </button>
        <input ref={fileRef} type="file" accept="image/*,application/pdf" className="hidden"
          onChange={(e) => setReceipt(e.target.files?.[0] ?? null)} />
      </div>

      {expense && (
        <div className="flex flex-wrap items-center justify-between gap-2 text-sm text-muted">
          <span>أضافه {memberName(expense.created_by)}</span>
          {expense.receipt_path && (
            <button type="button" onClick={openReceipt} className="inline-flex items-center gap-1 font-medium text-brand">
              <ArrowSquareOut className="size-4" weight="bold" /> عرض الفاتورة
            </button>
          )}
        </div>
      )}

      <div className="flex gap-2">
        <Button type="submit" loading={save.isPending} className="flex-1">
          {expense ? 'حفظ التعديل' : amount ? `إضافة ${formatSAR(amount)}` : 'إضافة'}
        </Button>
        {expense && (
          <ConfirmButton loading={remove.isPending} confirmText="تأكيد الحذف"
            onConfirm={() => remove.mutate(expense, { onSuccess: onDone })}>
            <Trash className="size-5" weight="bold" /><span className="sr-only">حذف</span>
          </ConfirmButton>
        )}
      </div>
      {expense?.recurring_id && (
        <p className="text-xs text-muted">هذه دفعة مصروف ثابت. حذفها يعيد حالته إلى «غير مدفوع» لهذا الشهر.</p>
      )}
    </form>
  );
}
