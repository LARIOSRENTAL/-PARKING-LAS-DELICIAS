
alter table public.parking_hotels add column if not exists invoice_on_credit boolean not null default false;
alter table public.parking_hotel_batches add column if not exists bank_transfer_invoice boolean not null default false;
create or replace function private.parking_assign_bank_to_first_shift(p_date date)
returns integer language plpgsql security definer set search_path='' as $$
declare target uuid;n integer;
begin
 select id into target from public.staff_shifts where shift_date=p_date and shift_code=1 order by opened_at,id limit 1;
 if target is null then return 0;end if;
 update public.parking_cash_movements m set shift_id=target,employee_name='AUTOMÁTICO · BANCO'
 from public.monthly_subscription_payments p where m.source_key='subscriber:'||p.id::text and p.billing_month=p_date and m.payment_method='bank'
 and coalesce((m.details->>'automatic_bank_payment')::boolean,false) and m.shift_id is distinct from target;
 get diagnostics n=row_count;return n;
end $$;
create or replace function private.parking_bind_bank_on_first_shift()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.shift_code=1 and extract(day from new.shift_date)=1 then perform private.parking_assign_bank_to_first_shift(new.shift_date);end if;return new;
end $$;
create trigger bind_bank_on_first_shift after insert on public.staff_shifts for each row execute function private.parking_bind_bank_on_first_shift();
create or replace function private.parking_prepare_bank_hotel_invoice(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.parking_hotel_batches;c public.parking_invoice_customers;f public.parking_invoices;h public.parking_hotels;
begin
 select * into b from public.parking_hotel_batches where id=p_batch_id for update;
 if not found or not b.bank_transfer_invoice or b.is_void or b.is_test then raise exception 'Compra no válida para facturar por transferencia';end if;
 perform pg_advisory_xact_lock(hashtextextended('full-invoice:hotel_batch:'||b.id::text||':',0));
 select * into f from public.parking_invoices where entity_type='hotel_batch' and entity_id=b.id order by issued_at desc limit 1;
 if found then return to_jsonb(f)||jsonb_build_object('number',coalesce(f.display_number,f.number::text));end if;
 select * into h from public.parking_hotels where id=b.hotel_id;
 select * into c from public.parking_invoice_customers where id=h.invoice_customer_id;
 if c.id is null or nullif(btrim(c.name),'') is null or nullif(btrim(c.tax_id),'') is null or nullif(btrim(c.address),'') is null then raise exception 'Faltan los datos fiscales del hotel';end if;
 insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,amount_before_vat,discount_eur,vat_eur,total_eur,issued_at,issued_by)
 values('hotel_batch',b.id,c.name,c.tax_id,c.address,b.days||' bonos hotel de 1 día · '||h.name,round(b.days*b.unit_price_eur/1.21,2),0,b.days*b.unit_price_eur-round(b.days*b.unit_price_eur/1.21,2),b.days*b.unit_price_eur,b.created_at,b.created_by) returning * into f;
 return to_jsonb(f)||jsonb_build_object('number',coalesce(f.display_number,f.number::text));
end $$;
create or replace function private.parking_hotel_transfer_policy()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not new.is_test and exists(select 1 from public.parking_hotels where id=new.hotel_id and invoice_on_credit) then
 new.bank_transfer_invoice:=true;new.payment_method:='bank';new.payment_status:='pending';new.paid_at:=null;new.paid_by:=null;new.paid_shift_id:=null;
 end if;return new;
