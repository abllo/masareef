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
