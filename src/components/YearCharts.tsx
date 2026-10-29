import { useState } from 'react';
import { Bar, BarChart, CartesianGrid, Cell, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { Table } from '@phosphor-icons/react';
import { formatAmount, formatSAR } from '../lib/money';
import { monthShortName, yearColor } from '../lib/years';
import type { YearOverview } from '../lib/types';
import { cx } from './ui';

const tooltipStyle = {
  background: 'var(--color-surface)',
  border: '1px solid var(--color-line)',
  borderRadius: 12,
  color: 'var(--color-ink)',
  fontFamily: 'inherit',
  direction: 'rtl' as const,
};

/** إجمالي كل سنة (السنة المختارة بارزة) */
export function YearTotalsBars({ rows, selected, onSelect }: {
  rows: { year: number; total: number }[]; selected: number; onSelect: (y: number) => void;
}) {
  const data = [...rows].sort((a, b) => a.year - b.year);
  return (
    <div className="h-44 w-full" dir="ltr">
      <ResponsiveContainer>
        <BarChart data={data} margin={{ top: 8, right: 0, left: 0, bottom: 0 }}>
          <XAxis dataKey="year" reversed axisLine={false} tickLine={false} tick={{ fill: 'var(--color-muted)', fontSize: 12 }} />
          <Tooltip cursor={{ fill: 'var(--color-surface-2)' }} contentStyle={tooltipStyle}
            formatter={(v) => [`${formatAmount(Number(v))} ر.س`, 'الإجمالي']} labelFormatter={(y) => `سنة ${y}`} />
          <Bar dataKey="total" radius={[4, 4, 0, 0]} maxBarSize={56} isAnimationActive={false} className="cursor-pointer"
            onClick={(d) => { const y = (d as { payload?: { year?: number } }).payload?.year; if (y) onSelect(y); }}>
            {data.map((d) => <Cell key={d.year} fill={d.year === selected ? 'var(--color-brand)' : 'var(--color-line)'} />)}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}

/** الصرف الشهري لكل سنة (حتى 3 سنوات) مع جدول بديل */
export function MonthlyByYear({ years, currentYear, currentMonth }: {
  years: YearOverview[]; currentYear: number; currentMonth: number;
}) {
  const [table, setTable] = useState(false);
  const shown = [...years].sort((a, b) => a.year - b.year);
  const data = Array.from({ length: 12 }, (_, i) => {
    const row: Record<string, number | null> = { month: i + 1 };
    for (const y of shown) {
      const future = y.year === currentYear && i + 1 > currentMonth;
      row[String(y.year)] = future ? null : y.data.months[i]?.total ?? 0;
    }
    return row;
  });

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        {shown.map((y) => (
          <span key={y.year} className="inline-flex items-center gap-1.5 rounded-full bg-surface-2 px-2.5 py-1 text-xs font-semibold">
            <span className="size-2.5 rounded-full" style={{ background: yearColor(y.year) }} />
            {y.year}
          </span>
        ))}
        <button type="button" onClick={() => setTable(!table)} aria-pressed={table}
          className={cx('ms-auto inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold',
            table ? 'bg-brand-soft text-brand' : 'bg-surface-2 text-muted')}>
          <Table className="size-4" /> {table ? 'الرسم' : 'جدول'}
        </button>
      </div>

      {table ? (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-muted">
                <th className="py-1.5 text-start font-medium">الشهر</th>
                {shown.map((y) => <th key={y.year} className="py-1.5 text-end font-medium">{y.year}</th>)}
              </tr>
            </thead>
            <tbody>
              {data.map((r) => (
                <tr key={r.month} className="border-t border-line/60">
                  <td className="py-1.5">{monthShortName(r.month as number)}</td>
                  {shown.map((y) => {
                    const v = r[String(y.year)];
                    return <td key={y.year} className="num py-1.5 text-end">{v === null || v === undefined ? '—' : formatSAR(v)}</td>;
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="h-56 w-full" dir="ltr">
          <ResponsiveContainer>
            <LineChart data={data} margin={{ top: 8, right: 4, left: 4, bottom: 0 }}>
              <CartesianGrid vertical={false} stroke="var(--color-line)" />
              <XAxis dataKey="month" reversed axisLine={false} tickLine={false} interval={0}
                tick={{ fill: 'var(--color-muted)', fontSize: 10 }} tickFormatter={(m) => monthShortName(Number(m)).slice(0, 3)} />
              <YAxis orientation="right" axisLine={false} tickLine={false} width={44}
                tick={{ fill: 'var(--color-muted)', fontSize: 10 }}
                tickFormatter={(v) => (Number(v) >= 100_000 ? `${Math.round(Number(v) / 100_000)}k` : formatAmount(Number(v)))} />
              <Tooltip contentStyle={tooltipStyle} labelFormatter={(m) => monthShortName(Number(m))}
                formatter={(v, name) => [v === null ? '—' : `${formatAmount(Number(v))} ر.س`, String(name)]} />
              {shown.map((y) => (
                <Line key={y.year} type="monotone" dataKey={String(y.year)} stroke={yearColor(y.year)} strokeWidth={2}
                  dot={{ r: 3, strokeWidth: 0, fill: yearColor(y.year) }} activeDot={{ r: 5 }} connectNulls={false} isAnimationActive={false} />
              ))}
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}
    </div>
  );
}
