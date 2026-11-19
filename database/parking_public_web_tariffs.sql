-- Prices for public online bookings, independently of the counter.
create or replace function public.quote_public_parking(
  p_vehicle_type_code text, p_entry_at timestamptz, p_duration_days integer
)
returns table (vehicle_type text, entry_at timestamptz, exit_at timestamptz,
  duration_days integer, price_eur numeric, available_spaces integer)
language plpgsql stable security definer set search_path = ''
as $function$
declare
  v_code text := upper(p_vehicle_type_code);
  v_id uuid;
  v_exit timestamptz;
  v_price numeric;
begin
  if p_entry_at is null or p_duration_days is null or p_duration_days not between 1 and 24 then
    raise exception 'Fecha o duración no válidas';
  end if;
  select id into v_id from public.vehicle_types where code=v_code and active;
  v_price := case v_code
    when 'MOTO' then (array[8, 16, 24, 32, 40, 47, 54, 61, 68, 75, 81, 87, 93, 99, 105, 110, 115, 120, 125, 130, 135, 140, 145, 150])[p_duration_days]
    when 'TURISMO' then (array[17, 32, 47, 62, 77, 89, 101, 113, 125, 137, 147, 157, 167, 177, 185, 193, 201, 209, 217, 225, 232, 239, 246, 252])[p_duration_days]
    when 'XL' then (array[19, 36, 53, 70, 87, 101, 115, 129, 143, 157, 169, 181, 193, 205, 215, 225, 235, 245, 255, 265, 274, 283, 292, 300])[p_duration_days]
    when 'XXL' then (array[22, 42, 61, 80, 99, 115, 131, 147, 163, 179, 193, 207, 221, 235, 247, 259, 271, 283, 295, 306, 317, 328, 339, 350])[p_duration_days]
  end;
  if v_id is null or v_price is null then raise exception 'Tipo de vehículo no válido'; end if;
  v_exit := p_entry_at + p_duration_days * interval '24 hours';
  return query select v_code, p_entry_at, v_exit, p_duration_days, v_price,
    private.parking_web_available(v_id,p_entry_at,v_exit,null);
end;
$function$;
