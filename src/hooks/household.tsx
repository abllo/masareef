import { createContext, useContext, type ReactNode } from 'react';
import type { HouseholdContext } from '../lib/api';

const Ctx = createContext<HouseholdContext | null>(null);

export function HouseholdProvider({ value, children }: { value: HouseholdContext; children: ReactNode }) {
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useHousehold(): HouseholdContext {
  const v = useContext(Ctx);
  if (!v) throw new Error('useHousehold must be used inside HouseholdProvider');
  return v;
}

/** اسم العضو من معرّفه */
export function useMemberName() {
  const { members } = useHousehold();
  return (userId: string) => members.find((m) => m.user_id === userId)?.display_name ?? '—';
}
