import { AnimatePresence, motion } from 'motion/react';
import { ChatCircleText, Paperclip, Repeat } from '@phosphor-icons/react';
import { useMemberName } from '../hooks/household';
import { formatDayLabel } from '../lib/dates';
import { formatSAR } from '../lib/money';
import { groupByDay } from '../lib/stats';
import type { Category, Expense } from '../lib/types';
import { useExpenseSheet } from './Layout';
import { CategoryIcon } from './ui';

export function ExpenseRow({ expense, category }: { expense: Expense; category?: Category }) {
  const openSheet = useExpenseSheet();
  const memberName = useMemberName();
  return (
    <button type="button" onClick={() => openSheet(expense)}
      className="flex w-full items-center gap-3 rounded-2xl px-2 py-2.5 text-start transition hover:bg-surface-2 active:bg-surface-2">
      <CategoryIcon category={category} />
      <span className="min-w-0 flex-1">
        <span className="block truncate font-semibold">{expense.description?.replace(/^📩\s*/, '') || category?.name || 'مصروف'}</span>
        <span className="flex items-center gap-1.5 text-xs text-muted">
          {expense.description && <span className="truncate">{category?.name}</span>}
          {expense.description && <span aria-hidden>•</span>}
          <span>{memberName(expense.created_by)}</span>
          {expense.recurring_id && <Repeat className="size-3.5" weight="bold" aria-label="مصروف ثابت" />}
          {expense.receipt_path && <Paperclip className="size-3.5" weight="bold" aria-label="فاتورة مرفقة" />}
          {expense.description?.startsWith('📩') && <ChatCircleText className="size-3.5" weight="bold" aria-label="من رسالة البنك" />}
        </span>
      </span>
      <span className="num shrink-0 font-semibold">{formatSAR(expense.amount)}</span>
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
