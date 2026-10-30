import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { HashRouter } from 'react-router';
import { Toaster } from 'sonner';
import { MotionConfig } from 'motion/react';
import App from './App';
import { AuthProvider } from './hooks/auth';
import { registerServiceWorker } from './lib/push';
import { applyAmountsHidden } from './lib/lock';
import { flushPending, persistCache, restoreCache } from './lib/offline';
import './index.css';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 30_000, refetchOnWindowFocus: false, retry: 1 },
  },
});

registerServiceWorker();
applyAmountsHidden();
// آخر نسخة من البيانات تظهر فوراً حتى بدون إنترنت، وتتحدث أول ما يرجع الاتصال
restoreCache(queryClient);
persistCache(queryClient);
const syncPending = () => flushPending().then((n) => { if (n) void queryClient.invalidateQueries(); });
window.addEventListener('online', syncPending);
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') void syncPending(); });
void syncPending();
// تحميل كل الصفحات مسبقاً بعد الفتح: أسرع تنقّل، وتشتغل بدون إنترنت
window.addEventListener('load', () => setTimeout(() => {
  void Promise.all([
    import('./pages/Dashboard'), import('./pages/Expenses'), import('./pages/Readings'), import('./pages/Settings'),
    import('./pages/Recurring'), import('./pages/Trips'), import('./pages/Renewals'), import('./pages/Years'), import('./pages/Messages'),
  ]).catch(() => {});
}, 2500));

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        {/* HashRouter: يعمل على GitHub Pages دون إعدادات إضافية للخادم */}
        <HashRouter>
          {/* يحترم إعداد «تقليل الحركة» في الآيفون */}
          <MotionConfig reducedMotion="user">
            <App />
          </MotionConfig>
        </HashRouter>
      </AuthProvider>
      <Toaster dir="rtl" position="top-center" richColors closeButton />
    </QueryClientProvider>
  </StrictMode>,
);
