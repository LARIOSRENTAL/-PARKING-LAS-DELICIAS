create or replace function public.parking_reinforcement_stay_spots(p_code text) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.parking_reinforcement_access where token_hash=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex') and revoked_at is null and expires_at>now()) then raise exception 'Código caducado';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'types',(select coalesce(jsonb_agg(t.id),'[]'::jsonb) from public.vehicle_types t where private.spot_accepts_vehicle(p.id,t.id))) order by p.sort_order,p.code),'[]'::jsonb) from public.parking_spots p where private.parking_spot_is_available(p.id));
end;$$;
create or replace function public.parking_reinforcement_create_stay_with_spot(p_code text,p_type uuid,p_plate text,p_model text,p_entry timestamptz,p_days integer,p_name text default null,p_spot_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.reservations;price numeric;
begin
 if not exists(select 1 from public.parking_reinforcement_access where token_hash=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex') and revoked_at is null and expires_at>now()) then raise exception 'Código caducado';end if;
 if p_entry is null or p_days is null or p_days not between 1 and 24 or length(trim(coalesce(p_plate,'')))<3 or length(trim(coalesce(p_model,'')))<2 then raise exception 'Datos incompletos';end if;
 price:=private.stay_price(p_type,p_days,p_entry);if price is null then raise exception 'Tarifa no disponible';end if;
 if p_spot_id is not null then
  perform 1 from public.parking_spots where id=p_spot_id for update;
  if not private.parking_spot_is_available(p_spot_id) or not private.spot_accepts_vehicle(p_spot_id,p_type) then raise exception 'La plaza ya no está disponible o no admite este vehículo. Elige otra plaza o deja sin asignar';end if;
 end if;
 insert into public.reservations(vehicle_type_id,entry_at,duration_days,plate,vehicle_make_model,customer_name,status,payment_status,payment_method,amount_eur,manual_price_override,source,assigned_spot_id)
 values(p_type,p_entry,p_days,upper(trim(p_plate)),upper(trim(p_model)),nullif(trim(coalesce(p_name,'')),''),'confirmed','pending',null,price,false,'admin',p_spot_id) returning * into r;
 return jsonb_build_object('id',r.id,'reference',r.reference,'plate',r.plate,'exit_at',r.exit_at,'payment_status',r.payment_status,'assigned_spot_id',r.assigned_spot_id);
end;$$;
create or replace function public.parking_set_pending_stay_spot(p_reservation_id uuid,p_spot_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.reservations;
begin
 perform public.rotation_operator_context();select * into r from public.reservations where id=p_reservation_id for update;
 if not found or r.status not in ('confirmed','pending_payment') or r.finished_at is not null or r.rotation_pending or exists(select 1 from public.parking_sessions where reservation_id=r.id) then raise exception 'Solo se puede asignar la plaza de reservas pendientes de entrada';end if;
 if p_spot_id is not null then
  perform 1 from public.parking_spots where id=p_spot_id for update;
  if not private.parking_spot_is_available(p_spot_id,r.id) or not private.spot_accepts_vehicle(p_spot_id,r.vehicle_type_id) then raise exception 'La plaza no está disponible para este vehículo';end if;
 end if;
 update public.reservations set assigned_spot_id=p_spot_id,updated_at=clock_timestamp() where id=r.id;
 return jsonb_build_object('id',r.id,'assigned_spot_id',p_spot_id);
end;$$;
revoke all on function public.parking_reinforcement_stay_spots(text) from public;
revoke all on function public.parking_reinforcement_create_stay_with_spot(text,uuid,text,text,timestamptz,integer,text,uuid) from public;
grant execute on function public.parking_reinforcement_stay_spots(text) to anon,authenticated;
grant execute on function public.parking_reinforcement_create_stay_with_spot(text,uuid,text,text,timestamptz,integer,text,uuid) to anon,authenticated;
revoke all on function public.parking_set_pending_stay_spot(uuid,uuid) from public,anon;
grant execute on function public.parking_set_pending_stay_spot(uuid,uuid) to authenticated;
