-- Default non-bank accounts to cash; a real collection remembers cash/card for later months.
update public.monthly_subscribers set preferred_payment_method=case when auto_email_bank or preferred_payment_method='bank' then 'bank' else 'cash' end;
alter table public.monthly_subscribers alter column preferred_payment_method set default 'cash';

create function public.parking_monthly_subscribers(p_month date) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_role text;
begin
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if v_role is null then raise exception 'No autorizado';end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'Mes no válido';end if;
 return (select coalesce(jsonb_agg(to_jsonb(s) order by s.customer_name,s.plate),'[]'::jsonb) from public.monthly_subscribers s where v_role in ('admin','manager') or (s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in ('cash','card') and not exists(select 1 from public.monthly_subscription_payments p where p.subscriber_id=s.id and p.billing_month=p_month)));
end $$;
revoke all on function public.parking_monthly_subscribers(date) from public,anon;
grant execute on function public.parking_monthly_subscribers(date) to authenticated;

create function private.parking_subscriber_visible(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.staff_profiles p where p.user_id=auth.uid() and p.active and (p.role in ('admin','manager') or exists(select 1 from public.monthly_subscribers s where s.id=p_id and s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in ('cash','card') and not exists(select 1 from public.monthly_subscription_payments m where m.subscriber_id=s.id and m.billing_month=date_trunc('month',now() at time zone 'Europe/Madrid')::date))))
$$;
revoke all on function private.parking_subscriber_visible(uuid) from public,anon;
grant execute on function private.parking_subscriber_visible(uuid) to authenticated;
drop policy monthly_subscribers_staff_read on public.monthly_subscribers;
create policy monthly_subscribers_staff_read on public.monthly_subscribers for select to authenticated using(private.parking_subscriber_visible(id));

create or replace function public.mark_monthly_subscription_paid(p_subscriber_id uuid,p_billing_month date,p_payment_method text)
returns public.monthly_subscription_payments language plpgsql security definer set search_path='' as $$
declare v_result public.monthly_subscription_payments;v_role text;v_sub public.monthly_subscribers;v_method text;v_today date:=(clock_timestamp() at time zone 'Europe/Madrid')::date;v_context jsonb;
begin
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if v_role is null then raise exception 'No autorizado';end if;
 if p_payment_method is null or p_payment_method not in ('bank','card','cash') then raise exception 'Forma de pago no válida';end if;
 if p_billing_month is null or extract(day from p_billing_month)<>1 then raise exception 'Mes no válido';end if;
 if p_billing_month>date_trunc('month',v_today+interval '1 month')::date or (p_billing_month=date_trunc('month',v_today+interval '1 month')::date and extract(day from v_today)<25) then raise exception 'El mes siguiente solo puede abonarse desde el día 25';end if;
 select * into v_sub from public.monthly_subscribers where id=p_subscriber_id and active for update;
 if not found then raise exception 'Abonado no activo';end if;
 if v_role='employee' and (coalesce(v_sub.auto_email_bank,false) or v_sub.preferred_payment_method='bank' or p_payment_method='bank') then raise exception 'Los empleados solo pueden cobrar abonados pendientes en efectivo o tarjeta';end if;
 v_method:=case when coalesce(v_sub.auto_email_bank,false) or v_sub.preferred_payment_method='bank' then 'bank' else p_payment_method end;
 if v_method='bank' and not(coalesce(v_sub.auto_email_bank,false) or v_sub.preferred_payment_method='bank') then raise exception 'Selecciona Banco en la ficha del abonado antes de cobrar por banco';end if;
 -- Never turn a retry into a change of payment method or a second cash entry.
 select * into v_result from public.monthly_subscription_payments where subscriber_id=p_subscriber_id and billing_month=p_billing_month;
 if found then return v_result;end if;
 v_context:=public.monthly_subscriber_write_context();
 insert into public.monthly_subscription_payments(subscriber_id,billing_month,payment_method,paid_by)values(p_subscriber_id,p_billing_month,v_method,auth.uid()) returning * into v_result;
 update public.monthly_subscribers set preferred_payment_method=v_method where id=p_subscriber_id and preferred_payment_method is distinct from v_method;
 return v_result;
