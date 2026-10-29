import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';
import { NavLink } from 'react-router';
import { GearSix, House, ListBullets, Plus, Repeat, type Icon } from '@phosphor-icons/react';
import { useHousehold } from '../hooks/household';
import { useRealtimeSync } from '../hooks/realtime';
import type { Expense } from '../lib/types';
import { cx } from './ui';
import { ExpenseSheet } from './ExpenseSheet';
import { Logo } from './Logo';

const SheetCtx = createContext<(expense?: Expense) => void>(() => {});
/** يفتح نافذة إضافة مصروف جديد، أو تعديل مصروف موجود */
export const useExpenseSheet = () => useContext(SheetCtx);

const NAV: { to: string; label: string; icon: Icon; end?: boolean }[] = [
  { to: '/', label: 'الرئيسية', icon: House, end: true },
  { to: '/expenses', label: 'العمليات', icon: ListBullets },
  { to: '/recurring', label: 'الثابتة', icon: Repeat },
  { to: '/settings', label: 'الإعدادات', icon: GearSix },
];

export function Layout({ children }: { children: ReactNode }) {
  const { household } = useHousehold();
  useRealtimeSync(household.id);

  const [state, setState] = useState<{ open: boolean; expense?: Expense }>({ open: false });
  const open = useCallback((expense?: Expense) => setState({ open: true, expense }), []);

  return (
    <SheetCtx.Provider value={open}>
      <div className="mx-auto flex min-h-dvh max-w-6xl">
        {/* شريط جانبي للكمبيوتر */}
        <aside className="sticky top-0 hidden h-dvh w-64 shrink-0 flex-col gap-1 border-l border-line p-4 md:flex">
          <div className="mb-6 flex items-center gap-3 px-2 pt-2">
            <Logo className="size-10" />
            <div>
              <div className="font-bold leading-tight">مصاريف البيت</div>
              <div className="text-xs text-muted">{household.name}</div>
            </div>
          </div>
          <button onClick={() => open()}
            className="mb-4 flex h-12 items-center justify-center gap-2 rounded-2xl bg-brand font-semibold text-brand-ink shadow-sm shadow-brand/30 hover:opacity-90">
            <Plus className="size-5" weight="bold" /> إضافة مصروف
          </button>
          {NAV.map(({ to, label, icon: NavIcon, end }) => (
            <NavLink key={to} to={to} end={end}
              className={({ isActive }) => cx(
                'flex h-11 items-center gap-3 rounded-xl px-3 font-medium transition',
                isActive ? 'bg-brand-soft text-brand' : 'text-muted hover:bg-surface-2 hover:text-ink',
              )}>
              {({ isActive }) => (<><NavIcon className="size-5" weight={isActive ? 'fill' : 'regular'} /> {label}</>)}
            </NavLink>
          ))}
        </aside>

        <main className="pt-safe min-w-0 flex-1 px-4 pb-36 md:px-8 md:pb-12">{children}</main>
      </div>

      {/* شريط سفلي للجوال مع زر الإضافة في المنتصف */}
      <nav className="pb-safe fixed inset-x-0 bottom-0 z-30 border-t border-line/70 bg-surface/90 backdrop-blur-xl md:hidden">
        <div className="mx-auto grid max-w-md grid-cols-5 items-end px-2 pt-1.5">
          {NAV.slice(0, 2).map((n) => <MobileLink key={n.to} {...n} />)}
          <div className="flex justify-center">
            <button onClick={() => open()} aria-label="إضافة مصروف"
              className="-mt-6 flex size-16 items-center justify-center rounded-full bg-brand text-brand-ink shadow-lg shadow-brand/40 ring-4 ring-bg transition active:scale-90">
              <Plus className="size-8" weight="bold" />
            </button>
          </div>
          {NAV.slice(2).map((n) => <MobileLink key={n.to} {...n} />)}
        </div>
      </nav>

      <ExpenseSheet
        open={state.open}
        expense={state.expense}
        onOpenChange={(o) => setState((s) => ({ ...s, open: o }))}
      />
    </SheetCtx.Provider>
  );
}

function MobileLink({ to, label, icon: NavIcon, end }: (typeof NAV)[number]) {
  return (
    <NavLink to={to} end={end}
      className={({ isActive }) => cx('flex flex-col items-center gap-0.5 py-1.5 text-[11px] font-semibold transition', isActive ? 'text-brand' : 'text-muted')}>
      {({ isActive }) => (<><NavIcon className="size-6" weight={isActive ? 'fill' : 'regular'} />{label}</>)}
    </NavLink>
  );
}
