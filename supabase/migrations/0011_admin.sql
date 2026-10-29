-- =====================================================================
--  0011: الإدارة لمنشئ العائلة فقط
--   المنشئ (owner): التصنيفات وتنظيمها، الميزانية واسم العائلة ورسوم العملات، البطاقات،
--                   المصاريف الثابتة، القواعد المتعلَّمة، الأعضاء ورمز الدعوة، أرشفة السنوات
--   بقية العائلة: يضيفون مصاريفهم ويعدّلون/يحذفون ما أضافوه، يسجّلون دفع الثابتة،
--                 يشوفون كل شيء، ويتحكمون بإشعاراتهم واسمهم وكلمة مرورهم
-- =====================================================================

create or replace function public.is_owner(p_household uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from household_members
                 where household_id = p_household and user_id = auth.uid() and role = 'owner')
$$;
revoke all on function public.is_owner(uuid) from public, anon;
grant execute on function public.is_owner(uuid) to authenticated;

-- العائلة: الإعدادات للمنشئ
drop policy if exists households_update on public.households;
create policy households_update on public.households for update to authenticated
  using (public.is_owner(id)) with check (public.is_owner(id));

-- التصنيفات / الثابتة / البطاقات / القواعد: الكل يشوف، والمنشئ يعدّل
drop policy if exists categories_all on public.categories;
drop policy if exists categories_select on public.categories;
drop policy if exists categories_owner on public.categories;
create policy categories_select on public.categories for select to authenticated using (public.is_member(household_id));
create policy categories_owner on public.categories for all to authenticated
  using (public.is_owner(household_id)) with check (public.is_owner(household_id));

drop policy if exists recurring_all on public.recurring_expenses;
drop policy if exists recurring_select on public.recurring_expenses;
drop policy if exists recurring_owner on public.recurring_expenses;
create policy recurring_select on public.recurring_expenses for select to authenticated using (public.is_member(household_id));
create policy recurring_owner on public.recurring_expenses for all to authenticated
  using (public.is_owner(household_id)) with check (public.is_owner(household_id));

drop policy if exists cards_all on public.cards;
drop policy if exists cards_select on public.cards;
drop policy if exists cards_owner on public.cards;
create policy cards_select on public.cards for select to authenticated using (public.is_member(household_id));
create policy cards_owner on public.cards for all to authenticated
  using (public.is_owner(household_id)) with check (public.is_owner(household_id));

drop policy if exists merchant_rules_all on public.merchant_rules;
drop policy if exists merchant_rules_select on public.merchant_rules;
drop policy if exists merchant_rules_owner on public.merchant_rules;
create policy merchant_rules_select on public.merchant_rules for select to authenticated using (public.is_member(household_id));
create policy merchant_rules_owner on public.merchant_rules for all to authenticated
  using (public.is_owner(household_id)) with check (public.is_owner(household_id));

-- المصاريف: كل شخص يعدّل ويحذف ما أضافه، والمنشئ يعدّل الكل
drop policy if exists expenses_update on public.expenses;
create policy expenses_update on public.expenses for update to authenticated
  using (public.is_member(household_id) and (created_by = (select auth.uid()) or public.is_owner(household_id)))
  with check (public.is_member(household_id));
drop policy if exists expenses_delete on public.expenses;
create policy expenses_delete on public.expenses for delete to authenticated
  using (public.is_member(household_id) and (created_by = (select auth.uid()) or public.is_owner(household_id)));

-- سجل الرسائل: كل شخص يحذف رسائله، والمنشئ الكل
drop policy if exists sms_log_delete on public.sms_log;
create policy sms_log_delete on public.sms_log for delete to authenticated
  using (public.is_member(household_id) and (user_id = (select auth.uid()) or public.is_owner(household_id)));

-- تسجيل دفع الثابتة متاح للكل (يربط رسالة البنك حتى لو سجّلها شخص آخر)
create or replace function public.mark_recurring_paid(p_recurring_id uuid, p_period date, p_date date default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  r public.recurring_expenses;
  v_period date := date_trunc('month', p_period)::date;
  v_id uuid;
begin
  select * into r from recurring_expenses where id = p_recurring_id;
  if r.id is null or not public.is_member(r.household_id) then raise exception 'recurring expense not found'; end if;

  select id into v_id from expenses where recurring_id = r.id and recurring_period = v_period;
  if v_id is not null then return v_id; end if;

  select id into v_id from expenses
  where household_id = r.household_id and recurring_id is null and source_hash is not null
    and amount = r.amount and date_trunc('month', expense_date)::date = v_period
  order by expense_date, created_at
  limit 1
  for update;
  if v_id is not null then
    update expenses set recurring_id = r.id, recurring_period = v_period, category_id = r.category_id
    where id = v_id;
    return v_id;
  end if;

  insert into expenses (household_id, category_id, amount, expense_date, description, recurring_id, recurring_period)
  values (
    r.household_id, r.category_id, r.amount,
    coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date),
    r.name, r.id, v_period
  )
  on conflict (recurring_id, recurring_period) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from expenses where recurring_id = r.id and recurring_period = v_period;
  end if;
  return v_id;
