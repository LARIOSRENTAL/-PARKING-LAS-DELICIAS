-- Creation is paid atomically; later changes have their own immutable payment/document.
CREATE OR REPLACE FUNCTION public.parking_create_stay_from_vouchers(p_codes text[], p_vehicle_type_id uuid, p_entry_at timestamp with time zone, p_days integer, p_plate text, p_model text, p_customer_name text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;info jsonb;r jsonb;
begin
 if not exists(select 1 from public.vehicle_types where id=p_vehicle_type_id and code='TURISMO') then raise exception 'Los bonos hotel solo son válidos para turismos';end if; ctx:=public.rotation_operator_context();info:=private.resolve_hotel_voucher_codes(p_codes,true);
 if p_days is null or p_days<>(info->>'days')::integer then raise exception 'Debes aportar un bono por cada día de estancia';end if;
 r:=private.create_hotel_paid_reservation((info->>'hotel_id')::uuid,p_vehicle_type_id,p_entry_at,p_days,p_plate,p_model,p_customer_name,p_phone,p_email,p_notes);
 update public.parking_hotel_vouchers set redeemed_reservation_id=(r->>'id')::uuid,redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where code in(select jsonb_array_elements_text(info->'codes'));
 return r||jsonb_build_object('hotel_name',info->>'hotel_name','voucher_codes',info->'codes');
end $function$;

alter table public.reservations add column creation_request_id uuid unique;
create table public.parking_stay_changes (
 id uuid primary key, reservation_id uuid not null references public.reservations(id),
 created_by uuid not null, created_at timestamptz not null default clock_timestamp(),
 payment_method text not null check(payment_method in ('cash','card','hotel_voucher')),
 amount_eur numeric(12,2) not null check(amount_eur>=0), before_data jsonb not null, after_data jsonb not null
);
create index parking_stay_changes_reservation_idx on public.parking_stay_changes(reservation_id,created_at);
alter table public.parking_stay_changes enable row level security;
create policy stay_changes_staff on public.parking_stay_changes for select to authenticated using(private.is_staff());
grant select on public.parking_stay_changes to authenticated;
revoke all on public.parking_stay_changes from anon;
revoke insert,update,delete on public.parking_stay_changes from authenticated;
create function public.parking_create_paid_stay(p_request_id uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
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
  if length(btrim(coalesce(p_data->>'plate','')))<3 or length(btrim(coalesce(p_data->>'model','')))<2 or days is null or days<1 or days>24 then raise exception 'Completa matrícula, marca/modelo y duración';end if;
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
end $$;
create function public.parking_save_stay_changes(p_request_id uuid,p_reservation_id uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
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
  if length(btrim(coalesce(p_data->>'plate','')))<3 or length(btrim(coalesce(p_data->>'model','')))<2 then raise exception 'Completa matrícula y marca/modelo';end if;
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
  elsif coalesce((p_data->>'print_ticket')::boolean,false) then receipt:=public.parking_issue_simplified('stay_change',c.id);end if;
 end if;
 return jsonb_build_object('reservation',to_jsonb(updated),'change',to_jsonb(c),'receipt',receipt,'invoice',invoice);
end $$;
revoke all on function public.parking_create_paid_stay(uuid,jsonb),public.parking_save_stay_changes(uuid,uuid,jsonb) from public,anon;
grant execute on function public.parking_create_paid_stay(uuid,jsonb),public.parking_save_stay_changes(uuid,uuid,jsonb) to authenticated;
alter table public.parking_invoices drop constraint parking_invoices_entity_type_check;
alter table public.parking_invoices add constraint parking_invoices_entity_type_check check(entity_type in ('subscriber','reservation','rotation','hotel_batch','stay_change'));

CREATE OR REPLACE FUNCTION public.parking_issue_full_invoice(p_entity_type text, p_entity_id uuid, p_billing_month date, p_customer_name text, p_customer_tax_id text, p_customer_address text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v public.parking_invoices;s public.rotation_sessions;v_name text:=nullif(btrim(p_customer_name),'');v_tax text:=nullif(btrim(p_customer_tax_id),'');v_address text:=nullif(btrim(p_customer_address),'');
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in ('admin','manager')) then
  if p_entity_type <> 'rotation' then raise exception 'Solo administradores y gerentes pueden emitir estas facturas';end if;
  if not exists(select 1 from public.rotation_sessions where id=p_entity_id and status='departed' and exit_user_id=auth.uid() and exit_shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid) then raise exception 'Solo puedes facturar cobros de Rotación de tu turno';end if;
 end if;
 if v_name is null or v_tax is null or v_address is null then raise exception 'Completa nombre, NIF/CIF y domicilio';end if;
 perform pg_advisory_xact_lock(hashtextextended('full-invoice:'||p_entity_type||':'||p_entity_id::text||':'||coalesce(p_billing_month::text,''),0));
 select * into v from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month order by issued_at desc limit 1;
 if found then return to_jsonb(v);end if;

 if p_entity_type='hotel_batch' then
  insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  select 'hotel_batch',b.id,v_name,v_tax,v_address,b.days||' bonos hotel de 1 día · '||h.name,null,
   round(b.days*b.unit_price_eur/1.21,2),0,b.days*b.unit_price_eur-round(b.days*b.unit_price_eur/1.21,2),b.days*b.unit_price_eur
  from public.parking_hotel_batches b join public.parking_hotels h on h.id=b.hotel_id
  where b.id=p_entity_id and b.payment_status='paid' and not b.is_void and not b.is_test returning * into v;
  if not found then raise exception 'Primero registra el cobro de los bonos hotel';end if;
 elsif p_entity_type='stay_change' then
  insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  select 'stay_change',c.id,v_name,v_tax,v_address,'Ampliación de estancia '||(c.after_data->>'reference'),c.after_data->>'plate',round(c.amount_eur/1.21,2),0,c.amount_eur-round(c.amount_eur/1.21,2),c.amount_eur from public.parking_stay_changes c where c.id=p_entity_id and c.amount_eur>0 returning * into v;
  if not found then raise exception 'No hay un cobro adicional que facturar';end if;
 elsif p_entity_type='rotation' then

  select * into s from public.rotation_sessions where id=p_entity_id and status='departed';if not found then raise exception 'Primero confirma el cobro de Rotación';end if;
  insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  values('rotation',s.id,v_name,v_tax,v_address,'Estacionamiento por horas',s.plate,round(s.amount_eur/1.21,2),0,s.amount_eur-round(s.amount_eur/1.21,2),s.amount_eur) returning * into v;
 else
  v:=public.issue_parking_invoice(p_entity_type,p_entity_id,p_billing_month,v_tax,v_address);
  update public.parking_invoices set customer_name=v_name where id=v.id returning * into v;
 end if;
 update public.parking_simplified_invoices set full_invoice_id=v.id where movement_id in(select id from public.parking_cash_movements where entity_type=p_entity_type and entity_id=p_entity_id);
 return to_jsonb(v);
end $function$;

create function public.parking_move_active_stay(p_reservation_id uuid,p_spot_id uuid) returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare r public.reservations;s public.parking_sessions;
begin
 perform public.rotation_operator_context();
 select * into r from public.reservations where id=p_reservation_id for update;
 if not found or not exists(select 1 from public.parking_sessions where reservation_id=r.id) or r.finished_at is not null or r.rotation_pending or r.status not in ('confirmed','checked_in') then raise exception 'No hay estancia activa';end if;
 perform 1 from public.parking_spots where id=p_spot_id for update;
 if not private.spot_accepts_vehicle(p_spot_id,r.vehicle_type_id) or not exists(select 1 from jsonb_array_elements(public.parking_available_rotation_spots(null)) x where (x->>'id')::uuid=p_spot_id) then raise exception 'La plaza no está disponible para este vehículo';end if;
 select * into s from public.parking_sessions where reservation_id=r.id and status='inside' limit 1;
 if found then perform public.backoffice_move_spot(s.id,p_spot_id);
 else update public.reservations set assigned_spot_id=p_spot_id,updated_at=clock_timestamp() where id=r.id;end if;
end $$;
revoke all on function public.parking_move_active_stay(uuid,uuid) from public,anon;
grant execute on function public.parking_move_active_stay(uuid,uuid) to authenticated;
-- Admission never charges a stay again: payment belongs to creation or a separate amendment.
create or replace function public.parking_check_in_and_collect(p_reservation_id uuid,p_spot_id uuid,p_actual_entry_at timestamptz) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare r public.reservations;v_session uuid;
begin
 perform public.rotation_operator_context();select * into r from public.reservations where id=p_reservation_id for update;
 if not found then raise exception 'Reserva inexistente';end if;
 perform 1 from public.parking_spots where id=p_spot_id for update;
 v_session:=public.backoffice_check_in(r.id,p_spot_id,p_actual_entry_at);
 return jsonb_build_object('session_id',v_session,'receipt',null);
end $$;
