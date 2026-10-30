import { useCallback, useEffect, useRef, useState, type MouseEvent, type PointerEvent, type ReactNode } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import { AirplaneTilt, ArrowUUpLeft, ChatCircleText, FileText, Money, Paperclip, Repeat, Trash } from '@phosphor-icons/react';
import { flag } from '../lib/countries';
import { useCanEdit, useMemberName } from '../hooks/household';
import { useDeleteWithUndo } from '../hooks/queries';
import { formatDayLabel } from '../lib/dates';
import { formatSAR } from '../lib/money';
import { groupByDay } from '../lib/stats';
import type { Category, Expense } from '../lib/types';
import { useExpenseSheet } from './Layout';
import { CategoryIcon, cx } from './ui';

const ACTION_WIDTH = 84; // عرض زر الحذف
let closeOpenRow: (() => void) | null = null; // صف واحد مفتوح في كل مرة

/**
 * السحب من اليمين لليسار يكشف زر «حذف»، والسحب لآخر الصف يحذف مباشرة.
 * touch-action: pan-y يخلّي التمرير العمودي للمتصفح والأفقي لنا.
 */
function SwipeToDelete({ onDelete, children }: { onDelete: () => void; children: ReactNode }) {
  const wrap = useRef<HTMLDivElement>(null);
  const content = useRef<HTMLDivElement>(null);
  const [x, setXState] = useState(0);
  const xRef = useRef(0);
  const [dragging, setDragging] = useState(false);
  const [revealed, setRevealed] = useState(false); // الخلفية الحمراء تبقى لين يرجع الصف مكانه
  const g = useRef({ id: -1, x0: 0, y0: 0, base: 0, mode: '' as '' | 'h' | 'v', moved: false });

  const setX = (v: number) => { xRef.current = v; setXState(v); };
  const close = useCallback(() => { xRef.current = 0; setXState(0); }, []);
  useEffect(() => () => { if (closeOpenRow === close) closeOpenRow = null; }, [close]);
  const width = () => wrap.current?.offsetWidth ?? 320;

  function remove() {
    if (closeOpenRow === close) closeOpenRow = null;
    setDragging(false);
    setX(-width());
    window.setTimeout(onDelete, 180);
  }

  function onPointerDown(e: PointerEvent) {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    g.current = { id: e.pointerId, x0: e.clientX, y0: e.clientY, base: xRef.current, mode: '', moved: false };
  }
  function onPointerMove(e: PointerEvent) {
    const s = g.current;
    if (s.id !== e.pointerId) return;
    const dx = e.clientX - s.x0;
    const dy = e.clientY - s.y0;
    if (!s.mode) {
      if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return;
      s.mode = Math.abs(dx) > Math.abs(dy) ? 'h' : 'v';
      if (s.mode !== 'h') return;
      s.moved = true;
      setDragging(true);
      setRevealed(true);
      wrap.current?.setPointerCapture(e.pointerId);
      if (closeOpenRow && closeOpenRow !== close) closeOpenRow();
    }
    if (s.mode === 'h') setX(Math.min(0, Math.max(-width(), s.base + dx)));
  }
  function finish(e: PointerEvent) {
    const s = g.current;
    if (s.id !== e.pointerId) return;
    s.id = -1;
    if (s.mode !== 'h') return;
    setDragging(false);
    const cur = xRef.current;
    if (e.type === 'pointerup' && cur < -width() * 0.55) return remove();
    if (cur < -ACTION_WIDTH / 2) { setX(-ACTION_WIDTH); closeOpenRow = close; }
    else close();
  }
  // بعد السحب، أو لو الصف مفتوح: الضغط عليه يقفله بدل ما يفتح التفاصيل
  function onClickCapture(e: MouseEvent) {
    if (!content.current?.contains(e.target as Node)) return;
    if (g.current.moved || xRef.current !== 0) {
      e.preventDefault();
      e.stopPropagation();
      if (!g.current.moved) close();
      g.current.moved = false;
    }
  }

  return (
    <div ref={wrap} className="relative overflow-hidden rounded-2xl" style={{ touchAction: 'pan-y' }}
      onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={finish} onPointerCancel={finish}
      onClickCapture={onClickCapture}>
      {(revealed || x < 0) && (
        <div className="absolute inset-y-0 right-0 flex justify-end bg-danger" dir="ltr" style={{ width: Math.max(ACTION_WIDTH, -x) + 24 }}>
          <button type="button" onClick={remove} style={{ width: Math.max(ACTION_WIDTH, -x) }}
            className="flex h-full items-center justify-center gap-1.5 text-sm font-semibold text-white">
            <Trash className="size-5" weight="bold" /> حذف
          </button>
        </div>
      )}
      <div ref={content} className="relative bg-surface"
        style={{ transform: `translateX(${x}px)`, transition: dragging ? 'none' : 'transform 200ms ease' }}
        onTransitionEnd={() => { if (xRef.current === 0) setRevealed(false); }}>
        {children}
      </div>
    </div>
  );
}

