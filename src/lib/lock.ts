// قفل التطبيق بـ Face ID (WebAuthn على الجهاز نفسه) وإخفاء المبالغ

const LOCK_KEY = 'masareef.lock.v1';
const HIDE_KEY = 'masareef.hide-amounts';
const UNLOCKED_KEY = 'masareef.unlocked';

const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
const random = (n: number) => crypto.getRandomValues(new Uint8Array(n));

function read<T>(key: string): T | null {
  try {
    const v = localStorage.getItem(key);
    return v ? (JSON.parse(v) as T) : null;
  } catch {
    return null;
  }
}

export async function lockAvailable(): Promise<boolean> {
  try {
    return Boolean(window.PublicKeyCredential) && (await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable());
  } catch {
    return false;
  }
}

export const lockEnabled = () => Boolean(read<{ id: string }>(LOCK_KEY)?.id);

/** يسجّل بصمة الوجه لهذا الجهاز ويفعّل القفل */
export async function enableLock(userName: string): Promise<void> {
  const cred = (await navigator.credentials.create({
    publicKey: {
      challenge: random(32),
      rp: { name: 'مصاريف', id: location.hostname },
      user: { id: random(16), name: userName || 'masareef', displayName: userName || 'مصاريف' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
      authenticatorSelection: { authenticatorAttachment: 'platform', userVerification: 'required', residentKey: 'discouraged' },
      timeout: 60_000,
    },
  })) as PublicKeyCredential | null;
  if (!cred) throw new Error('تعذّر تفعيل القفل');
  localStorage.setItem(LOCK_KEY, JSON.stringify({ id: b64u(cred.rawId) }));
  markUnlocked();
}

export function disableLock() {
  try {
    localStorage.removeItem(LOCK_KEY);
  } catch {
    /* تجاهل */
  }
}

/** يطلب Face ID؛ يرجع true لو نجح */
export async function unlock(): Promise<boolean> {
  const saved = read<{ id: string }>(LOCK_KEY);
  if (!saved) return true;
  try {
    const res = await navigator.credentials.get({
      publicKey: {
        challenge: random(32),
        rpId: location.hostname,
        allowCredentials: [{ type: 'public-key', id: unb64u(saved.id) }],
        userVerification: 'required',
        timeout: 60_000,
      },
    });
    if (!res) return false;
    markUnlocked();
    return true;
  } catch {
    return false;
  }
}

/** بعد تسجيل الدخول بكلمة المرور ما نطلب Face ID مرة ثانية في نفس الجلسة */
export function markUnlocked() {
  try {
    sessionStorage.setItem(UNLOCKED_KEY, String(Date.now()));
  } catch {
    /* تجاهل */
  }
}
export const unlockedThisSession = () => {
  try {
    return Boolean(sessionStorage.getItem(UNLOCKED_KEY));
  } catch {
    return false;
  }
};

// ---------- إخفاء المبالغ ----------
export const amountsHidden = () => {
  try {
    return localStorage.getItem(HIDE_KEY) === '1';
  } catch {
    return false;
  }
};
export function setAmountsHidden(hidden: boolean) {
  try {
    if (hidden) localStorage.setItem(HIDE_KEY, '1');
    else localStorage.removeItem(HIDE_KEY);
  } catch {
    /* تجاهل */
  }
  document.documentElement.classList.toggle('hide-amounts', hidden);
  window.dispatchEvent(new Event('masareef-hide'));
}
export function applyAmountsHidden() {
  document.documentElement.classList.toggle('hide-amounts', amountsHidden());
}
