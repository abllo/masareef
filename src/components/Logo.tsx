/** شعار التطبيق: بيت بداخله عملة */
export function Logo({ className = 'size-12' }: { className?: string }) {
  return (
    <svg viewBox="0 0 1024 1024" className={className} role="img" aria-label="مصاريف البيت">
      <defs>
        <linearGradient id="logo-bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#14876F" />
          <stop offset="1" stopColor="#0A4A3D" />
        </linearGradient>
        <linearGradient id="logo-coin" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#F7D57A" />
          <stop offset="1" stopColor="#E2A93B" />
        </linearGradient>
      </defs>
      <rect width="1024" height="1024" rx="230" fill="url(#logo-bg)" />
      <path d="M232 470 L512 240 L792 470 V744 a56 56 0 0 1 -56 56 H288 a56 56 0 0 1 -56 -56 Z"
        fill="none" stroke="#fff" strokeWidth="60" strokeLinejoin="round" strokeLinecap="round" />
      <circle cx="512" cy="600" r="118" fill="url(#logo-coin)" />
      <circle cx="512" cy="600" r="80" fill="none" stroke="#B9822A" strokeWidth="16" opacity=".55" />
    </svg>
  );
}
