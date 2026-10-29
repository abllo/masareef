/** أدوات إشعارات المتصفح (Web Push) */

export const isIOS = () =>
  /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

/** مفتوح كتطبيق من الشاشة الرئيسية؟ (الآيفون لا يسمح بالإشعارات غير ذلك) */
export const isStandalone = () =>
  window.matchMedia?.('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;

export const pushSupported = () =>
  'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

export type PushAvailability = 'ok' | 'install-first' | 'unsupported' | 'denied';

export function pushAvailability(): PushAvailability {
  if (isIOS() && !isStandalone()) return 'install-first';
  if (!pushSupported()) return 'unsupported';
  if (Notification.permission === 'denied') return 'denied';
  return 'ok';
}

export function deviceName(): string {
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/iPad/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)) return 'iPad';
  if (/Android/.test(ua)) return 'Android';
  if (/Mac/.test(ua)) return 'Mac';
  if (/Windows/.test(ua)) return 'Windows';
  return 'جهاز';
}

export function registerServiceWorker() {
  if (!('serviceWorker' in navigator) || import.meta.env.DEV) return;
  navigator.serviceWorker.register('./sw.js', { scope: './' }).catch(() => {});
}

export async function getRegistration(): Promise<ServiceWorkerRegistration | null> {
  if (!('serviceWorker' in navigator)) return null;
  return (await navigator.serviceWorker.getRegistration('./')) ?? (await navigator.serviceWorker.register('./sw.js', { scope: './' }));
}

export async function currentSubscription(): Promise<PushSubscription | null> {
  if (!pushSupported()) return null;
  const reg = await navigator.serviceWorker.getRegistration('./');
  return (await reg?.pushManager.getSubscription()) ?? null;
}

export function keyToBytes(base64url: string): Uint8Array<ArrayBuffer> {
  const b = atob(base64url.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((base64url.length + 3) % 4));
  const out = new Uint8Array(new ArrayBuffer(b.length));
  for (let i = 0; i < b.length; i++) out[i] = b.charCodeAt(i);
  return out;
}

/**
 * يشترك هذا الجهاز. يجب استدعاؤها مباشرة من ضغطة المستخدم وبعد تجهيز reg و publicKey مسبقاً،
 * لأن الآيفون يطلب أن يكون طلب الإذن ضمن الضغطة نفسها.
 */
export function subscribe(reg: ServiceWorkerRegistration, publicKey: string): Promise<PushSubscription> {
  // أول await في الضغطة: يطلب الإذن ويشترك (لو كان مشتركاً بنفس المفتاح يرجع الاشتراك نفسه)
  return reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyToBytes(publicKey) });
}
