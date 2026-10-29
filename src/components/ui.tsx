import { useEffect, useState, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode } from 'react';
import { Drawer } from 'vaul';
import { animate } from 'motion';
import { CaretDown, CaretLeft, CaretRight, CircleNotch, type Icon } from '@phosphor-icons/react';
import { addMonths, formatMonth, monthOf, todayISO } from '../lib/dates';
import { iconFor } from '../lib/icons';
import { formatSAR } from '../lib/money';
import type { Category, MonthKey } from '../lib/types';

export const cx = (...c: (string | false | null | undefined)[]) => c.filter(Boolean).join(' ');

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger';
const variants: Record<Variant, string> = {
  primary: 'bg-brand text-brand-ink shadow-sm shadow-brand/20 hover:opacity-90',
  secondary: 'bg-surface-2 text-ink hover:bg-line',
  ghost: 'text-ink hover:bg-surface-2',
  danger: 'bg-danger-soft text-danger hover:opacity-90',
};

export function Button({
  variant = 'primary', loading, className, children, disabled, ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; loading?: boolean }) {
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={cx(
        'inline-flex h-12 items-center justify-center gap-2 rounded-2xl px-5 font-semibold transition active:scale-[.97] disabled:opacity-50',
        variants[variant], className,
      )}
    >
      {loading && <CircleNotch className="size-4 animate-spin" weight="bold" />}
      {children}
    </button>
  );
}

export function IconButton({ label, className, children, ...rest }: ButtonHTMLAttributes<HTMLButtonElement> & { label: string }) {
  return (
    <button
      {...rest}
      aria-label={label}
      title={label}
      className={cx('inline-flex size-10 items-center justify-center rounded-full text-muted transition hover:bg-surface-2 hover:text-ink active:scale-95', className)}
    >
      {children}
    </button>
  );
}

/** زر حذف يحتاج ضغطتين: أسرع من نافذة تأكيد وأأمن من الحذف المباشر */
export function ConfirmButton({ onConfirm, children, confirmText = 'اضغط مرة أخرى للتأكيد', loading, className }: {
  onConfirm: () => void; children: ReactNode; confirmText?: string; loading?: boolean; className?: string;
}) {
  const [armed, setArmed] = useState(false);
  useEffect(() => {
    if (!armed) return;
    const t = setTimeout(() => setArmed(false), 3000);
    return () => clearTimeout(t);
  }, [armed]);
  return (
    <Button type="button" variant="danger" loading={loading} className={className}
      onClick={() => (armed ? onConfirm() : setArmed(true))}>
      {armed ? confirmText : children}
    </Button>
  );
}

// كل الحقول 16px على الأقل حتى لا يكبّر الآيفون الشاشة عند الكتابة
const fieldClass = 'h-12 w-full rounded-2xl border border-line bg-surface px-4 text-base outline-none transition focus:border-brand focus:ring-4 focus:ring-brand/10';

export function Field({ label, hint, className, ...rest }: InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: string }) {
  return (
    <label className={cx('block', className)}>
      <span className="mb-1.5 block text-sm font-medium text-muted">{label}</span>
      <input {...rest} className={fieldClass} />
      {hint && <span className="mt-1 block text-xs text-muted">{hint}</span>}
    </label>
  );
}

/** قائمة اختيار أصلية (أفضل تجربة على الجوال) مع سهم واضح */
export function Select<T extends string>({ label, value, onChange, options, showLabel, icon: LeadIcon }: {
  label: string; value: T; onChange: (v: T) => void; options: { value: T; label: string; disabled?: boolean }[];
  showLabel?: boolean; icon?: Icon;
}) {
  return (
    <label className="block">
      <span className={showLabel ? 'mb-1.5 block text-sm font-medium text-muted' : 'sr-only'}>{label}</span>
      <span className="relative block">
        {LeadIcon && <LeadIcon className="pointer-events-none absolute start-3.5 top-1/2 size-5 -translate-y-1/2 text-muted" />}
        <select aria-label={label} value={value} onChange={(e) => onChange(e.target.value as T)}
          className={cx(fieldClass, 'appearance-none pe-10', LeadIcon && 'ps-11')}>
          {options.map((o) => <option key={o.value} value={o.value} disabled={o.disabled}>{o.label}</option>)}
        </select>
        <CaretDown className="pointer-events-none absolute end-3.5 top-1/2 size-4 -translate-y-1/2 text-muted" weight="bold" />
      </span>
    </label>
  );
}

export function Spinner({ full }: { full?: boolean }) {
  return (
    <div className={cx('flex items-center justify-center text-brand', full ? 'min-h-dvh' : 'py-20')}>
      <CircleNotch className="size-8 animate-spin" weight="bold" aria-label="جارٍ التحميل" />
    </div>
  );
}

