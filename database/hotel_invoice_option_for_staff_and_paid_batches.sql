CREATE OR REPLACE FUNCTION public.parking_hotel_invoice_customer(p_hotel_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager','employee')) then raise exception 'No autorizado';end if;
 select jsonb_build_object('name',c.name,'tax_id',c.tax_id,'address',c.address) into result
 from public.parking_hotels h join public.parking_invoice_customers c on c.id=h.invoice_customer_id where h.id=p_hotel_id;
 return result;
end;
$function$
;
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
  if p_entity_type='rotation' and not exists(select 1 from public.rotation_sessions where id=p_entity_id and status='departed' and exit_user_id=auth.uid() and exit_shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid) then raise exception 'Solo puedes facturar cobros de Rotación de tu turno';end if;
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
end $function$
;
