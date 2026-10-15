-- Staff need calculation results, but only managers may open/edit tariff configuration.
alter policy tariffs_admin_write on public.tariffs using(private.is_manager()) with check(private.is_manager());
alter policy rotation_tariffs_admin_write on public.rotation_tariffs using(private.is_manager()) with check(private.is_manager());
alter policy rotation_segments_admin_write on public.rotation_tariff_segments using(private.is_manager()) with check(private.is_manager());
create table public.parking_rate_periods (
 id uuid primary key default gen_random_uuid(), service text not null check(service in ('days','hourly')),
 vehicle_type_id uuid references public.vehicle_types(id), rotation_tariff_id uuid references public.rotation_tariffs(id),
 days integer not null default 0, starts_on date not null, ends_on date not null, price_eur numeric(10,2),
 multiplier numeric(10,5) not null default 1 check(multiplier>0), daily_cap_eur numeric(10,2),
 check(ends_on>=starts_on), check(price_eur>=0),check(daily_cap_eur>=0),
 check((service='days' and vehicle_type_id is not null and rotation_tariff_id is null and days between 1 and 24 and price_eur is not null) or (service='hourly' and vehicle_type_id is null and rotation_tariff_id is not null and days=0 and daily_cap_eur is not null))
);
alter table public.parking_rate_periods enable row level security;
grant select,insert,update,delete on public.parking_rate_periods to authenticated;
create policy rate_periods_manager_all on public.parking_rate_periods to authenticated using(private.is_manager()) with check(private.is_manager());
create function private.check_rate_period_overlap() returns trigger language plpgsql security invoker set search_path=public,private as $$begin
 perform pg_advisory_xact_lock(hashtext('parking_rate_periods')::bigint);
 if exists(select 1 from public.parking_rate_periods r where r.id<>new.id and r.service=new.service and r.vehicle_type_id is not distinct from new.vehicle_type_id and r.rotation_tariff_id is not distinct from new.rotation_tariff_id and r.days=new.days and r.starts_on<=new.ends_on and r.ends_on>=new.starts_on) then raise exception 'Ya existe una tarifa especial para esa categoría, duración y fechas'; end if;
 return new; end;$$;
