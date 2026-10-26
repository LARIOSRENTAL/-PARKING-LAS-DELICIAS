alter table public.parking_commerce_bonus_sales add column if not exists package_count integer;
alter table public.parking_commerce_bonus_sales add column if not exists vehicle_category text;
alter table public.parking_commerce_bonus_sales add column if not exists request_id uuid;
alter table public.parking_commerce_bonus_sales add column if not exists customer_details jsonb;
create unique index if not exists parking_commerce_bonus_sales_request_uidx on public.parking_commerce_bonus_sales(request_id) where request_id is not null;
alter table public.parking_commerce_bonus_sales drop constraint if exists parking_commerce_bonus_sales_quantity_check;
alter table public.parking_commerce_bonus_sales add constraint parking_commerce_bonus_sales_quantity_check check(quantity>=1 and quantity<=25000000);
alter table public.parking_invoices drop constraint if exists parking_invoices_entity_type_check;
alter table public.parking_invoices add constraint parking_invoices_entity_type_check check(entity_type in('subscriber','reservation','rotation','hotel_batch','stay_change','commerce_sale'));
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
  if p_entity_type not in ('rotation','commerce_sale') then raise exception 'Solo administradores y gerentes pueden emitir estas facturas';end if;
  if p_entity_type='rotation' and not exists(select 1 from public.rotation_sessions where id=p_entity_id and status='departed' and exit_user_id=auth.uid() and exit_shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid) then raise exception 'Solo puedes facturar cobros de Rotación de tu turno';end if;
  if p_entity_type='commerce_sale' and not exists(select 1 from public.parking_commerce_bonus_sales where id=p_entity_id and user_id=auth.uid() and shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid) then raise exception 'Solo puedes facturar ventas de bonos de tu turno';end if;
 end if;
 if v_name is null or v_tax is null or v_address is null then raise exception 'Completa nombre, NIF/CIF y domicilio';end if;
 perform pg_advisory_xact_lock(hashtextextended('full-invoice:'||p_entity_type||':'||p_entity_id::text||':'||coalesce(p_billing_month::text,''),0));
 select * into v from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month order by issued_at desc limit 1;
 if found then return to_jsonb(v);end if;

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
 return to_jsonb(v);
end $function$

;
create or replace function public.parking_sell_commerce_packages(p_request_id uuid,p_packages integer,p_category text,p_payment_method text,p_print_ticket boolean default false,p_invoice_customer jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb;s public.parking_commerce_bonus_sales;price numeric;quantity integer;invoice jsonb;receipt jsonb;
begin
 ctx:=public.rotation_operator_context();
 if p_request_id is null or p_packages is null or p_packages not between 1 and 1000000 or p_category is null or p_category not in('TURISMO','XL') or p_payment_method is null or p_payment_method not in('cash','card') then raise exception 'Cantidad, categoría o forma de pago no válidas';end if;
 if p_invoice_customer is not null and (nullif(btrim(p_invoice_customer->>'name'),'') is null or nullif(btrim(p_invoice_customer->>'tax_id'),'') is null or nullif(btrim(p_invoice_customer->>'address'),'') is null) then raise exception 'Completa nombre, NIF/CIF y domicilio de la factura';end if;
 quantity:=p_packages*25;price:=p_packages*case when p_category='XL' then 25 else 20 end;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('commerce-sale:'||p_request_id::text,0));
 select * into s from public.parking_commerce_bonus_sales where request_id=p_request_id for update;
 if found then
  if s.user_id<>auth.uid() then raise exception 'No autorizado';end if;
  if s.quantity<>quantity or s.vehicle_category<>p_category or s.payment_method<>p_payment_method or s.customer_details is distinct from p_invoice_customer then raise exception 'Esta venta ya está registrada con otros datos. Comprueba la venta antes de crear otra';end if;
 else
  insert into public.parking_commerce_bonus_sales(quantity,amount_eur,payment_method,user_id,shift_id,employee_name,package_count,vehicle_category,request_id,customer_details)
  values(quantity,price,p_payment_method,auth.uid(),nullif(ctx->>'shift_id','')::uuid,ctx->>'employee_name',p_packages,p_category,p_request_id,p_invoice_customer) returning * into s;
  insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,reference,description,amount_eur,payment_method,user_id,shift_id,employee_name,details)
  values('commerce_sale:'||s.id,'rotation','commerce_sale',s.id,'BC-'||s.id::text,'Venta de '||quantity||' tickets bonos comercio · '||case when p_category='XL' then 'Furgoneta / XL' else 'Turismos' end,price,s.payment_method,s.user_id,s.shift_id,s.employee_name,jsonb_build_object('quantity',quantity,'packages',p_packages,'vehicle_category',p_category));
 end if;
 if p_invoice_customer is not null then invoice:=public.parking_issue_full_invoice('commerce_sale',s.id,null,p_invoice_customer->>'name',p_invoice_customer->>'tax_id',p_invoice_customer->>'address');end if;
 if coalesce(p_print_ticket,false) then
  if price<=3000 then receipt:=public.parking_issue_simplified('commerce_sale',s.id);
  elsif invoice is null then raise exception 'Para este importe, selecciona Generar factura y completa los datos del cliente';
  end if;
 end if;
 return jsonb_build_object('sale',to_jsonb(s),'invoice',invoice,'receipt',receipt);
end;$$;
revoke all on function public.parking_sell_commerce_packages(uuid,integer,text,text,boolean,jsonb) from public,anon;
grant execute on function public.parking_sell_commerce_packages(uuid,integer,text,text,boolean,jsonb) to authenticated;
