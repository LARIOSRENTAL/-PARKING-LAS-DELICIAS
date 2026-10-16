-- Invoice numbers are bigint in production. Cast explicitly and expose searchable document/customer data.
create or replace function public.parking_billing_movements(p_from timestamp,p_to timestamp) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_from timestamptz;v_to timestamptz;v_rows jsonb;
begin
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in ('admin','manager')) then raise exception 'No autorizado para Facturación';end if;
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
 'details',cm.details,'receipt_details',receipt.snapshot)order by m.event_at,m.kind,m.id),'[]'::jsonb) into v_rows from movements m left join public.staff_shifts s on s.id=m.shift_id
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
end $$;
revoke all on function public.parking_billing_movements(timestamp,timestamp) from public,anon;
grant execute on function public.parking_billing_movements(timestamp,timestamp) to authenticated;
