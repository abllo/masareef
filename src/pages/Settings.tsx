import { useEffect, useState, type FormEvent, type ReactNode } from 'react';
import { Link, useParams } from 'react-router';
import { toast } from 'sonner';
import {
  AirplaneTilt, ArrowsClockwise, BellRinging, CalendarBlank, CalendarPlus, CaretLeft, ChartBar, ChatCircleText, Copy, CreditCard, Key, LockKey, Repeat,
  ShieldCheck, SignOut, Plus, Sparkle, Tag, Target, UserCircle, UserMinus, UsersThree, type Icon,
} from '@phosphor-icons/react';
import { AiPanel } from '../components/AiPanel';
import { CardsSection } from '../components/CardsSection';
import { NotificationsCard } from '../components/Notifications';
import { BackButton, Button, Card, CategoryIcon, ConfirmButton, Field, IconButton, Sheet, cx } from '../components/ui';
import { useHousehold, useIsOwner } from '../hooks/household';
import { useAiStatus, useCards, useCategories, useDeleteCategory, useInvalidate, useSaveCategory, useUpdateHousehold } from '../hooks/queries';
import { usePushStatus } from '../hooks/push';
import { useAuth } from '../hooks/auth';
import {
  calendarUrl, fetchSmsToken, leaveHousehold, regenerateInviteCode, regenerateSmsToken, removeMember, setSalaryPayer, translateError,
} from '../lib/api';
import { amountsHidden, disableLock, enableLock, lockAvailable, lockEnabled, setAmountsHidden } from '../lib/lock';
import { CATEGORY_COLORS, CATEGORY_ICONS, COLOR_LABELS, ICON_LABELS } from '../lib/icons';
import { formatSAR, parseAmount, toInputValue } from '../lib/money';
import { SUPABASE_KEY, SUPABASE_URL, supabase } from '../lib/supabase';
import type { Category } from '../lib/types';

/** أقسام الإعدادات: كل قسم صفحة مستقلة */
const SECTIONS: Record<string, { title: string; owner?: boolean; render: () => ReactNode }> = {
  account: { title: 'حسابي', render: () => <><ProfileSection /><PasswordSection /></> },
  notifications: { title: 'الإشعارات', render: () => <NotificationsCard /> },
  privacy: { title: 'القفل والخصوصية', render: () => <PrivacySection /> },
  calendar: { title: 'تقويم الآيفون', render: () => <CalendarSection /> },
  family: { title: 'العائلة', render: () => <FamilySection /> },
  budget: { title: 'الميزانية', render: () => <BudgetSection /> },
  categories: { title: 'التصنيفات', owner: true, render: () => <CategoriesSection /> },
  cards: { title: 'البطاقات والبنوك', owner: true, render: () => <CardsSection /> },
  sms: { title: 'رسائل البنك', render: () => <SmsSection /> },
  ai: { title: 'الذكاء الاصطناعي', render: () => <AiPanel /> },
};

export default function Settings() {
  const { section } = useParams();
  const isOwner = useIsOwner();
  const s = section ? SECTIONS[section] : undefined;
  if (!s || (s.owner && !isOwner)) return <SettingsHome />;
  return (
    <div className="space-y-4 pt-4">
      <BackButton fallback="/settings" label="الإعدادات" />
      {s.render()}
    </div>
  );
}

function Row({ to, icon: RowIcon, tone, title, value }: { to: string; icon: Icon; tone: string; title: string; value?: ReactNode }) {
  return (
    <Link to={to} className="flex items-center gap-3 px-4 py-3 transition active:bg-surface-2">
      <span className="flex size-9 shrink-0 items-center justify-center rounded-xl text-white" style={{ background: tone }}>
        <RowIcon className="size-5" weight="fill" />
      </span>
      <span className="min-w-0 flex-1 font-medium">{title}</span>
      {value !== undefined && <span className="max-w-[45%] truncate text-sm text-muted">{value}</span>}
      <CaretLeft className="size-4 shrink-0 text-muted" weight="bold" />
    </Link>
  );
}

