create table if not exists private.parking_bank_auto_results(subscriber_id uuid not null references public.monthly_subscribers(id),billing_month date not null,status text not null,error text,updated_at timestamptz not null default clock_timestamp(),primary key(subscriber_id,billing_month));
alter table private.parking_bank_auto_results enable row level security;
revoke all on private.parking_bank_auto_results from public,anon,authenticated;
create or replace function private.parking_auto_bank_month(p_at timestamptz default clock_timestamp()) returns jsonb language plpgsql security definer set search_path='' as $$
declare today date:=(p_at at time zone 'Europe/Madrid')::date;month date;actor uuid;s public.monthly_subscribers;p public.monthly_subscription_payments;f public.parking_invoices;q jsonb;ok integer:=0;failed integer:=0;
begin
 if today<date '2026-11-01' or extract(day from today)<>1 then return jsonb_build_object('processed',0,'not_due',true);end if;
 month:=date_trunc('month',today)::date;
 perform pg_advisory_xact_lock(hashtextextended('automatic-bank:'||month::text,0));
 select user_id into actor from public.staff_profiles where active and role='admin' order by created_at,user_id limit 1;
 if actor is null then raise exception 'No hay administrador activo para atribuir la facturación automática';end if;
 for s in select * from public.monthly_subscribers where active and (auto_email_bank or preferred_payment_method='bank') and (scheduled_end_date is null or scheduled_end_date>=month) and total_eur>0 order by customer_name,id for update loop
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
 return jsonb_build_object('processed',ok,'errors',failed,'month',month);
end;$$;
revoke all on function private.parking_auto_bank_month(timestamptz) from public,anon,authenticated;
select cron.schedule('parking-automatic-bank-month','*/5 * 1 * *','select private.parking_auto_bank_month()');
create or replace function public.parking_selected_subscriber_documents(p_ids uuid[],p_month date) returns jsonb language plpgsql security definer set search_path='' as $$
declare docs jsonb:='[]';missing jsonb:='[]';s public.monthly_subscribers;f public.parking_invoices;r public.parking_monthly_receipts;v_role text;
begin
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if auth.uid() is null or v_role is null or v_role not in ('admin','manager') then raise exception 'Solo administrador o gerente pueden descargar estas facturas';end if;
 if p_month is null or extract(day from p_month)<>1 or coalesce(cardinality(p_ids),0) not between 1 and 1000 then raise exception 'Selecciona clientes y un mes válido';end if;
 for s in select * from public.monthly_subscribers where id=any(p_ids) order by customer_name,id loop
  if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then
   select * into r from public.parking_monthly_receipts where subscriber_id=s.id and billing_month=p_month order by issued_at desc limit 1;
   if found then docs:=docs||jsonb_build_array(to_jsonb(r)||jsonb_build_object('doc_kind','monthly_receipt','number',r.order_number::text));else missing:=missing||jsonb_build_array(jsonb_build_object('id',s.id,'name',s.customer_name,'plate',s.plate));end if;
  else
   select * into f from public.parking_invoices where entity_type='subscriber' and entity_id=s.id and billing_month=p_month order by is_production desc,issued_at desc limit 1;
   if found then docs:=docs||jsonb_build_array(to_jsonb(f)||jsonb_build_object('doc_kind','invoice','number',coalesce(f.display_number,f.number::text)));else missing:=missing||jsonb_build_array(jsonb_build_object('id',s.id,'name',s.customer_name,'plate',s.plate));end if;
  end if;
 end loop;
 return jsonb_build_object('documents',docs,'missing',missing);
end;$$;
revoke all on function public.parking_selected_subscriber_documents(uuid[],date) from public,anon;
grant execute on function public.parking_selected_subscriber_documents(uuid[],date) to authenticated;
