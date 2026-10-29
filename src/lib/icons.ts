import {
  AirplaneTilt, Baby, Barbell, BookOpen, Broom, Car, Coffee, DeviceMobile, DotsThreeCircle, Drop, ForkKnife,
  GasPump, Gift, GraduationCap, HandCoins, Heartbeat, House, Lightning, PawPrint, Pill, Receipt, Scooter,
  ShoppingBag, ShoppingCart, Sparkle, SteeringWheel, TShirt, Television, WifiHigh, Wrench,
  type Icon,
} from '@phosphor-icons/react';

/** مفاتيح الأيقونات المخزنة في قاعدة البيانات → الأيقونة */
export const CATEGORY_ICONS: Record<string, Icon> = {
  cart: ShoppingCart,
  food: ForkKnife,
  coffee: Coffee,
  bike: Scooter,
  receipt: Receipt,
  bag: ShoppingBag,
  car: Car,
  fuel: GasPump,
  broom: Broom,
  steering: SteeringWheel,
  home: House,
  power: Lightning,
  water: Drop,
  wifi: WifiHigh,
  phone: DeviceMobile,
  tv: Television,
  health: Heartbeat,
  pill: Pill,
  school: GraduationCap,
  books: BookOpen,
  baby: Baby,
  gift: Gift,
  clothes: TShirt,
  beauty: Sparkle,
  travel: AirplaneTilt,
  sport: Barbell,
  pet: PawPrint,
  repair: Wrench,
  charity: HandCoins,
  circle: DotsThreeCircle,
};

export const iconFor = (key: string): Icon => CATEGORY_ICONS[key] ?? DotsThreeCircle;

export const CATEGORY_COLORS = [
  '#0E6B58', '#2563EB', '#7C3AED', '#DB2777', '#C2410C', '#B45309',
  '#0891B2', '#475569', '#16A34A', '#DC2626', '#4F46E5', '#64748B',
];

/** أسماء عربية للأيقونات والألوان (لقارئ الشاشة) */
export const ICON_LABELS: Record<string, string> = {
  cart: 'عربة تسوق', food: 'طعام', coffee: 'قهوة', bike: 'توصيل', receipt: 'فاتورة', bag: 'حقيبة تسوق',
  car: 'سيارة', fuel: 'وقود', broom: 'تنظيف', steering: 'سائق', home: 'بيت', power: 'كهرباء', water: 'ماء',
  wifi: 'إنترنت', phone: 'جوال', tv: 'تلفزيون', health: 'صحة', pill: 'دواء', school: 'دراسة', books: 'كتب',
  baby: 'أطفال', gift: 'هدية', clothes: 'ملابس', beauty: 'تجميل', travel: 'سفر', sport: 'رياضة', pet: 'حيوان أليف',
  repair: 'صيانة', charity: 'صدقة', circle: 'أخرى',
};

export const COLOR_LABELS: Record<string, string> = {
  '#0E6B58': 'أخضر داكن', '#2563EB': 'أزرق', '#7C3AED': 'بنفسجي', '#DB2777': 'وردي', '#C2410C': 'برتقالي',
  '#B45309': 'بني', '#0891B2': 'سماوي', '#475569': 'رمادي داكن', '#16A34A': 'أخضر', '#DC2626': 'أحمر',
  '#4F46E5': 'نيلي', '#64748B': 'رمادي',
};
