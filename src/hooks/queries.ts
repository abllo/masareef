import { useCallback } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import * as api from '../lib/api';
import { addMonths, monthEnd } from '../lib/dates';
import { hideExpense, showExpense, useHiddenExpenses } from '../lib/pendingDelete';
import type { Expense, ISODate, MonthKey } from '../lib/types';
import { useHousehold } from './household';

/** يخفي العمليات اللي تنتظر الحذف (مهلة «تراجع») من أي قائمة */
function useWithoutHidden() {
  const hidden = useHiddenExpenses();
  return useCallback((rows: Expense[]) => (hidden.size ? rows.filter((e) => !hidden.has(e.id)) : rows), [hidden]);
}

export const keys = {
  household: (uid: string) => ['household', uid] as const,
  categories: (h: string) => ['categories', h] as const,
  expenses: (h: string, from: string, to: string) => ['expenses', h, from, to] as const,
  monthly: (h: string, from: string) => ['monthly', h, from] as const,
  recurring: (h: string) => ['recurring', h] as const,
  recurringPayments: (h: string, m: string) => ['recurring-payments', h, m] as const,
  smsLog: (h: string) => ['sms-log', h] as const,
  rules: (h: string) => ['rules', h] as const,
  aiStatus: (h: string) => ['ai-status', h] as const,
  audit: (h: string) => ['category-audit', h] as const,
  cards: (h: string) => ['cards', h] as const,
  trips: (h: string) => ['trips', h] as const,
  tripExpenses: (id: string) => ['trip-expenses', id] as const,
};

/** كل ما يتأثر بتغيير في المصروفات */
export const EXPENSE_DEPENDENT = ['expenses', 'monthly', 'recurring-payments', 'trips', 'trip-expenses', 'years', 'renewals'];

const onError = (e: Error) => toast.error(e.message);

export function useInvalidate() {
  const qc = useQueryClient();
  return (...roots: string[]) =>
    Promise.all(roots.map((r) => qc.invalidateQueries({ queryKey: [r] })));
}

export function useCategories() {
  const { household } = useHousehold();
  return useQuery({ queryKey: keys.categories(household.id), queryFn: () => api.fetchCategories(household.id) });
}

export function useExpenses(from: ISODate, to: ISODate) {
  const { household } = useHousehold();
  const select = useWithoutHidden();
  return useQuery({
    queryKey: keys.expenses(household.id, from, to),
    queryFn: () => api.fetchExpenses(household.id, from, to),
    placeholderData: (prev) => prev, // يبقي البيانات السابقة أثناء التنقل بين الأشهر
    select,
  });
}

export const useMonthExpenses = (month: MonthKey) => useExpenses(month, monthEnd(month));

export function useMonthlyTotals(currentMonth: MonthKey, count = 6) {
  const { household } = useHousehold();
  const from = addMonths(currentMonth, -(count - 1));
  return useQuery({
    queryKey: keys.monthly(household.id, from),
    queryFn: () => api.fetchMonthlyTotals(household.id, from),
    placeholderData: (prev) => prev,
  });
}

export function useRecurring() {
  const { household } = useHousehold();
  return useQuery({ queryKey: keys.recurring(household.id), queryFn: () => api.fetchRecurring(household.id) });
}

export function useSmsLog() {
  const { household } = useHousehold();
  return useQuery({ queryKey: keys.smsLog(household.id), queryFn: () => api.fetchSmsLog(household.id) });
}

export function useRules() {
  const { household } = useHousehold();
  return useQuery({ queryKey: keys.rules(household.id), queryFn: () => api.fetchRules(household.id) });
}

export function useAiStatus() {
  const { household } = useHousehold();
  return useQuery({ queryKey: keys.aiStatus(household.id), queryFn: api.fetchAiStatus, staleTime: 60_000 });
}

export function useCards() {
  const { household } = useHousehold();
  return useQuery({ queryKey: keys.cards(household.id), queryFn: () => api.fetchCards(household.id) });
}

export function useCategoryAudit() {
  const { household } = useHousehold();
  return useQuery({ queryKey: keys.audit(household.id), queryFn: () => api.fetchCategoryAudit(household.id) });
}

/** كل ما يتأثر بتنظيم التصنيفات */
export const CATEGORY_DEPENDENT = ['categories', 'rules', 'category-audit', 'recurring', ...EXPENSE_DEPENDENT];

export function useRecurringPayments(month: MonthKey) {
  const { household } = useHousehold();
  return useQuery({
    queryKey: keys.recurringPayments(household.id, month),
    queryFn: () => api.fetchRecurringPayments(household.id, month),
  });
}

// ---------- عمليات الكتابة ----------
export function useSaveExpense() {
  const { household } = useHousehold();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (v: { input: api.ExpenseInput; id?: string; receipt?: File | null }) =>
      api.saveExpense(household.id, v.input, { id: v.id, receipt: v.receipt }),
    onSettled: () => invalidate(...EXPENSE_DEPENDENT, 'rules'),
    onError,
  });
}

