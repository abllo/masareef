import { useEffect, useRef, useState, type ReactNode } from 'react';
import { toast } from 'sonner';
import { ScanSmiley } from '@phosphor-icons/react';
import { lockEnabled, unlock, unlockedThisSession } from '../lib/lock';
import { supabase } from '../lib/supabase';
import { Logo } from './Logo';
import { Button } from './ui';

/** يقفل التطبيق عند فتحه، وبعد دقيقة في الخلفية، لو القفل مفعّل */
export function AppLock({ children }: { children: ReactNode }) {
  const [locked, setLocked] = useState(() => lockEnabled() && !unlockedThisSession());
  const hiddenAt = useRef<number | null>(null);

  useEffect(() => {
    const onVisibility = () => {
      if (document.visibilityState === 'hidden') hiddenAt.current = Date.now();
      else if (hiddenAt.current && Date.now() - hiddenAt.current > 60_000 && lockEnabled()) setLocked(true);
    };
    document.addEventListener('visibilitychange', onVisibility);
    return () => document.removeEventListener('visibilitychange', onVisibility);
  }, []);

  return (
    <>
      <div aria-hidden={locked || undefined} className={locked ? 'invisible' : undefined}>{children}</div>
      {locked && <LockScreen onUnlock={() => setLocked(false)} />}
    </>
  );
}

function LockScreen({ onUnlock }: { onUnlock: () => void }) {
  const [busy, setBusy] = useState(false);
  async function tryUnlock() {
    setBusy(true);
    const ok = await unlock();
    setBusy(false);
    if (ok) onUnlock();
    else toast.error('ما تم التحقق');
  }
  return (
    <div className="pt-safe pb-safe fixed inset-0 z-50 flex flex-col items-center justify-center gap-6 bg-bg px-8 text-center">
      <Logo className="size-16" />
      <h1 className="text-2xl font-bold">مصاريف</h1>
      <Button className="w-full max-w-xs" loading={busy} onClick={tryUnlock}>
        <ScanSmiley className="size-6" weight="bold" /> فتح بـ Face ID
      </Button>
      <button type="button" className="text-sm font-semibold text-muted" onClick={() => supabase.auth.signOut()}>
        الدخول بكلمة المرور
      </button>
    </div>
  );
}