function Group({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section>
      {title && <h2 className="mb-1.5 px-4 text-xs font-semibold text-muted">{title}</h2>}
      <div className="divide-y divide-line/70 overflow-hidden rounded-card bg-surface shadow-[0_1px_2px_rgb(0_0_0/0.04)]">{children}</div>
    </section>
  );
}

function SettingsHome() {
  const { household, me, members } = useHousehold();
  const { session } = useAuth();
  const isOwner = useIsOwner();
  const { data: categories = [] } = useCategories();
  const { data: cards = [] } = useCards();
  const { data: ai } = useAiStatus();
  const { data: push } = usePushStatus();
  const activeCats = categories.filter((c) => !c.is_archived).length;

  return (
    <div className="space-y-5 pt-4">
      <h1 className="text-xl font-bold">الإعدادات</h1>

      <Link to="/settings/account" className="flex items-center gap-3 rounded-card bg-surface p-4 shadow-[0_1px_2px_rgb(0_0_0/0.04)]">
        <span className="flex size-14 shrink-0 items-center justify-center rounded-full bg-brand text-2xl font-bold text-brand-ink">
          {me.display_name.trim().charAt(0)}
        </span>
        <span className="min-w-0 flex-1">
          <span className="block truncate text-lg font-bold">{me.display_name}</span>
          <span className="block truncate text-sm text-muted" dir="ltr">{session?.user.email}</span>
          <span className="mt-1 inline-block rounded-full bg-brand-soft px-2 py-0.5 text-[11px] font-semibold text-brand">
            {isOwner ? 'منشئ العائلة' : 'عضو'} · {household.name}
          </span>
        </span>
        <CaretLeft className="size-4 shrink-0 text-muted" weight="bold" />
      </Link>

      <Group>
        <Row to="/settings/notifications" icon={BellRinging} tone="#E11D48" title="الإشعارات"
          value={push ? (push.devices > 0 ? 'مفعّلة' : 'غير مفعّلة') : undefined} />
        <Row to="/settings/privacy" icon={LockKey} tone="#0F172A" title="القفل والخصوصية" value={lockEnabled() ? 'Face ID' : undefined} />
        <Row to="/settings/calendar" icon={CalendarBlank} tone="#DC2626" title="تقويم الآيفون" />
        <Row to="/settings/family" icon={UsersThree} tone="#2563EB" title="العائلة" value={`${members.length} ${members.length > 2 ? 'أفراد' : members.length === 2 ? 'فردين' : 'فرد'}`} />
        <Row to="/settings/budget" icon={Target} tone="#0E6B58" title="الميزانية الشهرية"
          value={household.monthly_budget ? formatSAR(household.monthly_budget) : 'غير محددة'} />
      </Group>

      {isOwner && (
        <Group title="الإدارة">
          <Row to="/settings/categories" icon={Tag} tone="#7C3AED" title="التصنيفات" value={`${activeCats}`} />
          <Row to="/settings/cards" icon={CreditCard} tone="#475569" title="البطاقات والبنوك" value={cards.length ? `${cards.length}` : undefined} />
        </Group>
      )}

      <Group title="التسجيل التلقائي">
        <Row to="/settings/sms" icon={ChatCircleText} tone="#16A34A" title="اختصار رسائل البنك" />
        <Row to="/settings/ai" icon={Sparkle} tone="#C2410C" title="الذكاء الاصطناعي"
          value={ai ? (ai.enabled ? 'Claude يعمل' : 'غير مفعّل') : undefined} />
        <Row to="/messages" icon={ChatCircleText} tone="#0891B2" title="سجل رسائل البنك" />
      </Group>

      <Group title="البيت">
        <Row to="/recurring" icon={Repeat} tone="#B45309" title="المصاريف الثابتة" />
        <Row to="/renewals" icon={ShieldCheck} tone="#9333EA" title="التجديدات والضمانات" />
        <Row to="/trips" icon={AirplaneTilt} tone="#0284C7" title="الرحلات" />
        <Row to="/years" icon={ChartBar} tone="#0E6B58" title="المقارنة السنوية" />
      </Group>

      <Button variant="ghost" className="w-full text-danger" onClick={() => supabase.auth.signOut()}>
        <SignOut className="size-5" weight="bold" /> تسجيل الخروج
      </Button>
    </div>
  );
}

