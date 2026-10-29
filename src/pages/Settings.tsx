import { useState, type FormEvent } from 'react';
import { toast } from 'sonner';
import {
  ArrowsClockwise, ChatCircleText, Copy, Key, SignOut, Plus, Tag, Target, UserMinus, UsersThree,
} from '@phosphor-icons/react';
import { AiPanel } from '../components/AiPanel';
import { CardsSection } from '../components/CardsSection';
import { Button, Card, CategoryIcon, ConfirmButton, Field, IconButton, Sheet, cx } from '../components/ui';
import { useHousehold } from '../hooks/household';
import { useCategories, useDeleteCategory, useInvalidate, useSaveCategory, useUpdateHousehold } from '../hooks/queries';
import {
  fetchSmsToken, leaveHousehold, regenerateInviteCode, regenerateSmsToken, removeMember, translateError,
} from '../lib/api';
import { CATEGORY_COLORS, CATEGORY_ICONS, COLOR_LABELS, ICON_LABELS } from '../lib/icons';
import { formatSAR, parseAmount, toInputValue } from '../lib/money';
import { SUPABASE_KEY, SUPABASE_URL, supabase } from '../lib/supabase';
import type { Category } from '../lib/types';

export default function Settings() {
  return (
    <div className="space-y-5 pt-4">
      <h1 className="text-xl font-bold">الإعدادات</h1>
      <BudgetSection />
      <FamilySection />
      <SmsSection />
      <AiPanel />
      <CardsSection />
      <CategoriesSection />
      <PasswordSection />
      <Button variant="ghost" className="w-full text-danger" onClick={() => supabase.auth.signOut()}>
        <SignOut className="size-5" weight="bold" /> تسجيل الخروج
      </Button>
    </div>
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
        {household.monthly_budget ? `الحالية: ${formatSAR(household.monthly_budget)}` : 'لم تُحدَّد بعد. اتركها فارغة لإلغائها.'}
      </p>
      <form onSubmit={submit} className="mt-4 flex items-end gap-2">
        <Field label="المبلغ (ر.س)" inputMode="decimal" dir="ltr" placeholder="مثال: 12000" className="flex-1"
          value={text} onChange={(e) => setText(e.target.value)} />
        <Button type="submit" loading={update.isPending}>حفظ</Button>
      </form>
    </Card>
  );
}