end $$;

-- تنظيم التصنيفات بالذكاء الاصطناعي: للمنشئ فقط
create or replace function public.ai_category_plan()
returns jsonb language plpgsql security definer set search_path = public
set statement_timeout to '70s'
as $$
declare v_h uuid := public.my_household(); v_names text[]; v_plan jsonb;
begin
  if not public.is_owner(v_h) then raise exception 'only the owner can do this'; end if;
  if v_h is null then raise exception 'not in a household'; end if;
  if not public.ai_enabled() then raise exception 'ai not enabled'; end if;
  select array_agg(name) into v_names from categories where household_id = v_h;

  v_plan := public.ai_call('plan',
    $sys$You organise the expense categories of a Saudi family budget app. Goal: a clean, unified, reasonably small set of clear Arabic categories, without losing any data. You receive every category with its usage and top merchants, plus merchants that appear in several categories.
Propose only changes that clearly help; an empty list of operations is a valid answer. Allowed operations:
- merge (from → into): duplicates or near-duplicates (e.g. "مطاعم" and "المطاعم والمقاهي"). Everything moves into "into" and "from" is archived.
- move_merchant (merchant → into): put all expenses of one merchant into the right category, to unify inconsistent merchants or rescue merchants sitting in the "other" category.
- create (name, icon): only when at least 3 expenses (in "other" or spread elsewhere) clearly form a common spending area with no category; then add move_merchant operations for those merchants.
- rename (from → new_name): only for unclear or awkward names.
- archive (from): family-created categories with no expenses in 90 days and no recurring expenses.
- delete (from): only categories with expenses_total = 0 and recurring = 0.
Core categories (is_core = true) are pinned: never merge them away, rename, archive or delete them — but you may merge other categories INTO them and move merchants into or out of them. Never merge, rename, archive or delete the "other" category (is_other = true). Use the exact existing names. Write summary and reasons in short Arabic.$sys$,
    'Data:' || E'\n' || public.category_stats(v_h)::text,
    jsonb_build_object(
      'name', 'category_plan',
      'description', 'A safe plan to organise the categories.',
      'input_schema', jsonb_build_object(
        'type', 'object',
        'properties', jsonb_build_object(
          'summary', jsonb_build_object('type', 'string'),
          'operations', jsonb_build_object('type', 'array', 'items', jsonb_build_object(
            'type', 'object',
            'properties', jsonb_build_object(
              'op', jsonb_build_object('type', 'string', 'enum', jsonb_build_array('merge', 'move_merchant', 'create', 'rename', 'archive', 'delete')),
              'from', jsonb_build_object('type', 'string', 'enum', to_jsonb(coalesce(v_names, '{}'))),
              'into', jsonb_build_object('type', 'string'),
              'merchant', jsonb_build_object('type', 'string'),
              'name', jsonb_build_object('type', 'string'),
              'new_name', jsonb_build_object('type', 'string'),
              'icon', jsonb_build_object('type', 'string', 'enum', to_jsonb(public.allowed_icons())),
              'reason', jsonb_build_object('type', 'string')),
            'required', jsonb_build_array('op', 'reason')))),
        'required', jsonb_build_array('summary', 'operations'))),
    2500);
  if v_plan is null then raise exception 'ai unavailable'; end if;
  return v_plan;
end $$;

create or replace function public.apply_category_plan(p_operations jsonb, p_actor text default 'ai')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_h uuid := public.my_household();
  v_batch uuid := gen_random_uuid();
  op jsonb;
  v_from categories; v_into categories;
  v_ids uuid[]; v_rec uuid[]; v_rules jsonb; v_moves jsonb; v_prev jsonb;
  v_key text; v_new uuid; v_label text;
  v_applied jsonb := '[]'; v_skipped jsonb := '[]';
  v_actor text := case when p_actor = 'user' then 'user' else 'ai' end;
