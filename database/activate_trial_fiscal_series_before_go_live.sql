
create table private.parking_test_fiscal_counters(series text not null,year integer not null,last_number bigint not null default 0,primary key(series,year));
alter table private.parking_test_fiscal_counters enable row level security;
revoke all on private.parking_test_fiscal_counters from public,anon,authenticated;
alter table public.parking_invoices add column if not exists legacy_number text;
alter table public.parking_simplified_invoices add column if not exists legacy_number text;
alter table public.parking_simplified_invoices add column if not exists is_production boolean;
CREATE OR REPLACE FUNCTION private.parking_fiscal_serial(p_series text, p_at timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n bigint;y integer:=extract(year from p_at at time zone 'Europe/Madrid');begin
 if p_series not in('ONH','OTH','OFH','OND','OTD','OFD','OFM') then raise exception 'Serie fiscal no válida';end if;
 if p_at<timestamptz '2026-10-31 22:00 Europe/Madrid' then
 insert into private.parking_test_fiscal_counters(series,year,last_number) values(p_series,y,1) on conflict(series,year) do update set last_number=parking_test_fiscal_counters.last_number+1 returning last_number into n;
 else
 insert into private.parking_fiscal_counters(series,year,last_number) values(p_series,y,1) on conflict(series,year) do update set last_number=parking_fiscal_counters.last_number+1 returning last_number into n;
 end if;
 return to_char(y%100,'FM00')||lpad(n::text,greatest(4,length(n::text)),'0');end;$function$
;
CREATE OR REPLACE FUNCTION private.parking_number_full_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.parking_cash_movements;begin
 m:=private.parking_entity_movement(new.entity_type,new.entity_id,new.billing_month);
 new.is_production:=coalesce(m.paid_at,new.issued_at,clock_timestamp())>=timestamptz '2026-10-31 22:00 Europe/Madrid';
 if new.is_production then
  new.issued_at:=greatest(coalesce(new.issued_at,clock_timestamp()),coalesce(m.paid_at,'-infinity'));
  new.series:=case when new.entity_type='subscriber' then 'OFM' when new.entity_type in('reservation','stay_change','hotel_batch') then 'OFD' else 'OFH' end;
  new.serial_number:=private.parking_fiscal_serial(new.series,new.issued_at);new.display_number:=new.series||' '||new.serial_number;new.invoice_date:=(new.issued_at at time zone 'Europe/Madrid')::date;
 else
  new.issued_at:=coalesce(m.paid_at,new.issued_at,clock_timestamp());
  new.series:=case when new.entity_type='subscriber' then 'OFM' when new.entity_type in('reservation','stay_change','hotel_batch') then 'OFD' else 'OFH' end;
  new.serial_number:=private.parking_fiscal_serial(new.series,new.issued_at);
  new.display_number:=new.series||' '||new.serial_number||' · PRUEBA';
  new.invoice_date:=(new.issued_at at time zone 'Europe/Madrid')::date;
 end if;return new;end;$function$
;
CREATE OR REPLACE FUNCTION private.parking_create_production_receipt(p_movement uuid, p_print boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.parking_cash_movements;r public.parking_simplified_invoices;f public.parking_invoices;ser text;num text;dt timestamptz;
begin
 select * into m from public.parking_cash_movements where id=p_movement for update;if not found then raise exception 'Cobro no encontrado';end if;
 select * into r from public.parking_simplified_invoices where movement_id=m.id;if found then return private.parking_receipt_json(r.id);end if;
 select * into f from public.parking_invoices where entity_type=m.entity_type and entity_id=m.entity_id and is_production=(m.paid_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') order by issued_at desc limit 1;
 if found then ser:=f.series;num:=f.serial_number;dt:=f.issued_at;
 else
  ser:=(case when m.payment_method='cash' and not p_print then 'ON' else 'OT' end)||(case when m.category='stay' then 'D' else 'H' end);
  dt:=m.paid_at;num:=private.parking_fiscal_serial(ser,dt);
 end if;
 insert into public.parking_simplified_invoices(number,movement_id,issued_at,issued_by,amount_before_vat,vat_rate,vat_eur,total_eur,full_invoice_id,snapshot,series,serial_number,invoice_date,is_production)
 values(ser||' '||num||case when m.paid_at<timestamptz '2026-10-31 22:00 Europe/Madrid' then ' · PRUEBA' else '' end,m.id,dt,auth.uid(),round(m.amount_eur/1.21,2),21,m.amount_eur-round(m.amount_eur/1.21,2),m.amount_eur,f.id,to_jsonb(m),ser,num,(dt at time zone 'Europe/Madrid')::date,m.paid_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') returning * into r;
 return private.parking_receipt_json(r.id);
end;$function$
;
CREATE OR REPLACE FUNCTION public.parking_issue_simplified(p_entity_type text, p_entity_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare m public.parking_cash_movements; r public.parking_simplified_invoices; v_year integer;v_num bigint;v_full uuid;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select * into m from public.parking_cash_movements where entity_type=p_entity_type and entity_id=p_entity_id order by paid_at desc limit 1 for update;
 if not found then raise exception 'Primero registra el cobro. Los bonos hotel canjeados no generan un segundo cobro';end if;
 select * into r from public.parking_simplified_invoices where movement_id=m.id;if found then if r.series is not null then return private.parking_receipt_json(r.id);end if;return to_jsonb(r);end if;
 if m.amount_eur>3000 then raise exception 'Para este importe debes emitir una factura completa';end if;
 return private.parking_create_production_receipt(m.id,true);
end $function$;
;
CREATE OR REPLACE FUNCTION private.parking_automatic_fiscal_document()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare mp public.monthly_subscription_payments;s public.monthly_subscribers;
begin
 if new.amount_eur<0 or (new.amount_eur=0 and new.entity_type<>'subscriber_payment') then return new;end if;
 if new.entity_type='hotel_batch' and exists(select 1 from public.parking_hotel_batches where id=new.entity_id and bank_transfer_invoice) and exists(select 1 from public.parking_invoices where entity_type='hotel_batch' and entity_id=new.entity_id) then return new;end if;
 if new.entity_type='subscriber_payment' then
  select * into mp from public.monthly_subscription_payments where id=new.entity_id;select * into s from public.monthly_subscribers where id=mp.subscriber_id;
  if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then
   insert into public.parking_monthly_receipts(payment_id,subscriber_id,billing_month,customer_name,customer_tax_id,customer_address,amount_eur,issued_at) values(mp.id,s.id,mp.billing_month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),new.amount_eur,new.paid_at) on conflict(payment_id) do nothing;
  else
   perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('full-invoice:subscriber:'||s.id::text||':'||mp.billing_month::text,0));
   if not exists(select 1 from public.parking_invoices where entity_type='subscriber' and entity_id=s.id and billing_month=mp.billing_month and is_production=(new.paid_at>=timestamptz '2026-10-31 22:00 Europe/Madrid')) then
    insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur,issued_at,issued_by) values('subscriber',s.id,mp.billing_month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),s.vehicle,s.plate,coalesce((mp.pricing_snapshot->>'price')::numeric,new.amount_eur/1.21),coalesce((mp.pricing_snapshot->>'discount')::numeric,0),coalesce((mp.pricing_snapshot->>'vat_eur')::numeric,new.amount_eur-round(new.amount_eur/1.21,2)),new.amount_eur,new.paid_at,mp.paid_by) on conflict do nothing;
   end if;
  end if;
 elsif not exists(select 1 from public.parking_invoices where entity_type=new.entity_type and entity_id=new.entity_id and is_production) and not exists(select 1 from public.parking_simplified_invoices where movement_id=new.id) then
  perform private.parking_create_production_receipt(new.id,new.payment_method<>'cash');
 end if;return new;end;$function$
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
 if p_entity_type in('reservation','stay_change','hotel_batch') and not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager')) and not exists(select 1 from public.parking_cash_movements m where m.entity_type=p_entity_type and m.entity_id=p_entity_id and m.user_id=auth.uid() and m.shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid) then raise exception 'Solo puedes facturar cobros de tu turno';end if;
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
do $$
declare f public.parking_invoices;r public.parking_simplified_invoices;m public.parking_cash_movements;ser text;num text;
begin
 for f in select * from public.parking_invoices where not is_production and serial_number is null order by issued_at,id for update loop
 ser:=case when f.entity_type='subscriber' then 'OFM' when f.entity_type in('reservation','stay_change','hotel_batch') then 'OFD' else 'OFH' end;
 num:=private.parking_fiscal_serial(ser,f.issued_at);
 update public.parking_invoices set legacy_number=coalesce(legacy_number,number::text),series=ser,serial_number=num,display_number=ser||' '||num||' · PRUEBA',invoice_date=(issued_at at time zone 'Europe/Madrid')::date where id=f.id;
 end loop;
 for r in select * from public.parking_simplified_invoices where serial_number is null and issued_at<timestamptz '2026-10-31 22:00 Europe/Madrid' order by issued_at,id for update loop
 select * into m from public.parking_cash_movements where id=r.movement_id;
 if not found then raise exception 'Ticket sin cobro asociado: %',r.id;end if;
 ser:='OT'||case when m.category='stay' then 'D' else 'H' end;
 num:=private.parking_fiscal_serial(ser,r.issued_at);
 update public.parking_simplified_invoices set legacy_number=coalesce(legacy_number,number),series=ser,serial_number=num,number=ser||' '||num||' · PRUEBA',invoice_date=(issued_at at time zone 'Europe/Madrid')::date,is_production=false where id=r.id;
 end loop;
end $$;

revoke all on function private.parking_fiscal_serial(text,timestamptz),private.parking_create_production_receipt(uuid,boolean),private.parking_number_full_invoice(),private.parking_automatic_fiscal_document() from public,anon,authenticated;
