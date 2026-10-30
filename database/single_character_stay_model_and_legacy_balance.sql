CREATE OR REPLACE FUNCTION public.parking_save_stay_changes(p_request_id uuid, p_reservation_id uuid, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;r public.reservations;updated public.reservations;c public.parking_stay_changes;info jsonb;invoice jsonb;receipt jsonb;days integer:=(p_data->>'days')::integer;type_id uuid:=(p_data->>'vehicle_type_id')::uuid;method text:=p_data->>'payment_method';amount numeric:=round((p_data->>'amount_eur')::numeric,2);diff numeric;added integer;entry_time timestamptz:=(p_data->>'entry_at')::timestamptz;
begin
 ctx:=public.rotation_operator_context();if p_request_id is null then raise exception 'Falta el identificador de operación';end if;
 perform pg_advisory_xact_lock(hashtextextended('stay-change:'||p_request_id,0));
 select * into c from public.parking_stay_changes where id=p_request_id;
 if found then
  if c.created_by<>auth.uid() or c.reservation_id<>p_reservation_id then raise exception 'No autorizado';end if;
  select * into updated from public.reservations where id=c.reservation_id;
 else
  select * into r from public.reservations where id=p_reservation_id for update;
  if not found or r.status not in ('confirmed','checked_in','pending_payment') or r.rotation_pending or r.finished_at is not null then raise exception 'Esta estancia no se puede modificar';end if;
  if (p_data->>'expected_updated_at')::timestamptz is distinct from r.updated_at then raise exception 'La reserva ha cambiado. Actualiza la ficha antes de guardar';end if;
  if method is null or method not in ('cash','card','hotel_voucher') or days is null or days<1 or days>24 or entry_time is null or amount is null or amount<0 or amount>999999 then raise exception 'Revisa duración, precio, entrada y forma de pago';end if;
  if length(btrim(coalesce(p_data->>'plate','')))<3 or length(btrim(coalesce(p_data->>'model','')))<1 then raise exception 'Completa matrícula y marca/modelo';end if;
  if exists(select 1 from public.parking_sessions where reservation_id=r.id) and entry_time<>r.entry_at then raise exception 'No se puede cambiar la entrada inicial de una estancia iniciada';end if;
  if r.assigned_spot_id is not null and not private.spot_accepts_vehicle(r.assigned_spot_id,type_id) then raise exception 'La plaza actual no admite este tamaño. Cambia primero a una plaza compatible';end if;
  if private.stay_price(type_id,days,entry_time) is null then raise exception 'No existe tarifa para esta categoría y duración';end if;
  added:=days-r.duration_days;
  if method='hotel_voucher' then
   if not exists(select 1 from public.vehicle_types where id=type_id and code='TURISMO') then raise exception 'Los bonos hotel solo son válidos para turismos';end if;
   if added<0 then raise exception 'Los bonos canjeados no se pueden devolver desde esta ficha';end if;
   if added>0 then
    info:=private.resolve_hotel_voucher_codes(array(select jsonb_array_elements_text(p_data->'codes')),true);
    if (info->>'available_days')::integer<added then raise exception 'Bonos insuficientes';end if;
    if (info->>'days')::integer<>added then raise exception 'Aporta un bono por cada día adicional';end if;
    if r.hotel_id is not null and r.hotel_id<>(info->>'hotel_id')::uuid then raise exception 'Utiliza bonos del mismo hotel';end if;
    perform 1 from public.parking_hotels where id=(info->>'hotel_id')::uuid for update;
    insert into public.parking_hotel_redemptions(reservation_id,hotel_id,days) values(r.id,(info->>'hotel_id')::uuid,added)
    on conflict(reservation_id) do update set days=parking_hotel_redemptions.days+excluded.days;
    update public.parking_hotel_vouchers set redeemed_reservation_id=r.id,redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where code in(select jsonb_array_elements_text(info->'codes'));
   end if;
   amount:=r.amount_eur;diff:=0;
  else
   diff:=round(amount-r.amount_eur,2);
   if diff<0 then raise exception 'El precio no puede ser inferior al ya abonado. La devolución requiere una rectificación';end if;
   if diff>0 and r.payment_status<>'paid' then raise exception 'El pago inicial no consta registrado. Verifica ese pago antes de cobrar una ampliación';end if;
  end if;
  update public.reservations set vehicle_type_id=type_id,entry_at=entry_time,duration_days=days,amount_eur=amount,manual_price_override=true,plate=upper(btrim(p_data->>'plate')),vehicle_make_model=upper(btrim(p_data->>'model')),customer_name=nullif(btrim(p_data->>'name'),''),customer_phone=nullif(btrim(p_data->>'phone'),''),customer_email=nullif(btrim(p_data->>'email'),''),notes=nullif(btrim(p_data->>'notes'),''),hotel_id=coalesce(r.hotel_id,(info->>'hotel_id')::uuid),updated_at=clock_timestamp() where id=r.id returning * into updated;
  update public.parking_sessions set vehicle_type_id=updated.vehicle_type_id,plate=updated.plate,vehicle_make_model=updated.vehicle_make_model,customer_name=updated.customer_name,customer_phone=updated.customer_phone,planned_exit_at=updated.exit_at,updated_at=clock_timestamp() where reservation_id=r.id;
  insert into public.parking_stay_changes(id,reservation_id,created_by,payment_method,amount_eur,before_data,after_data) values(p_request_id,r.id,auth.uid(),method,coalesce(diff,0),to_jsonb(r),to_jsonb(updated)) returning * into c;
  if diff>0 then
   insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,reference,plate,description,amount_eur,payment_method,user_id,shift_id,employee_name,details)
   values('stay_change:'||c.id,'stay','stay_change',c.id,r.reference,updated.plate,'Ampliación / modificación de estancia',diff,method,auth.uid(),nullif(ctx->>'shift_id','')::uuid,ctx->>'employee_name',jsonb_build_object('reservation_id',r.id,'entry_at',updated.entry_at,'exit_at',updated.exit_at,'old_exit_at',r.exit_at));
  end if;
 end if;
 if c.amount_eur>0 then
  if p_data->'invoice_customer' is not null and p_data->'invoice_customer'<>'null'::jsonb then
   invoice:=public.parking_issue_full_invoice('stay_change',c.id,null,p_data->'invoice_customer'->>'name',p_data->'invoice_customer'->>'tax_id',p_data->'invoice_customer'->>'address');
  elsif coalesce((p_data->>'print_ticket')::boolean,false) or c.payment_method='card' then receipt:=public.parking_issue_simplified('stay_change',c.id);end if;
 end if;
 if c.amount_eur>0 and c.payment_method='card' and receipt is null then receipt:=public.parking_issue_simplified('stay_change',c.id);end if;
 return jsonb_build_object('reservation',to_jsonb(updated),'change',to_jsonb(c),'receipt',receipt,'invoice',invoice);
