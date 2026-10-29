import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import * as api from '../lib/api';
import { addMonths, monthEnd } from '../lib/dates';
import type { ISODate, MonthKey } from '../lib/types';
import { useHousehold } from './household';

export const keys = {
  household: (uid: string) => ['household', uid] as const,
  categories: (h: string) => ['categories', h] as const,
  expenses: (h: string, from: string, to: string) => ['expenses', h, from, to] as const,
  monthly: (h: string, from: string) => ['monthly', h, from] as const,
  recurring: (h: string) => ['recurring', h] as const,
  recurringPayments: (h: string, m: string) => ['recurring-payments', h, m] as const,
};

/** كل ما يتأثر بتغيير في المصروفات */
export const EXPENSE_DEPENDENT = ['expenses', 'monthly', 'recurring-payments'];

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
  return useQuery({
    queryKey: keys.expenses(household.id, from, to),
    queryFn: () => api.fetchExpenses(household.id, from, to),
    placeholderData: (prev) => prev, // يبقي البيانات السابقة أثناء التنقل بين الأشهر
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
    onSettled: () => invalidate(...EXPENSE_DEPENDENT),
    onError,
  });
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
    mutationFn: async (v: { name?: string; monthly_budget?: number | null; display_name?: string }) => {
      const { display_name, ...patch } = v;
      if (Object.keys(patch).length) await api.updateHousehold(household.id, patch);
      if (display_name) await api.updateDisplayName(household.id, me.user_id, display_name);
    },
    onSuccess: () => toast.success('تم الحفظ'),
    onSettled: () => invalidate('household'),
    onError,
  });
}
