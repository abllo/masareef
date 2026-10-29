import { useState } from 'react';
import { toast } from 'sonner';
import { Bell, BellRinging, BellSlash, CheckCircle, PaperPlaneTilt, X } from '@phosphor-icons/react';
import { usePush } from '../hooks/push';
import { sendTestPush } from '../lib/api';
import { isIOS } from '../lib/push';
import type { NotifyKey } from '../lib/types';
import { Button, Card, cx } from './ui';

const KINDS: { key: NotifyKey; title: string; hint: string }[] = [
  { key: 'self', title: 'مصروفي من رسالة البنك', hint: 'تم تسجيل 45 ر.س · ستاربكس ← مطاعم' },
  { key: 'family', title: 'مصاريف العائلة', hint: 'لما أحد من العائلة يسجّل مصروفاً' },
  { key: 'budget', title: 'تنبيه الميزانية', hint: 'عند الوصول لـ 80% وعند تجاوزها' },
  { key: 'recurring', title: 'المصاريف الثابتة', hint: 'يوم موعد الدفع الساعة 9 الصبح' },
  { key: 'monthly', title: 'ملخص الشهر والسنة', hint: 'أول كل شهر، وأول السنة' },
  { key: 'sms_issue', title: 'رسالة بنك ما انسجلت', hint: 'عملية مرفوضة، أو رسالة ما انقرأت' },
  { key: 'travel', title: 'الرحلات', hint: 'ميزانية الرحلة، وملخصها لما تنتهي' },
];

function Switch({ checked, onChange, label, disabled }: { checked: boolean; onChange: (v: boolean) => void; label: string; disabled?: boolean }) {
  return (
    <button type="button" role="switch" aria-checked={checked} aria-label={label} disabled={disabled} onClick={() => onChange(!checked)}
      className={cx('relative h-7 w-12 shrink-0 rounded-full transition disabled:opacity-50', checked ? 'bg-brand' : 'bg-line')}>
      <span className={cx('absolute top-0.5 size-6 rounded-full bg-white shadow transition-all', checked ? 'start-[22px]' : 'start-0.5')} />
    </button>
  );
}

