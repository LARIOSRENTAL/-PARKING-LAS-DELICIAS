-- Production documents begin on 2026-11-01 in Málaga. Earlier records remain test history.
create table if not exists private.parking_fiscal_counters(series text not null,year integer not null,last_number bigint not null default 0,primary key(series,year));
alter table private.parking_fiscal_counters enable row level security;
revoke all on private.parking_fiscal_counters from public,anon,authenticated;
create table if not exists private.parking_monthly_receipt_only(subscriber_id uuid primary key references public.monthly_subscribers(id),updated_at timestamptz not null default now(),updated_by uuid);
alter table private.parking_monthly_receipt_only enable row level security;
revoke all on private.parking_monthly_receipt_only from public,anon,authenticated;
create table if not exists public.parking_monthly_receipts(id uuid primary key default gen_random_uuid(),payment_id uuid not null unique references public.monthly_subscription_payments(id),subscriber_id uuid not null references public.monthly_subscribers(id),billing_month date not null,customer_name text not null,customer_tax_id text,customer_address text,amount_eur numeric(12,2) not null,issued_at timestamptz not null default now());
alter table public.parking_monthly_receipts enable row level security;
revoke all on public.parking_monthly_receipts from anon;
grant select on public.parking_monthly_receipts to authenticated;
drop policy if exists staff_monthly_receipts on public.parking_monthly_receipts;
create policy staff_monthly_receipts on public.parking_monthly_receipts for select to authenticated using(exists(select 1 from public.staff_profiles p where p.user_id=auth.uid() and p.active and p.role in('admin','manager')) or exists(select 1 from public.monthly_subscription_payments m where m.id=payment_id and m.paid_by=auth.uid()));
alter table public.parking_invoices add column if not exists series text;
alter table public.parking_invoices add column if not exists serial_number text;
alter table public.parking_invoices add column if not exists display_number text;
alter table public.parking_invoices add column if not exists invoice_date date;
alter table public.parking_invoices add column if not exists is_production boolean not null default false;
alter table public.parking_invoices drop constraint if exists parking_invoices_entity_type_entity_id_billing_month_key;
create unique index if not exists parking_invoices_test_month_unique on public.parking_invoices(entity_type,entity_id,billing_month) where not is_production;
create unique index if not exists parking_invoices_production_entity_unique on public.parking_invoices(entity_type,entity_id,coalesce(billing_month,date '1900-01-01')) where is_production;
create unique index if not exists parking_invoices_series_number_unique on public.parking_invoices(series,serial_number) where is_production;
alter table public.parking_simplified_invoices add column if not exists series text;
alter table public.parking_simplified_invoices add column if not exists serial_number text;
alter table public.parking_simplified_invoices add column if not exists invoice_date date;
alter table public.parking_simplified_invoices add column if not exists customer_name text;
alter table public.parking_simplified_invoices add column if not exists customer_tax_id text;
alter table public.parking_simplified_invoices add column if not exists customer_address text;
create unique index if not exists parking_simplified_series_number_unique on public.parking_simplified_invoices(series,serial_number) where series is not null;
create or replace function private.parking_fiscal_serial(p_series text,p_at timestamptz) returns text language plpgsql security definer set search_path='' as $$
declare n bigint;y integer:=extract(year from p_at at time zone 'Europe/Madrid');begin
 if p_series not in('ONH','OTH','OFH','OND','OTD','OFD','OFM') then raise exception 'Serie fiscal no válida';end if;
 insert into private.parking_fiscal_counters(series,year,last_number) values(p_series,y,1) on conflict(series,year) do update set last_number=parking_fiscal_counters.last_number+1 returning last_number into n;
 return to_char(y%100,'FM00')||lpad(n::text,greatest(4,length(n::text)),'0');end;$$;
revoke all on function private.parking_fiscal_serial(text,timestamptz) from public,anon,authenticated;
create or replace function private.parking_entity_movement(p_type text,p_id uuid,p_month date default null) returns public.parking_cash_movements language sql stable security definer set search_path='' as $$
 select m.* from public.parking_cash_movements m where (m.entity_type=p_type and m.entity_id=p_id) or (p_type='subscriber' and m.entity_type='subscriber_payment' and exists(select 1 from public.monthly_subscription_payments p where p.id=m.entity_id and p.subscriber_id=p_id and p.billing_month=p_month)) order by m.paid_at desc limit 1;
$$;
revoke all on function private.parking_entity_movement(text,uuid,date) from public,anon,authenticated;
create or replace function private.parking_is_production(p_type text,p_id uuid,p_month date default null) returns boolean language plpgsql stable security definer set search_path='' as $$
declare m public.parking_cash_movements;begin m:=private.parking_entity_movement(p_type,p_id,p_month);return coalesce(m.paid_at,clock_timestamp())>=timestamptz '2026-10-31 22:00 Europe/Madrid';end;$$;
revoke all on function private.parking_is_production(text,uuid,date) from public,anon,authenticated;
create or replace function private.parking_number_full_invoice() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.parking_cash_movements;begin
 m:=private.parking_entity_movement(new.entity_type,new.entity_id,new.billing_month);
 new.is_production:=coalesce(m.paid_at,new.issued_at,clock_timestamp())>=timestamptz '2026-10-31 22:00 Europe/Madrid';
 if new.is_production then
  new.issued_at:=greatest(coalesce(new.issued_at,clock_timestamp()),coalesce(m.paid_at,'-infinity'));
  new.series:=case when new.entity_type='subscriber' then 'OFM' when new.entity_type in('reservation','stay_change','hotel_batch') then 'OFD' else 'OFH' end;
  new.serial_number:=private.parking_fiscal_serial(new.series,new.issued_at);new.display_number:=new.series||' '||new.serial_number;new.invoice_date:=(new.issued_at at time zone 'Europe/Madrid')::date;
 end if;return new;end;$$;