function ProfileSection() {
  const { me } = useHousehold();
  const update = useUpdateHousehold();
  const invalidate = useInvalidate();
  const [name, setName] = useState(me.display_name);
  const [payer, setPayer] = useState(me.salary_payer ?? '');
  const [savingPayer, setSavingPayer] = useState(false);
  return (
    <Card>
      <h2 className="inline-flex items-center gap-2 font-bold"><UserCircle className="size-5 text-brand" weight="duotone" />حسابي</h2>
      <form className="mt-4 flex items-end gap-2" onSubmit={(e) => {
        e.preventDefault();
        if (!name.trim()) return toast.error('الاسم لا يمكن أن يكون فارغاً');
        update.mutate({ display_name: name.trim() });
      }}>
        <Field label="اسمك" className="flex-1" value={name} maxLength={30} onChange={(e) => setName(e.target.value)} />
        <Button type="submit" variant="secondary" loading={update.isPending}>حفظ</Button>
      </form>
      <form className="mt-3 flex items-end gap-2" onSubmit={async (e) => {
        e.preventDefault();
        setSavingPayer(true);
        try {
          await setSalaryPayer(payer);
          await invalidate('household');
          toast.success('تم الحفظ');
        } catch (err) {
          toast.error((err as Error).message);
        } finally {
          setSavingPayer(false);
        }
      }}>
        <Field label="جهة الراتب" placeholder="جهة عملك" className="flex-1" value={payer} maxLength={120} onChange={(e) => setPayer(e.target.value)} />
        <Button type="submit" variant="secondary" loading={savingPayer}>حفظ</Button>
      </form>
    </Card>
  );
}

