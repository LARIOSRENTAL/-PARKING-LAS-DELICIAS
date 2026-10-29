alter table public.parking_invoices add column if not exists payment_context jsonb;
alter table public.parking_monthly_receipts add column if not exists payment_context jsonb;
create or replace function private.parking_subscriber_payment_context(p_payment_id uuid)
returns jsonb language sql volatile set search_path='' as $$
 select jsonb_build_object('payment_id',p.id,'paid_at',p.paid_at,'payment_method',p.payment_method,
 'employee_name',case when coalesce((m.details->>'automatic_bank_payment')::boolean,false) then 'AUTOMÁTICO · BANCO' else coalesce(nullif(m.employee_name,''),sp.full_name) end,
 'automatic_bank_payment',coalesce((m.details->>'automatic_bank_payment')::boolean,false),
 'shift_id',m.shift_id,'shift_code',s.shift_code,'shift_number',s.shift_number,'shift_date',s.shift_date,'shift_opened_at',s.opened_at)
 from public.monthly_subscription_payments p
 left join public.parking_cash_movements m on m.source_key='subscriber:'||p.id::text
 left join public.staff_shifts s on s.id=m.shift_id
 left join public.staff_profiles sp on sp.user_id=p.paid_by where p.id=p_payment_id;
$$;
create or replace function private.parking_snapshot_subscriber_document_payment()
returns trigger language plpgsql security definer set search_path='' as $$
declare pid uuid;
begin
 if tg_table_name='parking_monthly_receipts' then pid:=new.payment_id;
 elsif new.entity_type='subscriber' then select id into pid from public.monthly_subscription_payments where subscriber_id=new.entity_id and billing_month=new.billing_month;
 else return new;end if;
 new.payment_context:=private.parking_subscriber_payment_context(pid);return new;
end;
$$;
create trigger snapshot_subscriber_invoice_payment before insert on public.parking_invoices for each row execute function private.parking_snapshot_subscriber_document_payment();
create trigger snapshot_subscriber_receipt_payment before insert on public.parking_monthly_receipts for each row execute function private.parking_snapshot_subscriber_document_payment();
create or replace function private.parking_refresh_subscriber_document_payment()
returns trigger language plpgsql security definer set search_path='' as $$
declare p public.monthly_subscription_payments;ctx jsonb;
begin
 if new.entity_type<>'subscriber_payment' then return new;end if;
 select * into p from public.monthly_subscription_payments where id=new.entity_id;
 if not found then return new;end if;
 ctx:=private.parking_subscriber_payment_context(p.id);
 update public.parking_invoices set payment_context=ctx where entity_type='subscriber' and entity_id=p.subscriber_id and billing_month=p.billing_month and payment_context is distinct from ctx;
 update public.parking_monthly_receipts set payment_context=ctx where payment_id=p.id and payment_context is distinct from ctx;
 return new;
end;
$$;
create trigger refresh_subscriber_document_payment after insert or update of employee_name,shift_id,details on public.parking_cash_movements for each row execute function private.parking_refresh_subscriber_document_payment();
update public.parking_invoices i set payment_context=private.parking_subscriber_payment_context(p.id) from public.monthly_subscription_payments p where i.entity_type='subscriber' and i.entity_id=p.subscriber_id and i.billing_month=p.billing_month;
update public.parking_monthly_receipts r set payment_context=private.parking_subscriber_payment_context(r.payment_id);
revoke all on function private.parking_subscriber_payment_context(uuid) from public,anon,authenticated;
revoke all on function private.parking_snapshot_subscriber_document_payment() from public,anon,authenticated;
revoke all on function private.parking_refresh_subscriber_document_payment() from public,anon,authenticated;
