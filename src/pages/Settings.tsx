import { useState, type FormEvent } from 'react';
import { toast } from 'sonner';
import { ArrowsClockwise, Copy, SignOut, Plus, Tag, Target, UsersThree } from '@phosphor-icons/react';
import { Button, Card, CategoryIcon, ConfirmButton, Field, IconButton, Sheet, cx } from '../components/ui';
import { useHousehold } from '../hooks/household';
import { useCategories, useDeleteCategory, useInvalidate, useSaveCategory, useUpdateHousehold } from '../hooks/queries';
import { regenerateInviteCode } from '../lib/api';
import { CATEGORY_COLORS, CATEGORY_ICONS } from '../lib/icons';
import { formatSAR, parseAmount, toInputValue } from '../lib/money';
import { supabase } from '../lib/supabase';
import type { Category } from '../lib/types';

export default function Settings() {
  return (
    <div className="space-y-5 pt-4">
      <h1 className="text-xl font-bold">الإعدادات</h1>
      <BudgetSection />
      <FamilySection />
      <CategoriesSection />
      <Button variant="ghost" className="w-full text-danger" onClick={() => supabase.auth.signOut()}>
        <SignOut className="size-5" weight="bold" /> تسجيل الخروج
      </Button>
    </div>
  );
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

  async function copyCode() {
    await navigator.clipboard.writeText(household.invite_code).catch(() => {});
    toast.success('تم نسخ رمز الدعوة');
  }

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
            <li key={m.user_id} className="flex items-center justify-between rounded-xl bg-surface-2 px-4 py-2.5">
              <span className="font-medium">{m.display_name}{m.user_id === me.user_id && ' (أنت)'}</span>
              <span className="text-xs text-muted">{m.role === 'owner' ? 'المنشئ' : 'عضو'}</span>
            </li>
          ))}
        </ul>
      </div>

      <div className="rounded-2xl border border-dashed border-line p-4">
        <p className="text-sm text-muted">شارك هذا الرمز مع زوجتك/زوجك ليسجّل وينضم إلى نفس الحساب العائلي:</p>
        <div className="mt-3 flex items-center gap-2">
          <code dir="ltr" className="flex-1 rounded-xl bg-surface-2 py-2.5 text-center text-xl font-bold tracking-[.3em]">
            {household.invite_code}
          </code>
          <IconButton label="نسخ الرمز" onClick={copyCode}><Copy className="size-5" weight="bold" /></IconButton>
          {me.role === 'owner' && (
            <IconButton label="إنشاء رمز جديد" onClick={rotate} disabled={rotating}>
              <ArrowsClockwise className={cx('size-5', rotating && 'animate-spin')} weight="bold" />
            </IconButton>
          )}
        </div>
      </div>
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
            <button key={key} type="button" aria-label={key} aria-pressed={icon === key} onClick={() => setIcon(key)}
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
            <button key={c} type="button" aria-label={c} aria-pressed={color === c} onClick={() => setColor(c)}
              className={cx('size-9 rounded-full ring-offset-2 ring-offset-surface', color === c && 'ring-2 ring-ink')}
              style={{ background: c }} />
          ))}
        </div>
      </fieldset>
      {item && (
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
        {item && (
          <ConfirmButton loading={remove.isPending} confirmText="تأكيد الحذف"
            onConfirm={() => remove.mutate(item.id, { onSuccess: onDone })}>حذف</ConfirmButton>
        )}
      </div>
    </form>
  );
}
