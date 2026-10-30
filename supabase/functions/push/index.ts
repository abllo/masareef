// مصاريف — دالة الإشعارات (Supabase Edge Function باسم push)
// ترسل Web Push مشفّراً (RFC 8291 + VAPID RFC 8292) بدون أي مكتبة خارجية.
// تُنادى من:
//   - قاعدة البيانات بعد كل مصروف / رسالة بنك متجاهَلة / يومياً  ← { secret, kind, id }
//   - التطبيق (بحساب المستخدم)                                   ← { action: 'init' | 'test' }
//   - تقويم الآيفون (GET ?ics=رمز التقويم)                         ← ملف ICS للتجديدات والمصاريف الثابتة
// مفاتيح VAPID تُولَّد هنا أول مرة وتُحفظ في push_config (لا يراها أحد).

const env = (k: string): string =>
  // deno-lint-ignore no-explicit-any
  (globalThis as any).Deno?.env.get(k) ?? (globalThis as any).process?.env?.[k] ?? '';

const SUPABASE_URL = () => env('SUPABASE_URL').replace(/\/$/, '');
const SERVICE_KEY = () => env('SUPABASE_SERVICE_ROLE_KEY');

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

// ---------- ترميز ----------
const enc = new TextEncoder();
export function b64url(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export function unb64url(s: string): Uint8Array {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}
function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

// ---------- VAPID ----------
export interface Vapid { publicKey: string; privateJwk: JsonWebKey }

export async function generateVapid(): Promise<Vapid> {
  const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
  return { publicKey: b64url(raw), privateJwk: await crypto.subtle.exportKey('jwk', kp.privateKey) };
}

export async function vapidHeader(endpoint: string, vapid: Vapid, subject: string): Promise<string> {
  const header = b64url(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = b64url(enc.encode(JSON.stringify({
    aud: new URL(endpoint).origin,
    exp: Math.floor(Date.now() / 1000) + 12 * 3600,
    sub: subject,
  })));
  const key = await crypto.subtle.importKey('jwk', vapid.privateJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  // WebCrypto يعطي التوقيع بصيغة r||s (64 بايت) وهي المطلوبة في JWS
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(`${header}.${claims}`)));
  return `vapid t=${header}.${claims}.${b64url(sig)}, k=${vapid.publicKey}`;
}

// ---------- التشفير (aes128gcm) ----------
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, bytes * 8));
}

export async function encryptPayload(payload: Uint8Array, p256dh: string, authSecret: string): Promise<Uint8Array> {
  const uaPublic = unb64url(p256dh);
  const auth = unb64url(authSecret);
  const local = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', local.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, local.privateKey, 256));

  const ikm = await hkdf(auth, shared, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);

  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, concat(payload, new Uint8Array([2]))));

  const header = new Uint8Array(16 + 4 + 1 + asPublic.length);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, 4096);
  header[20] = asPublic.length;
  header.set(asPublic, 21);
  return concat(header, cipher);
}

export interface PushMessage { endpoint: string; p256dh: string; auth: string; payload: Record<string, unknown> }

export async function sendOne(m: PushMessage, vapid: Vapid, subject: string, fetchImpl: typeof fetch = fetch): Promise<number> {
  const body = await encryptPayload(enc.encode(JSON.stringify(m.payload)), m.p256dh, m.auth);
  const res = await fetchImpl(m.endpoint, {
    method: 'POST',
    headers: {
      Authorization: await vapidHeader(m.endpoint, vapid, subject),
      'Content-Encoding': 'aes128gcm',
      'Content-Type': 'application/octet-stream',
      TTL: '86400',
      Urgency: 'high',
    },
    body,
  });
  await res.body?.cancel().catch(() => {});
  return res.status;
}

// ---------- قاعدة البيانات (REST بمفتاح الخادم) ----------
async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const res = await fetch(`${SUPABASE_URL()}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: SERVICE_KEY(), Authorization: `Bearer ${SERVICE_KEY()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`${fn}: ${res.status} ${await res.text()}`);
  return (await res.json()) as T;
}

interface Config { vapid_public: string | null; vapid_private: JsonWebKey | null; hook_secret: string; function_url: string | null; subject: string }