function PrivacySection() {
  const { me } = useHousehold();
  const { session } = useAuth();
  const [available, setAvailable] = useState<boolean | null>(null);
  const [locked, setLocked] = useState(lockEnabled);
  const [hidden, setHidden] = useState(amountsHidden);
  const [busy, setBusy] = useState(false);
  useEffect(() => { void lockAvailable().then(setAvailable); }, []);

  async function toggleLock(on: boolean) {
    if (!on) {
      disableLock();
      setLocked(false);
      return;
    }
    setBusy(true);
    try {
      await enableLock(session?.user.email ?? me.display_name);
      setLocked(true);
      toast.success('تم تفعيل القفل');
    } catch (e) {
      toast.error(e instanceof DOMException && e.name === 'NotAllowedError' ? 'تم الإلغاء' : 'تعذّر تفعيل القفل');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card className="space-y-2">
      <h2 className="mb-2 inline-flex items-center gap-2 font-bold"><LockKey className="size-5 text-brand" weight="duotone" />القفل والخصوصية</h2>
      <label className="flex items-center justify-between gap-3 rounded-2xl bg-surface-2 px-4 py-3">
        <span>
          <span className="block font-medium">قفل التطبيق بـ Face ID</span>
          {available === false && <span className="text-xs text-muted">غير متاح على هذا الجهاز</span>}
        </span>
        <input type="checkbox" checked={locked} disabled={available === false || busy}
          onChange={(e) => void toggleLock(e.target.checked)} className="size-5 accent-[var(--color-brand)]" />
      </label>
      <label className="flex items-center justify-between gap-3 rounded-2xl bg-surface-2 px-4 py-3">
        <span className="font-medium">إخفاء المبالغ</span>
        <input type="checkbox" checked={hidden} onChange={(e) => { setAmountsHidden(e.target.checked); setHidden(e.target.checked); }}
          className="size-5 accent-[var(--color-brand)]" />
      </label>
    </Card>
  );
}

function CalendarSection() {
  const [url, setUrl] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function subscribe() {
    setBusy(true);
    try {
      const u = url ?? (await calendarUrl());
      setUrl(u);
      window.location.href = u;
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Card className="space-y-3">
      <h2 className="inline-flex items-center gap-2 font-bold"><CalendarBlank className="size-5 text-brand" weight="duotone" />تقويم الآيفون</h2>
      <p className="text-sm text-muted">التجديدات والفواتير والمصاريف الثابتة في تقويمك.</p>
      <Button className="w-full" loading={busy} onClick={subscribe}>
        <CalendarPlus className="size-5" weight="bold" /> إضافة للتقويم
      </Button>
      {url && <CopyRow label="رابط الاشتراك" value={url} copied="تم نسخ الرابط" />}
    </Card>
  );
}

async function copyText(text: string, message: string) {
  try {
    await navigator.clipboard.writeText(text);
    toast.success(message);
  } catch {
    toast.error('تعذّر النسخ، اضغط مطولاً على النص وانسخه');
  }
}

function BudgetSection() {
  const { household } = useHousehold();
  const isOwner = useIsOwner();
  const update = useUpdateHousehold();
  const [text, setText] = useState(household.monthly_budget ? toInputValue(household.monthly_budget) : '');

  function submit(e: FormEvent) {
    e.preventDefault();
    if (text.trim() === '') return update.mutate({ monthly_budget: null });
    const v = parseAmount(text);
    if (!v) return toast.error('أدخل مبلغاً صحيحاً');
    update.mutate({ monthly_budget: v });
  }

  return (
    <Card>
      <h2 className="inline-flex items-center gap-2 font-bold"><Target className="size-5 text-brand" weight="duotone" />الميزانية الشهرية</h2>
      <p className="mt-1 text-sm text-muted">
        {household.monthly_budget ? `الحالية: ${formatSAR(household.monthly_budget)}` : 'غير محددة'}
      </p>
      {isOwner && <form onSubmit={submit} className="mt-4 flex items-end gap-2">
        <Field label="المبلغ (ر.س)" inputMode="decimal" dir="ltr" placeholder="12000" className="flex-1"
          value={text} onChange={(e) => setText(e.target.value)} />
        <Button type="submit" loading={update.isPending}>حفظ</Button>
      </form>}
    </Card>
  );
}

function FamilySection() {
  const { household, me, members } = useHousehold();
  const update = useUpdateHousehold();
  const invalidate = useInvalidate();
  const [familyName, setFamilyName] = useState(household.name);
  const [rotating, setRotating] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const isOwner = me.role === 'owner';

  async function rotate() {
    setRotating(true);
    try {
      await regenerateInviteCode();
      await invalidate('household');
      toast.success('تم إنشاء رمز دعوة جديد');
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setRotating(false);
    }
  }

  async function remove(userId: string, displayName: string) {
    setBusy(userId);
    try {
      await removeMember(userId);
      await invalidate('household');
      toast.success(`تمت إزالة ${displayName} من العائلة`);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function leave() {
    setBusy(me.user_id);
    try {
      await leaveHousehold();
      await invalidate('household');
      toast.success('غادرت العائلة');
    } catch (e) {
      toast.error((e as Error).message);
      setBusy(null);
    }
  }

  return (
    <Card className="space-y-4">
      <h2 className="inline-flex items-center gap-2 font-bold"><UsersThree className="size-5 text-brand" weight="duotone" />العائلة</h2>
      {isOwner && (
        <form className="flex items-end gap-2" onSubmit={(e) => {
          e.preventDefault();
          if (!familyName.trim()) return toast.error('اسم العائلة لا يمكن أن يكون فارغاً');
          update.mutate({ name: familyName.trim() });
        }}>
          <Field label="اسم العائلة" className="flex-1" value={familyName} maxLength={60} onChange={(e) => setFamilyName(e.target.value)} />
          <Button type="submit" variant="secondary" loading={update.isPending}>حفظ</Button>
        </form>
      )}

      <div>
        <p className="mb-2 text-sm font-medium text-muted">الأعضاء</p>
        <ul className="space-y-1">
          {members.map((m) => (
            <li key={m.user_id} className="flex items-center justify-between gap-2 rounded-xl bg-surface-2 px-4 py-2.5">
              <span className="min-w-0 flex-1 truncate font-medium">{m.display_name}{m.user_id === me.user_id && ' (أنت)'}</span>
              <span className="text-xs text-muted">{m.role === 'owner' ? 'المنشئ' : 'عضو'}</span>
              {isOwner && m.user_id !== me.user_id && (
                <ConfirmButton className="h-8 px-3 text-xs" loading={busy === m.user_id} confirmText="تأكيد الإزالة"
                  onConfirm={() => remove(m.user_id, m.display_name)}>
                  <UserMinus className="size-4" weight="bold" /> إزالة
                </ConfirmButton>
              )}
            </li>
          ))}
        </ul>
      </div>

      <div className="rounded-2xl border border-dashed border-line p-4">
        <p className="text-sm text-muted">رمز الدعوة</p>
        <div className="mt-3 flex items-center gap-2">
          <code dir="ltr" className="flex-1 rounded-xl bg-surface-2 py-2.5 text-center text-xl font-bold tracking-[.3em]">
            {household.invite_code}
          </code>
          <IconButton label="نسخ الرمز" onClick={() => copyText(household.invite_code, 'تم نسخ رمز الدعوة')}>
            <Copy className="size-5" weight="bold" />
          </IconButton>
          {isOwner && (
            <IconButton label="إنشاء رمز جديد" onClick={rotate} disabled={rotating}>
              <ArrowsClockwise className={cx('size-5', rotating && 'animate-spin')} weight="bold" />
            </IconButton>
          )}
        </div>
      </div>

      {!isOwner && (
        <ConfirmButton className="w-full" loading={busy === me.user_id} confirmText="تأكيد المغادرة" onConfirm={leave}>
          مغادرة العائلة
        </ConfirmButton>
      )}
    </Card>
  );
}

function CopyRow({ label, value, copied }: { label: string; value: string; copied: string }) {
  return (
    <div>
      <p className="mb-1 text-sm font-medium text-muted">{label}</p>
      <div className="flex items-center gap-2">
        <code dir="ltr" className="min-w-0 flex-1 select-all truncate rounded-xl bg-surface-2 px-3 py-2.5 text-sm">{value}</code>
        <IconButton label={`نسخ ${label}`} onClick={() => copyText(value, copied)}>
          <Copy className="size-5" weight="bold" />
        </IconButton>
      </div>
    </div>
  );
}

/** قيم اختصار الآيفون: الرابط والمفتاح ورمز المستخدم، مع طريقة الإعداد */
function SmsSection() {
  const [token, setToken] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [rotating, setRotating] = useState(false);
  const endpoint = `${SUPABASE_URL}/rest/v1/rpc/sms_expense`;

  async function reveal() {
    setLoading(true);
    try {
      setToken(await fetchSmsToken());
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setLoading(false);
    }
  }

  async function rotate() {
    setRotating(true);
    try {
      setToken(await regenerateSmsToken());
      toast.success('تم إنشاء رمز جديد، حدّثه في الاختصار');
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setRotating(false);
    }
  }

  return (
    <Card className="space-y-4">
      <div>
        <h2 className="inline-flex items-center gap-2 font-bold"><ChatCircleText className="size-5 text-brand" weight="duotone" />التسجيل التلقائي من رسائل البنك</h2>
      </div>
      <CopyRow label="1. الرابط" value={endpoint} copied="تم نسخ الرابط" />
      <CopyRow label="2. المفتاح (apikey)" value={SUPABASE_KEY} copied="تم نسخ المفتاح" />
      {token ? (
        <>
          <CopyRow label="3. رمزك الخاص (token)" value={token} copied="تم نسخ رمزك الخاص" />
          <p className="text-xs text-danger">لا تشارك هذا الرمز.</p>
          <ConfirmButton className="h-10 px-4 text-sm" loading={rotating} confirmText="تأكيد: الرمز القديم سيتوقف" onConfirm={rotate}>
            <ArrowsClockwise className="size-4" weight="bold" /> تجديد رمزي
          </ConfirmButton>
        </>
      ) : (
        <Button variant="secondary" onClick={reveal} loading={loading}>
          <Key className="size-5" weight="duotone" /> إظهار رمزك الخاص
        </Button>
      )}

      <details className="rounded-2xl bg-surface-2 px-4 py-3 text-sm">
        <summary className="cursor-pointer font-semibold">طريقة إعداد الاختصار</summary>
        <ol className="mt-3 list-decimal space-y-2 ps-5 leading-relaxed text-muted">
          <li>تطبيق <b>الاختصارات</b> ← <b>+</b> ← أضف إجراء <b>«الحصول على محتويات URL»</b>، والصق <b>الرابط</b>.</li>
          <li>اضغط السهم الأزرق: <b>الطريقة POST</b>.</li>
          <li><b>الرؤوس (Headers)</b> ← أضف رأساً: المفتاح <code dir="ltr">apikey</code> والقيمة <b>المفتاح</b>.</li>
          <li><b>نص الطلب: JSON</b> ← أضف حقلاً نصياً <code dir="ltr">token</code> وقيمته <b>رمزك الخاص</b>، وحقلاً نصياً <code dir="ltr">message</code> واختر له <b>«مدخل الاختصار»</b> من الشريط فوق الكيبورد، وحقلاً نصياً <code dir="ltr">sender</code> واختر له <b>«مدخل الاختصار»</b> ثم اضغط عليه واختر <b>«المرسل»</b>.</li>
          <li>سمِّ الاختصار <b>«تسجيل مصروف»</b>.</li>
          <li><b>التحكم التلقائي</b> ← <b>+</b> ← <b>رسالة</b> ← الرسالة تتضمن <b dir="ltr">SAR</b> ← إجراء «تشغيل الاختصار: تسجيل مصروف» بالمدخل <b>إدخال الاختصار</b> ← أطفئ «التأكيد قبل التشغيل». وكرّرها لـ <b>ريال</b> و<b>ر.س</b> و<b>تنتهي</b>.</li>
          <li>فعّل الإشعارات من الإعدادات ← الإشعارات.</li>
        </ol>
      </details>
    </Card>
  );
}

function PasswordSection() {
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (password.length < 6) return toast.error('كلمة المرور 6 أحرف أو أرقام على الأقل');
    setLoading(true);
    const { error } = await supabase.auth.updateUser({ password });
    setLoading(false);
    if (error) return toast.error(translateError(error.message));
    setPassword('');
    toast.success('تم تغيير كلمة المرور');
  }

  return (
    <Card>
      <h2 className="inline-flex items-center gap-2 font-bold"><Key className="size-5 text-brand" weight="duotone" />كلمة المرور</h2>
      <form onSubmit={submit} className="mt-4 flex items-end gap-2">
        <Field label="كلمة مرور جديدة" type="password" dir="ltr" autoComplete="new-password" minLength={6} className="flex-1"
          value={password} onChange={(e) => setPassword(e.target.value)} />
        <Button type="submit" variant="secondary" loading={loading}>تغيير</Button>
      </form>
    </Card>
  );
}

function CategoriesSection() {
  const { data: categories = [] } = useCategories();
  const [editing, setEditing] = useState<{ open: boolean; item?: Category }>({ open: false });

  return (
    <Card className="p-3">
      <div className="flex items-center justify-between px-2 pt-2">
        <h2 className="inline-flex items-center gap-2 font-bold"><Tag className="size-5 text-brand" weight="duotone" />التصنيفات</h2>
        <Button variant="ghost" className="h-9 px-3 text-sm" onClick={() => setEditing({ open: true })}>
          <Plus className="size-4" weight="bold" /> تصنيف جديد
        </Button>
      </div>
      <ul className="mt-2">
        {categories.map((c) => (
          <li key={c.id}>
            <button type="button" onClick={() => setEditing({ open: true, item: c })}
              className={cx('flex w-full items-center gap-3 rounded-2xl px-2 py-2 text-start hover:bg-surface-2', c.is_archived && 'opacity-50')}>
              <CategoryIcon category={c} size="sm" />
              <span className="flex-1 font-medium">{c.name}</span>
              {c.is_core && <span className="text-xs text-muted">أساسي</span>}
              {c.created_by_ai && !c.is_core && <span className="text-xs text-brand">أنشأه Claude</span>}
              {c.is_archived && <span className="text-xs text-muted">مؤرشف</span>}
            </button>
          </li>
        ))}
      </ul>
      <Sheet open={editing.open} onOpenChange={(o) => setEditing((s) => ({ ...s, open: o }))}
        title={editing.item ? 'تعديل التصنيف' : 'تصنيف جديد'}>
        <CategoryForm key={editing.item?.id ?? 'new'} item={editing.item} nextOrder={categories.length + 1}
          onDone={() => setEditing({ open: false })} />
      </Sheet>
    </Card>
  );
}

function CategoryForm({ item, nextOrder, onDone }: { item?: Category; nextOrder: number; onDone: () => void }) {
  const save = useSaveCategory();
  const remove = useDeleteCategory();
  const [name, setName] = useState(item?.name ?? '');
  const [icon, setIcon] = useState(item?.icon ?? 'circle');
  const [color, setColor] = useState(item?.color ?? CATEGORY_COLORS[0]!);
  const [archived, setArchived] = useState(item?.is_archived ?? false);
  const preview = { ...(item ?? ({} as Category)), icon, color };

  function submit(e: FormEvent) {
    e.preventDefault();
    if (!name.trim()) return toast.error('اكتب اسم التصنيف');
    save.mutate(
      { id: item?.id, input: { name: name.trim(), icon, color, is_archived: archived, ...(item ? {} : { sort_order: nextOrder }) } },
      { onSuccess: onDone },
    );
  }

  return (
    <form onSubmit={submit} className="space-y-4 pb-2">
      <div className="flex items-end gap-3">
        <CategoryIcon category={preview} size="lg" />
        <Field label="الاسم" className="flex-1" value={name} maxLength={40} autoFocus={!item} onChange={(e) => setName(e.target.value)} />
      </div>
      <fieldset>
        <legend className="mb-2 text-sm font-medium text-muted">الأيقونة</legend>
        <div className="grid grid-cols-6 gap-1.5 sm:grid-cols-8">
          {Object.entries(CATEGORY_ICONS).map(([key, Icon]) => (
            <button key={key} type="button" aria-label={ICON_LABELS[key] ?? key} title={ICON_LABELS[key]} aria-pressed={icon === key} onClick={() => setIcon(key)}
              className={cx('flex aspect-square items-center justify-center rounded-xl transition active:scale-90', icon === key ? 'text-white' : 'bg-surface-2 text-muted')}
              style={icon === key ? { background: color } : undefined}>
              <Icon className="size-5" weight="duotone" />
            </button>
          ))}
        </div>
      </fieldset>
      <fieldset>
        <legend className="mb-2 text-sm font-medium text-muted">اللون</legend>
        <div className="flex flex-wrap gap-2">
          {CATEGORY_COLORS.map((c) => (
            <button key={c} type="button" aria-label={COLOR_LABELS[c] ?? c} title={COLOR_LABELS[c]} aria-pressed={color === c} onClick={() => setColor(c)}
              className={cx('size-9 rounded-full ring-offset-2 ring-offset-surface', color === c && 'ring-2 ring-ink')}
              style={{ background: c }} />
          ))}
        </div>
      </fieldset>
      {item?.is_core && (
        <p className="rounded-2xl bg-surface-2 px-4 py-3 text-xs text-muted">
          تصنيف أساسي لا يمكن حذفه.
        </p>
      )}
      {item && !item.is_core && (
        <label className="flex items-center justify-between rounded-2xl bg-surface-2 px-4 py-3">
          <span>
            <span className="block font-medium">أرشفة</span>
          </span>
          <input type="checkbox" checked={archived} onChange={(e) => setArchived(e.target.checked)} className="size-5 accent-[var(--color-brand)]" />
        </label>
      )}
      <div className="flex gap-2">
        <Button type="submit" loading={save.isPending} className="flex-1">{item ? 'حفظ التعديل' : 'إضافة'}</Button>
        {item && !item.is_core && (
          <ConfirmButton loading={remove.isPending} confirmText="تأكيد الحذف"
            onConfirm={() => remove.mutate(item.id, { onSuccess: onDone })}>حذف</ConfirmButton>
        )}
      </div>
    </form>
  );
}