end $$;
revoke all on function public.mark_monthly_subscription_paid(uuid,date,text) from public,anon;
grant execute on function public.mark_monthly_subscription_paid(uuid,date,text) to authenticated;

create function public.parking_export_cashbook(p_shift_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.staff_shifts;
begin
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role='admin') then raise exception 'Solo el administrador puede descargar la hoja de caja';end if;
 select * into s from public.staff_shifts where id=p_shift_id;if not found then raise exception 'Turno no válido';end if;
 return public.parking_cashbook(s.shift_date,s.shift_code,s.id);
end $$;
revoke all on function public.parking_export_cashbook(uuid) from public,anon;
grant execute on function public.parking_export_cashbook(uuid) to authenticated;

create function public.parking_billing_movements(p_from timestamp,p_to timestamp) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_from timestamptz;v_to timestamptz;v_rows jsonb;
begin
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in ('admin','manager')) then raise exception 'No autorizado para Facturación';end if;
 if p_from is null or p_to is null or p_to<p_from then raise exception 'Revisa el intervalo de fechas y horas';end if;
 -- Inputs are Madrid wall times, irrespective of the browser or database timezone.
 v_from:=date_trunc('minute',p_from) at time zone 'Europe/Madrid';v_to:=(date_trunc('minute',p_to)+interval '1 minute') at time zone 'Europe/Madrid';
 with movements as (
 select m.id,'income'::text as kind,m.category,m.paid_at as event_at,m.reference,m.plate,m.description,m.amount_eur,m.payment_method,m.employee_name,m.shift_id,m.entity_type,m.entity_id,
 coalesce((select string_agg(i.number,', ' order by i.issued_at) from public.parking_invoices i where (i.entity_type=m.entity_type and i.entity_id=m.entity_id) or (m.entity_type='subscriber_payment' and i.entity_type='subscriber' and exists(select 1 from public.monthly_subscription_payments mp where mp.id=m.entity_id and mp.subscriber_id=i.entity_id and mp.billing_month=i.billing_month))),'') as invoice_number
 from public.parking_cash_movements m where m.paid_at>=v_from and m.paid_at<v_to
 union all select w.id,'withdrawal','withdrawal',w.created_at,'R-'||w.withdrawal_number,null,'Retirada de efectivo',w.amount_eur,'cash',w.employee_name,w.shift_id,'cash_withdrawal',w.id,'' from public.parking_cash_withdrawals w where w.created_at>=v_from and w.created_at<v_to
 union all select e.id,e.kind,e.kind,e.created_at,case when e.kind='voucher' then 'V-' else 'G-' end||e.entry_number,null,e.description,e.amount_eur,'cash',e.employee_name,e.shift_id,'cash_entry',e.id,'' from public.parking_cash_entries e where e.created_at>=v_from and e.created_at<v_to
 ) select coalesce(jsonb_agg(to_jsonb(m)||jsonb_build_object('shift_code',s.shift_code,'shift_date',s.shift_date)order by m.event_at,m.kind,m.id),'[]'::jsonb) into v_rows from movements m left join public.staff_shifts s on s.id=m.shift_id;
 return jsonb_build_object('from',v_from,'to_exclusive',v_to,'from_local',p_from,'to_local',p_to,'rows',v_rows,'generated_at',clock_timestamp());
end $$;
revoke all on function public.parking_billing_movements(timestamp,timestamp) from public,anon;
grant execute on function public.parking_billing_movements(timestamp,timestamp) to authenticated;

-- Collections are RPC-only; employees cannot bypass the non-bank/pending collection checks.
revoke insert,update,delete on public.monthly_subscription_payments from authenticated;
drop policy monthly_payment_staff_read on public.monthly_subscription_payments;
create policy monthly_payment_staff_read on public.monthly_subscription_payments for select to authenticated using(
 exists(select 1 from public.staff_profiles p where p.user_id=auth.uid() and p.active and (p.role in ('admin','manager') or exists(select 1 from public.monthly_subscribers s where s.id=subscriber_id and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in ('cash','card')))));