async function ensureConfig(): Promise<Config & { vapid_public: string; vapid_private: JsonWebKey }> {
  let cfg = await rpc<Config>('push_config_get');
  const url = `${SUPABASE_URL()}/functions/v1/push`;
  if (!cfg.vapid_public || !cfg.vapid_private || cfg.function_url !== url) {
    const fresh = cfg.vapid_public ? null : await generateVapid();
    cfg = await rpc<Config>('push_config_set', {
      p_public: fresh?.publicKey ?? null, p_private: fresh?.privateJwk ?? null, p_function_url: url,
    });
  }
  return cfg as Config & { vapid_public: string; vapid_private: JsonWebKey };
}

async function currentUser(req: Request): Promise<string | null> {
  const authz = req.headers.get('Authorization');
  if (!authz?.startsWith('Bearer ')) return null;
  const res = await fetch(`${SUPABASE_URL()}/auth/v1/user`, { headers: { apikey: SERVICE_KEY(), Authorization: authz } });
  if (!res.ok) return null;
  const user = (await res.json()) as { id?: string };
  return user.id ?? null;
}

async function deliver(messages: PushMessage[], cfg: Config & { vapid_public: string; vapid_private: JsonWebKey }) {
  const vapid = { publicKey: cfg.vapid_public, privateJwk: cfg.vapid_private };
  let sent = 0;
  const failed: { endpoint: string; status: number | string }[] = [];
  await Promise.all(messages.map(async (m) => {
    try {
      const status = await sendOne(m, vapid, cfg.subject);
      if (status >= 200 && status < 300) {
        sent++;
        await rpc('push_result', { p_endpoint: m.endpoint, p_ok: true }).catch(() => {});
      } else {
        failed.push({ endpoint: new URL(m.endpoint).host, status });
        // 404/410 = الجهاز ألغى الاشتراك نهائياً
        if (status === 404 || status === 410) await rpc('push_result', { p_endpoint: m.endpoint, p_ok: false }).catch(() => {});
      }
    } catch (e) {
      failed.push({ endpoint: m.endpoint.slice(0, 40), status: String(e) });
    }
  }));
  return { sent, failed };
}

/** اشتراك تقويم الآيفون: الرمز سري لكل مستخدم ويعطي قراءة المواعيد فقط */
export async function calendar(req: Request): Promise<Response> {
  const token = new URL(req.url).searchParams.get('ics') ?? '';
  const notFound = () => new Response('not found', { status: 404 });
  if (!/^[0-9a-f]{64}$/.test(token)) return notFound();
  const ics = await rpc<string | null>('calendar_ics', { p_token: token }).catch(() => null);
  if (!ics) return notFound();
  return new Response(ics, {
    headers: {
      'Content-Type': 'text/calendar; charset=utf-8',
      'Content-Disposition': 'inline; filename="masareef.ics"',
      'Cache-Control': 'no-cache',
    },
  });
}

export async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method === 'GET') return calendar(req);
  if (req.method !== 'POST') return json({ error: 'method' }, 405);
  try {
    const body = (await req.json().catch(() => ({}))) as { action?: string; secret?: string; kind?: string; id?: string };
    const cfg = await ensureConfig();

    // من التطبيق
    if (body.action === 'init' || body.action === 'test') {
      const userId = await currentUser(req);
      if (!userId) return json({ error: 'unauthorized' }, 401);
      if (body.action === 'init') return json({ publicKey: cfg.vapid_public });
      const messages = await rpc<PushMessage[]>('push_test_messages', { p_user: userId });
      return json(await deliver(messages, cfg));
    }

    // من قاعدة البيانات
    if (!body.secret || body.secret !== cfg.hook_secret) return json({ error: 'unauthorized' }, 401);
    // كل الأنواع (مصروف، رسالة بنك، يومي، نهاية رحلة، …) تُبنى في قاعدة البيانات
    const messages = body.kind ? await rpc<PushMessage[]>('push_build', { p_kind: body.kind, p_id: body.id ?? null }) : [];
    return json(await deliver(messages, cfg));
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
}

// deno-lint-ignore no-explicit-any
if ((globalThis as any).Deno?.serve) (globalThis as any).Deno.serve(handle);
