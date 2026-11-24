create or replace function public.quote_public_parking_checkout(
  p_vehicle_type_code text,
  p_entry_at timestamptz,
  p_billable_days integer,
  p_exit_at timestamptz
)
returns table (
  vehicle_type text,
  entry_at timestamptz,
  exit_at timestamptz,
  duration_days integer,
  price_eur numeric,
  available_spaces integer
)
language plpgsql stable security definer set search_path = ''
as $function$
declare q record; v_type uuid;
begin
  if p_entry_at is null or p_exit_at is null or p_exit_at <= p_entry_at
     or p_billable_days is null or p_billable_days not between 1 and 24 then
    raise exception 'Fecha, hora o duración no válidas';
  end if;
  select * into q from public.quote_public_parking(p_vehicle_type_code,p_entry_at,p_billable_days);
  select id into v_type from public.vehicle_types where code=upper(p_vehicle_type_code) and active;
  if v_type is null then raise exception 'Tipo de vehículo no válido'; end if;
  return query select q.vehicle_type,p_entry_at,p_exit_at,p_billable_days,q.price_eur,
    private.parking_web_available(v_type,p_entry_at,p_exit_at,null);
end;
$function$;
revoke all on function public.quote_public_parking_checkout(text,timestamptz,integer,timestamptz) from public,anon,authenticated;
grant execute on function public.quote_public_parking_checkout(text,timestamptz,integer,timestamptz) to service_role;