begin
  if not public.is_owner(v_h) then raise exception 'only the owner can do this'; end if;
  if v_h is null then raise exception 'not in a household'; end if;
  perform set_config('masareef.no_learn', 'on', true);  -- التنظيم لا يُنشئ قواعد تلقائية من النقل

  for op in select * from jsonb_array_elements(coalesce(p_operations, '[]')) loop
    v_from := null; v_into := null;
    select * into v_from from categories where household_id = v_h and name = op->>'from';
    select * into v_into from categories where household_id = v_h and name = op->>'into';

    case op->>'op'
    when 'create' then
      v_new := public.safe_create_category(v_h, op->>'name', op->>'icon', v_batch, v_actor);
      if v_new is null then v_skipped := v_skipped || jsonb_build_array(op || '{"why":"اسم مكرر أو غير صالح أو وصلنا الحد"}'); continue; end if;

    when 'rename' then
      if v_from.id is null or v_from.icon = 'circle' or v_from.is_core or coalesce(btrim(op->>'new_name'), '') = ''
         or exists (select 1 from categories where household_id = v_h and public.normalize_category(name) = public.normalize_category(op->>'new_name') and id <> v_from.id) then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"غير مسموح أو الاسم مستخدم"}'); continue;
      end if;
      update categories set name = left(btrim(op->>'new_name'), 40) where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'rename', jsonb_build_object('id', v_from.id, 'old_name', v_from.name, 'new_name', btrim(op->>'new_name')), v_actor);

    when 'merge' then
      if v_from.id is null or v_into.id is null or v_from.id = v_into.id or v_from.icon = 'circle' or v_from.is_core or v_into.is_archived then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"غير مسموح (تصنيف أساسي أو غير موجود)"}'); continue;
      end if;
      select coalesce(array_agg(id), '{}') into v_ids from expenses where category_id = v_from.id;
      select coalesce(array_agg(id), '{}') into v_rec from recurring_expenses where category_id = v_from.id;
      select coalesce(jsonb_agg(merchant_key), '[]') into v_rules from merchant_rules where category_id = v_from.id;
      update expenses set category_id = v_into.id where id = any (v_ids);
      update recurring_expenses set category_id = v_into.id where id = any (v_rec);
      update merchant_rules set category_id = v_into.id where category_id = v_from.id;
      update categories set is_archived = true where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'merge', jsonb_build_object('from_id', v_from.id, 'into_id', v_into.id, 'from_name', v_from.name, 'into_name', v_into.name,
              'expense_ids', to_jsonb(v_ids), 'recurring_ids', to_jsonb(v_rec), 'rule_keys', v_rules, 'from_was_archived', v_from.is_archived), v_actor);

    when 'archive' then
      if v_from.id is null or v_from.icon = 'circle' or v_from.is_core or v_from.is_archived then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"غير مسموح (تصنيف أساسي أو غير موجود)"}'); continue;
      end if;
      update categories set is_archived = true where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'archive', jsonb_build_object('id', v_from.id, 'name', v_from.name), v_actor);

    when 'delete' then
      if v_from.id is null or v_from.icon = 'circle' or v_from.is_core then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"تصنيف أساسي مثبّت"}'); continue;
      end if;
      if exists (select 1 from expenses where category_id = v_from.id)
         or exists (select 1 from recurring_expenses where category_id = v_from.id) then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"عليه عمليات، يمكن أرشفته فقط"}'); continue;
      end if;
      select coalesce(jsonb_agg(to_jsonb(r)), '[]') into v_rules from merchant_rules r where category_id = v_from.id;
      delete from categories where id = v_from.id;
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'delete', jsonb_build_object('category', to_jsonb(v_from), 'rules', v_rules), v_actor);

    when 'move_merchant' then
      if v_into.id is not null and v_into.is_archived then v_into := null; end if;
      if v_into.id is null and op ? 'into' then
        -- التصنيف قد يكون أُنشئ في نفس الخطة
        select * into v_into from categories where household_id = v_h and not is_archived
          and public.normalize_category(name) = public.normalize_category(op->>'into');
      end if;
      v_key := public.normalize_merchant(op->>'merchant');
      if v_into.id is null or v_key is null then
        v_skipped := v_skipped || jsonb_build_array(op || '{"why":"التصنيف أو المتجر غير موجود"}'); continue;
      end if;
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'category_id', category_id)), '[]') into v_moves
      from expenses where household_id = v_h and recurring_id is null and category_id <> v_into.id
        and (merchant_key = v_key or public.normalize_merchant(regexp_replace(coalesce(description, ''), '^📩\s*', '')) = v_key);
      select to_jsonb(r) into v_prev from merchant_rules r where household_id = v_h and merchant_key = v_key;
      update expenses set category_id = v_into.id
      where id in (select (x->>'id')::uuid from jsonb_array_elements(v_moves) x);
      v_label := btrim(op->>'merchant');
      insert into merchant_rules (household_id, merchant_key, merchant_label, category_id, created_by)
      values (v_h, v_key, v_label, v_into.id, auth.uid())
      on conflict (household_id, merchant_key) do update set category_id = excluded.category_id, updated_at = now();
      insert into category_audit (household_id, batch_id, op, details, actor)
      values (v_h, v_batch, 'move_merchant', jsonb_build_object('merchant_key', v_key, 'merchant', v_label, 'into_id', v_into.id,
              'into_name', v_into.name, 'moves', v_moves, 'previous_rule', v_prev), v_actor);

    else
      v_skipped := v_skipped || jsonb_build_array(op || '{"why":"عملية غير معروفة"}'); continue;
    end case;
    v_applied := v_applied || jsonb_build_array(op);
  end loop;

  perform set_config('masareef.no_learn', '', true);
  return jsonb_build_object('batch_id', case when jsonb_array_length(v_applied) > 0 then v_batch end,
                            'applied', v_applied, 'skipped', v_skipped);