revoke all on function private.parking_number_full_invoice() from public,anon,authenticated;
drop trigger if exists number_production_parking_invoice on public.parking_invoices;
create trigger number_production_parking_invoice before insert on public.parking_invoices for each row execute function private.parking_number_full_invoice();
create or replace function private.parking_receipt_json(p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select to_jsonb(r)||jsonb_build_object('display_number',r.number,'entity_type',m.entity_type,'entity_id',m.entity_id,'billing_month',null,'vehicle',m.description,'plate',m.plate,'doc_kind','simplified') from public.parking_simplified_invoices r join public.parking_cash_movements m on m.id=r.movement_id where r.id=p_id;
$$;
revoke all on function private.parking_receipt_json(uuid) from public,anon,authenticated;
create or replace function private.parking_create_production_receipt(p_movement uuid,p_print boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.parking_cash_movements;r public.parking_simplified_invoices;f public.parking_invoices;ser text;num text;dt timestamptz;
begin
 select * into m from public.parking_cash_movements where id=p_movement for update;if not found then raise exception 'Cobro no encontrado';end if;
 select * into r from public.parking_simplified_invoices where movement_id=m.id;if found then return private.parking_receipt_json(r.id);end if;
 select * into f from public.parking_invoices where entity_type=m.entity_type and entity_id=m.entity_id and is_production order by issued_at desc limit 1;
 if found then ser:=f.series;num:=f.serial_number;dt:=f.issued_at;
 else
  ser:=(case when m.payment_method='cash' and not p_print then 'ON' else 'OT' end)||(case when m.category='stay' then 'D' else 'H' end);
  dt:=m.paid_at;num:=private.parking_fiscal_serial(ser,dt);
 end if;
 insert into public.parking_simplified_invoices(number,movement_id,issued_at,issued_by,amount_before_vat,vat_rate,vat_eur,total_eur,full_invoice_id,snapshot,series,serial_number,invoice_date)
 values(ser||' '||num,m.id,dt,auth.uid(),round(m.amount_eur/1.21,2),21,m.amount_eur-round(m.amount_eur/1.21,2),m.amount_eur,f.id,to_jsonb(m),ser,num,(dt at time zone 'Europe/Madrid')::date) returning * into r;
 return private.parking_receipt_json(r.id);
end;$$;
revoke all on function private.parking_create_production_receipt(uuid,boolean) from public,anon,authenticated;
create or replace function public.parking_set_monthly_receipt_only(p_subscriber_id uuid,p_receipt_only boolean) returns void language plpgsql security definer set search_path='' as $$
begin if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Solo el administrador puede cambiar este régimen documental';end if;
 perform 1 from public.monthly_subscribers where id=p_subscriber_id for update;if not found then raise exception 'Abonado no encontrado';end if;
 if p_receipt_only then insert into private.parking_monthly_receipt_only(subscriber_id,updated_by) values(p_subscriber_id,auth.uid()) on conflict(subscriber_id) do update set updated_at=now(),updated_by=auth.uid();else delete from private.parking_monthly_receipt_only where subscriber_id=p_subscriber_id;end if;end;$$;
revoke all on function public.parking_set_monthly_receipt_only(uuid,boolean) from public,anon;
grant execute on function public.parking_set_monthly_receipt_only(uuid,boolean) to authenticated;
create or replace function private.parking_automatic_fiscal_document() returns trigger language plpgsql security definer set search_path='' as $$
declare mp public.monthly_subscription_payments;s public.monthly_subscribers;
begin
 if new.paid_at<timestamptz '2026-10-31 22:00 Europe/Madrid' or new.amount_eur<0 or (new.amount_eur=0 and new.entity_type<>'subscriber_payment') then return new;end if;
 if new.entity_type='subscriber_payment' then
  select * into mp from public.monthly_subscription_payments where id=new.entity_id;select * into s from public.monthly_subscribers where id=mp.subscriber_id;
  if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then
   insert into public.parking_monthly_receipts(payment_id,subscriber_id,billing_month,customer_name,customer_tax_id,customer_address,amount_eur,issued_at) values(mp.id,s.id,mp.billing_month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),new.amount_eur,new.paid_at) on conflict(payment_id) do nothing;
  else
   perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('full-invoice:subscriber:'||s.id::text||':'||mp.billing_month::text,0));
   if not exists(select 1 from public.parking_invoices where entity_type='subscriber' and entity_id=s.id and billing_month=mp.billing_month and is_production) then
    insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur,issued_at,issued_by) values('subscriber',s.id,mp.billing_month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),s.vehicle,s.plate,coalesce((mp.pricing_snapshot->>'price')::numeric,new.amount_eur/1.21),coalesce((mp.pricing_snapshot->>'discount')::numeric,0),coalesce((mp.pricing_snapshot->>'vat_eur')::numeric,new.amount_eur-round(new.amount_eur/1.21,2)),new.amount_eur,new.paid_at,mp.paid_by) on conflict do nothing;
   end if;
  end if;
 elsif not exists(select 1 from public.parking_invoices where entity_type=new.entity_type and entity_id=new.entity_id and is_production) and not exists(select 1 from public.parking_simplified_invoices where movement_id=new.id) then
  perform private.parking_create_production_receipt(new.id,new.payment_method<>'cash');
 end if;return new;end;$$;
revoke all on function private.parking_automatic_fiscal_document() from public,anon,authenticated;
drop trigger if exists automatic_production_fiscal_document on public.parking_cash_movements;
create constraint trigger automatic_production_fiscal_document after insert on public.parking_cash_movements deferrable initially deferred for each row execute function private.parking_automatic_fiscal_document();
create or replace function private.parking_preserve_stay_arrival() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.reservation_id is not null then
  if tg_op='INSERT' then select entry_at into new.actual_entry_at from public.reservations where id=new.reservation_id;
  elsif old.actual_entry_at is null and new.actual_entry_at is not null then select entry_at into new.actual_entry_at from public.reservations where id=new.reservation_id;
  end if;
 end if;return new;end;$$;
revoke all on function private.parking_preserve_stay_arrival() from public,anon,authenticated;
drop trigger if exists preserve_created_stay_arrival on public.parking_sessions;
create trigger preserve_created_stay_arrival before insert or update of actual_entry_at on public.parking_sessions for each row execute function private.parking_preserve_stay_arrival();
create or replace function public.parking_get_monthly_receipt(p_subscriber_id uuid,p_month date) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.parking_monthly_receipts;mp public.monthly_subscription_payments;s public.monthly_subscribers;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if not exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=p_subscriber_id) then raise exception 'Este abonado no está marcado para recibo mensual';end if;
 select * into mp from public.monthly_subscription_payments where subscriber_id=p_subscriber_id and billing_month=p_month;
 if not found then raise exception 'Primero registra el pago del mes';end if;
 if mp.paid_by is distinct from auth.uid() and not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager')) then raise exception 'No autorizado para este recibo';end if;
 select * into s from public.monthly_subscribers where id=p_subscriber_id;
 if exists(select 1 from public.parking_invoices where entity_type='subscriber' and entity_id=p_subscriber_id and billing_month=p_month and is_production) then raise exception 'Este mes ya tiene factura. No se genera un segundo documento';end if;
 insert into public.parking_monthly_receipts(payment_id,subscriber_id,billing_month,customer_name,customer_tax_id,customer_address,amount_eur,issued_at) values(mp.id,s.id,mp.billing_month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),coalesce((mp.pricing_snapshot->>'total_eur')::numeric,s.total_eur),mp.paid_at) on conflict(payment_id) do nothing;
 select * into r from public.parking_monthly_receipts where payment_id=mp.id;return to_jsonb(r);end;$$;
revoke all on function public.parking_get_monthly_receipt(uuid,date) from public,anon;
grant execute on function public.parking_get_monthly_receipt(uuid,date) to authenticated;
CREATE OR REPLACE FUNCTION public.issue_parking_invoice(p_entity_type text, p_entity_id uuid, p_billing_month date DEFAULT NULL::date, p_customer_tax_id text DEFAULT NULL::text, p_customer_address text DEFAULT NULL::text)
 RETURNS parking_invoices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.parking_invoices; s public.monthly_subscribers; r public.reservations; v_price numeric; v_discount numeric; v_vat numeric; v_total numeric;