export function NotificationsCard() {
  const push = usePush();
  const [busy, setBusy] = useState<string | null>(null);
  const prefs = push.status.data?.prefs;

  async function run(name: string, fn: () => Promise<unknown>, done?: string) {
    setBusy(name);
    try { await fn(); if (done) toast.success(done); } catch (e) { toast.error((e as Error).message); } finally { setBusy(null); }
  }

  return (
    <Card className="space-y-4">
      <h2 className="inline-flex items-center gap-2 font-bold"><BellRinging className="size-5 text-brand" weight="duotone" />الإشعارات</h2>

      {push.availability === 'install-first' && (
        <p className="rounded-2xl bg-warn-soft px-4 py-3 text-sm leading-relaxed">
          افتح «مصاريف» من أيقونته على الشاشة الرئيسية (مو من Safari) عشان تقدر تفعّل الإشعارات.
        </p>
      )}
      {push.availability === 'unsupported' && (
        <p className="rounded-2xl bg-surface-2 px-4 py-3 text-sm text-muted">هذا المتصفح لا يدعم الإشعارات.</p>
      )}
      {push.availability === 'denied' && (
        <p className="rounded-2xl bg-danger-soft px-4 py-3 text-sm leading-relaxed text-danger">
          الإشعارات مرفوضة لهذا التطبيق. فعّلها من إعدادات الجهاز ← الإشعارات ← مصاريف، ثم ارجع هنا.
        </p>
      )}

      {push.availability === 'ok' && (
        push.enabled ? (
          <div className="space-y-3">
            <p className="inline-flex items-center gap-1.5 text-sm font-semibold text-brand">
              <CheckCircle className="size-5" weight="fill" /> مفعّلة على هذا الجهاز
            </p>
            <div className="flex flex-wrap gap-2">
              <Button variant="secondary" className="h-10 px-4 text-sm" loading={busy === 'test'}
                onClick={() => run('test', async () => {
                  const r = await sendTestPush();
                  if (!r.sent) throw new Error('ما وصل الإشعار، جرّب إيقاف الإشعارات وتفعيلها من جديد');
                }, 'أرسلت لك إشعار تجربة')}>
                <PaperPlaneTilt className="size-4" weight="bold" /> إرسال تجربة
              </Button>
              <Button variant="ghost" className="h-10 px-4 text-sm text-muted" loading={busy === 'off'}
                onClick={() => run('off', push.disable, 'أوقفت الإشعارات على هذا الجهاز')}>
                <BellSlash className="size-4" weight="bold" /> إيقاف على هذا الجهاز
              </Button>
            </div>
            {isIOS() && (
              <p className="rounded-2xl bg-surface-2 px-4 py-3 text-xs leading-relaxed text-muted">
                بعد ما توصلك التجربة، تقدر تطفي إشعارات الاختصارات المكررة: الإعدادات ← الإشعارات ← Shortcuts ← أطفئ Allow Notifications.
                التسجيل التلقائي يظل شغال.
              </p>
            )}
          </div>
        ) : (
          <div className="space-y-2">
            <p className="text-sm leading-relaxed text-muted">فعّلها على هذا الجهاز ليوصلك تأكيد كل عملية وتنبيهات الميزانية والمصاريف الثابتة.</p>
            <Button className="w-full" loading={busy === 'on' || push.loading} disabled={!push.ready}
              onClick={() => run('on', push.enable, 'تم تفعيل الإشعارات')}>
              <Bell className="size-5" weight="bold" /> تفعيل الإشعارات على هذا الجهاز
            </Button>
          </div>
        )
      )}

      {prefs && (
        <ul className="divide-y divide-line/70 rounded-2xl bg-surface-2 px-4">
          {KINDS.map((k) => (
            <li key={k.key} className="flex items-center justify-between gap-3 py-3">
              <div className="min-w-0">
                <p className="text-sm font-semibold">{k.title}</p>
                <p className="truncate text-xs text-muted">{k.hint}</p>
              </div>
              <Switch label={k.title} checked={prefs[k.key] !== false} disabled={busy === k.key}
                onChange={(v) => run(k.key, () => push.setPrefs({ [k.key]: v }))} />
            </li>
          ))}
        </ul>
      )}
      <p className="text-xs text-muted">التفضيلات لك أنت على كل أجهزتك، وكل شخص في العائلة يتحكم بإشعاراته.</p>
    </Card>
  );
}

const DISMISS_KEY = 'masareef.push-prompt-dismissed';

/** تذكير في الرئيسية لمن لم يفعّل الإشعارات على جهازه */
export function PushPrompt() {
  const push = usePush();
  const [hidden, setHidden] = useState(() => {
    try { return Number(localStorage.getItem(DISMISS_KEY) ?? 0) > Date.now(); } catch { return false; }
  });
  const [busy, setBusy] = useState(false);
  if (hidden || push.availability !== 'ok' || push.enabled || push.loading) return null;

  function dismiss() {
    setHidden(true);
    try { localStorage.setItem(DISMISS_KEY, String(Date.now() + 7 * 24 * 3600 * 1000)); } catch { /* تجاهل */ }
  }

  return (
    <div className="flex items-center gap-3 rounded-card bg-brand-soft px-4 py-3">
      <BellRinging className="size-7 shrink-0 text-brand" weight="duotone" />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-bold">فعّل الإشعارات</p>
        <p className="text-xs leading-relaxed text-muted">تأكيد كل عملية، والميزانية، والمصاريف الثابتة</p>
      </div>
      <Button className="h-10 shrink-0 px-4 text-sm" loading={busy} disabled={!push.ready}
        onClick={async () => {
          setBusy(true);
          try { await push.enable(); toast.success('تم تفعيل الإشعارات'); } catch (e) { toast.error((e as Error).message); } finally { setBusy(false); }
        }}>
        تفعيل
      </Button>
      <button type="button" onClick={dismiss} aria-label="إخفاء" className="shrink-0 text-muted"><X className="size-4" weight="bold" /></button>
    </div>
  );
}
