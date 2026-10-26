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

  -- Preserve an explicitly chosen end instead of rounding its clock time to full days.
  if (tg_op='INSERT' and new.exit_at is not null) or (tg_op='UPDATE' and new.exit_at is distinct from old.exit_at) then
    if new.exit_at<=new.entry_at or ceil(extract(epoch from (new.exit_at-new.entry_at))/86400.0)::integer<>new.duration_days then
      raise exception 'La fecha de salida no coincide con los días de estancia';
    end if;
  else
    new.exit_at := new.entry_at + (new.duration_days::double precision * interval '24 hours');
  end if;
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
$function$
;
CREATE OR REPLACE FUNCTION public.parking_pay_and_enter_stay_with_exit(p_reservation_id uuid, p_spot_id uuid, p_exit_at timestamp with time zone, p_method text, p_codes text[] DEFAULT '{}'::text[], p_print_ticket boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare p_days integer;ctx jsonb;r public.reservations;result jsonb;receipt jsonb;vprice numeric;code text;i integer;session_id uuid;
begin
 ctx:=public.rotation_operator_context();
 select * into r from public.reservations where id=p_reservation_id for update;
 if not found or r.status not in ('confirmed','pending_payment') or exists(select 1 from public.parking_sessions ps where ps.reservation_id=r.id) or r.finished_at is not null then raise exception 'Reserva no disponible para entrada';end if;
 if p_spot_id is null then raise exception 'Selecciona una plaza';end if;
 if p_exit_at is null or p_exit_at<=r.entry_at then raise exception 'La salida debe ser posterior a la entrada';end if;
 p_days:=ceil(extract(epoch from (p_exit_at-r.entry_at))/86400.0)::integer;
 if p_days is null or p_days not between 1 and 24 then raise exception 'Duración inválida';end if;
 if r.payment_status='paid' then raise exception 'Esta reserva ya está pagada. Usa Dar entrada';end if;
 vprice:=private.stay_price(r.vehicle_type_id,p_days,r.entry_at);
 if vprice is null then raise exception 'No existe tarifa para esa duración';end if;
 update public.reservations set duration_days=p_days,exit_at=p_exit_at,amount_eur=vprice,manual_price_override=false,updated_at=clock_timestamp() where id=r.id;
 if p_method in ('cash','card') then
  if coalesce(cardinality(p_codes),0)>0 then raise exception 'No introduzcas bonos para cobros en efectivo o tarjeta';end if;
  result:=public.parking_collect_stay(r.id,p_method,p_print_ticket);
  receipt:=result->'receipt';
 elsif p_method='hotel_voucher' then
  if cardinality(p_codes)<>p_days then raise exception 'Introduce un bono actual por cada día';end if;
  perform public.parking_pay_stay_hotel_vouchers(r.id,p_codes);
 elsif p_method='hotel_voucher_old' then
  if r.vehicle_type_id is distinct from (select id from public.vehicle_types where code='TURISMO' limit 1) then raise exception 'Los bonos hotel son solo para turismos';end if;
  if cardinality(p_codes)<>p_days then raise exception 'Introduce un bono antiguo por cada día';end if;
  for i in 1..p_days loop
   code:=upper(btrim(p_codes[i]));
   if code='' or length(code)>80 then raise exception 'Número de bono antiguo incorrecto (día %) ',i;end if;
   insert into public.parking_legacy_hotel_vouchers(reservation_id,hotel_voucher_number,day_number,recorded_by) values(r.id,code,i,auth.uid());
  end loop;
  update public.reservations set payment_method='hotel_voucher_old',payment_status='paid',updated_at=clock_timestamp() where id=r.id;
 else raise exception 'Forma de pago inválida';end if;
 session_id:=public.backoffice_check_in(r.id,p_spot_id,clock_timestamp());
 return jsonb_build_object('ok',true,'session_id',session_id,'reservation_id',r.id,'receipt',receipt,'days',p_days,'method',p_method);
end $function$
;
revoke all on function public.parking_pay_and_enter_stay_with_exit(uuid,uuid,timestamptz,text,text[],boolean) from public,anon;
grant execute on function public.parking_pay_and_enter_stay_with_exit(uuid,uuid,timestamptz,text,text[],boolean) to authenticated;