function FamilySection() {
  const { household, me, members } = useHousehold();
  const update = useUpdateHousehold();
  const invalidate = useInvalidate();
  const [name, setName] = useState(me.display_name);
  const [familyName, setFamilyName] = useState(household.name);
  const [rotating, setRotating] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const isOwner = me.role === 'owner';

  async function rotate() {
    setRotating(true);
    try {
      await regenerateInviteCode();
      await invalidate('household');
      toast.success('تم إنشاء رمز جديد، الرمز القديم لم يعد يعمل');
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
      <form className="space-y-3" onSubmit={(e) => {
        e.preventDefault();
        if (!name.trim() || !familyName.trim()) return toast.error('الأسماء لا يمكن أن تكون فارغة');
        update.mutate({ display_name: name.trim(), name: familyName.trim() });
      }}>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="اسمك" value={name} maxLength={30} onChange={(e) => setName(e.target.value)} />
          <Field label="اسم العائلة" value={familyName} maxLength={60} onChange={(e) => setFamilyName(e.target.value)} />
        </div>
        <Button type="submit" variant="secondary" loading={update.isPending}>حفظ الأسماء</Button>
      </form>

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
        {isOwner && members.length > 1 && (
          <p className="mt-2 text-xs text-muted">العضو المُزال يفقد الوصول فوراً، وتبقى عملياته في السجل.</p>
        )}
      </div>

      <div className="rounded-2xl border border-dashed border-line p-4">
        <p className="text-sm text-muted">شارك هذا الرمز مع زوجتك/زوجك ليسجّل وينضم إلى نفس الحساب العائلي:</p>
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
        {isOwner && <p className="mt-2 text-xs text-muted">بعد انضمام الجميع جدّد الرمز حتى لا يستخدمه أحد آخر.</p>}
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
      toast.success('تم إنشاء رمز جديد. حدّثه في الاختصار، القديم توقف');
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
        <p className="mt-1 text-sm text-muted">
          اختصار في الآيفون يرسل رسالة الشراء للتطبيق فتُسجَّل تلقائياً وتظهر بعلامة 📩. انسخ القيم الثلاث إلى الاختصار.
        </p>
      </div>
      <CopyRow label="1. الرابط" value={endpoint} copied="تم نسخ الرابط" />
      <CopyRow label="2. المفتاح (apikey)" value={SUPABASE_KEY} copied="تم نسخ المفتاح" />
      {token ? (
        <>
          <CopyRow label="3. رمزك الخاص (token)" value={token} copied="تم نسخ رمزك الخاص" />
          <p className="text-xs text-danger">رمزك يسجّل مصاريف باسمك في عائلتك، لا تعطه أحداً. إذا تسرّب جدّده من هنا.</p>
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
        <summary className="cursor-pointer font-semibold">طريقة إعداد الاختصار (مرة واحدة)</summary>
        <ol className="mt-3 list-decimal space-y-2 ps-5 leading-relaxed text-muted">
          <li>تطبيق <b>الاختصارات</b> ← <b>+</b> ← أضف إجراء <b>«الحصول على محتويات URL»</b>، والصق <b>الرابط</b>.</li>
          <li>اضغط السهم الأزرق: <b>الطريقة POST</b>.</li>
          <li><b>الرؤوس (Headers)</b> ← أضف رأساً: المفتاح <code dir="ltr">apikey</code> والقيمة <b>المفتاح</b>.</li>
          <li><b>نص الطلب: JSON</b> ← أضف حقلاً نصياً <code dir="ltr">token</code> وقيمته <b>رمزك الخاص</b>، وحقلاً نصياً <code dir="ltr">message</code> واختر له <b>«مدخل الاختصار»</b> من الشريط فوق الكيبورد.</li>
          <li>أضف إجراء <b>«إظهار إشعار»</b> واختر فيه <b>«محتويات URL»</b>، وسمِّ الاختصار <b>«تسجيل مصروف»</b>.</li>
          <li>جرّبه بزر التشغيل: إشعار <b>«تجاهل: رسالة فارغة»</b> يعني أن الإعداد صحيح.</li>
          <li><b>التحكم التلقائي</b> ← <b>+</b> ← <b>رسالة</b> ← الرسالة تتضمن <b>شراء</b> ← إجراء «تشغيل الاختصار: تسجيل مصروف» بالمدخل <b>إدخال الاختصار</b> ← أطفئ «التأكيد قبل التشغيل».</li>
          <li>إذا كان بنكك يرسل بالإنجليزي، كرّر الخطوة السابقة بكلمة <b dir="ltr">Purchase</b>.</li>
        </ol>
        <p className="mt-3 text-xs text-muted">
          يتجاهل التطبيق رسائل التحقق والإيداع والمرفوضة والملغاة، ولا يكرر الرسالة نفسها، ويربطها بالمصروف الثابت إن كان بنفس المبلغ.
        </p>
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
          تصنيف أساسي مثبّت: تقدر تغيّر اسمه وأيقونته ولونه، لكن ما ينحذف ولا يدمجه الذكاء الاصطناعي.
        </p>
      )}
      {item && !item.is_core && (
        <label className="flex items-center justify-between rounded-2xl bg-surface-2 px-4 py-3">
          <span>
            <span className="block font-medium">أرشفة</span>
            <span className="text-xs text-muted">يختفي من شاشة الإضافة، وتبقى عملياته السابقة</span>
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
