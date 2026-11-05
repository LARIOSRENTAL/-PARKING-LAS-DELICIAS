-- Employee document access follows the payment month in Europe/Madrid.
create or replace function private.assert_rotation_document_access(p_session_id uuid)
returns void language plpgsql security invoker set search_path='' as $$
declare first timestamptz:=date_trunc('month',clock_timestamp() at time zone 'Europe/Madrid') at time zone 'Europe/Madrid';last timestamptz;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager')) then return;end if;
 last:=(date_trunc('month',clock_timestamp() at time zone 'Europe/Madrid')+interval '1 month') at time zone 'Europe/Madrid';
 if not exists(select 1 from public.rotation_sessions where id=p_session_id and status='departed' and exit_at>=first and exit_at<last) then
  raise exception 'Solo puedes emitir documentos de cobros de Rotación del mes vigente';
 end if;
end $$;
revoke all on function private.assert_rotation_document_access(uuid) from public,anon,authenticated;

create or replace function public.parking_rotation_ticket_search(p_from date,p_to date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare first date:=date_trunc('month',clock_timestamp() at time zone 'Europe/Madrid')::date;last date;result jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if p_from is null or p_to is null or p_from>p_to then raise exception 'Fechas no válidas';end if;
 last:=(first+interval '1 month'-interval '1 day')::date;
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager')) and (p_from<first or p_to>last) then raise exception 'La búsqueda de empleados está limitada al mes vigente';end if;
 select coalesce(jsonb_agg(to_jsonb(rows) order by rows.entry_at desc,rows.id),'[]'::jsonb) into result from (
 select s.id,s.ticket_number,s.plate,s.client_text,s.leaves_keys,s.key_number,s.entry_at,s.exit_at,s.status,s.amount_eur,s.payment_method,
 s.entry_shift_id,s.exit_shift_id,s.entry_user_id,s.exit_user_id,jsonb_build_object('name',t.name,'code',t.code) rotation_tariffs
 from public.rotation_sessions s left join public.rotation_tariffs t on t.id=s.tariff_id
 where (s.entry_at>=p_from::timestamp at time zone 'Europe/Madrid' and s.entry_at<(p_to+1)::timestamp at time zone 'Europe/Madrid')
 or (s.exit_at>=p_from::timestamp at time zone 'Europe/Madrid' and s.exit_at<(p_to+1)::timestamp at time zone 'Europe/Madrid')
 order by s.entry_at desc,s.id limit 5000) rows;
 return result;
end $$;

create or replace function public.parking_rotation_invoice_document(p_session_id uuid,p_customer jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare doc jsonb;m public.parking_cash_movements;
begin
 perform private.assert_rotation_document_access(p_session_id);
 select * into m from public.parking_cash_movements where entity_type='rotation' and entity_id=p_session_id order by paid_at desc limit 1 for update;
 if not found then raise exception 'El cobro no consta registrado';end if;
 select to_jsonb(i)||jsonb_build_object('number',coalesce(i.display_number,i.number::text)) into doc from public.parking_invoices i where entity_type='rotation' and entity_id=p_session_id and is_production=private.parking_is_production('rotation',p_session_id,null) order by issued_at desc limit 1;
 if doc is not null then return doc;end if;
 select private.parking_receipt_json(s.id) into doc from public.parking_simplified_invoices s where s.movement_id=m.id and s.series='OTH'
 and nullif(btrim(s.customer_name),'') is not null and nullif(btrim(s.customer_tax_id),'') is not null and nullif(btrim(s.customer_address),'') is not null limit 1;
 if doc is not null then return doc;end if;
 if p_customer is null then return jsonb_build_object('needs_customer',true);end if;
 return public.parking_issue_full_invoice('rotation',p_session_id,null,p_customer->>'name',p_customer->>'tax_id',p_customer->>'address');
end $$;
revoke all on function public.parking_rotation_ticket_search(date,date),public.parking_rotation_invoice_document(uuid,jsonb) from public,anon;
grant execute on function public.parking_rotation_ticket_search(date,date),public.parking_rotation_invoice_document(uuid,jsonb) to authenticated;
CREATE OR REPLACE FUNCTION public.parking_issue_full_invoice(p_entity_type text, p_entity_id uuid, p_billing_month date, p_customer_name text, p_customer_tax_id text, p_customer_address text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v public.parking_invoices;s public.rotation_sessions;v_name text:=nullif(btrim(p_customer_name),'');v_tax text:=nullif(btrim(p_customer_tax_id),'');v_address text:=nullif(btrim(p_customer_address),'');v_m public.parking_cash_movements;v_receipt public.parking_simplified_invoices;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in ('admin','manager')) then
  if p_entity_type not in ('rotation','commerce_sale','reservation','stay_change','hotel_batch') then raise exception 'Solo administradores y gerentes pueden emitir estas facturas';end if;
  if p_entity_type='rotation' then perform private.assert_rotation_document_access(p_entity_id);end if;
  if p_entity_type='commerce_sale' and not exists(select 1 from public.parking_commerce_bonus_sales where id=p_entity_id and user_id=auth.uid() and shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid) then raise exception 'Solo puedes facturar ventas de bonos de tu turno';end if;
 end if;
 if p_entity_type in('reservation','stay_change') and not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager')) and not exists(select 1 from public.parking_cash_movements m where m.entity_type=p_entity_type and m.entity_id=p_entity_id and m.user_id=auth.uid() and m.shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid) then raise exception 'Solo puedes facturar cobros de tu turno';end if;
 if v_name is null or v_tax is null or v_address is null then raise exception 'Completa nombre, NIF/CIF y domicilio';end if;
 v_m:=private.parking_entity_movement(p_entity_type,p_entity_id,p_billing_month);
 if v_m.id is not null then
  perform 1 from public.parking_cash_movements where id=v_m.id for update;
  select * into v_receipt from public.parking_simplified_invoices where movement_id=v_m.id and series in('OTH','OTD') for update;
  if found then
   update public.parking_simplified_invoices set customer_name=v_name,customer_tax_id=v_tax,customer_address=v_address where id=v_receipt.id;
   return private.parking_receipt_json(v_receipt.id);
  end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('full-invoice:'||p_entity_type||':'||p_entity_id::text||':'||coalesce(p_billing_month::text,''),0));
 select * into v from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month and is_production=private.parking_is_production(p_entity_type,p_entity_id,p_billing_month) order by issued_at desc limit 1;
 if found then return to_jsonb(v)||jsonb_build_object('number',coalesce(v.display_number,v.number::text));end if;

 if p_entity_type='commerce_sale' then
  insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  select 'commerce_sale',b.id,v_name,v_tax,v_address,'Venta de '||b.quantity||' tickets de bonos comercio · '||case when b.vehicle_category='XL' then 'Furgoneta / XL' else 'Turismos' end,null,round(b.amount_eur/1.21,2),0,b.amount_eur-round(b.amount_eur/1.21,2),b.amount_eur from public.parking_commerce_bonus_sales b where b.id=p_entity_id returning * into v;
  if not found then raise exception 'Venta de bonos inexistente';end if;
 elsif p_entity_type='hotel_batch' then
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
 return to_jsonb(v)||jsonb_build_object('number',coalesce(v.display_number,v.number::text));
end $function$;

CREATE OR REPLACE FUNCTION public.parking_issue_simplified(p_entity_type text, p_entity_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare m public.parking_cash_movements; r public.parking_simplified_invoices; v_year integer;v_num bigint;v_full uuid;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if p_entity_type='rotation' then perform private.assert_rotation_document_access(p_entity_id);end if;
 select * into m from public.parking_cash_movements where entity_type=p_entity_type and entity_id=p_entity_id order by paid_at desc limit 1 for update;
 if not found then raise exception 'Primero registra el cobro. Los bonos hotel canjeados no generan un segundo cobro';end if;
 select * into r from public.parking_simplified_invoices where movement_id=m.id;if found then if r.series is not null then return private.parking_receipt_json(r.id);end if;return to_jsonb(r);end if;
 if m.amount_eur>3000 then raise exception 'Para este importe debes emitir una factura completa';end if;
 return private.parking_create_production_receipt(m.id,true);
end $function$;

