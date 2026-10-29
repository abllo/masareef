import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { HashRouter } from 'react-router';
import { Toaster } from 'sonner';
import { MotionConfig } from 'motion/react';
import App from './App';
import { AuthProvider } from './hooks/auth';
import './index.css';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 30_000, refetchOnWindowFocus: false, retry: 1 },
  },
});

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
