import { useEffect } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { EXPENSE_DEPENDENT } from './queries';

/** يحدّث البيانات فوراً عندما يضيف أحد أفراد العائلة أو يعدّل شيئاً */
export function useRealtimeSync(householdId: string) {
  const qc = useQueryClient();
  useEffect(() => {
    const refresh = (roots: string[]) => roots.forEach((r) => qc.invalidateQueries({ queryKey: [r] }));
    const filter = `household_id=eq.${householdId}`;
    const channel = supabase
      .channel(`household-${householdId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'expenses', filter }, () => refresh(EXPENSE_DEPENDENT))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'categories', filter }, () => refresh(['categories']))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'recurring_expenses', filter }, () => refresh(['recurring']))
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'households', filter: `id=eq.${householdId}` }, () => refresh(['household']))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'trips', filter }, () => refresh(['trips', 'expenses']))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'renewals', filter }, () => refresh(['renewals']))
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'sms_log', filter }, () => refresh(['sms-log', 'ai-status', 'categories', 'cards']))
      // أحداث الحذف في Supabase لا تقبل الفلترة، فنستقبلها بدون فلتر (تحمل المعرّف فقط) ونحدّث
      .on('postgres_changes', { event: 'DELETE', schema: 'public', table: 'expenses' }, () => refresh(EXPENSE_DEPENDENT))
      .on('postgres_changes', { event: 'DELETE', schema: 'public', table: 'categories' }, () => refresh(['categories']))
      .on('postgres_changes', { event: 'DELETE', schema: 'public', table: 'recurring_expenses' }, () => refresh(['recurring']))
      .subscribe();

    // عند العودة للتطبيق بعد غياب
    const onVisible = () => document.visibilityState === 'visible' && refresh([...EXPENSE_DEPENDENT, 'recurring']);
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      document.removeEventListener('visibilitychange', onVisible);
      supabase.removeChannel(channel);
    };
  }, [householdId, qc]);
}
