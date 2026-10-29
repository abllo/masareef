-- (طُبّق مسبقاً) يقبل أسماء الحقول حتى لو دخلت معها مسافات من كيبورد الآيفون
create or replace function public.sms_expense(jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare k text; v_token text; v_msg text;
begin
  for k in select jsonb_object_keys($1) loop
    if lower(trim(k)) = 'token' then v_token := $1->>k; end if;
    if lower(trim(k)) = 'message' then v_msg := $1->>k; end if;
  end loop;
  return public.sms_expense(trim(v_token), v_msg);
end $$;
revoke all on function public.sms_expense(jsonb) from public;
grant execute on function public.sms_expense(jsonb) to anon, authenticated;
notify pgrst, 'reload schema';