/** حذف بالسحب: تختفي العملية فوراً، وتنحذف فعلياً بعد 4 ثوانٍ إلا لو ضغط «تراجع» */
export function useDeleteWithUndo() {
  const invalidate = useInvalidate();
  return (expense: Expense) => {
    hideExpense(expense.id);
    let settled = false;
    const commit = async () => {
      if (settled) return;
      settled = true;
      try {
        await api.deleteExpense(expense);
        await invalidate(...EXPENSE_DEPENDENT);
      } catch (e) {
        toast.error((e as Error).message);
      } finally {
        showExpense(expense.id);
      }
    };
    toast('تم حذف العملية', {
      duration: 4000,
      action: { label: 'تراجع', onClick: () => { settled = true; showExpense(expense.id); } },
      onAutoClose: () => void commit(),
      onDismiss: () => void commit(),
    });
  };
}

export function useDeleteExpense() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: api.deleteExpense,
    onSuccess: () => toast.success('تم حذف العملية'),
    onSettled: () => invalidate(...EXPENSE_DEPENDENT),
    onError,
  });
}

export function useSaveCategory() {
  const { household } = useHousehold();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (v: { input: api.CategoryInput; id?: string }) => api.saveCategory(household.id, v.input, v.id),
    onSuccess: () => toast.success('تم حفظ التصنيف'),
    onSettled: () => invalidate('categories'),
    onError,
  });
}

export function useDeleteCategory() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: api.deleteCategory,
    onSuccess: () => toast.success('تم حذف التصنيف'),
    onSettled: () => invalidate('categories'),
    onError,
  });
}

export function useSaveRecurring() {
  const { household } = useHousehold();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (v: { input: api.RecurringInput; id?: string }) => api.saveRecurring(household.id, v.input, v.id),
    onSuccess: () => toast.success('تم حفظ المصروف الثابت'),
    onSettled: () => invalidate('recurring'),
    onError,
  });
}

export function useDeleteRecurring() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: api.deleteRecurring,
    onSuccess: () => toast.success('تم حذف المصروف الثابت'),
    onSettled: () => invalidate('recurring', ...EXPENSE_DEPENDENT),
    onError,
  });
}

export function useMarkPaid() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (v: { recurringId: string; period: MonthKey; date: ISODate }) =>
      api.markRecurringPaid(v.recurringId, v.period, v.date),
    onSettled: () => invalidate(...EXPENSE_DEPENDENT),
    onError,
  });
}

export function useUpdateHousehold() {
  const { household, me } = useHousehold();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: async (v: { name?: string; monthly_budget?: number | null; fx_fee_pct?: number; display_name?: string }) => {
      const { display_name, ...patch } = v;
      if (Object.keys(patch).length) await api.updateHousehold(household.id, patch);
      if (display_name) await api.updateDisplayName(household.id, me.user_id, display_name);
    },
    onSuccess: () => toast.success('تم الحفظ'),
    onSettled: () => invalidate('household'),
    onError,
  });
}

// ---------- الرحلات ----------
export function useTrips() {
  const { household } = useHousehold();
  return useQuery({ queryKey: keys.trips(household.id), queryFn: () => api.fetchTrips(household.id) });
}

export function useTripExpenses(tripId: string | undefined) {
  const select = useWithoutHidden();
  return useQuery({
    queryKey: keys.tripExpenses(tripId ?? '-'),
    queryFn: () => api.fetchTripExpenses(tripId!),
    enabled: Boolean(tripId),
    select,
  });
}

export function useTripActions() {
  const invalidate = useInvalidate();
  const done = () => invalidate(...EXPENSE_DEPENDENT);
  return {
    update: useMutation({
      mutationFn: (v: { id: string; patch: Parameters<typeof api.updateTrip>[1] }) => api.updateTrip(v.id, v.patch),
      onSuccess: () => toast.success('تم حفظ الرحلة'), onSettled: done, onError,
    }),
    status: useMutation({
      mutationFn: (v: { id: string; active: boolean }) => api.setTripStatus(v.id, v.active),
      onSuccess: (_d, v) => toast.success(v.active ? 'تم استئناف الرحلة' : 'انتهت الرحلة'), onSettled: done, onError,
    }),
    remove: useMutation({
      mutationFn: api.deleteTrip,
      onSuccess: () => toast.success('تم حذف الرحلة'), onSettled: done, onError,
    }),
  };
}

// ---------- السنوات ----------
export function useYears() {
  const { household } = useHousehold();
  return useQuery({ queryKey: ['years', household.id], queryFn: api.fetchYearsOverview, staleTime: 60_000 });
}

// ---------- التجديدات ----------
export function useRenewals() {
  const { household } = useHousehold();
  return useQuery({ queryKey: ['renewals', household.id], queryFn: () => api.fetchRenewals(household.id) });
}
