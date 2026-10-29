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
