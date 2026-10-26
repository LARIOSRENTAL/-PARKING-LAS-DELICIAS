-- One internal receipt order number, shared by both copies and every reprint.
alter table public.parking_monthly_receipts add column if not exists order_number bigint;
create unique index if not exists parking_monthly_receipt_order_unique on public.parking_monthly_receipts(order_number);
create table if not exists private.parking_monthly_receipt_counter(singleton boolean primary key default true check(singleton),last_number bigint not null);
alter table private.parking_monthly_receipt_counter enable row level security;
revoke all on private.parking_monthly_receipt_counter from public,anon,authenticated;
insert into private.parking_monthly_receipt_counter(singleton,last_number)values(true,11417)on conflict(singleton)do nothing;
update private.parking_monthly_receipt_counter set last_number=greatest(last_number,coalesce((select max(order_number)from public.parking_monthly_receipts),11417));
DO $$declare r record;n bigint;begin
 for r in select id from public.parking_monthly_receipts where order_number is null order by issued_at,id loop
  update private.parking_monthly_receipt_counter set last_number=last_number+1 where singleton returning last_number into n;
  update public.parking_monthly_receipts set order_number=n where id=r.id;
 end loop;
end$$;
create or replace function private.parking_number_monthly_receipt() returns trigger language plpgsql security definer set search_path='' as $$
declare existing bigint;begin
 perform 1 from public.monthly_subscription_payments where id=new.payment_id for update;
 select order_number into existing from public.parking_monthly_receipts where payment_id=new.payment_id;
 if found then new.order_number:=existing;return new;end if;
 update private.parking_monthly_receipt_counter set last_number=last_number+1 where singleton returning last_number into new.order_number;
 return new;
end;$$;
revoke all on function private.parking_number_monthly_receipt() from public,anon,authenticated;
drop trigger if exists number_monthly_receipt on public.parking_monthly_receipts;
create trigger number_monthly_receipt before insert on public.parking_monthly_receipts for each row execute function private.parking_number_monthly_receipt();
CREATE OR REPLACE FUNCTION private.parking_report_fiscal_fields(p_type text, p_id uuid, p_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.parking_cash_movements;f public.parking_invoices;r public.parking_simplified_invoices;mp public.monthly_subscription_payments;mr public.parking_monthly_receipts;
begin
 select * into m from public.parking_cash_movements where entity_type=p_type and entity_id=p_id limit 1;if not found then return '{}'::jsonb;end if;
 if p_type='subscriber_payment' then select * into mp from public.monthly_subscription_payments where id=p_id;
  select * into mr from public.parking_monthly_receipts where payment_id=p_id;
  if found then return jsonb_build_object('document_series',null,'document_number',null,'document_date',(mr.issued_at at time zone 'Europe/Madrid')::date,'document_kind','monthly_receipt','receipt_month',mr.billing_month,'receipt_order_number',mr.order_number,'invoice_number','','receipt_number','','customer_name',mr.customer_name,'customer_tax_id',mr.customer_tax_id,'customer_address',mr.customer_address,'base_eur',mr.amount_eur,'vat_eur',0);end if;
 end if;
 select * into f from public.parking_invoices i where ((i.entity_type=p_type and i.entity_id=p_id) or (p_type='subscriber_payment' and i.entity_type='subscriber' and i.entity_id=mp.subscriber_id and i.billing_month=mp.billing_month)) and i.is_production=(p_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') order by i.issued_at desc limit 1;
 if found then return jsonb_build_object('document_series',f.series,'document_number',coalesce(f.serial_number,f.number::text),'document_date',coalesce(f.invoice_date,(f.issued_at at time zone 'Europe/Madrid')::date),'document_kind','full','invoice_number',coalesce(f.display_number,f.number::text),'customer_name',f.customer_name,'customer_tax_id',f.customer_tax_id,'customer_address',f.customer_address,'base_eur',f.amount_before_vat-coalesce(f.discount_eur,0),'vat_eur',f.vat_eur);end if;
 select * into r from public.parking_simplified_invoices where movement_id=m.id;
 if found then return jsonb_build_object('document_series',r.series,'document_number',coalesce(r.serial_number,r.number),'document_date',coalesce(r.invoice_date,(r.issued_at at time zone 'Europe/Madrid')::date),'document_kind','simplified','receipt_number',r.number,'customer_name',coalesce(r.customer_name,'CLIENTES VARIOS'),'customer_tax_id',coalesce(r.customer_tax_id,''),'customer_address',coalesce(r.customer_address,''),'base_eur',r.amount_before_vat,'vat_eur',r.vat_eur);end if;
 return '{}'::jsonb;
end;$function$
;

