CREATE OR REPLACE FUNCTION public.parking_edit_pending_stay(p_reservation_id uuid, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.reservations;changed public.reservations;tid uuid:=(p_data->>'vehicle_type_id')::uuid;
 v_plate text:=upper(btrim(coalesce(p_data->>'plate','')));v_model text:=upper(btrim(coalesce(p_data->>'model','')));price numeric;different_type boolean;new_entry timestamptz;new_days integer;period_changed boolean;
begin
 perform public.rotation_operator_context();
 select * into r from public.reservations where id=p_reservation_id for update;
 if not found or r.status not in('confirmed','pending_payment') or r.payment_status='paid' or r.finished_at is not null or exists(select 1 from public.parking_sessions where reservation_id=r.id) then raise exception 'La reserva ya no está pendiente. Actualiza el listado para editarla';end if;
 if r.updated_at is distinct from (p_data->>'expected_updated_at')::timestamptz then raise exception 'La reserva ha cambiado. Abre de nuevo la ficha antes de guardar';end if;
 if length(v_plate)<3 or length(v_plate)>30 or length(v_model)<1 or length(v_model)>200 then raise exception 'Completa matrícula y marca/modelo';end if;
 new_entry:=coalesce((p_data->>'entry_at')::timestamptz,r.entry_at);new_days:=coalesce((p_data->>'duration_days')::integer,r.duration_days);
 if new_entry is null or new_days not between 1 and 24 then raise exception 'Indica fecha de entrada y entre 1 y 24 días';end if;
 period_changed:=new_entry is distinct from r.entry_at or new_days is distinct from r.duration_days;
 price:=private.stay_price(tid,new_days,new_entry);if price is null then raise exception 'No existe una tarifa para esta categoría y duración';end if;
 different_type:=tid is distinct from r.vehicle_type_id;
 update public.reservations set entry_at=new_entry,duration_days=new_days,vehicle_type_id=tid,plate=v_plate,vehicle_make_model=v_model,
 customer_name=nullif(btrim(p_data->>'name'),''),customer_phone=nullif(btrim(p_data->>'phone'),''),customer_email=nullif(btrim(p_data->>'email'),''),notes=nullif(btrim(p_data->>'notes'),''),
 amount_eur=case when different_type or period_changed then price else r.amount_eur end,manual_price_override=case when different_type or period_changed then false else r.manual_price_override end,
 assigned_spot_id=case when r.assigned_spot_id is not null and not private.spot_accepts_vehicle(r.assigned_spot_id,tid) then null else r.assigned_spot_id end,
 updated_at=clock_timestamp() where id=r.id returning * into changed;
 return to_jsonb(changed);
end $function$;
