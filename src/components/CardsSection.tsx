import { useState, type FormEvent } from 'react';
import { toast } from 'sonner';
import { CreditCard, Trash } from '@phosphor-icons/react';
import { useHousehold } from '../hooks/household';
import { useCards, useInvalidate, useUpdateHousehold } from '../hooks/queries';
import { deleteCard, saveCard } from '../lib/api';
import { BANK_LABELS, CARD_TYPE_LABELS } from '../lib/stats';
import type { Card as CardRow } from '../lib/types';
import { Button, Card, Field, IconButton, Select } from './ui';

/** البطاقات التي عرفها التطبيق من رسائل البنك + نسب رسوم العمليات الأجنبية */
export function CardsSection() {
  const { household } = useHousehold();
  const { data: cards = [] } = useCards();
  const update = useUpdateHousehold();
  const [fee, setFee] = useState(String(household.fx_fee_pct ?? 0));

  function saveFee(e: FormEvent) {
    e.preventDefault();
    const v = Number(fee.replace('٫', '.'));
    if (!(v >= 0 && v <= 20)) return toast.error('النسبة بين 0 و 20');
    update.mutate({ fx_fee_pct: v });
  }

  return (
    <Card className="space-y-4">
      <div>
        <h2 className="inline-flex items-center gap-2 font-bold"><CreditCard className="size-5 text-brand" weight="duotone" />البطاقات والبنوك</h2>
        <p className="mt-1 text-sm leading-relaxed text-muted">
          يتعرف التطبيق على بطاقاتكم من رسائل البنك (آخر 4 أرقام) ويتذكر بنكها ونوعها. أي عملية بعملة أجنبية بدون مبلغ بالريال
          تتحول بسعر صرف اليوم، مضافاً لها نسبة رسوم البطاقة.
        </p>
      </div>

      <form onSubmit={saveFee} className="flex items-end gap-2">
        <Field label="نسبة رسوم العمليات الأجنبية الافتراضية (%)" hint="تُستخدم للبطاقات اللي ما لها نسبة خاصة. اكتبها شاملة الضريبة، مثلاً 2.75% + 15% ضريبة = 3.16"
          inputMode="decimal" dir="ltr" className="flex-1" value={fee} onChange={(e) => setFee(e.target.value)} />
        <Button type="submit" variant="secondary" loading={update.isPending}>حفظ</Button>
      </form>

      {cards.length === 0 ? (
        <p className="rounded-xl bg-surface-2 px-3 py-2.5 text-xs text-muted">ما فيه بطاقات بعد. تظهر هنا تلقائياً مع أول رسالة بنك فيها آخر 4 أرقام.</p>
      ) : (
        <ul className="space-y-2">{cards.map((c) => <CardItem key={c.card_last4} card={c} />)}</ul>
      )}
      <p className="text-xs text-muted">
        أسعار الصرف من <a href="https://www.exchangerate-api.com" target="_blank" rel="noopener noreferrer" className="underline">ExchangeRate-API</a> وتتحدث يومياً.
        العملات المربوطة بالريال (دولار، درهم…) بسعر الربط الثابت.
      </p>
    </Card>
  );
}

function CardItem({ card }: { card: CardRow }) {
  const { household } = useHousehold();
  const invalidate = useInvalidate();
  const [bank, setBank] = useState(card.bank ?? '');
  const [nickname, setNickname] = useState(card.nickname ?? '');
  const [fee, setFee] = useState(card.fx_fee_pct == null ? '' : String(card.fx_fee_pct));
  const [saving, setSaving] = useState(false);
  const type = card.card_type ? CARD_TYPE_LABELS[card.card_type] ?? card.card_type : 'بطاقة';
  const kind = card.card_kind === 'credit' && card.card_type !== 'mada' ? ' ائتمانية' : '';

  async function save() {
    const f = fee.trim() === '' ? null : Number(fee.replace('٫', '.'));
    if (f !== null && !(f >= 0 && f <= 20)) return toast.error('النسبة بين 0 و 20');
    setSaving(true);
    try {
      await saveCard(household.id, card.card_last4, { bank: bank || null, nickname: nickname.trim() || null, fx_fee_pct: f });
      await invalidate('cards');
      toast.success('تم حفظ البطاقة');
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setSaving(false);
    }
  }

  async function remove() {
    try {
      await deleteCard(household.id, card.card_last4);
      await invalidate('cards');
    } catch (e) {
      toast.error((e as Error).message);
    }
  }

  return (
    <li className="rounded-2xl border border-line p-3">
      <div className="flex items-center justify-between gap-2">
        <p className="font-semibold"><span dir="ltr">•{card.card_last4}</span> · {type}{kind}</p>
        <IconButton label="نسيان البطاقة" className="size-8" onClick={remove}><Trash className="size-4" weight="bold" /></IconButton>
      </div>
      <div className="mt-2 grid gap-2 sm:grid-cols-3">
        <Select label="البنك" showLabel value={bank} onChange={setBank}
          options={[{ value: '', label: 'غير معروف' }, ...Object.entries(BANK_LABELS).map(([k, v]) => ({ value: k, label: v }))]} />
        <Field label="اسم مختصر (اختياري)" placeholder="مثال: فيزا السفر" maxLength={30} value={nickname} onChange={(e) => setNickname(e.target.value)} />
        <Field label="رسوم أجنبية % (اختياري)" placeholder="الافتراضية" inputMode="decimal" dir="ltr" value={fee} onChange={(e) => setFee(e.target.value)} />
      </div>
      <Button variant="secondary" className="mt-2 h-9 text-sm" onClick={save} loading={saving}>حفظ</Button>
    </li>
  );
}
