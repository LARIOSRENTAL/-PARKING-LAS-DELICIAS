-- Retrieve the document for a paid month; this RPC never creates another payment.
create or replace function public.parking_monthly_payment_document(p_payment_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.monthly_subscription_payments;s public.monthly_subscribers;f public.parking_invoices;prod boolean;v_role text;
begin
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if auth.uid() is null or v_role is null then raise exception 'No autorizado';end if;
 select * into p from public.monthly_subscription_payments where id=p_payment_id for update;
 if not found then raise exception 'Pago mensual no encontrado';end if;
 if p.paid_by is distinct from auth.uid() and v_role not in('admin','manager') then raise exception 'No autorizado para este documento';end if;
 select * into s from public.monthly_subscribers where id=p.subscriber_id;
 if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then return public.parking_get_monthly_receipt(s.id,p.billing_month)||jsonb_build_object('doc_kind','monthly_receipt');end if;
 prod:=p.paid_at>=timestamptz '2026-10-31 22:00 Europe/Madrid';
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('full-invoice:subscriber:'||s.id::text||':'||p.billing_month::text,0));
 select * into f from public.parking_invoices where entity_type='subscriber' and entity_id=s.id and billing_month=p.billing_month and is_production=prod order by issued_at desc limit 1;
 if not found then
  insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur,issued_at,issued_by)
  values('subscriber',s.id,p.billing_month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),s.vehicle,s.plate,coalesce((p.pricing_snapshot->>'price')::numeric,s.price_eur),coalesce((p.pricing_snapshot->>'discount')::numeric,s.discount_amount_eur,0),coalesce((p.pricing_snapshot->>'vat_eur')::numeric,s.vat_amount_eur,0),coalesce((p.pricing_snapshot->>'total_eur')::numeric,s.total_eur),p.paid_at,auth.uid()) returning * into f;
 end if;
 return to_jsonb(f)||jsonb_build_object('number',coalesce(f.display_number,f.number::text),'doc_kind','invoice');
end;$$;
revoke all on function public.parking_monthly_payment_document(uuid) from public,anon;
grant execute on function public.parking_monthly_payment_document(uuid) to authenticated;
