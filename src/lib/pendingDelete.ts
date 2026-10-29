import { useSyncExternalStore } from 'react';

/** عمليات محذوفة بالسحب تنتظر انتهاء مهلة «تراجع»: تختفي من القوائم فوراً */
let hidden: ReadonlySet<string> = new Set();
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());

export function hideExpense(id: string) {
  hidden = new Set(hidden).add(id);
  emit();
}

export function showExpense(id: string) {
  if (!hidden.has(id)) return;
  const next = new Set(hidden);
  next.delete(id);
  hidden = next;
  emit();
}

export function useHiddenExpenses(): ReadonlySet<string> {
  return useSyncExternalStore(
    (l) => { listeners.add(l); return () => { listeners.delete(l); }; },
    () => hidden,
  );
}