create trigger rate_periods_overlap before insert or update on public.parking_rate_periods for each row execute function private.check_rate_period_overlap();
-- The resolver exposes only the public quoted price, keeping configuration management restricted.
create function private.stay_price(p_type uuid,p_days integer,p_entry timestamptz) returns numeric language sql stable security definer set search_path=public,private as $$
select coalesce((select price_eur from public.parking_rate_periods where service='days' and vehicle_type_id=p_type and days=p_days and (p_entry at time zone 'Europe/Madrid')::date between starts_on and ends_on limit 1),(select price_eur from public.tariffs where vehicle_type_id=p_type and days=p_days));$$;
revoke all on function private.stay_price(uuid,integer,timestamptz) from public;
grant execute on function private.stay_price(uuid,integer,timestamptz) to authenticated,anon;
create function public.parking_stay_price(p_vehicle_type_id uuid,p_days integer,p_entry_at timestamptz) returns numeric language sql stable security invoker set search_path=public,private as $$select private.stay_price(p_vehicle_type_id,p_days,p_entry_at);$$;
revoke all on function public.parking_stay_price(uuid,integer,timestamptz) from public;
grant execute on function public.parking_stay_price(uuid,integer,timestamptz) to authenticated,anon;
CREATE OR REPLACE FUNCTION public.set_reservation_computed_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_price numeric(10,2);
begin
  if new.duration_days < 1 or new.duration_days > 24 then
    raise exception 'La duración debe estar entre 1 y 24 días';
  end if;

  if tg_op='UPDATE' and new.vehicle_type_id=old.vehicle_type_id and new.entry_at=old.entry_at and new.duration_days=old.duration_days then
    new.plate := upper(trim(new.plate));
    return new;
  end if;

  new.exit_at := new.entry_at + (new.duration_days::double precision * interval '24 hours');
  new.plate := case when new.plate is null then null else upper(trim(new.plate)) end;

  v_price := private.stay_price(new.vehicle_type_id,new.duration_days,new.entry_at);

  if v_price is null then
    raise exception 'No existe tarifa para este tipo de vehículo y duración';
  end if;

  new.tariff_amount_eur := v_price;

  if new.payment_method = 'hotel_voucher' and not new.manual_price_override then
    new.amount_eur := 0;
  elsif not new.manual_price_override then
    new.amount_eur := v_price;
  end if;

  if new.status = 'pending_payment' and new.expires_at is null then
    new.expires_at := now() + interval '20 minutes';
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.quote_parking(p_vehicle_type_code text, p_entry_at timestamp with time zone, p_duration_days integer)
 RETURNS TABLE(vehicle_type text, entry_at timestamp with time zone, exit_at timestamp with time zone, duration_days integer, price_eur numeric, available_spaces integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_id uuid;
  v_exit timestamptz;
  v_price numeric(10,2);
begin
  if p_duration_days < 1 or p_duration_days > 24 then
    raise exception 'La duración debe estar entre 1 y 24 días';
  end if;
  select id into v_id from public.vehicle_types
  where code = upper(p_vehicle_type_code) and active = true;
  if v_id is null then raise exception 'Tipo de vehículo no válido'; end if;
  v_exit := p_entry_at + (p_duration_days::double precision * interval '24 hours');
  v_price := private.stay_price(v_id,p_duration_days,p_entry_at);
  return query
  select upper(p_vehicle_type_code), p_entry_at, v_exit, p_duration_days, v_price::numeric,
         private.get_available_spaces(v_id, p_entry_at, v_exit, null);
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_reservation_terms(p_reservation_id uuid, p_vehicle_type_id uuid, p_duration_days integer, p_amount_eur numeric, p_manual_price_override boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'auth', 'pg_temp'
AS $function$
declare
  v_user uuid := auth.uid();
  v_old public.reservations%rowtype;
  v_new public.reservations%rowtype;
  v_standard numeric(10,2);
  v_amount numeric(10,2);
  v_diff numeric(10,2);
begin
  if v_user is null or not private.is_staff() then
    raise exception 'Acceso no autorizado';
  end if;

  if p_duration_days < 1 or p_duration_days > 24 then
    raise exception 'La duración debe estar entre 1 y 24 días';
  end if;

  select * into v_old
  from public.reservations
  where id=p_reservation_id
  for update;

  if not found then raise exception 'Reserva no encontrada'; end if;
  if v_old.status='cancelled' then raise exception 'La reserva está cancelada'; end if;

  v_standard := private.stay_price(p_vehicle_type_id,p_duration_days,v_old.entry_at);

  if v_standard is null then
    raise exception 'No existe tarifa para esta categoría y duración';
  end if;

  v_amount := greatest(coalesce(p_amount_eur,v_standard),0);

  update public.reservations
  set vehicle_type_id=p_vehicle_type_id,
      duration_days=p_duration_days,
      amount_eur=v_amount,
      manual_price_override=p_manual_price_override,
      updated_at=clock_timestamp()
  where id=p_reservation_id
  returning * into v_new;

  -- Keep session dates/type in sync if the stay has already started.
  update public.parking_sessions
  set vehicle_type_id=v_new.vehicle_type_id,
      planned_exit_at=v_new.exit_at,
      updated_at=clock_timestamp()
  where reservation_id=p_reservation_id;

  v_diff := round(v_new.amount_eur - v_old.amount_eur,2);

  return jsonb_build_object(
    'ok',true,
    'old_amount_eur',v_old.amount_eur,
    'new_amount_eur',v_new.amount_eur,
    'standard_amount_eur',v_new.tariff_amount_eur,
    'difference_eur',v_diff,
    'old_exit_at',v_old.exit_at,
    'new_exit_at',v_new.exit_at,
    'duration_days',v_new.duration_days
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.calculate_rotation_amount(p_tariff_code text, p_entry_at timestamp with time zone, p_exit_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'auth', 'pg_temp'
AS $function$
declare
  v_tariff public.rotation_tariffs%rowtype;
  v_total_minutes integer;
  v_full_days integer;
  v_remainder integer;
  v_chargeable_remainder integer;
  v_partial_raw numeric(14,5) := 0;
  v_raw numeric(14,5);
  v_i integer;
  v_minutes integer;
  v_factor numeric;
  v_cap numeric;
  v_period public.parking_rate_periods%rowtype;
  v_rounded numeric(10,2);
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception 'Acceso no autorizado';
  end if;

  if p_exit_at < p_entry_at then
    raise exception 'La salida no puede ser anterior a la entrada';
  end if;

  select * into v_tariff
  from public.rotation_tariffs
  where code=upper(trim(p_tariff_code))
    and active=true;

  if not found then
    raise exception 'Tarifa de rotación no encontrada';
  end if;

  if not v_tariff.calculation_ready then
    raise exception 'Los tramos de esta tarifa todavía no están configurados';
  end if;

  v_total_minutes := greatest(0,floor(extract(epoch from (p_exit_at-p_entry_at))/60.0)::integer);
  v_full_days := v_total_minutes / 1440;
  v_remainder := v_total_minutes % 1440;

  v_raw := 0;
  -- Each rolling 24h block uses the tariff on its start date in Málaga.
  for v_i in 0..v_full_days loop
    v_minutes := case when v_i<v_full_days then 1440 else v_remainder end;
    if v_minutes=0 then continue; end if;
    select * into v_period from public.parking_rate_periods where service='hourly' and rotation_tariff_id=v_tariff.id and ((p_entry_at+v_i*interval '24 hours') at time zone 'Europe/Madrid')::date between starts_on and ends_on limit 1;
    v_factor := coalesce(v_period.multiplier,1);
    v_cap := coalesce(v_period.daily_cap_eur,v_tariff.daily_cap_eur);
    if v_minutes>=720 then v_partial_raw:=v_cap;
    else
      select coalesce(sum(greatest(0,least(v_minutes,s.to_minute)-s.from_minute)::numeric*s.price_per_minute_eur),0)*v_factor into v_partial_raw from public.rotation_tariff_segments s where s.tariff_id=v_tariff.id and s.from_minute<v_minutes;
      v_partial_raw:=least(v_partial_raw,v_cap);
    end if;
    v_raw:=v_raw+v_partial_raw;
  end loop;
  v_chargeable_remainder:=least(v_remainder,720);

  v_rounded := public.floor_to_rotation_step(v_raw,v_tariff.rounding_step_eur);

  return jsonb_build_object(
    'tariff_code',v_tariff.code,
    'tariff_name',v_tariff.name,
    'total_minutes',v_total_minutes,
    'full_days',v_full_days,
    'remainder_minutes',v_remainder,
    'chargeable_remainder_minutes',v_chargeable_remainder,
    'daily_cap_eur',v_tariff.daily_cap_eur,
    'raw_amount_eur',round(v_raw,5),
    'amount_eur',round(v_rounded,2),
    'rounding_step_eur',v_tariff.rounding_step_eur
  );
end
$function$;

-- Save hourly cap and all segment prices atomically.
create function public.parking_save_rotation_rate(p_tariff_id uuid,p_daily_cap_eur numeric,p_segments jsonb) returns void language plpgsql security invoker set search_path=public,private as $$
declare s jsonb;
begin
 if not private.is_manager() then raise exception 'Solo administradores y gerentes pueden modificar tarifas'; end if;
 if p_daily_cap_eur is null or p_daily_cap_eur<0 then raise exception 'Precio no válido'; end if;
 perform 1 from public.rotation_tariffs where id=p_tariff_id for update;
 if not found then raise exception 'Tarifa no encontrada'; end if;
 if jsonb_array_length(p_segments)<>(select count(*) from public.rotation_tariff_segments where tariff_id=p_tariff_id) then raise exception 'Faltan tramos de tarifa'; end if;
 for s in select value from jsonb_array_elements(p_segments) loop
  if (s->>'price_per_minute_eur')::numeric is null or (s->>'price_per_minute_eur')::numeric<0 then raise exception 'Precio por minuto no válido'; end if;
  update public.rotation_tariff_segments set price_per_minute_eur=(s->>'price_per_minute_eur')::numeric where tariff_id=p_tariff_id and segment_order=(s->>'segment_order')::integer;
  if not found then raise exception 'Tramo no válido'; end if;
 end loop;
 update public.rotation_tariffs set daily_cap_eur=p_daily_cap_eur where id=p_tariff_id;
end;$$;
revoke all on function public.parking_save_rotation_rate(uuid,numeric,jsonb) from public;
grant execute on function public.parking_save_rotation_rate(uuid,numeric,jsonb) to authenticated;
