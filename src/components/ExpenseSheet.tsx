import { useMemo, useRef, useState, type FormEvent } from 'react';
import { toast } from 'sonner';
import { ArrowSquareOut, Camera, ChatCircleText, CheckCircle, Receipt as ReceiptIcon, Sparkle, Trash } from '@phosphor-icons/react';
import { useCards, useCategories, useDeleteExpense, useSaveExpense } from '../hooks/queries';
import { useMemberName } from '../hooks/household';
import { receiptUrl } from '../lib/api';
import { addDays, formatDayLabel, todayISO } from '../lib/dates';
import { formatSAR, parseAmount, toInputValue } from '../lib/money';
import { cardLabel, channelLabel, fxLabel } from '../lib/stats';
import type { Expense } from '../lib/types';
import type { ExpenseDraft } from './Layout';
import { Button, CategoryIcon, ConfirmButton, Sheet, cx } from './ui';

export function ExpenseSheet({ open, onOpenChange, expense, draft }: {
  open: boolean; onOpenChange: (o: boolean) => void; expense?: Expense; draft?: ExpenseDraft;
}) {
  return (
    <Sheet open={open} onOpenChange={onOpenChange} title={expense ? 'تعديل المصروف' : 'مصروف جديد'}>
      <ExpenseForm key={expense?.id ?? `new-${draft?.description ?? ''}-${draft?.amount ?? ''}`} expense={expense} draft={draft}
        onDone={() => onOpenChange(false)} />
    </Sheet>
  );
}

/** تفاصيل ما قرأه التطبيق من رسالة البنك */
function SmsDetails({ expense }: { expense: Expense }) {
  const { data: cards = [] } = useCards();
  const meta = expense.sms_meta;
  if (!meta) return null;
  const cardMap = new Map(cards.map((c) => [c.card_last4, c]));
  const fx = fxLabel(meta);
  const parts = [
    cardLabel(meta, cardMap),
    channelLabel(meta),
    fx && `${fx}${meta.approx ? ' ≈' : ''}`,
    meta.fees_sar && `شامل رسوم ${meta.fees_sar} ر.س`,
  ].filter(Boolean);
  return (
    <div className="flex items-start gap-2 rounded-2xl bg-surface-2 px-3 py-2.5 text-xs leading-relaxed text-muted">
      <ChatCircleText className="mt-0.5 size-4 shrink-0" weight="duotone" />
      <span className="flex-1">
        من رسالة البنك{parts.length > 0 && ` · ${parts.join(' · ')}`}
        <span className="mt-0.5 flex items-center gap-1">
          {meta.rule ? 'التصنيف من قاعدة تعلّمها التطبيق منكم'
            : meta.source === 'ai' ? <><Sparkle className="size-3.5" weight="fill" /> قرأها وصنّفها Claude</>
            : 'قراءة محلية (بدون ذكاء اصطناعي)'}
        </span>
      </span>
    </div>
  );
}

function ExpenseForm({ expense, draft, onDone }: { expense?: Expense; draft?: ExpenseDraft; onDone: () => void }) {
  const today = todayISO();
  const { data: categories = [] } = useCategories();
  const save = useSaveExpense();
  const remove = useDeleteExpense();
  const memberName = useMemberName();
  const fileRef = useRef<HTMLInputElement>(null);

  const [amountText, setAmountText] = useState(
    expense ? toInputValue(expense.amount) : draft?.amount ? toInputValue(draft.amount) : '');
  const [categoryId, setCategoryId] = useState(expense?.category_id ?? draft?.categoryId ?? '');
  const [date, setDate] = useState(expense?.expense_date ?? draft?.date ?? today);
  const [description, setDescription] = useState(expense?.description ?? draft?.description ?? '');
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
    // تغيير تصنيف عملية من رسالة بنك = قاعدة يتعلّمها التطبيق لهذا المتجر
    if (expense?.merchant_key && !expense.recurring_id && expense.category_id !== categoryId) {
      const merchant = expense.sms_meta?.merchant ?? expense.description?.replace(/^📩\s*/, '') ?? '';
      const cat = categories.find((c) => c.id === categoryId)?.name ?? '';
      toast(`تعلّمت: عمليات «${merchant}» القادمة تروح لـ «${cat}»`, {
        description: 'تقدر تعدّل القواعد من الإعدادات ← الذكاء الاصطناعي',
        icon: <Sparkle className="size-4" weight="fill" />,
      });
    }
    onDone();
  }

  // الفاتورة تُعرض داخل اللوحة نفسها (window.open غير موثوق في التطبيق المثبّت على الآيفون)
  const [receiptView, setReceiptView] = useState<{ url: string; isPdf: boolean } | null>(null);
  const [loadingReceipt, setLoadingReceipt] = useState(false);

  async function toggleReceipt() {
    if (receiptView) return setReceiptView(null);
    if (!expense?.receipt_path) return;
    setLoadingReceipt(true);
    try {
      const url = await receiptUrl(expense.receipt_path);
      setReceiptView({ url, isPdf: expense.receipt_path.toLowerCase().endsWith('.pdf') });
    } catch (err) {
      toast.error((err as Error).message);
    } finally {
      setLoadingReceipt(false);
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

      {expense?.sms_meta && <SmsDetails expense={expense} />}

      {expense && (
        <div className="flex flex-wrap items-center justify-between gap-2 text-sm text-muted">
          <span>أضافه {memberName(expense.created_by)}</span>
          {expense.receipt_path && (
            <button type="button" onClick={toggleReceipt} disabled={loadingReceipt} aria-expanded={Boolean(receiptView)}
              className="inline-flex items-center gap-1 font-medium text-brand disabled:opacity-50">
              <ReceiptIcon className="size-4" weight="bold" /> {receiptView ? 'إخفاء الفاتورة' : loadingReceipt ? 'جارٍ التحميل…' : 'عرض الفاتورة'}
            </button>
          )}
        </div>
      )}

      {receiptView && (
        <div className="space-y-2">
          {!receiptView.isPdf && (
            <img src={receiptView.url} alt="صورة الفاتورة" className="max-h-[55dvh] w-full rounded-2xl bg-surface-2 object-contain" />
          )}
          <a href={receiptView.url} target="_blank" rel="noopener noreferrer"
            className="inline-flex items-center gap-1 text-sm font-medium text-brand">
            <ArrowSquareOut className="size-4" weight="bold" /> {receiptView.isPdf ? 'فتح ملف الفاتورة' : 'فتح بالحجم الكامل'}
          </a>
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