end $function$
;
CREATE OR REPLACE FUNCTION public.parking_create_paid_stay(p_request_id uuid, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;r public.reservations;created jsonb;receipt jsonb;method text:=p_data->>'payment_method';days integer:=(p_data->>'days')::integer;type_id uuid:=(p_data->>'vehicle_type_id')::uuid;standard numeric;amount numeric;
begin
 ctx:=public.rotation_operator_context();
 if p_request_id is null then raise exception 'Falta el identificador de operación';end if;
 perform pg_advisory_xact_lock(hashtextextended('new-stay:'||p_request_id,0));
 select * into r from public.reservations where creation_request_id=p_request_id;
 if found then
  if r.created_by<>auth.uid() then raise exception 'No autorizado';end if;
 else
  if method is null or method not in ('cash','card','hotel_voucher') then raise exception 'Forma de pago inválida';end if;
  if length(btrim(coalesce(p_data->>'plate','')))<3 or length(btrim(coalesce(p_data->>'model','')))<1 or days is null or days<1 or days>24 then raise exception 'Completa matrícula, marca/modelo y duración';end if;
  if method='hotel_voucher' then
   select id into type_id from public.vehicle_types where code='TURISMO';
   created:=public.parking_create_stay_from_vouchers(array(select jsonb_array_elements_text(p_data->'codes')),type_id,(p_data->>'entry_at')::timestamptz,days,p_data->>'plate',p_data->>'model',p_data->>'name',p_data->>'phone',p_data->>'email',p_data->>'notes');
   update public.reservations set creation_request_id=p_request_id where id=(created->>'id')::uuid returning * into r;
  else
   standard:=private.stay_price(type_id,days,(p_data->>'entry_at')::timestamptz);amount:=round((p_data->>'amount_eur')::numeric,2);
   if standard is null or amount is null or amount<0 or amount>999999 then raise exception 'Precio no válido';end if;
   insert into public.reservations(creation_request_id,vehicle_type_id,entry_at,duration_days,plate,vehicle_make_model,customer_name,customer_phone,customer_email,notes,status,payment_status,payment_method,amount_eur,manual_price_override,source,created_by)
   values(p_request_id,type_id,(p_data->>'entry_at')::timestamptz,days,upper(btrim(p_data->>'plate')),upper(btrim(p_data->>'model')),nullif(btrim(p_data->>'name'),''),nullif(btrim(p_data->>'phone'),''),nullif(btrim(p_data->>'email'),''),nullif(btrim(p_data->>'notes'),''),'confirmed','paid',method,amount,true,'admin',auth.uid()) returning * into r;
  end if;
 end if;
 if r.payment_method in ('cash','card') and coalesce((p_data->>'print_ticket')::boolean,false) then receipt:=public.parking_issue_simplified('reservation',r.id);end if;
 return jsonb_build_object('reservation',to_jsonb(r),'receipt',receipt);
end $function$
;
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
  if p_entry is null or p_days not between 1 and 24 or length(trim(coalesce(p_plate, ''))) < 3 or length(trim(coalesce(p_model, ''))) <1 then
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
;
CREATE OR REPLACE FUNCTION public.parking_create_unpaid_stay(p_request_id uuid, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;r public.reservations;d integer:=(p_data->>'days')::integer;tid uuid:=(p_data->>'vehicle_type_id')::uuid;e timestamptz:=(p_data->>'entry_at')::timestamptz;price numeric;x timestamptz:=nullif(p_data->>'exit_at','')::timestamptz;
begin
ctx:=public.rotation_operator_context();
if p_request_id is null then raise exception 'Identificador obligatorio';end if;
perform pg_advisory_xact_lock(hashtextextended('unpaid-stay:'||p_request_id,0));
select * into r from public.reservations where creation_request_id=p_request_id;
if found then return to_jsonb(r);end if;
if x is not null then
 if e is null or x<=e then raise exception 'La salida debe ser posterior a la entrada';end if;
 d:=ceil(extract(epoch from (x-e))/86400.0)::integer;
end if;
if d is null or d not between 1 and 24 or e is null or length(trim(coalesce(p_data->>'plate','')))<3 or length(trim(coalesce(p_data->>'model','')))<1 then raise exception 'Datos de estancia incompletos';end if;
price:=private.stay_price(tid,d,e);if price is null then raise exception 'Tarifa no encontrada';end if;
insert into public.reservations(creation_request_id,vehicle_type_id,entry_at,exit_at,duration_days,plate,vehicle_make_model,customer_name,customer_phone,customer_email,notes,status,payment_status,payment_method,amount_eur,manual_price_override,source,created_by)
values(p_request_id,tid,e,x,d,upper(trim(p_data->>'plate')),upper(trim(p_data->>'model')),nullif(trim(p_data->>'name'),''),nullif(trim(p_data->>'phone'),''),nullif(trim(p_data->>'email'),''),nullif(trim(p_data->>'notes'),''),'confirmed','pending',null,price,false,'admin',auth.uid()) returning * into r;
return to_jsonb(r);
end $function$
;
CREATE OR REPLACE FUNCTION public.parking_reinforcement_create_stay_with_spot(p_code text, p_type uuid, p_plate text, p_model text, p_entry timestamp with time zone, p_days integer, p_name text DEFAULT NULL::text, p_spot_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.reservations;price numeric;
begin
 if not exists(select 1 from public.parking_reinforcement_access where token_hash=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex') and revoked_at is null and expires_at>now()) then raise exception 'Código caducado';end if;
 if p_entry is null or p_days is null or p_days not between 1 and 24 or length(trim(coalesce(p_plate,'')))<3 or length(trim(coalesce(p_model,'')))<1 then raise exception 'Datos incompletos';end if;
 price:=private.stay_price(p_type,p_days,p_entry);if price is null then raise exception 'Tarifa no disponible';end if;
 if p_spot_id is not null then
  perform 1 from public.parking_spots where id=p_spot_id for update;
  if not private.parking_spot_is_available(p_spot_id) or not private.spot_accepts_vehicle(p_spot_id,p_type) then raise exception 'La plaza ya no está disponible o no admite este vehículo. Elige otra plaza o deja sin asignar';end if;
 end if;
 insert into public.reservations(vehicle_type_id,entry_at,duration_days,plate,vehicle_make_model,customer_name,status,payment_status,payment_method,amount_eur,manual_price_override,source,assigned_spot_id)
 values(p_type,p_entry,p_days,upper(trim(p_plate)),upper(trim(p_model)),nullif(trim(coalesce(p_name,'')),''),'confirmed','pending',null,price,false,'admin',p_spot_id) returning * into r;
 return jsonb_build_object('id',r.id,'reference',r.reference,'plate',r.plate,'exit_at',r.exit_at,'payment_status',r.payment_status,'assigned_spot_id',r.assigned_spot_id);
end;$function$
;
CREATE OR REPLACE FUNCTION public.parking_convert_rotation_stay(p_session_id uuid, p_vehicle_type_id uuid, p_spot_id uuid, p_days integer, p_model text, p_method text DEFAULT 'hotel_voucher'::text, p_codes text[] DEFAULT '{}'::text[], p_difference_method text DEFAULT 'cash'::text, p_print_ticket boolean DEFAULT false, p_commit boolean DEFAULT false, p_expected_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.rotation_sessions;r jsonb;doc jsonb;rot jsonb;rid uuid;covered integer:=0;price numeric:=0;difference numeric:=0;v_now timestamptz:=clock_timestamp();covered_until timestamptz;planned_exit timestamptz;charge_until timestamptz;tariff text;info jsonb;v_code text;i integer;
begin
 perform public.rotation_operator_context();
 select * into s from public.rotation_sessions where id=p_session_id for update;
 if not found then raise exception 'Ticket inexistente';end if;
 if s.converted_reservation_id is not null then return jsonb_build_object('id',s.converted_reservation_id,'already_converted',true);end if;
 if s.status<>'inside' or s.billing_only then raise exception 'El ticket no está dentro de Rotación';end if;
 if p_days is null or p_days not between 1 and 24 then raise exception 'Selecciona entre 1 y 24 días';end if;
 if p_method is null or p_method not in ('cash','card','hotel_voucher','hotel_voucher_old') then raise exception 'Forma de pago inválida';end if;
 if length(btrim(coalesce(p_model,'')))<1 then raise exception 'Completa marca/modelo';end if;
 perform 1 from public.parking_spots p where p.id=p_spot_id and p.active and private.spot_accepts_vehicle(p.id,p_vehicle_type_id) for update;
 if not found then raise exception 'Selecciona una plaza compatible';end if;
 planned_exit:=s.entry_at+p_days*interval '24 hours';
 if p_method in ('hotel_voucher','hotel_voucher_old') then
  if not exists(select 1 from public.vehicle_types where id=p_vehicle_type_id and vehicle_types.code='TURISMO') then raise exception 'Bonos hotel: solo turismos';end if;
  covered:=coalesce(cardinality(p_codes),0);
  if covered<1 or covered>p_days then raise exception 'Indica entre 1 y % bonos',p_days;end if;
  if p_method='hotel_voucher' then info:=private.resolve_hotel_voucher_codes(p_codes,false);
  else
   if (select count(distinct upper(btrim(x))) from unnest(p_codes) x)<>covered then raise exception 'Hay bonos antiguos repetidos';end if;
   foreach v_code in array p_codes loop if nullif(btrim(v_code),'') is null or length(v_code)>80 then raise exception 'Número de bono antiguo inválido';end if;end loop;
  end if;
  covered_until:=s.entry_at+covered*interval '24 hours';charge_until:=greatest(v_now,planned_exit);
  select t.code into tariff from public.rotation_tariffs t where t.id=s.tariff_id;
  if charge_until>covered_until then difference:=(public.calculate_rotation_amount(tariff,covered_until,charge_until)->>'amount_eur')::numeric;end if;
 else
  if coalesce(cardinality(p_codes),0)>0 then raise exception 'No introduzcas bonos para efectivo o tarjeta';end if;
  price:=private.stay_price(p_vehicle_type_id,p_days,s.entry_at);
  if price is null then raise exception 'Tarifa de estancia inexistente';end if;
 end if;
 if not p_commit then return jsonb_build_object('stay_amount',price,'difference_amount',difference,'total',price+difference,'entry_at',s.entry_at,'exit_at',planned_exit,'covered_until',covered_until,'charge_until',charge_until,'covered_days',covered);end if;
 if p_expected_amount is null or abs(round(p_expected_amount,2)-round(price+difference,2))>0.001 then raise exception 'El importe ha cambiado. Recalcula antes de confirmar';end if;
 if difference>0 then
  if p_difference_method is null or p_difference_method not in ('cash','card') then raise exception 'Selecciona el pago de la diferencia';end if;
  rot:=public.parking_checkout_rotation(s.id,difference,p_difference_method,p_print_ticket,'Diferencia al convertir a estancia; bonos: '||covered||'; cobertura hasta '||covered_until::text,null);
 else
  update public.rotation_sessions set status='cancelled',updated_at=v_now where id=s.id;
 end if;
 if p_method='hotel_voucher' then
  r:=public.parking_create_stay_from_vouchers(p_codes,p_vehicle_type_id,s.entry_at,covered,s.plate,p_model,s.client_text,null,null,'Convertida desde ticket '||s.ticket_number);
  rid:=(r->>'id')::uuid;
  update public.reservations set duration_days=p_days,exit_at=planned_exit where id=rid;
 else
  r:=public.parking_create_unpaid_stay(s.id,jsonb_build_object('vehicle_type_id',p_vehicle_type_id,'entry_at',s.entry_at,'days',p_days,'plate',s.plate,'model',p_model,'name',s.client_text,'notes','Convertida desde ticket '||s.ticket_number));rid:=(r->>'id')::uuid;
  if p_method in ('cash','card') then doc:=public.parking_collect_stay(rid,p_method,p_print_ticket);
  else
   for i in 1..covered loop insert into public.parking_legacy_hotel_vouchers(reservation_id,hotel_voucher_number,day_number,recorded_by) values(rid,upper(btrim(p_codes[i])),i,auth.uid());end loop;
   update public.reservations set amount_eur=0,manual_price_override=true,payment_method='hotel_voucher_old',payment_status='paid' where id=rid;
  end if;
 end if;
 perform public.backoffice_check_in(rid,p_spot_id,s.entry_at);
 update public.rotation_sessions set converted_reservation_id=rid,updated_at=v_now where id=s.id;
 return jsonb_build_object('id',rid,'receipt',doc->'receipt','rotation_receipt',rot->'receipt','difference_amount',difference);
end;$function$
;
alter table public.reservations drop constraint reservations_payment_method_check;
alter table public.reservations add constraint reservations_payment_method_check check(payment_method is null or payment_method in('cash','card','hotel_voucher','hotel_voucher_old','online'));
-- Count vouchers redeemed through legacy entry as well as normal redemption records.
create or replace view public.parking_hotel_balances as
select h.id,h.name,h.active,
coalesce(p.days,0)::integer purchased_days,coalesce(u.days,0)::integer used_days,
(coalesce(p.days,0)-coalesce(u.days,0))::integer available_days
from public.parking_hotels h
left join lateral(select sum(b.days) days from public.parking_hotel_batches b where b.hotel_id=h.id and not b.is_void)p on true
left join lateral(
 select coalesce((select sum(r.days) from public.parking_hotel_redemptions r where r.hotel_id=h.id),0)+
 (select count(*) from public.parking_hotel_vouchers v join public.parking_hotel_batches b on b.id=v.batch_id
 where b.hotel_id=h.id and v.redeemed_reservation_id is not null
 and not exists(select 1 from public.parking_hotel_redemptions r where r.reservation_id=v.redeemed_reservation_id and r.hotel_id=h.id)) days
)u on true;