export function ExpenseRow({ expense, category }: { expense: Expense; category?: Category }) {
  const canEdit = useCanEdit();
  const deleteWithUndo = useDeleteWithUndo();
  const row = <ExpenseRowButton expense={expense} category={category} />;
  return canEdit(expense.created_by)
    ? <SwipeToDelete onDelete={() => deleteWithUndo(expense)}>{row}</SwipeToDelete>
    : row;
}

function ExpenseRowButton({ expense, category }: { expense: Expense; category?: Category }) {
  const openSheet = useExpenseSheet();
  const memberName = useMemberName();
  return (
    <button type="button" onClick={() => openSheet(expense)}
      className="flex w-full items-center gap-3 rounded-2xl px-2 py-2.5 text-start transition hover:bg-surface-2 active:bg-surface-2">
      <CategoryIcon category={category} />
      <span className="min-w-0 flex-1">
        <span className="block truncate font-semibold">{expense.description?.replace(/^[📩🧾]\s*/u, '') || category?.name || 'مصروف'}</span>
        <span className="flex items-center gap-1.5 text-xs text-muted">
          {expense.description && <span className="truncate">{category?.name}</span>}
          {expense.description && <span aria-hidden>•</span>}
          <span>{memberName(expense.created_by)}</span>
          {expense.recurring_id && <Repeat className="size-3.5" weight="bold" aria-label="مصروف ثابت" />}
          {expense.receipt_path && <Paperclip className="size-3.5" weight="bold" aria-label="فاتورة مرفقة" />}
          {expense.description?.startsWith('📩') && <ChatCircleText className="size-3.5" weight="bold" aria-label="من رسالة البنك" />}
          {expense.description?.startsWith('🧾') && <FileText className="size-3.5" weight="bold" aria-label="من كشف الحساب" />}
          {expense.trip_id && <AirplaneTilt className="size-3.5 text-brand" weight="bold" aria-label="مصروف رحلة" />}
          {expense.kind === 'refund' && <ArrowUUpLeft className="size-3.5 text-brand" weight="bold" aria-label="استرداد" />}
          {expense.kind === 'cash' && <Money className="size-3.5" weight="bold" aria-label="سحب نقدي" />}
          {expense.sms_meta?.country && expense.sms_meta.country !== 'SA' && <span aria-hidden>{flag(expense.sms_meta.country)}</span>}
        </span>
      </span>
      <span className={cx('num shrink-0 font-semibold', expense.amount < 0 && 'text-brand')}>{formatSAR(expense.amount)}</span>
    </button>
  );
}

export function ExpenseGroups({ expenses, categories }: { expenses: Expense[]; categories: Category[] }) {
  const byId = new Map(categories.map((c) => [c.id, c]));
  return (
    <div className="space-y-5">
      {groupByDay(expenses).map((g) => (
        <section key={g.date}>
          <header className="mb-1 flex items-center justify-between px-2 text-sm text-muted">
            <h3 className="font-semibold text-ink">{formatDayLabel(g.date)}</h3>
            <span className="num">{formatSAR(g.total)}</span>
          </header>
          <div className="rounded-card bg-surface p-1.5 shadow-[0_1px_2px_rgb(0_0_0/0.04)]">
            <AnimatePresence initial={false}>
              {g.items.map((e) => (
                <motion.div key={e.id} layout initial={{ opacity: 0, y: -6 }} animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, height: 0 }} transition={{ duration: 0.25 }}>
                  <ExpenseRow expense={e} category={byId.get(e.category_id)} />
                </motion.div>
              ))}
            </AnimatePresence>
          </div>
        </section>
      ))}
    </div>
  );
}
