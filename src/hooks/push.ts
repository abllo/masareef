import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import * as api from '../lib/api';
import { currentSubscription, deviceName, getRegistration, pushAvailability, subscribe, type PushAvailability } from '../lib/push';
import type { NotifyPrefs } from '../lib/types';
import { useHousehold } from './household';

export const pushKey = (h: string) => ['push-status', h] as const;

export function usePushStatus() {
  const { household } = useHousehold();
  return useQuery({ queryKey: pushKey(household.id), queryFn: api.fetchPushStatus, staleTime: 60_000 });
}

/** حالة الإشعارات على هذا الجهاز + تفعيلها وإيقافها */
export function usePush() {
  const { household } = useHousehold();
  const qc = useQueryClient();
  const status = usePushStatus();
  const [availability, setAvailability] = useState<PushAvailability>(() => pushAvailability());
  const [reg, setReg] = useState<ServiceWorkerRegistration | null>(null);
  const [sub, setSub] = useState<PushSubscription | null | undefined>(undefined);
  const [publicKey, setPublicKey] = useState<string | null>(null);

  useEffect(() => {
    if (availability !== 'ok') { setSub(null); return; }
    let alive = true;
    getRegistration()
      .then(async (r) => { if (!alive) return; setReg(r); setSub((await r?.pushManager.getSubscription()) ?? null); })
      .catch(() => alive && setSub(null));
    return () => { alive = false; };
  }, [availability]);

  // المفتاح العام جاهز قبل الضغطة (الآيفون يشترط الاشتراك داخل الضغطة مباشرة)
  useEffect(() => {
    if (availability !== 'ok' || !status.isSuccess) return;
    if (status.data.public_key) { setPublicKey(status.data.public_key); return; }
    api.initPush().then((r) => setPublicKey(r.publicKey)).catch(() => {});
  }, [availability, status.isSuccess, status.data?.public_key]);

  const refresh = () => qc.invalidateQueries({ queryKey: pushKey(household.id) });

  async function enable() {
    if (!reg || !publicKey) throw new Error('الإشعارات تتجهز، جرّب بعد ثواني');
    let s: PushSubscription;
    try {
      s = await subscribe(reg, publicKey);
    } catch (e) {
      setAvailability(pushAvailability());
      if (typeof Notification !== 'undefined' && Notification.permission === 'denied') {
        throw new Error('الإذن مرفوض. فعّله من الإعدادات ← الإشعارات ← مصاريف');
      }
      throw new Error(`تعذّر تفعيل الإشعارات: ${(e as Error).message}`);
    }
    await api.pushSubscribe(s.toJSON(), deviceName());
    setSub(s);
    await refresh();
  }

  async function disable() {
    if (!sub) return;
    await api.pushUnsubscribe(sub.endpoint);
    await sub.unsubscribe().catch(() => {});
    setSub(null);
    await refresh();
  }

  async function setPrefs(prefs: Partial<NotifyPrefs>) {
    const updated = await api.setPushPrefs(prefs);
    qc.setQueryData(pushKey(household.id), (old: typeof status.data) => (old ? { ...old, prefs: updated } : old));
  }

  return {
    availability,
    status,
    enabled: Boolean(sub),
    loading: sub === undefined || (availability === 'ok' && !publicKey && !sub),
    ready: Boolean(reg && publicKey),
    enable,
    disable,
    setPrefs,
  };
}

/** عند فتح التطبيق: يحدّث اشتراك هذا الجهاز (لو تغيّر من المتصفح أو انتقل لحساب آخر) */
export function usePushRefresh() {
  const done = useRef(false);
  useEffect(() => {
    if (done.current || pushAvailability() !== 'ok' || Notification.permission !== 'granted') return;
    done.current = true;
    currentSubscription()
      .then((s) => s && api.pushSubscribe(s.toJSON(), deviceName()))
      .catch(() => {});
  }, []);
}