end $$;
create or replace function private.parking_invoice_new_transfer_batch()
returns trigger language plpgsql security definer set search_path='' as $$
begin if new.bank_transfer_invoice and not new.is_test and not new.is_void then perform private.parking_prepare_bank_hotel_invoice(new.id);end if;return new;end $$;
create trigger hotel_transfer_policy before insert on public.parking_hotel_batches for each row execute function private.parking_hotel_transfer_policy();
create trigger zz_invoice_new_transfer_batch after insert on public.parking_hotel_batches for each row execute function private.parking_invoice_new_transfer_batch();
create or replace function public.parking_hotel_batch_invoice(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select to_jsonb(i)||jsonb_build_object('number',coalesce(i.display_number,i.number::text),'bank_transfer_invoice',b.bank_transfer_invoice,'payment_method',b.payment_method,'payment_status',b.payment_status) into r from public.parking_invoices i
 join public.parking_hotel_batches b on i.entity_type='hotel_batch' and i.entity_id=b.id where b.id=p_batch_id and not b.is_void order by i.issued_at desc limit 1;
 if r is null then raise exception 'Esta compra aún no tiene factura emitida';end if;return r;
end $$;
CREATE OR REPLACE FUNCTION public.parking_buy_hotel_batch(p_hotel_name text, p_days integer, p_payment_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;r jsonb;paid jsonb;
begin
 ctx:=public.rotation_operator_context();
 if p_payment_method is null or p_payment_method not in('pending','cash','card','bank') then raise exception 'Forma de pago inválida';end if;
 r:=public.create_parking_hotel_batch_by_name(p_hotel_name,p_days);
 if exists(select 1 from public.parking_hotel_batches where id=(r->>'id')::uuid and bank_transfer_invoice) then
 return r||jsonb_build_object('payment_status','pending','payment_method','bank','bank_transfer_invoice',true);
 end if;
 if p_payment_method<>'pending' then paid:=public.parking_collect_hotel_batch((r->>'id')::uuid,p_payment_method,false,null);end if;
 return r||jsonb_build_object('payment_status',case when p_payment_method='pending' then 'pending' else 'paid' end,'payment_method',p_payment_method);
end $function$
;
CREATE OR REPLACE FUNCTION public.parking_collect_hotel_batch(p_batch_id uuid, p_payment_method text, p_print_ticket boolean DEFAULT false, p_invoice_customer jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;b public.parking_hotel_batches;receipt jsonb;invoice jsonb;already_paid boolean;
begin
 ctx:=public.rotation_operator_context();
 if p_payment_method is null or p_payment_method not in('cash','card','bank') then raise exception 'Selecciona efectivo, tarjeta o banco';end if;
 select * into b from public.parking_hotel_batches where id=p_batch_id for update;
 if not found or b.is_void or b.is_test then raise exception 'Compra no válida para cobrar';end if;
 if b.bank_transfer_invoice then p_payment_method:='bank';end if;
 already_paid:=b.payment_status='paid';
 if not already_paid then
  update public.parking_hotel_batches set payment_status='paid',payment_method=p_payment_method,
   paid_at=clock_timestamp(),paid_by=(ctx->>'user_id')::uuid,paid_shift_id=nullif(ctx->>'shift_id','')::uuid
  where id=b.id returning * into b;
 end if;
 if b.bank_transfer_invoice then
 invoice:=private.parking_prepare_bank_hotel_invoice(b.id);
 elsif p_invoice_customer is not null then
  invoice:=public.parking_issue_full_invoice('hotel_batch',b.id,null,p_invoice_customer->>'name',p_invoice_customer->>'tax_id',p_invoice_customer->>'address');
 else
  select to_jsonb(i) into invoice from public.parking_invoices i where entity_type='hotel_batch' and entity_id=b.id order by issued_at desc limit 1;
 end if;
 if p_print_ticket and invoice is null then receipt:=public.parking_issue_simplified('hotel_batch',b.id);end if;
 return jsonb_build_object('batch',to_jsonb(b),'receipt',receipt,'invoice',invoice,'already_paid',already_paid);
end $function$
;
CREATE OR REPLACE FUNCTION public.parking_hotel_available_batches()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return(select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object('invoice_id',(select id from public.parking_invoices where entity_type='hotel_batch' and entity_id=b.id order by issued_at desc limit 1),'invoice_number',(select coalesce(display_number,number::text) from public.parking_invoices where entity_type='hotel_batch' and entity_id=b.id order by issued_at desc limit 1),'available_days',v.available,'used_days',v.used,'available_codes',v.codes) order by (b.payment_status='pending') desc,b.created_at desc,b.id),'[]'::jsonb)
 from public.parking_hotel_batches b cross join lateral(
 select count(*)filter(where redeemed_reservation_id is null)::integer as available,count(*)filter(where redeemed_reservation_id is not null)::integer as used,
 coalesce(jsonb_agg(code order by number)filter(where redeemed_reservation_id is null),'[]'::jsonb) as codes
 from public.parking_hotel_vouchers where batch_id=b.id) v
 where not b.is_void and (v.available>0 or b.payment_status='pending' or b.bank_transfer_invoice));
end $function$
;
CREATE OR REPLACE FUNCTION private.parking_auto_bank_month(p_at timestamp with time zone DEFAULT clock_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare today date:=(p_at at time zone 'Europe/Madrid')::date;month date;actor uuid;s public.monthly_subscribers;p public.monthly_subscription_payments;f public.parking_invoices;q jsonb;ok integer:=0;failed integer:=0;
begin
 if today<date '2026-11-01' or extract(day from today)<>1 then return jsonb_build_object('processed',0,'not_due',true);end if;
 month:=date_trunc('month',today)::date;
 perform pg_advisory_xact_lock(hashtextextended('automatic-bank:'||month::text,0));
 select user_id into actor from public.staff_profiles where active and role='admin' order by created_at,user_id limit 1;
 if actor is null then raise exception 'No hay administrador activo para atribuir la facturación automática';end if;
 for s in select * from public.monthly_subscribers where active and (auto_email_bank or preferred_payment_method='bank') and (scheduled_end_date is null or scheduled_end_date>=month) and (membership_start_date is null or membership_start_date<=month) and total_eur>0 order by customer_name,id for update loop
  begin
   insert into public.monthly_subscription_payments(subscriber_id,billing_month,payment_method,paid_by,paid_at) values(s.id,month,'bank',actor,p_at) on conflict(subscriber_id,billing_month) do nothing;
   select * into p from public.monthly_subscription_payments where subscriber_id=s.id and billing_month=month for update;
   if p.payment_method='bank' and p.paid_at=p_at then update public.parking_cash_movements set shift_id=null,employee_name='AUTOMÁTICO · BANCO',details=coalesce(details,'{}'::jsonb)||jsonb_build_object('automatic_bank_payment',true) where source_key='subscriber:'||p.id::text;end if;
   q:=p.pricing_snapshot;
   if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then
    insert into public.parking_monthly_receipts(payment_id,subscriber_id,billing_month,customer_name,customer_tax_id,customer_address,amount_eur,issued_at) values(p.id,s.id,month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),coalesce((q->>'total_eur')::numeric,s.total_eur),p.paid_at) on conflict(payment_id) do nothing;
   else
    perform pg_advisory_xact_lock(hashtextextended('full-invoice:subscriber:'||s.id::text||':'||month::text,0));
    select * into f from public.parking_invoices where entity_type='subscriber' and entity_id=s.id and billing_month=month and is_production=(p.paid_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') order by issued_at desc limit 1;
    if not found then
     insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur,issued_at,issued_by) values('subscriber',s.id,month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),s.vehicle,s.plate,coalesce((q->>'price')::numeric,s.price_eur),coalesce((q->>'discount')::numeric,s.discount_amount_eur,0),coalesce((q->>'vat_eur')::numeric,s.vat_amount_eur,0),coalesce((q->>'total_eur')::numeric,s.total_eur),p.paid_at,actor);
    end if;
   end if;
   insert into private.parking_bank_auto_results values(s.id,month,'done',null,clock_timestamp()) on conflict(subscriber_id,billing_month) do update set status='done',error=null,updated_at=excluded.updated_at;ok:=ok+1;
  exception when others then
   insert into private.parking_bank_auto_results values(s.id,month,'error',sqlerrm,clock_timestamp()) on conflict(subscriber_id,billing_month) do update set status='error',error=excluded.error,updated_at=excluded.updated_at;failed:=failed+1;
  end;
 end loop;
 perform private.parking_assign_bank_to_first_shift(month);
 return jsonb_build_object('processed',ok,'errors',failed,'month',month);
