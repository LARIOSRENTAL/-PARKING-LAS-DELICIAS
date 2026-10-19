create table public.parking_invoice_customers (
 id uuid primary key default gen_random_uuid(),
 name text not null,
 tax_id text not null,
 tax_key text generated always as (regexp_replace(upper(tax_id),'[^A-Z0-9]','','g')) stored unique,
 address text not null,
 plates text[] not null default '{}',
 updated_at timestamptz not null default clock_timestamp()
);
alter table public.parking_invoice_customers enable row level security;
revoke all on public.parking_invoice_customers from anon, authenticated;
create function private.remember_invoice_customer() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if nullif(btrim(new.customer_name),'') is null or nullif(regexp_replace(upper(new.customer_tax_id),'[^A-Z0-9]','','g'),'') is null or nullif(btrim(new.customer_address),'') is null then return new;end if;
 insert into public.parking_invoice_customers(name,tax_id,address,plates,updated_at)
 values(btrim(new.customer_name),btrim(new.customer_tax_id),btrim(new.customer_address),
 case when nullif(btrim(new.plate),'') is null then '{}'::text[] else array[regexp_replace(upper(new.plate),'[^A-Z0-9]','','g')] end,new.issued_at)
 on conflict(tax_key) do update set
 name=case when excluded.updated_at>=parking_invoice_customers.updated_at then excluded.name else parking_invoice_customers.name end,
 tax_id=case when excluded.updated_at>=parking_invoice_customers.updated_at then excluded.tax_id else parking_invoice_customers.tax_id end,
 address=case when excluded.updated_at>=parking_invoice_customers.updated_at then excluded.address else parking_invoice_customers.address end,
 plates=array(select distinct unnest(parking_invoice_customers.plates||excluded.plates)),
 updated_at=greatest(parking_invoice_customers.updated_at,excluded.updated_at);
 return new;
end $$;
revoke all on function private.remember_invoice_customer() from public,anon,authenticated;
create trigger remember_invoice_customer after insert or update of customer_name,customer_tax_id,customer_address,plate on public.parking_invoices for each row execute function private.remember_invoice_customer();
-- Populate from issued invoices without altering those documents.
insert into public.parking_invoice_customers(name,tax_id,address,plates,updated_at)
select distinct on (regexp_replace(upper(customer_tax_id),'[^A-Z0-9]','','g'))
 customer_name,customer_tax_id,customer_address,
 array(select distinct regexp_replace(upper(p.plate),'[^A-Z0-9]','','g') from public.parking_invoices p where regexp_replace(upper(p.customer_tax_id),'[^A-Z0-9]','','g')=regexp_replace(upper(i.customer_tax_id),'[^A-Z0-9]','','g') and nullif(btrim(p.plate),'') is not null),issued_at
from public.parking_invoices i where nullif(btrim(customer_name),'') is not null and nullif(regexp_replace(upper(customer_tax_id),'[^A-Z0-9]','','g'),'') is not null and nullif(btrim(customer_address),'') is not null
order by regexp_replace(upper(customer_tax_id),'[^A-Z0-9]','','g'),issued_at desc;
create function public.parking_search_invoice_customers(p_query text) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_query text:=btrim(p_query);v_key text:=regexp_replace(upper(p_query),'[^A-Z0-9]','','g');
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if coalesce(length(v_query),0)<2 then return '[]'::jsonb;end if;
 return coalesce((select jsonb_agg(to_jsonb(c)) from (
 select id,name,tax_id,address,plates from public.parking_invoice_customers
 where position(lower(v_query) in lower(name))>0 or (length(v_key)>0 and (position(v_key in tax_key)>0 or exists(select 1 from unnest(plates) plate where position(v_key in plate)>0)))
 order by updated_at desc,id limit 20) c),'[]'::jsonb);
end $$;
revoke all on function public.parking_search_invoice_customers(text) from public,anon;
grant execute on function public.parking_search_invoice_customers(text) to authenticated;

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
  if p_entity_type <> 'rotation' then raise exception 'Solo administradores y gerentes pueden emitir estas facturas';end if;
  if not exists(select 1 from public.rotation_sessions where id=p_entity_id and status='departed' and exit_user_id=auth.uid() and exit_shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid) then raise exception 'Solo puedes facturar cobros de Rotación de tu turno';end if;
 end if;
 if v_name is null or v_tax is null or v_address is null then raise exception 'Completa nombre, NIF/CIF y domicilio';end if;
 perform pg_advisory_xact_lock(hashtextextended('full-invoice:'||p_entity_type||':'||p_entity_id::text||':'||coalesce(p_billing_month::text,''),0));
 select * into v from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month order by issued_at desc limit 1;
 if found then return to_jsonb(v);end if;

 if p_entity_type='hotel_batch' then
  insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  select 'hotel_batch',b.id,v_name,v_tax,v_address,b.days||' bonos hotel de 1 día · '||h.name,null,
   round(b.days*b.unit_price_eur/1.21,2),0,b.days*b.unit_price_eur-round(b.days*b.unit_price_eur/1.21,2),b.days*b.unit_price_eur
  from public.parking_hotel_batches b join public.parking_hotels h on h.id=b.hotel_id
  where b.id=p_entity_id and b.payment_status='paid' and not b.is_void and not b.is_test returning * into v;
  if not found then raise exception 'Primero registra el cobro de los bonos hotel';end if;
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
