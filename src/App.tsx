import { lazy, Suspense } from 'react';
import { Route, Routes } from 'react-router';
import { useQuery } from '@tanstack/react-query';
import { useAuth } from './hooks/auth';
import { HouseholdProvider } from './hooks/household';
import { keys } from './hooks/queries';
import { fetchHouseholdContext } from './lib/api';
import { isConfigured } from './lib/supabase';
import { Layout } from './components/Layout';
import { Spinner, FullScreenMessage } from './components/ui';
import Login from './pages/Login';
import Onboarding from './pages/Onboarding';

// تحميل الصفحات عند الحاجة لتسريع أول فتح
const Dashboard = lazy(() => import('./pages/Dashboard'));
const Expenses = lazy(() => import('./pages/Expenses'));
const RecurringPage = lazy(() => import('./pages/Recurring'));
const Settings = lazy(() => import('./pages/Settings'));

export default function App() {
  const { session, loading } = useAuth();
  const userId = session?.user.id;

  const household = useQuery({
    queryKey: keys.household(userId ?? 'anon'),
    queryFn: () => fetchHouseholdContext(userId!),
    enabled: Boolean(userId),
  });

  if (!isConfigured) {
    return (
      <FullScreenMessage title="الإعداد غير مكتمل">
        أضف VITE_SUPABASE_URL و VITE_SUPABASE_ANON_KEY في ملف ‎.env.local‎ أو في أسرار GitHub، ثم أعد التشغيل.
      </FullScreenMessage>
    );
  }
  if (loading || (userId && household.isPending)) return <Spinner full />;
  if (!session) return <Login />;
  if (household.isError) {
    return <FullScreenMessage title="تعذّر تحميل البيانات">{household.error.message}</FullScreenMessage>;
  }
  if (!household.data) return <Onboarding />;

  return (
    <HouseholdProvider value={household.data}>
      <Layout>
        <Suspense fallback={<Spinner />}>
          <Routes>
            <Route index element={<Dashboard />} />
            <Route path="expenses" element={<Expenses />} />
            <Route path="recurring" element={<RecurringPage />} />
            <Route path="settings" element={<Settings />} />
            <Route path="*" element={<Dashboard />} />
          </Routes>
        </Suspense>
      </Layout>
    </HouseholdProvider>
  );
}
