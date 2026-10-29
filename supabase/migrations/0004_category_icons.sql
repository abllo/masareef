-- تحديث أيقونات التصنيفات الافتراضية لتكون أدق
update public.categories set icon = 'broom'
where icon = 'home' and name like '%العاملة%';

update public.categories set icon = 'food'
where icon = 'coffee' and name like '%المطاعم%';
