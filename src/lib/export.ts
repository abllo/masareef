import { formatDayShort } from './dates';
import { formatSAR, sumHalalas, toRiyals } from './money';
import { byCategory } from './stats';
import type { Category, Expense, Member } from './types';

export interface ReportInput {
  title: string;
  periodLabel: string;
  expenses: Expense[];
  categories: Category[];
  members: Member[];
}

function rows({ expenses, categories, members }: ReportInput) {
  const cat = new Map(categories.map((c) => [c.id, c.name]));
  const who = new Map(members.map((m) => [m.user_id, m.display_name]));
  return [...expenses]
    .sort((a, b) => a.expense_date.localeCompare(b.expense_date) || a.created_at.localeCompare(b.created_at))
    .map((e) => ({
      date: e.expense_date,
      category: cat.get(e.category_id) ?? '—',
      description: e.description ?? '',
      amount: e.amount,
      by: who.get(e.created_by) ?? 'عضو سابق',
    }));
}

function download(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

const isTouchDevice = () => window.matchMedia?.('(pointer: coarse)').matches ?? false;

export type Delivery = 'shared' | 'downloaded' | 'cancelled' | { retry: () => Promise<void> };

/**
 * يسلّم الملف للمستخدم:
 * - الجوال: قائمة المشاركة (حفظ في الملفات، واتساب…) لأن التنزيل المباشر لا يعمل داخل التطبيق المثبّت على الآيفون
 * - الكمبيوتر: تنزيل مباشر
 * إذا رفض الآيفون المشاركة لأن تجهيز الملف أخذ وقتاً، نعيد دالة تُستدعى من ضغطة جديدة.
 */
export async function deliverFile(file: File): Promise<Delivery> {
  const share = () => navigator.share({ files: [file], title: file.name });
  if (isTouchDevice() && typeof navigator.share === 'function' && navigator.canShare?.({ files: [file] })) {
    try {
      await share();
      return 'shared';
    } catch (e) {
      const name = (e as DOMException).name;
      if (name === 'AbortError') return 'cancelled';
      if (name === 'NotAllowedError') return { retry: () => share().catch(() => {}) };
    }
  }
  download(file, file.name);
  return 'downloaded';
}

/** ملف Excel بورقتين: العمليات + ملخص التصنيفات، باتجاه من اليمين لليسار */
export async function exportExcel(input: ReportInput, filename: string) {
  const { default: ExcelJS } = await import('exceljs'); // تحميل عند الطلب فقط
  const wb = new ExcelJS.Workbook();
  wb.creator = 'مصاريف';
  const money = '#,##0.00 "ر.س"';

  const ws = wb.addWorksheet('العمليات', { views: [{ rightToLeft: true, state: 'frozen', ySplit: 1 }] });
  ws.columns = [
    { header: 'التاريخ', key: 'date', width: 14 },
    { header: 'التصنيف', key: 'category', width: 26 },
    { header: 'الوصف', key: 'description', width: 34 },
    { header: 'المبلغ', key: 'amount', width: 16, style: { numFmt: money } },
    { header: 'أضافه', key: 'by', width: 14 },
  ];
  const data = rows(input);
  data.forEach((r) => ws.addRow({ ...r, date: new Date(`${r.date}T00:00:00Z`), amount: toRiyals(r.amount) }));
  ws.getColumn('date').numFmt = 'yyyy-mm-dd';
  const totalRow = ws.addRow({ description: 'الإجمالي', amount: { formula: `SUM(D2:D${data.length + 1})`, result: toRiyals(sumHalalas(data.map((r) => r.amount))) } });
  totalRow.font = { bold: true };
  ws.getRow(1).font = { bold: true, color: { argb: 'FFFFFFFF' } };
  ws.getRow(1).fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF0E6B58' } };

  const summary = wb.addWorksheet('ملخص التصنيفات', { views: [{ rightToLeft: true }] });
  summary.columns = [
    { header: 'التصنيف', key: 'name', width: 28 },
    { header: 'عدد العمليات', key: 'count', width: 14 },
    { header: 'الإجمالي', key: 'total', width: 18, style: { numFmt: money } },
    { header: 'النسبة', key: 'percent', width: 10 },
  ];
  for (const s of byCategory(input.expenses, input.categories)) {
    summary.addRow({ name: s.category?.name ?? '—', count: s.count, total: toRiyals(s.total), percent: `${s.percent}%` });
  }
  summary.getRow(1).font = { bold: true };

  const buffer = await wb.xlsx.writeBuffer();
  return deliverFile(new File([buffer], filename, { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
}

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

/**
 * تقرير PDF عبر نافذة الطباعة في المتصفح ("حفظ كـ PDF").
 * هذا يضمن عرض الخط العربي واتصال الحروف بشكل صحيح، وهو ما تفشل فيه أغلب مكتبات PDF في المتصفح.
 * يُطبع داخل نفس الصفحة (بدون نافذة منبثقة) فيعمل أيضاً في التطبيق المثبّت على الآيفون.
 */
export function printReport(input: ReportInput) {
  const data = rows(input);
  const total = sumHalalas(data.map((r) => r.amount));
  const slices = byCategory(input.expenses, input.categories);

  document.getElementById('print-root')?.remove();
  const root = document.createElement('div');
  root.id = 'print-root';
  root.dir = 'rtl';
  root.innerHTML = `
<h1>${esc(input.title)}</h1>
<div class="muted">${esc(input.periodLabel)}، ${data.length} عملية</div>
<div class="total">${esc(formatSAR(total))}</div>
<h2>حسب التصنيف</h2>
<table><thead><tr><th>التصنيف</th><th>العمليات</th><th>النسبة</th><th>الإجمالي</th></tr></thead><tbody>
${slices.map((s) => `<tr><td>${esc(s.category?.name ?? '—')}</td><td>${s.count}</td><td>${s.percent}%</td><td class="num">${esc(formatSAR(s.total))}</td></tr>`).join('')}
</tbody></table>
<h2>العمليات</h2>
<table><thead><tr><th>التاريخ</th><th>التصنيف</th><th>الوصف</th><th>أضافه</th><th>المبلغ</th></tr></thead><tbody>
${data.map((r) => `<tr><td>${esc(formatDayShort(r.date))}</td><td>${esc(r.category)}</td><td>${esc(r.description)}</td><td>${esc(r.by)}</td><td class="num">${esc(formatSAR(r.amount))}</td></tr>`).join('')}
</tbody></table>`;
  document.body.appendChild(root);

  // عنوان الصفحة = اسم ملف PDF المقترح
  const previousTitle = document.title;
  document.title = `${input.title} - ${input.periodLabel}`;
  const cleanup = () => {
    document.title = previousTitle;
    root.remove();
    window.removeEventListener('afterprint', cleanup);
  };
  window.addEventListener('afterprint', cleanup);
  requestAnimationFrame(() => setTimeout(() => window.print(), 50));
}
