alter table public.parking_reinforcement_access
  alter column created_by drop not null;
alter table public.parking_reinforcement_access
  add column if not exists access_method text not null default 'manager';
alter table public.parking_reinforcement_access
  drop constraint if exists parking_reinforcement_access_method_check;
alter table public.parking_reinforcement_access
  add constraint parking_reinforcement_access_method_check
  check (
    (access_method = 'manager' and created_by is not null)
    or (access_method = 'fixed_pin' and created_by is null)
  );

create or replace function public.parking_reinforcement_login(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'private', 'pg_temp'
as $function$
declare
  v text := encode(extensions.gen_random_bytes(24), 'hex');
  expiry timestamptz := now() + interval '8 hours';
begin
  if coalesce(p_pin, '') <> '1' then
    raise exception 'Clave incorrecta';
  end if;
  insert into public.parking_reinforcement_access(token_hash, created_by, expires_at, access_method)
  values (encode(extensions.digest(v, 'sha256'), 'hex'), null, expiry, 'fixed_pin');
  return jsonb_build_object('code', v, 'expires_at', expiry);
end
$function$;

revoke all on function public.parking_reinforcement_login(text) from public;
grant execute on function public.parking_reinforcement_login(text) to anon, authenticated;