export function FullScreenMessage({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="flex min-h-dvh items-center justify-center p-6">
      <div className="max-w-md text-center">
        <h1 className="mb-2 text-xl font-bold">{title}</h1>
        <p className="leading-relaxed text-muted">{children}</p>
      </div>
    </div>
  );
}

export function EmptyState({ icon: EmptyIcon, title, children }: { icon?: Icon; title: string; children?: ReactNode }) {
  return (
    <div className="flex flex-col items-center rounded-card bg-surface px-6 py-10 text-center">
      {EmptyIcon && (
        <span className="mb-4 flex size-16 items-center justify-center rounded-3xl bg-brand-soft text-brand">
          <EmptyIcon className="size-8" weight="duotone" />
        </span>
      )}
      <p className="font-bold">{title}</p>
      {children && <div className="mt-1.5 max-w-xs text-sm leading-relaxed text-muted">{children}</div>}
    </div>
  );
}

export function CategoryIcon({ category, size = 'md' }: { category?: Category; size?: 'sm' | 'md' | 'lg' }) {
  const Glyph = iconFor(category?.icon ?? 'circle');
  const color = category?.color ?? '#64748B';
  const dims = { sm: 'size-9 rounded-xl', md: 'size-11 rounded-2xl', lg: 'size-14 rounded-2xl' }[size];
  const glyph = { sm: 'size-5', md: 'size-6', lg: 'size-7' }[size];
  return (
    <span className={cx('inline-flex shrink-0 items-center justify-center', dims)}
      style={{ backgroundColor: `${color}1A`, color }}>
      <Glyph className={glyph} weight="duotone" />
    </span>
  );
}

export function MonthSwitcher({ month, onChange }: { month: MonthKey; onChange: (m: MonthKey) => void }) {
  const current = monthOf(todayISO());
  const isCurrent = month >= current;
  return (
    <div className="flex items-center gap-0.5 rounded-full bg-surface p-1 shadow-sm">
      {/* في الاتجاه RTL: السهم الأيمن = الشهر السابق */}
      <IconButton label="الشهر السابق" className="size-8" onClick={() => onChange(addMonths(month, -1))}>
        <CaretRight className="size-4" weight="bold" />
      </IconButton>
      <button type="button" onClick={() => onChange(current)}
        className="min-w-28 rounded-full px-2 text-center text-sm font-semibold" title="العودة للشهر الحالي">
        {formatMonth(month)}
      </button>
      <IconButton label="الشهر التالي" disabled={isCurrent} className="size-8 disabled:opacity-25"
        onClick={() => onChange(addMonths(month, 1))}>
        <CaretLeft className="size-4" weight="bold" />
      </IconButton>
    </div>
  );
}

/** لوحة سفلية على الجوال، ونافذة بعرض محدود على الكمبيوتر */
export function Sheet({ open, onOpenChange, title, children }: {
  open: boolean; onOpenChange: (o: boolean) => void; title: string; children: ReactNode;
}) {
  return (
    <Drawer.Root open={open} onOpenChange={onOpenChange} repositionInputs={false}>
      <Drawer.Portal>
        <Drawer.Overlay className="fixed inset-0 z-40 bg-black/40 backdrop-blur-[2px]" />
        <Drawer.Content
          dir="rtl"
          className="fixed inset-x-0 bottom-0 z-50 mx-auto flex max-h-[94dvh] w-full max-w-lg flex-col rounded-t-[28px] bg-surface outline-none md:bottom-6 md:rounded-[28px]"
        >
          <div className="mx-auto mt-3 h-1.5 w-10 shrink-0 rounded-full bg-line md:hidden" />
          <Drawer.Title className="px-5 pt-4 text-lg font-bold">{title}</Drawer.Title>
          <Drawer.Description className="sr-only">{title}</Drawer.Description>
          <div className="overflow-y-auto px-5 pb-safe pt-3">{children}</div>
        </Drawer.Content>
      </Drawer.Portal>
    </Drawer.Root>
  );
}

export function Card({ className, children }: { className?: string; children: ReactNode }) {
  return <section className={cx('rounded-card bg-surface p-5 shadow-[0_1px_2px_rgb(0_0_0/0.04)]', className)}>{children}</section>;
}

export function SectionTitle({ children, action }: { children: ReactNode; action?: ReactNode }) {
  return (
    <div className="mb-3 flex items-center justify-between">
      <h2 className="font-bold">{children}</h2>
      {action}
    </div>
  );
}

/** مبلغ يتحرك عدّاً عند تغيّره */
export function AnimatedAmount({ value, className }: { value: number; className?: string }) {
  const [shown, setShown] = useState(value);
  useEffect(() => {
    const controls = animate(shown, value, {
      duration: 0.6, ease: [0.22, 1, 0.36, 1], onUpdate: (v) => setShown(Math.round(v)),
    });
    return () => controls.stop();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);
  return <span className={cx('num', className)}>{formatSAR(shown)}</span>;
}
