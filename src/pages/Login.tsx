import { useState, type FormEvent } from 'react';
import { toast } from 'sonner';
import { Button, Field } from '../components/ui';
import { Logo } from '../components/Logo';
import { translateError } from '../lib/api';
import { supabase } from '../lib/supabase';

/** رابط الموقع بدون أي #مسار، تعود إليه روابط الإيميل */
const siteUrl = () => window.location.href.split('#')[0]!;

export default function Login() {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    const { data, error } = mode === 'signin'
      ? await supabase.auth.signInWithPassword({ email, password })
      : await supabase.auth.signUp({ email, password, options: { emailRedirectTo: siteUrl() } });
    setLoading(false);
    if (error) return toast.error(translateError(error.message));
    if (mode === 'signup' && !data.session) toast.success('أرسلنا رابط التأكيد إلى بريدك، افتحه ثم سجّل الدخول');
  }

  async function forgot() {
    if (!/\S+@\S+\.\S+/.test(email)) return toast.error('اكتب بريدك الإلكتروني أولاً');
    setSending(true);
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: siteUrl() });
    setSending(false);
    if (error) return toast.error(translateError(error.message));
    toast.success('إذا كان البريد مسجلاً فسيصلك رابط لتعيين كلمة مرور جديدة');
  }

  return (
    <div className="flex min-h-dvh items-center justify-center p-5">
      <div className="w-full max-w-sm">
        <div className="mb-8">
          <Logo className="mb-5 size-16 drop-shadow-lg" />
          <h1 className="text-3xl font-bold">مصاريف</h1>
          <p className="mt-2 text-muted">سجّلوا مصاريف العائلة في ثوانٍ، واعرفوا أين يذهب كل ريال.</p>
        </div>
        <form onSubmit={submit} className="space-y-4">
          <Field label="البريد الإلكتروني" type="email" dir="ltr" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          <Field label="كلمة المرور" type="password" dir="ltr" minLength={8} required
            autoComplete={mode === 'signin' ? 'current-password' : 'new-password'}
            value={password} onChange={(e) => setPassword(e.target.value)} />
          <Button type="submit" loading={loading} className="w-full">
            {mode === 'signin' ? 'تسجيل الدخول' : 'إنشاء حساب'}
          </Button>
        </form>
        <div className="mt-5 flex flex-col items-center gap-3 text-sm text-muted">
          <button type="button" onClick={() => setMode(mode === 'signin' ? 'signup' : 'signin')} className="hover:text-ink">
            {mode === 'signin' ? 'ليس لديك حساب؟ أنشئ حساباً' : 'لديك حساب؟ سجّل الدخول'}
          </button>
          {mode === 'signin' && (
            <button type="button" onClick={forgot} disabled={sending} className="hover:text-ink disabled:opacity-50">
              {sending ? 'جارٍ الإرسال…' : 'نسيت كلمة المرور؟'}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

/** تظهر بعد فتح رابط «استعادة كلمة المرور» من الإيميل */
export function NewPassword({ onDone }: { onDone: () => void }) {
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (password.length < 8) return toast.error('كلمة المرور 8 أحرف على الأقل');
    setLoading(true);
    const { error } = await supabase.auth.updateUser({ password });
    setLoading(false);
    if (error) return toast.error(translateError(error.message));
    toast.success('تم تعيين كلمة المرور الجديدة');
    onDone();
  }

  return (
    <div className="flex min-h-dvh items-center justify-center p-5">
      <form onSubmit={submit} className="w-full max-w-sm space-y-4">
        <Logo className="size-14" />
        <h1 className="text-2xl font-bold">كلمة مرور جديدة</h1>
        <Field label="كلمة المرور الجديدة" type="password" dir="ltr" minLength={8} required autoFocus
          autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
        <Button type="submit" loading={loading} className="w-full">حفظ</Button>
      </form>
    </div>
  );
}