begin
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active=true and role in ('admin','manager')) and not(p_entity_type='reservation' and exists(select 1 from public.parking_cash_movements m where m.entity_type='reservation' and m.entity_id=p_entity_id and m.user_id=auth.uid() and m.shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid)) then raise exception 'Solo administradores y gerentes pueden emitir facturas';end if;
 if p_entity_type='subscriber' and exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=p_entity_id) then raise exception 'Este abonado recibe un recibo mensual sin factura';end if;
 if exists(select 1 from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month and is_production=private.parking_is_production(p_entity_type,p_entity_id,p_billing_month)) then select * into v from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month and is_production=private.parking_is_production(p_entity_type,p_entity_id,p_billing_month) order by issued_at desc limit 1;return v;end if;
 if p_entity_type='subscriber' then
  select * into s from public.monthly_subscribers where id=p_entity_id;
  if not found then raise exception 'Abonado inexistente';end if;
  if p_billing_month is null then raise exception 'Indica mes de facturación';end if;
  v_price:=(private.subscriber_month_quote(s.id,p_billing_month)->>'price')::numeric;v_discount:=(private.subscriber_month_quote(s.id,p_billing_month)->>'discount')::numeric;
  v_vat:=(private.subscriber_month_quote(s.id,p_billing_month)->>'vat_eur')::numeric;v_total:=(private.subscriber_month_quote(s.id,p_billing_month)->>'total_eur')::numeric;
  insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  values('subscriber',p_entity_id,p_billing_month,s.customer_name,coalesce(nullif(p_customer_tax_id,''),s.tax_id),coalesce(nullif(p_customer_address,''),concat_ws(' ',s.address,s.postal_code,s.city)),s.vehicle,s.plate,v_price,v_discount,v_vat,v_total)
  on conflict do nothing;
 elsif p_entity_type='reservation' then
  select * into r from public.reservations where id=p_entity_id;
  if not found then raise exception 'Estancia inexistente';end if;
  v_total:=r.amount_eur;v_price:=round(v_total/1.21,2);v_discount:=0;v_vat:=v_total-v_price;
  insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  values('reservation',p_entity_id,null,coalesce(r.customer_name,'Cliente sin identificar'),nullif(p_customer_tax_id,''),nullif(p_customer_address,''),r.vehicle_make_model,r.plate,v_price,v_discount,v_vat,v_total)
  on conflict do nothing;
 else raise exception 'Tipo de factura no válido';end if;
 select * into v from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month and is_production=private.parking_is_production(p_entity_type,p_entity_id,p_billing_month) order by issued_at desc limit 1;
 return v;
end;$function$

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
 if v_m.id is not null and v_m.paid_at>=timestamptz '2026-10-31 22:00 Europe/Madrid' then
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
 if m.paid_at>=timestamptz '2026-10-31 22:00 Europe/Madrid' then return private.parking_create_production_receipt(m.id,true);end if;
 if m.amount_eur>3000 then raise exception 'Para este importe debes emitir una factura completa';end if;
 select id into v_full from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id order by issued_at desc limit 1;
 v_year:=extract(year from clock_timestamp() at time zone 'Europe/Madrid');
 insert into private.parking_receipt_counters(year,last_number) values(v_year,1) on conflict(year) do update set last_number=parking_receipt_counters.last_number+1 returning last_number into v_num;
 insert into public.parking_simplified_invoices(number,movement_id,issued_by,amount_before_vat,vat_eur,total_eur,full_invoice_id,snapshot)
 values('PLDFS-'||v_year||'-'||lpad(v_num::text,7,'0'),m.id,auth.uid(),round(m.amount_eur/1.21,2),m.amount_eur-round(m.amount_eur/1.21,2),m.amount_eur,v_full,to_jsonb(m)) returning * into r;
 return to_jsonb(r);
end $function$


