import { dehydrate, hydrate, type DehydratedState, type QueryClient } from '@tanstack/react-query';
import type { ExpenseInput } from './api';
import { supabase } from './supabase';

// ---------- البيانات بدون إنترنت: آخر نسخة من البيانات تنحفظ في الجهاز وتظهر فوراً ----------
const CACHE_KEY = 'masareef.cache.v1';
const PERSIST = new Set(['household', 'categories', 'expenses', 'monthly', 'recurring', 'recurring-payments', 'trips',
  'trip-expenses', 'renewals', 'cards', 'incomes', 'years']);
const MAX_AGE = 14 * 24 * 3600 * 1000;

export function restoreCache(qc: QueryClient) {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (!raw) return;
    const { at, state } = JSON.parse(raw) as { at: number; state: DehydratedState };
    if (Date.now() - at > MAX_AGE) return;
    hydrate(qc, state);
  } catch {
    /* نسخة تالفة: نتجاهلها */
  }
}

export function persistCache(qc: QueryClient) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const save = () => {
    try {
      const state = dehydrate(qc, {
        shouldDehydrateQuery: (q) => q.state.status === 'success' && PERSIST.has(String(q.queryKey[0])),
      });
      const text = JSON.stringify({ at: Date.now(), state });
      if (text.length < 3_000_000) localStorage.setItem(CACHE_KEY, text);
    } catch {
      /* المساحة ممتلئة أو التخزين مقفل */
    }
  };
  return qc.getQueryCache().subscribe(() => {
    clearTimeout(timer);
    timer = setTimeout(save, 1500);
  });
}

export function clearOfflineData() {
  try {
    localStorage.removeItem(CACHE_KEY);
    localStorage.removeItem(QUEUE_KEY);
  } catch {
    /* تجاهل */
  }
}

// ---------- إضافة مصروف بدون إنترنت: ينحفظ في الجهاز ويرتفع أول ما يرجع الاتصال ----------
const QUEUE_KEY = 'masareef.pending.v1';
const EVENT = 'masareef-pending';

export interface PendingExpense { id: string; household_id: string; input: ExpenseInput; queued_at: string }

export function pendingExpenses(): PendingExpense[] {
  try {
    return JSON.parse(localStorage.getItem(QUEUE_KEY) ?? '[]') as PendingExpense[];
  } catch {
    return [];
  }
}

function setPending(list: PendingExpense[]) {
  try {
    localStorage.setItem(QUEUE_KEY, JSON.stringify(list));
  } catch {
    /* تجاهل */
  }
  window.dispatchEvent(new Event(EVENT));
}

export function onPendingChange(cb: () => void) {
  window.addEventListener(EVENT, cb);
  return () => window.removeEventListener(EVENT, cb);
}

export const isOffline = () => typeof navigator !== 'undefined' && navigator.onLine === false;
export const isNetworkError = (e: unknown) =>
  /Failed to fetch|NetworkError|Load failed|الاتصال بالخادم/i.test(e instanceof Error ? e.message : String(e));

export function queueExpense(householdId: string, input: ExpenseInput): PendingExpense {
  // المعرّف من الجهاز: لو انرفعت مرتين (انقطع الاتصال بعد الحفظ) ما تتكرر
  const item: PendingExpense = { id: crypto.randomUUID(), household_id: householdId, input, queued_at: new Date().toISOString() };
  setPending([...pendingExpenses(), item]);
  return item;
}

let flushing = false;
/** يرفع المصاريف المحفوظة في الجهاز؛ يرجع عدد اللي انرفعت */
export async function flushPending(): Promise<number> {
  if (flushing || isOffline()) return 0;
  flushing = true;
  let done = 0;
  try {
    for (const p of pendingExpenses()) {
      const { error } = await supabase.from('expenses').insert({ id: p.id, household_id: p.household_id, ...p.input });
      if (error && error.code !== '23505' && isNetworkError(error.message)) break;
      // نجحت، أو موجودة مسبقاً (23505)، أو مرفوضة نهائياً (صلاحية/بيانات): تنشال من الانتظار
      setPending(pendingExpenses().filter((x) => x.id !== p.id));
      if (!error || error.code === '23505') done++;
    }
  } finally {
    flushing = false;
  }
  return done;
}
