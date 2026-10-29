/** كل المبالغ في التطبيق بالهللة (عدد صحيح). 1 ريال = 100 هللة. */
export type Halalas = number;
/** تاريخ بصيغة YYYY-MM-DD */
export type ISODate = string;
/** بداية شهر بصيغة YYYY-MM-01 */
export type MonthKey = string;

export interface Household {
  id: string;
  name: string;
  currency: string;
  monthly_budget: Halalas | null;
  invite_code: string;
}

export interface Member {
  household_id: string;
  user_id: string;
  display_name: string;
  role: 'owner' | 'member';
}

export interface Category {
  id: string;
  household_id: string;
  name: string;
  icon: string;
  color: string;
  sort_order: number;
  is_archived: boolean;
}

export interface Expense {
  id: string;
  household_id: string;
  category_id: string;
  amount: Halalas;
  expense_date: ISODate;
  description: string | null;
  receipt_path: string | null;
  recurring_id: string | null;
  recurring_period: MonthKey | null;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface Recurring {
  id: string;
  household_id: string;
  category_id: string;
  name: string;
  amount: Halalas;
  day_of_month: number;
  start_month: MonthKey;
  is_active: boolean;
}

export interface MonthlyTotal {
  month: MonthKey;
  category_id: string;
  total: Halalas;
  tx_count: number;
}
