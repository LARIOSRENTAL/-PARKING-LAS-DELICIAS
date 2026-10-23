CREATE OR REPLACE FUNCTION public.parking_reinforcement_create_stay(p_code text, p_type uuid, p_plate text, p_model text, p_entry timestamp with time zone, p_days integer, p_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  r public.reservations;
  price numeric;
begin
  if not exists (
    select 1 from public.parking_reinforcement_access
    where token_hash = encode(extensions.digest(coalesce(p_code, ''), 'sha256'), 'hex')
      and revoked_at is null and expires_at > now()
  ) then
    raise exception 'Código caducado';
  end if;
  if p_entry is null or p_days not between 1 and 24 or length(trim(coalesce(p_plate, ''))) < 3 or length(trim(coalesce(p_model, ''))) < 2 then
    raise exception 'Datos incompletos';
  end if;
  price := private.stay_price(p_type, p_days, p_entry);
  if price is null then raise exception 'Tarifa no disponible'; end if;
  insert into public.reservations(
    vehicle_type_id, entry_at, duration_days, plate, vehicle_make_model, customer_name,
    status, payment_status, payment_method, amount_eur, manual_price_override, source
  )
  values(
    p_type, p_entry, p_days, upper(trim(p_plate)), upper(trim(p_model)),
    nullif(trim(coalesce(p_name, '')), ''), 'confirmed', 'pending', null,
    price, false, 'admin'
  )
  returning * into r;
  return jsonb_build_object(
    'reference', r.reference, 'plate', r.plate, 'exit_at', r.exit_at, 'payment_status', r.payment_status
  );
end
$function$


CREATE OR REPLACE FUNCTION public.parking_reinforcement_enter(p_code text, p_tariff text, p_plate text, p_spot text, p_client text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  t public.rotation_tariffs;
  ps public.parking_spots;
  s public.rotation_sessions;
  vplate text := regexp_replace(upper(coalesce(p_plate, '')), '[^A-Z0-9]', '', 'g');
begin
  if not exists (
    select 1 from public.parking_reinforcement_access
    where token_hash = encode(extensions.digest(coalesce(p_code, ''), 'sha256'), 'hex')
      and revoked_at is null and expires_at > now()
  ) then
    raise exception 'Código caducado';
  end if;
  if vplate !~ '^[A-Z0-9]{3,16}$' then raise exception 'Matrícula incorrecta'; end if;
  perform pg_advisory_xact_lock(hashtext('rotation_plate'), hashtext(vplate));
  if exists (
    select 1 from public.rotation_sessions
    where status = 'inside' and regexp_replace(upper(plate), '[^A-Z0-9]', '', 'g') = vplate
  ) then raise exception 'Vehículo ya dentro'; end if;
  select * into t from public.rotation_tariffs where code = upper(trim(p_tariff)) and active;
  if not found then raise exception 'Tarifa incorrecta'; end if;
  select * into ps from public.parking_spots
  where upper(regexp_replace(code, '[^A-Za-z0-9]', '', 'g')) =
        upper(regexp_replace(coalesce(p_spot, ''), '[^A-Za-z0-9]', '', 'g'))
    and active and inventory_state = 'available'
  for update;
  if not found or not private.rotation_spot_accepts_tariff(ps.id, t.code) or not private.rotation_spot_is_free(ps.id) then
    raise exception 'Plaza inexistente, incompatible u ocupada';
  end if;
  insert into public.rotation_sessions(
    tariff_id, plate, client_text, leaves_keys, key_number, spot_id, spot_code, entry_employee_name, billing_only
  )
  values(
    t.id, vplate, nullif(left(trim(coalesce(p_client, '')), 300), ''),
    ps.zone not in ('A', 'M'), ps.code, ps.id, ps.code, 'REFUERZO', false
  )
  returning * into s;
  return jsonb_build_object(
    'ticket_number', s.ticket_number, 'plate', s.plate, 'spot', s.spot_code,
    'entry_at', s.entry_at, 'tariff', t.name
  );
end
$function$


CREATE OR REPLACE FUNCTION public.parking_reinforcement_issue()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  v text := encode(extensions.gen_random_bytes(24), 'hex');
  expiry timestamptz := now() + interval '8 hours';
begin
  if auth.uid() is null or not exists (
    select 1 from public.staff_profiles
    where user_id = auth.uid() and active and role in ('admin', 'manager')
  ) then
    raise exception 'Acceso denegado';
  end if;
  insert into public.parking_reinforcement_access(token_hash, created_by, expires_at)
  values(encode(extensions.digest(v, 'sha256'), 'hex'), auth.uid(), expiry);
  return jsonb_build_object('code', v, 'expires_at', expiry);
end
$function$


CREATE OR REPLACE FUNCTION public.parking_reinforcement_options(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  if not exists (
    select 1
    from public.parking_reinforcement_access
    where token_hash = encode(extensions.digest(coalesce(p_code, ''), 'sha256'), 'hex')
      and revoked_at is null
      and expires_at > now()
  ) then
    raise exception 'Código no válido o caducado';
  end if;
  return jsonb_build_object(
    'tariffs', (
      select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name) order by sort_order), '[]'::jsonb)
      from public.rotation_tariffs where active
    ),
    'types', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order), '[]'::jsonb)
      from public.vehicle_types
    )
  );
end
$function$