end;$function$
;
CREATE OR REPLACE FUNCTION public.parking_cashbook(p_date date, p_shift_code integer, p_shift_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_role text;v_start timestamptz;v_end timestamptz;v_rows jsonb;v_withdrawals jsonb;v_withdrawal_total numeric;s public.staff_shifts;v_id uuid:=p_shift_id;v_name text;v_saved jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if p_shift_code not in (1,2,3) or p_date is null then raise exception 'Turno no válido';end if;
 if v_id is null and v_role in ('admin','manager') then
  select case when count(*)=1 then (array_agg(id))[1] end into v_id from public.staff_shifts where shift_date=p_date and shift_code=p_shift_code;
 end if;
 if v_id is not null then
  select * into s from public.staff_shifts where id=v_id;
  if not found or (v_role not in ('admin','manager') and s.user_id<>auth.uid()) then raise exception 'No autorizado para este turno';end if;
  p_date:=s.shift_date;p_shift_code:=s.shift_code;
  select full_name into v_name from public.staff_profiles where user_id=s.user_id;
  select final_report into v_saved from public.parking_cash_counts where shift_id=s.id;
  if s.closed_at is not null and v_saved is not null then
 select coalesce(jsonb_agg(to_jsonb(m) order by m.paid_at,m.id),'[]'::jsonb) into v_rows from public.parking_cash_movements m where m.shift_id=s.id;
 return v_saved||jsonb_build_object('rows',v_rows);end if;
 elsif v_role not in ('admin','manager') then raise exception 'Selecciona tu turno';end if;
 v_start:=(case p_shift_code when 1 then p_date::timestamp-interval '2 hours' when 2 then p_date::timestamp+interval '6 hours' else p_date::timestamp+interval '14 hours' end) at time zone 'Europe/Madrid';
 v_end:=(case p_shift_code when 1 then p_date::timestamp+interval '6 hours' when 2 then p_date::timestamp+interval '14 hours' else p_date::timestamp+interval '22 hours' end) at time zone 'Europe/Madrid';
 select coalesce(jsonb_agg(to_jsonb(m) order by m.paid_at,m.id),'[]'::jsonb) into v_rows from public.parking_cash_movements m where (v_id is not null and m.shift_id=v_id) or (v_id is null and m.paid_at>=v_start and m.paid_at<v_end);
 select coalesce(jsonb_agg(to_jsonb(w) order by w.created_at,w.id),'[]'::jsonb),coalesce(sum(w.amount_eur),0) into v_withdrawals,v_withdrawal_total from public.parking_cash_withdrawals w where (v_id is not null and w.shift_id=v_id) or (v_id is null and w.created_at>=v_start and w.created_at<v_end);
 return jsonb_build_object('date',p_date,'shift_code',p_shift_code,'shift_id',v_id,'employee_name',coalesce(v_name,''),'opened_at',s.opened_at,'closed_at',s.closed_at,'generated_at',clock_timestamp(),'from',v_start,'to',v_end,'rows',v_rows,'withdrawals',v_withdrawals,'withdrawal_total_eur',v_withdrawal_total,'cash_state',case when v_id is not null then private.parking_cash_state(v_id) else null end);
end $function$
;
revoke all on function private.parking_assign_bank_to_first_shift(date),private.parking_bind_bank_on_first_shift(),private.parking_prepare_bank_hotel_invoice(uuid),private.parking_hotel_transfer_policy(),private.parking_invoice_new_transfer_batch() from public,anon,authenticated;
revoke all on function public.parking_hotel_batch_invoice(uuid) from public,anon;
grant execute on function public.parking_hotel_batch_invoice(uuid) to authenticated;

CREATE OR REPLACE FUNCTION private.parking_automatic_fiscal_document()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare mp public.monthly_subscription_payments;s public.monthly_subscribers;
begin
 if new.paid_at<timestamptz '2026-10-31 22:00 Europe/Madrid' or new.amount_eur<0 or (new.amount_eur=0 and new.entity_type<>'subscriber_payment') then return new;end if;
 if new.entity_type='hotel_batch' and exists(select 1 from public.parking_hotel_batches where id=new.entity_id and bank_transfer_invoice) and exists(select 1 from public.parking_invoices where entity_type='hotel_batch' and entity_id=new.entity_id) then return new;end if;
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
 end if;return new;end;$function$
;

update public.parking_hotels set invoice_on_credit=true where name in('HOTEL TRIBUNA','PINAR APARTMENTS','SIMBA');
