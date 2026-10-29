import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;

export const isConfigured = Boolean(url && key);

/** رابط المشروع والمفتاح العام (publishable): آمنان للعرض، ويحتاجهما اختصار الآيفون */
export const SUPABASE_URL = url || '';
export const SUPABASE_KEY = key || '';

// || وليس ??: أسرار GitHub غير المضافة تصل كنص فارغ "" فتنهار الصفحة بدل رسالة الإعداد
export const supabase = createClient(url || 'http://localhost', key || 'missing-key', {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});
