import { Bar, BarChart, Cell, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis } from 'recharts';
import { formatMonthShort } from '../lib/dates';
import { formatAmount, formatSAR } from '../lib/money';
import type { CategorySlice } from '../lib/stats';
import type { MonthKey } from '../lib/types';

const tooltipStyle = {
  background: 'var(--color-surface)',
  border: '1px solid var(--color-line)',
  borderRadius: 12,
  color: 'var(--color-ink)',
  fontFamily: 'inherit',
  direction: 'rtl' as const,
};

export function CategoryDonut({ slices, total }: { slices: CategorySlice[]; total: number }) {
  return (
    <div className="relative mx-auto aspect-square w-full max-w-56">
      <ResponsiveContainer>
        <PieChart>
          <Pie data={slices} dataKey="total" nameKey="categoryId" innerRadius="70%" outerRadius="100%"
            paddingAngle={slices.length > 1 ? 2 : 0} stroke="none" startAngle={90} endAngle={-270} isAnimationActive={false}>
            {slices.map((s) => <Cell key={s.categoryId} fill={s.category?.color ?? '#64748B'} />)}
          </Pie>
        </PieChart>
      </ResponsiveContainer>
      <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
        <span className="text-xs text-muted">{slices.length} تصنيفات</span>
        <span className="num text-lg font-bold">{formatSAR(total)}</span>
      </div>
    </div>
  );
}

export function MonthlyBars({ data, selected, onSelect }: {
  data: { month: MonthKey; total: number }[]; selected: MonthKey; onSelect: (m: MonthKey) => void;
}) {
  return (
    <div className="h-48 w-full" dir="ltr">
      <ResponsiveContainer>
        <BarChart data={data} margin={{ top: 8, right: 0, left: 0, bottom: 0 }}>
          {/* reversed: الأشهر تقرأ من اليمين لليسار كما في العربية */}
          <XAxis dataKey="month" reversed tickFormatter={formatMonthShort} axisLine={false} tickLine={false}
            tick={{ fill: 'var(--color-muted)', fontSize: 12 }} />
          <Tooltip cursor={{ fill: 'var(--color-surface-2)' }} contentStyle={tooltipStyle}
            formatter={(v) => [`${formatAmount(Number(v))} ر.س`, 'الإجمالي']}
            labelFormatter={(m) => formatMonthShort(String(m))} />
          <Bar dataKey="total" radius={[8, 8, 8, 8]} isAnimationActive={false}
            onClick={(d) => { const m = (d as { payload?: { month?: string } }).payload?.month; if (m) onSelect(m); }}
            className="cursor-pointer">
            {data.map((d) => (
              <Cell key={d.month} fill={d.month === selected ? 'var(--color-brand)' : 'var(--color-line)'} />
            ))}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