;
CREATE OR REPLACE FUNCTION public.parking_collect_stay(p_reservation_id uuid, p_payment_method text, p_print_ticket boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;r public.reservations;receipt jsonb;
begin
 ctx:=public.rotation_operator_context();select * into r from public.reservations where id=p_reservation_id for update;if not found then raise exception 'Reserva inexistente';end if;
 if r.status in ('cancelled','expired') then raise exception 'Reserva cancelada o caducada';end if;
 if r.payment_method='hotel_voucher' then raise exception 'Esta estancia se paga con bonos ya comprados';end if;
 if r.payment_status<>'paid' then
  if p_payment_method not in ('cash','card') then raise exception 'Selecciona efectivo o tarjeta';end if;
  update public.reservations set payment_status='paid',payment_method=p_payment_method,updated_at=clock_timestamp() where id=r.id returning * into r;
 end if;
 if coalesce(current_setting('parking.full_invoice_mode',true),'')<>'on' and (p_print_ticket or p_payment_method='card') then receipt:=public.parking_issue_simplified('reservation',r.id);end if;
 return jsonb_build_object('reservation',to_jsonb(r),'receipt',receipt);
end $function$

;
CREATE OR REPLACE FUNCTION public.parking_checkout_rotation(p_session_id uuid, p_final_amount_eur numeric, p_payment_method text, p_print_ticket boolean DEFAULT false, p_adjustment_note text DEFAULT NULL::text, p_invoice_customer jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;s public.rotation_sessions;t public.rotation_tariffs;calc jsonb;v_now timestamptz:=clock_timestamp();v_total numeric;receipt jsonb;invoice jsonb;meta jsonb;hours numeric:=0;reason text;quoted_at timestamptz;expected numeric;quote jsonb;commerce_discount numeric;manual boolean;note text;
begin
 ctx:=public.rotation_operator_context();
 if p_final_amount_eur>0 and (p_payment_method is null or p_payment_method not in ('cash','card')) then raise exception 'Forma de pago inválida';end if;
 if p_final_amount_eur is null or p_final_amount_eur<0 or p_final_amount_eur>999999 then raise exception 'Importe inválido';end if;
 select * into s from public.rotation_sessions where id=p_session_id for update;
 if not found then raise exception 'Ticket inexistente';end if;
 if s.status='cancelled' then raise exception 'El ticket se ha cancelado o convertido a estancia';end if;
 if s.status='inside' then
  select * into t from public.rotation_tariffs where id=s.tariff_id;
  calc:=public.calculate_rotation_amount(t.code,s.entry_at,v_now);v_total:=round(p_final_amount_eur,2);
  if left(ltrim(coalesce(p_adjustment_note,'')),1)='{' then
   meta:=p_adjustment_note::jsonb;
   if jsonb_typeof(meta)<>'object' or coalesce(meta->>'version','') not in ('1','2') then raise exception 'Datos del ajuste no válidos';end if;
   hours:=coalesce((meta->>'commerce_free_hours')::numeric,0);reason:=nullif(btrim(meta->>'reason'),'');quoted_at:=(meta->>'quoted_exit_at')::timestamptz;
   if hours<0 or hours>10000 or hours<>trunc(hours) then raise exception 'Introduce un número entero de bonos igual o mayor que cero';end if;
   if quoted_at is null or quoted_at<s.entry_at or quoted_at>v_now+interval '1 minute' then raise exception 'Recalcula el precio antes de confirmar la salida';end if;
   quote:=public.calculate_rotation_amount(t.code,s.entry_at,quoted_at);
   if meta->>'version'='2' then expected:=(public.parking_rotation_quote(t.code,s.entry_at,quoted_at,hours::integer)->>'after_commerce_eur')::numeric;
   elsif quoted_at-hours*interval '1 hour'<=s.entry_at then expected:=0;
   else expected:=(public.calculate_rotation_amount(t.code,s.entry_at,quoted_at-hours*interval '1 hour')->>'amount_eur')::numeric;end if;
   commerce_discount:=greatest(0,(quote->>'amount_eur')::numeric-expected);manual:=v_total<>round(expected,2);
   if manual and coalesce(length(reason),0)<3 then raise exception 'Escribe el motivo del cambio manual de precio';end if;
   if not manual then reason:=null;end if;
   note:=concat_ws('; ',case when hours>0 then 'Bonos de comercio: '||hours::text||' hora(s)' end,case when manual then 'Cambio manual: '||reason end);
  else
   -- Compatibility with older open cashier tabs; their known hour count is still audited.
   hours:=coalesce(substring(p_adjustment_note from '^Horas gratis: ([0-9]+(?:[.][0-9]+)?)')::numeric,0);
   note:=p_adjustment_note;
  end if;
  if exists(select 1 from public.parking_authorized_plates ap where ap.plate=regexp_replace(upper(coalesce(s.plate,'')),'[^A-Z0-9]','','g') and ap.active) then v_total:=0; note:=concat_ws('; ',note,'MATRICULA AUTORIZADA - EXENTA DE PAGO');end if;
  update public.rotation_sessions set status='departed',exit_at=v_now,paid_at=v_now,raw_amount_eur=(calc->>'raw_amount_eur')::numeric,tariff_amount_eur=(calc->>'amount_eur')::numeric,discount_bono_eur=greatest(0,(calc->>'amount_eur')::numeric-v_total),amount_eur=v_total,manual_final_amount_eur=v_total,adjustment_note=nullif(btrim(note),''),payment_method=case when v_total=0 then null else p_payment_method end,exit_user_id=(ctx->>'user_id')::uuid,exit_employee_name=ctx->>'employee_name',exit_shift_id=nullif(ctx->>'shift_id','')::uuid,exit_shift_code=nullif(ctx->>'shift_code','')::smallint,exit_shift_date=(ctx->>'shift_date')::date,updated_at=v_now where id=s.id returning * into s;
  update public.parking_cash_movements set details=coalesce(details,'{}'::jsonb)||jsonb_build_object('commerce_free_hours',hours,'commerce_discount_eur',commerce_discount,'manual_price_adjustment',manual,'adjustment_reason',reason,'expected_after_vouchers_eur',expected,'quoted_exit_at',quoted_at)
  where entity_type='rotation' and entity_id=s.id;
  if s.source_reservation_id is not null then update public.reservations set status='completed',rotation_pending=false,assigned_spot_id=null,updated_at=v_now where id=s.source_reservation_id;end if;
 end if;
 if p_invoice_customer is not null then invoice:=public.parking_issue_full_invoice('rotation',s.id,null,p_invoice_customer->>'name',p_invoice_customer->>'tax_id',p_invoice_customer->>'address');end if;
 if p_print_ticket or s.payment_method='card' then receipt:=public.parking_issue_simplified('rotation',s.id);end if;
 return jsonb_build_object('session',to_jsonb(s),'receipt',receipt,'invoice',invoice);
end $function$

;
CREATE OR REPLACE FUNCTION public.parking_pay_enter_stay_documents(p_reservation_id uuid, p_spot_id uuid, p_exit_at timestamp with time zone, p_method text, p_codes text[] DEFAULT '{}'::text[], p_print_ticket boolean DEFAULT false, p_invoice_customer jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;invoice jsonb;
begin
 perform public.rotation_operator_context();
 if p_invoice_customer is not null then
  if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager','employee')) then raise exception 'No autorizado para generar facturas de estancias';end if;
  if p_method not in('cash','card') then raise exception 'Los bonos hotel ya están pagados y no generan otra factura al canjearse';end if;
  if nullif(btrim(p_invoice_customer->>'name'),'') is null or nullif(btrim(p_invoice_customer->>'tax_id'),'') is null or nullif(btrim(p_invoice_customer->>'address'),'') is null then raise exception 'Completa nombre, NIF/CIF y domicilio para la factura';end if;
 end if;
 if p_invoice_customer is not null then perform set_config('parking.full_invoice_mode','on',true);end if;
 result:=public.parking_pay_and_enter_stay_with_exit(p_reservation_id,p_spot_id,p_exit_at,p_method,p_codes,p_print_ticket);
 if p_invoice_customer is not null then
  invoice:=public.parking_issue_full_invoice('reservation',p_reservation_id,null,p_invoice_customer->>'name',p_invoice_customer->>'tax_id',p_invoice_customer->>'address');
 end if;
 perform set_config('parking.full_invoice_mode','',true);
 if p_invoice_customer is not null and (p_print_ticket or p_method='card') then result:=result||jsonb_build_object('receipt',public.parking_issue_simplified('reservation',p_reservation_id));end if;
 return result||jsonb_build_object('invoice',invoice);
end;$function$

;
CREATE OR REPLACE FUNCTION private.parking_guard_cash_close()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ declare v_state jsonb; v_report jsonb; begin if old.closed_at is null and new.closed_at is not null then v_state:=private.parking_cash_state(new.id); if not coalesce((v_state->>'saved')::boolean,false) then raise exception 'Guarda el Resumen de caja antes de cerrar el turno'; end if; if new.shift_date>=date '2026-11-01' and (nullif(v_state->>'difference','') is null or round((v_state->>'difference')::numeric,2)<>0) then raise exception 'No se puede cerrar: la caja está descuadrada en % €. Corrige y guarda el arqueo',v_state->>'difference';end if; v_report:=public.parking_cashbook(new.shift_date,new.shift_code,new.id)||jsonb_build_object('generated_at',new.closed_at,'closed_at',new.closed_at); update public.parking_cash_counts set final_report=v_report where shift_id=new.id; end if; return new; end $function$

;
CREATE OR REPLACE FUNCTION private.subscriber_month_quote(p_id uuid, p_month date, p_at timestamp with time zone DEFAULT clock_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.monthly_subscribers;m public.monthly_subscription_payments;paid boolean;late boolean;price numeric;discount numeric;vat numeric;total numeric;rate numeric;cutoff timestamptz;alert_at timestamptz;review boolean;
begin
 if p_month is null or extract(day from p_month)<>1 then raise exception 'Mes no válido';end if;
 select * into s from public.monthly_subscribers where id=p_id;
 if not found then raise exception 'Abonado inexistente';end if;
 select * into m from public.monthly_subscription_payments where subscriber_id=p_id and billing_month=p_month;paid:=found;
 cutoff:=(p_month+9)::timestamp at time zone 'Europe/Madrid';alert_at:=(p_month+14)::timestamp at time zone 'Europe/Madrid';
 if paid and m.pricing_snapshot is not null then return m.pricing_snapshot||jsonb_build_object('paid',true,'overdue_alert',false);end if;
 -- Old settled months predate this policy. Never recalculate them as late payments.
 late:=not paid and p_at>=cutoff;
 price:=round(coalesce(s.price_eur,0),2);rate:=coalesce(s.vat_pct,21);
 discount:=case when late then 0 else least(price,greatest(0,coalesce(s.discount_amount_eur,round(price*coalesce(s.discount_pct,0)/100,2)))) end;
 if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then price:=s.total_eur;discount:=0;rate:=0;end if;
 vat:=round(greatest(0,price-discount)*rate/100,2);total:=greatest(0,price-discount)+vat;
 review:=not paid and exists(select 1 from public.parking_invoices i where i.entity_type='subscriber' and i.entity_id=p_id and i.billing_month=p_month and i.is_production=(p_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') and i.total_eur<>total);
 return jsonb_build_object('price',price,'discount',discount,'vat_pct',rate,'vat_eur',vat,'total_eur',total,'discount_forfeited',late and coalesce(s.discount_amount_eur,round(price*coalesce(s.discount_pct,0)/100,2))>0,'discount_deadline',cutoff,'alert_from',alert_at,'paid',paid,'overdue_alert',s.active and not paid and p_at>=alert_at,'invoice_requires_review',review);
end$function$


;
CREATE OR REPLACE FUNCTION private.queue_parking_bank_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$declare j uuid;begin
 if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=new.subscriber_id) then return new;end if;
 if new.payment_method<>'bank'or not exists(select 1 from public.monthly_subscribers where id=new.subscriber_id and auto_email_bank)then return new;end if;
 insert into public.parking_invoice_mail_jobs(payment_id,subscriber_id,billing_month,pricing_snapshot)select new.id,new.subscriber_id,new.billing_month,coalesce(new.pricing_snapshot,jsonb_build_object('price',s.price_eur,'discount',coalesce(s.discount_amount_eur,round(s.price_eur*coalesce(s.discount_pct,0)/100,2)),'vat_pct',coalesce(s.vat_pct,21)))from public.monthly_subscribers s where s.id=new.subscriber_id on conflict(payment_id)do nothing returning id into j;
 if j is null then select id into j from public.parking_invoice_mail_jobs where payment_id=new.id;end if;
 begin
  perform private.prepare_parking_invoice_mail(j);
  if exists(select 1 from public.parking_invoice_mail_jobs where id=j and status='queued')then perform private.dispatch_parking_invoice_mail();end if;
 exception when others then update public.parking_invoice_mail_jobs set status='error',last_error='Pago registrado; preparación del correo pendiente: '||sqlerrm,updated_at=clock_timestamp()where id=j and status<>'sent';end;
 return new;
end $function$

;
CREATE OR REPLACE FUNCTION private.prepare_parking_invoice_mail(p_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare j public.parking_invoice_mail_jobs;p public.monthly_subscription_payments;s public.monthly_subscribers;v public.parking_invoices;price numeric;discount numeric;vat numeric;recipient_email text;
begin
 select * into j from public.parking_invoice_mail_jobs where id=p_job_id for update;
 if not found or j.status in ('sent','sending')then return;end if;
 select * into p from public.monthly_subscription_payments where id=j.payment_id;
 select * into s from public.monthly_subscribers where id=j.subscriber_id;
 if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then update public.parking_invoice_mail_jobs set status='error',last_error='Abonado de solo recibo: no genera factura ni correo automático',updated_at=clock_timestamp() where id=j.id;return;end if;
 if p.payment_method<>'bank'or not s.auto_email_bank then update public.parking_invoice_mail_jobs set status='error',last_error='El pago ya no es por banco o el envío automático está desactivado',updated_at=clock_timestamp()where id=j.id;return;end if;
 recipient_email:=lower(nullif(btrim(s.email),''));
 if nullif(btrim(s.customer_name),'')is null or nullif(btrim(s.tax_id),'')is null or nullif(btrim(s.address),'')is null then update public.parking_invoice_mail_jobs set status='missing_fiscal',recipient=recipient_email,last_error='Faltan nombre, NIF/CIF o domicilio de facturación',updated_at=clock_timestamp()where id=j.id;return;end if;
 perform pg_advisory_xact_lock(hashtextextended('monthly-invoice:'||s.id||':'||p.billing_month,0));
 select * into v from public.parking_invoices where entity_type='subscriber'and entity_id=s.id and billing_month=p.billing_month and is_production=(p.paid_at>=timestamptz '2026-10-31 22:00 Europe/Madrid');
 if not found then
  price:=coalesce((j.pricing_snapshot->>'price')::numeric,s.price_eur);discount:=coalesce((j.pricing_snapshot->>'discount')::numeric,s.discount_amount_eur,round(s.price_eur*coalesce(s.discount_pct,0)/100,2));vat:=round((price-discount)*coalesce((j.pricing_snapshot->>'vat_pct')::numeric,s.vat_pct,21)/100,2);
  insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur,issued_by)
  values('subscriber',s.id,p.billing_month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),s.vehicle,s.plate,price,discount,vat,price-discount+vat,p.paid_by)
  on conflict do nothing;
  select * into v from public.parking_invoices where entity_type='subscriber'and entity_id=s.id and billing_month=p.billing_month and is_production=(p.paid_at>=timestamptz '2026-10-31 22:00 Europe/Madrid');
 end if;
 update public.parking_invoice_mail_jobs set invoice_id=v.id,recipient=recipient_email,status=case when recipient_email is null or recipient_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'then 'missing_email'else 'queued'end,last_error=case when recipient_email is null then 'Falta email del cliente'else null end,updated_at=clock_timestamp()where id=j.id;
end $function$

;
CREATE OR REPLACE FUNCTION public.parking_claim_bank_invoice_mail()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$declare j public.parking_invoice_mail_jobs;v jsonb;begin
 select * into j from public.parking_invoice_mail_jobs where (status='queued'or(status='provider_unconfigured'and updated_at<clock_timestamp()-interval '15 minutes')or(status='error'and attempts<5 and updated_at<clock_timestamp()-interval '2 minutes')or(status='sending'and lease_until<clock_timestamp()and created_at>clock_timestamp()-interval '23 hours'))order by created_at for update skip locked limit 1;
 if not found then return null;end if;
 if j.status='sending'then update public.parking_invoice_mail_jobs set status='queued'where id=j.id;end if;
 perform private.prepare_parking_invoice_mail(j.id);
 select * into j from public.parking_invoice_mail_jobs where id=j.id;
 if j.status<>'queued'then return jsonb_build_object('skipped',true);end if;
 update public.parking_invoice_mail_jobs set status='sending',attempts=attempts+1,lease_until=clock_timestamp()+interval '5 minutes',updated_at=clock_timestamp()where id=j.id returning * into j;
 select to_jsonb(i)||jsonb_build_object('number',coalesce(i.display_number,i.number::text)) into v from public.parking_invoices i where i.id=j.invoice_id;
 return jsonb_build_object('id',j.id,'recipient',j.recipient,'invoice',v);
end $function$

;
CREATE OR REPLACE FUNCTION public.parking_monthly_subscribers(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_role text; practice boolean;
begin
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if auth.uid() is null or v_role is null then raise exception 'No autorizado';end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'Mes no válido';end if;
 practice:=coalesce(private.subscriber_training_window(p_month),false);
 return(select coalesce(jsonb_agg(to_jsonb(s)||jsonb_build_object(
  'receipt_only',exists(select 1 from private.parking_monthly_receipt_only ro where ro.subscriber_id=s.id),'monthly_charge',case when practice and t.subscriber_id is not null and s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in('cash','card') then t.pricing_snapshot||jsonb_build_object('paid',t.paid_at is not null,'overdue_alert',false,'discount_forfeited',false,'invoice_requires_review',false,'training',true) else private.subscriber_month_quote(s.id,p_month) end,
  'training',case when practice and t.subscriber_id is not null and s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in('cash','card') then jsonb_build_object('active',true,'ends_at',timestamptz '2026-10-25 00:00 Europe/Madrid','payment',case when t.paid_at is not null then jsonb_build_object('id',t.payment_id,'subscriber_id',s.id,'billing_month',p_month,'payment_method',t.payment_method,'paid_at',t.paid_at,'training',true) else null end) else null end
 ) order by s.customer_name,s.plate),'[]'::jsonb)
 from public.monthly_subscribers s left join private.parking_subscriber_training t on t.subscriber_id=s.id
 where v_role in('admin','manager') or (s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in('cash','card') and case when practice and t.subscriber_id is not null then t.paid_at is null else not exists(select 1 from public.monthly_subscription_payments p where p.subscriber_id=s.id and p.billing_month=p_month) end));
end$function$


;

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
  elsif coalesce((p_data->>'print_ticket')::boolean,false) or c.payment_method='card' then receipt:=public.parking_issue_simplified('stay_change',c.id);end if;
 end if;
 if c.amount_eur>0 and c.payment_method='card' and receipt is null then receipt:=public.parking_issue_simplified('stay_change',c.id);end if;
 return jsonb_build_object('reservation',to_jsonb(updated),'change',to_jsonb(c),'receipt',receipt,'invoice',invoice);
end $function$;
-- Preserve existing report APIs and add independent series/number/date fields.
create or replace function private.parking_report_fiscal_fields(p_type text,p_id uuid,p_at timestamptz) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare m public.parking_cash_movements;f public.parking_invoices;r public.parking_simplified_invoices;mp public.monthly_subscription_payments;mr public.parking_monthly_receipts;
begin
 select * into m from public.parking_cash_movements where entity_type=p_type and entity_id=p_id limit 1;if not found then return '{}'::jsonb;end if;
 if p_type='subscriber_payment' then select * into mp from public.monthly_subscription_payments where id=p_id;
  select * into mr from public.parking_monthly_receipts where payment_id=p_id;
  if found then return jsonb_build_object('document_series',null,'document_number',null,'document_date',(mr.issued_at at time zone 'Europe/Madrid')::date,'document_kind','monthly_receipt','receipt_month',mr.billing_month,'invoice_number','','receipt_number','','customer_name',mr.customer_name,'customer_tax_id',mr.customer_tax_id,'customer_address',mr.customer_address,'base_eur',mr.amount_eur,'vat_eur',0);end if;
 end if;
 select * into f from public.parking_invoices i where ((i.entity_type=p_type and i.entity_id=p_id) or (p_type='subscriber_payment' and i.entity_type='subscriber' and i.entity_id=mp.subscriber_id and i.billing_month=mp.billing_month)) and i.is_production=(p_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') order by i.issued_at desc limit 1;
 if found then return jsonb_build_object('document_series',f.series,'document_number',coalesce(f.serial_number,f.number::text),'document_date',coalesce(f.invoice_date,(f.issued_at at time zone 'Europe/Madrid')::date),'document_kind','full','invoice_number',coalesce(f.display_number,f.number::text),'customer_name',f.customer_name,'customer_tax_id',f.customer_tax_id,'customer_address',f.customer_address,'base_eur',f.amount_before_vat-coalesce(f.discount_eur,0),'vat_eur',f.vat_eur);end if;
 select * into r from public.parking_simplified_invoices where movement_id=m.id;
 if found then return jsonb_build_object('document_series',r.series,'document_number',coalesce(r.serial_number,r.number),'document_date',coalesce(r.invoice_date,(r.issued_at at time zone 'Europe/Madrid')::date),'document_kind','simplified','receipt_number',r.number,'customer_name',coalesce(r.customer_name,'CLIENTES VARIOS'),'customer_tax_id',coalesce(r.customer_tax_id,''),'customer_address',coalesce(r.customer_address,''),'base_eur',r.amount_before_vat,'vat_eur',r.vat_eur);end if;
 return '{}'::jsonb;
end;$$;
revoke all on function private.parking_report_fiscal_fields(text,uuid,timestamptz) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.parking_billing_movements(p_from timestamp without time zone, p_to timestamp without time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_from timestamptz;v_to timestamptz;v_rows jsonb;
begin
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'No autorizado para Facturación';end if;
 if p_from is null or p_to is null or p_to<p_from then raise exception 'Revisa el intervalo de fechas y horas';end if;
 -- Inputs are Madrid wall times, irrespective of the browser or database timezone.
 v_from:=date_trunc('minute',p_from) at time zone 'Europe/Madrid';v_to:=(date_trunc('minute',p_to)+interval '1 minute') at time zone 'Europe/Madrid';
 with movements as (
 select m.id,'income'::text as kind,m.category,m.paid_at as event_at,m.reference,m.plate,m.description,m.amount_eur,m.payment_method,m.employee_name,m.shift_id,m.entity_type,m.entity_id,
 coalesce((select string_agg(i.number::text,', ' order by i.issued_at) from public.parking_invoices i where (i.entity_type=m.entity_type and i.entity_id=m.entity_id) or (m.entity_type='subscriber_payment' and i.entity_type='subscriber' and exists(select 1 from public.monthly_subscription_payments mp where mp.id=m.entity_id and mp.subscriber_id=i.entity_id and mp.billing_month=i.billing_month))),'') as invoice_number
 from public.parking_cash_movements m where m.paid_at>=v_from and m.paid_at<v_to
 union all select w.id,'withdrawal','withdrawal',w.created_at,'R-'||w.withdrawal_number,null,'Retirada de efectivo',w.amount_eur,'cash',w.employee_name,w.shift_id,'cash_withdrawal',w.id,'' from public.parking_cash_withdrawals w where w.created_at>=v_from and w.created_at<v_to
 union all select e.id,e.kind,e.kind,e.created_at,case when e.kind='voucher' then 'V-' else 'G-' end||e.entry_number,null,e.description,e.amount_eur,'cash',e.employee_name,e.shift_id,'cash_entry',e.id,'' from public.parking_cash_entries e where e.created_at>=v_from and e.created_at<v_to
 union all select r.voucher_id,'voucher_return','voucher_return',r.returned_at,'V-'||e.entry_number,null,'Cancelación de vale · devolución a caja',r.amount_eur,'cash',r.employee_name,r.shift_id,'cash_voucher_return',r.voucher_id,'' from public.parking_cash_voucher_returns r join public.parking_cash_entries e on e.id=r.voucher_id where r.returned_at>=v_from and r.returned_at<v_to
 ) select coalesce(jsonb_agg(to_jsonb(m)||jsonb_build_object('shift_code',s.shift_code,'shift_date',s.shift_date,
 'customer_name',coalesce(nullif(inv.customer_name,''),nullif(res.customer_name,''),nullif(sub.customer_name,''),nullif(rot.client_text,''),hotel.name,''),
 'customer_tax_id',coalesce(inv.customer_tax_id,to_jsonb(sub)->>'tax_id',''),
 'customer_address',coalesce(inv.customer_address,to_jsonb(sub)->>'address',''),
 'customer_phone',coalesce(res.customer_phone,to_jsonb(sub)->>'phone',''),
 'customer_email',coalesce(res.customer_email,to_jsonb(sub)->>'email',''),
 'ticket_number',coalesce(rot.ticket_number::text,''),'receipt_number',coalesce(receipt.number,''),
 'details',cm.details,'receipt_details',receipt.snapshot)||private.parking_report_fiscal_fields(m.entity_type,m.entity_id,m.event_at) order by m.event_at,m.kind,m.id),'[]'::jsonb) into v_rows from movements m left join public.staff_shifts s on s.id=m.shift_id
 left join public.parking_cash_movements cm on m.kind='income' and cm.id=m.id
 left join public.rotation_sessions rot on m.entity_type='rotation' and rot.id=m.entity_id
 left join public.reservations res on m.entity_type='reservation' and res.id=m.entity_id
 left join public.monthly_subscription_payments mp on m.entity_type='subscriber_payment' and mp.id=m.entity_id
 left join public.monthly_subscribers sub on sub.id=mp.subscriber_id
 left join public.parking_hotel_batches batch on m.entity_type='hotel_batch' and batch.id=m.entity_id
 left join public.parking_hotels hotel on hotel.id=batch.hotel_id
 left join public.parking_simplified_invoices receipt on m.kind='income' and receipt.movement_id=m.id
 left join lateral(select i.customer_name,i.customer_tax_id,i.customer_address from public.parking_invoices i where (i.entity_type=m.entity_type and i.entity_id=m.entity_id) or (m.entity_type='subscriber_payment' and i.entity_type='subscriber' and i.entity_id=mp.subscriber_id and i.billing_month=mp.billing_month) order by i.issued_at desc,i.number desc limit 1) inv on true;
 return jsonb_build_object('from',v_from,'to_exclusive',v_to,'from_local',p_from,'to_local',p_to,'rows',v_rows,'generated_at',clock_timestamp());
end $function$;
-- The operational day starts at 22:00 Europe/Madrid on the preceding date.
create or replace function private.parking_shift_slot(p_at timestamptz) returns jsonb language sql immutable set search_path='' as $$
 select jsonb_build_object('shift_code',case when extract(hour from t)>=22 or extract(hour from t)<6 then 1 when extract(hour from t)<14 then 2 else 3 end,'shift_date',t::date+case when extract(hour from t)>=22 then 1 else 0 end) from (select p_at at time zone 'Europe/Madrid' t) q;
$$;
revoke all on function private.parking_shift_slot(timestamptz) from public,anon,authenticated;
create table if not exists private.parking_initial_cash_openings(shift_id uuid primary key references public.staff_shifts(id),amount_eur numeric(12,2) not null check(amount_eur>=0),created_at timestamptz not null default clock_timestamp(),created_by uuid not null);
alter table private.parking_initial_cash_openings enable row level security;
revoke all on private.parking_initial_cash_openings from public,anon,authenticated;
create or replace function private.parking_initialise_cash_opening(p_shift_id uuid,p_amount numeric) returns void language plpgsql security definer set search_path='' as $$
declare s public.staff_shifts;
begin
 select * into s from public.staff_shifts where id=p_shift_id and user_id=auth.uid() and closed_at is null for update;
 if not found or not private.is_staff() then raise exception 'Necesitas tu turno abierto';end if;
 if s.shift_date<>date '2026-11-01' or s.shift_code<>1 then raise exception 'El saldo inicial manual corresponde al turno 1 del 1/11/2026';end if;
 if p_amount is null or p_amount<0 or p_amount>=10000000000 or p_amount<>round(p_amount,2) then raise exception 'Introduce un saldo inicial válido en euros, con un máximo de dos decimales';end if;
 if exists(select 1 from private.parking_initial_cash_openings where shift_id=s.id) then raise exception 'El saldo inicial de este turno ya está registrado';end if;
 insert into private.parking_initial_cash_openings(shift_id,amount_eur,created_by)values(s.id,p_amount,auth.uid());
 insert into public.parking_cash_counts(shift_id,opening_balance,loose_coins,wrapped_coins,banknotes,vouchers,denomination_breakdown,updated_by)
 values(s.id,p_amount,0,0,p_amount,0,jsonb_build_object('banknotes',jsonb_build_object('unallocated',p_amount)),auth.uid());
 insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details) values(s.id,auth.uid(),'cash_opening_confirmed','cash_count',s.id,jsonb_build_object('opening_balance',p_amount,'reason','Inicio de uso de la aplicación'));
end;$$;
revoke all on function private.parking_initialise_cash_opening(uuid,numeric) from public,anon,authenticated;
create or replace function private.parking_guard_initial_opening_balance() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from private.parking_initial_cash_openings o where o.shift_id=new.shift_id and o.amount_eur is distinct from new.opening_balance) then raise exception 'El saldo de entrada ya se confirmó al abrir el turno y no se puede modificar';end if;return new;
end;$$;
revoke all on function private.parking_guard_initial_opening_balance() from public,anon,authenticated;
drop trigger if exists guard_initial_cash_opening on public.parking_cash_counts;
create trigger guard_initial_cash_opening before insert or update of opening_balance on public.parking_cash_counts for each row execute function private.parking_guard_initial_opening_balance();
create or replace function public.parking_shift_opening_requirement() returns jsonb language plpgsql security definer set search_path='' as $$
declare slot jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if exists(select 1 from public.staff_shifts where user_id=auth.uid() and closed_at is null) then return jsonb_build_object('required',false);end if;
 slot:=private.parking_shift_slot(clock_timestamp());return slot||jsonb_build_object('required',(slot->>'shift_date')='2026-11-01' and (slot->>'shift_code')::integer=1);
end;$$;
revoke all on function public.parking_shift_opening_requirement() from public,anon;
grant execute on function public.parking_shift_opening_requirement() to authenticated;
CREATE OR REPLACE FUNCTION private.parking_open_staff_shift(p_opening_balance numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'auth', 'pg_temp'
AS $function$
declare
  v_user uuid := auth.uid();
  v_shift public.staff_shifts%rowtype;
  v_local timestamp := clock_timestamp() at time zone 'Europe/Madrid';
  v_hour integer;
  v_code smallint;
  v_date date;
  v_name text;
  v_role text;
begin
  if v_user is null or not private.is_staff() then
    raise exception 'Acceso no autorizado';
  end if;

  select full_name, role into v_name, v_role
  from public.staff_profiles
  where user_id=v_user and active=true;

  if v_name is null then
    raise exception 'Usuario no autorizado';
  end if;

  if v_role='admin' then
    raise exception 'El administrador utiliza acceso libre y no participa en turnos';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('parking-open-shift:'||v_user::text,0));
  select * into v_shift
  from public.staff_shifts
  where user_id=v_user and closed_at is null
  order by opened_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'ok',true,'already_open',true,'id',v_shift.id,
      'shift_number',v_shift.shift_code,
      'shift_code',v_shift.shift_code,
      'shift_date',v_shift.shift_date,
      'opened_at',v_shift.opened_at,
      'employee_name',v_name
    );
  end if;

  v_hour := extract(hour from v_local);
  if v_hour >= 22 then
    v_code := 1;
    v_date := v_local::date + 1;
  elsif v_hour < 6 then
    v_code := 1;
    v_date := v_local::date;
  elsif v_hour < 14 then
    v_code := 2;
    v_date := v_local::date;
  else
    v_code := 3;
    v_date := v_local::date;
  end if;

  if v_date=date '2026-11-01' and v_code=1 and (p_opening_balance is null or p_opening_balance<0 or p_opening_balance>=10000000000 or p_opening_balance<>round(p_opening_balance,2)) then
    raise exception 'Introduce el saldo de caja a la entrada para iniciar el turno 1 del 1/11';
  end if;

  insert into public.staff_shifts(user_id,shift_code,shift_date)
  values(v_user,v_code,v_date)
  returning * into v_shift;

  if v_date=date '2026-11-01' and v_code=1 then
    perform private.parking_initialise_cash_opening(v_shift.id,p_opening_balance);
  end if;

  insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)
  values(v_shift.id,v_user,'shift_opened','shift',v_shift.id,
    jsonb_build_object(
      'shift_number',v_code,
      'shift_code',v_code,
      'shift_date',v_date,
      'employee_name',v_name
    ));

  return jsonb_build_object(
    'ok',true,'already_open',false,'id',v_shift.id,
    'shift_number',v_code,
    'shift_code',v_code,
    'shift_date',v_date,
    'opened_at',v_shift.opened_at,
    'employee_name',v_name
  );
end
$function$

;
revoke all on function private.parking_open_staff_shift(numeric) from public,anon,authenticated;
create or replace function public.open_staff_shift() returns jsonb language sql security definer set search_path='' as $$select private.parking_open_staff_shift(null)$$;
create or replace function public.parking_start_staff_shift(p_opening_balance numeric default null) returns jsonb language sql security definer set search_path='' as $$select private.parking_open_staff_shift(p_opening_balance)$$;
revoke all on function public.open_staff_shift() from public,anon;
revoke all on function public.parking_start_staff_shift(numeric) from public,anon;
grant execute on function public.open_staff_shift() to authenticated;
grant execute on function public.parking_start_staff_shift(numeric) to authenticated;
CREATE OR REPLACE FUNCTION private.parking_cash_state(p_shift_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb;v_active jsonb;v_total numeric;v_legacy numeric;v_until timestamptz;v_returns jsonb;v_detail jsonb;v_production boolean;
begin
 v:=private.parking_cash_state_before_vouchers(p_shift_id);
 select denomination_breakdown into v_detail from public.parking_cash_counts where shift_id=p_shift_id;
 if v_detail is null and nullif(v->>'inherited_from_shift','') is not null then
  select denomination_breakdown into v_detail from public.parking_cash_counts where shift_id=(v->>'inherited_from_shift')::uuid;
 end if;
 select coalesce(closed_at,clock_timestamp()) into v_until from public.staff_shifts where id=p_shift_id;
 select shift_date>=date '2026-11-01' into v_production from public.staff_shifts where id=p_shift_id;
 v_legacy:=case when v_production then 0 else private.parking_legacy_voucher_balance(v_until) end;
 select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at,e.id),'[]'::jsonb),coalesce(sum(e.amount_eur),0)+v_legacy into v_active,v_total
 from public.parking_cash_entries e where e.kind='voucher' and (not v_production or e.created_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') and e.created_at<=v_until and not exists(select 1 from public.parking_cash_voucher_returns r where r.voucher_id=e.id and r.returned_at<=v_until);
 select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('entry_number',e.entry_number) order by r.returned_at),'[]'::jsonb) into v_returns from public.parking_cash_voucher_returns r join public.parking_cash_entries e on e.id=r.voucher_id where r.shift_id=p_shift_id;
 select v_returns||coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('legacy',true)),'[]'::jsonb) into v_returns from private.parking_legacy_voucher_returns r where r.shift_id=p_shift_id;
 return v||jsonb_build_object('denomination_breakdown',coalesce(v_detail,'{}'::jsonb),'vouchers',v_total,'legacy_vouchers',v_legacy,'active_vouchers',v_active,'voucher_returns',v_returns,'counted_total',(v->>'cash_total')::numeric+v_total,'difference',(v->>'cash_total')::numeric+v_total-(v->>'expected_balance')::numeric);
end $function$

;
CREATE OR REPLACE FUNCTION public.parking_active_cash_vouchers()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at,e.id),'[]'::jsonb)from public.parking_cash_entries e where e.kind='voucher' and (clock_timestamp()<timestamptz '2026-10-31 22:00 Europe/Madrid' or e.created_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') and not exists(select 1 from public.parking_cash_voucher_returns r where r.voucher_id=e.id)),'legacy_vouchers',case when clock_timestamp()>=timestamptz '2026-10-31 22:00 Europe/Madrid' then 0 else private.parking_legacy_voucher_balance() end);
end$function$;