end $$;

create or replace function public.undo_category_batch(p_batch uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_h uuid := public.my_household();
  a category_audit;
  n int := 0;
  x jsonb;
begin
  if not public.is_owner(v_h) then raise exception 'only the owner can do this'; end if;
  if v_h is null then raise exception 'not in a household'; end if;
  perform set_config('masareef.no_learn', 'on', true);
  for a in select * from category_audit where household_id = v_h and batch_id = p_batch and undone_at is null order by created_at desc, id desc loop
    case a.op
    when 'create' then
      if exists (select 1 from expenses where category_id = (a.details->>'id')::uuid)
         or exists (select 1 from recurring_expenses where category_id = (a.details->>'id')::uuid) then
        update categories set is_archived = true where id = (a.details->>'id')::uuid;
      else
        delete from categories where id = (a.details->>'id')::uuid;
      end if;
    when 'rename' then
      update categories set name = a.details->>'old_name'
      where id = (a.details->>'id')::uuid
        and not exists (select 1 from categories where household_id = v_h and name = a.details->>'old_name' and id <> (a.details->>'id')::uuid);
    when 'merge' then
      update categories set is_archived = coalesce((a.details->>'from_was_archived')::boolean, false) where id = (a.details->>'from_id')::uuid;
      update expenses set category_id = (a.details->>'from_id')::uuid
      where id in (select (v #>> '{}')::uuid from jsonb_array_elements(a.details->'expense_ids') v)
        and category_id = (a.details->>'into_id')::uuid;
      update recurring_expenses set category_id = (a.details->>'from_id')::uuid
      where id in (select (v #>> '{}')::uuid from jsonb_array_elements(a.details->'recurring_ids') v)
        and category_id = (a.details->>'into_id')::uuid;
      update merchant_rules set category_id = (a.details->>'from_id')::uuid
      where household_id = v_h and merchant_key in (select v #>> '{}' from jsonb_array_elements(a.details->'rule_keys') v)
        and category_id = (a.details->>'into_id')::uuid;
    when 'archive' then
      update categories set is_archived = false where id = (a.details->>'id')::uuid;
    when 'delete' then
      insert into categories select * from jsonb_populate_record(null::categories, a.details->'category')
      on conflict do nothing;
      for x in select * from jsonb_array_elements(a.details->'rules') loop
        insert into merchant_rules select * from jsonb_populate_record(null::merchant_rules, x) on conflict do nothing;
      end loop;
    when 'move_merchant' then
      update expenses e set category_id = (m->>'category_id')::uuid
      from jsonb_array_elements(a.details->'moves') m
      where e.id = (m->>'id')::uuid and e.category_id = (a.details->>'into_id')::uuid
        and exists (select 1 from categories c where c.id = (m->>'category_id')::uuid);
      if a.details->'previous_rule' is null or jsonb_typeof(a.details->'previous_rule') = 'null' then
        delete from merchant_rules where household_id = v_h and merchant_key = a.details->>'merchant_key';
      else
        update merchant_rules set category_id = (a.details->'previous_rule'->>'category_id')::uuid,
                                  merchant_label = a.details->'previous_rule'->>'merchant_label'
        where household_id = v_h and merchant_key = a.details->>'merchant_key';
      end if;
    else null;
    end case;
    update category_audit set undone_at = now() where id = a.id;
    n := n + 1;
  end loop;
  perform set_config('masareef.no_learn', '', true);
  return n;
end $$;

notify pgrst, 'reload schema';
