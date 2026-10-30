-- Free-text legacy voucher records may also redeem a registered current voucher.
create or replace function private.parking_redeem_registered_legacy_hotel_voucher()
returns trigger language plpgsql security definer set search_path to '' as $$
declare entered text:=upper(btrim(new.hotel_voucher_number));canonical text;v public.parking_hotel_vouchers;b public.parking_hotel_batches;
begin
 if entered !~ '^(H-?)?[0-9]+$' then return new;end if;
 canonical:='H-'||((regexp_replace(entered,'^H-?',''))::numeric)::text;
 select * into v from public.parking_hotel_vouchers hv where hv.code=canonical for update;
 if not found then return new;end if;
 select * into b from public.parking_hotel_batches hb where hb.id=v.batch_id;
 if b.is_void then raise exception 'El bono % pertenece a una compra anulada',v.code;end if;
 if not exists(select 1 from public.parking_hotels h where h.id=b.hotel_id and h.active) then raise exception 'El hotel del bono % está desactivado',v.code;end if;
 if v.redeemed_reservation_id is not null then raise exception 'El bono % ya está utilizado y no puede volver a canjearse',v.code;end if;
 update public.parking_hotel_vouchers hv set redeemed_reservation_id=new.reservation_id,redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where hv.number=v.number;
 return new;
end $$;
revoke all on function private.parking_redeem_registered_legacy_hotel_voucher() from public,anon,authenticated;
create trigger redeem_registered_legacy_hotel_voucher after insert on public.parking_legacy_hotel_vouchers for each row execute function private.parking_redeem_registered_legacy_hotel_voucher();

CREATE OR REPLACE FUNCTION public.parking_pay_and_enter_stay(p_reservation_id uuid, p_spot_id uuid, p_days integer, p_method text, p_codes text[] DEFAULT '{}'::text[], p_print_ticket boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;r public.reservations;result jsonb;receipt jsonb;vprice numeric;code text;i integer;session_id uuid;
begin
 ctx:=public.rotation_operator_context();
 select * into r from public.reservations where id=p_reservation_id for update;
 if not found or r.status not in ('confirmed','pending_payment') or exists(select 1 from public.parking_sessions ps where ps.reservation_id=r.id) or r.finished_at is not null then raise exception 'Reserva no disponible para entrada';end if;
 if p_spot_id is null then raise exception 'Selecciona una plaza';end if;
 if p_days is null or p_days not between 1 and 24 then raise exception 'Duración inválida';end if;
 if r.payment_status='paid' then raise exception 'Esta reserva ya está pagada. Usa Dar entrada';end if;
 vprice:=private.stay_price(r.vehicle_type_id,p_days,r.entry_at);
 if vprice is null then raise exception 'No existe tarifa para esa duración';end if;
 update public.reservations set duration_days=p_days,amount_eur=vprice,manual_price_override=false,updated_at=clock_timestamp() where id=r.id;
 if p_method in ('cash','card') then
  if coalesce(cardinality(p_codes),0)>0 then raise exception 'No introduzcas bonos para cobros en efectivo o tarjeta';end if;
  result:=public.parking_collect_stay(r.id,p_method,p_print_ticket);
  receipt:=result->'receipt';
 elsif p_method='hotel_voucher' then
  if cardinality(p_codes)<>p_days then raise exception 'Introduce un bono actual por cada día';end if;
  perform public.parking_pay_stay_hotel_vouchers(r.id,p_codes);
 elsif p_method='hotel_voucher_old' then
  if r.vehicle_type_id is distinct from (select id from public.vehicle_types vt where vt.code='TURISMO' limit 1) then raise exception 'Los bonos hotel son solo para turismos';end if;
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
  if r.vehicle_type_id is distinct from (select id from public.vehicle_types vt where vt.code='TURISMO' limit 1) then raise exception 'Los bonos hotel son solo para turismos';end if;
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
