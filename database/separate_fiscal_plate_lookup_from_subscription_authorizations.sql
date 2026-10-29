-- Fiscal plate history is independent of subscription access authorizations.
-- Only the subscriber editor RPC writes monthly_subscriber_extra_plates.
create or replace function private.remember_simplified_invoice_customer()
returns trigger language plpgsql security definer set search_path to '' as $$
declare p text;
begin
 if nullif(btrim(new.customer_name),'') is null or nullif(regexp_replace(upper(new.customer_tax_id),'[^A-Z0-9]','','g'),'') is null or nullif(btrim(new.customer_address),'') is null then return new;end if;
 select regexp_replace(upper(m.plate),'[^A-Z0-9]','','g') into p from public.parking_cash_movements m where m.id=new.movement_id;
 insert into public.parking_invoice_customers(name,tax_id,address,plates,updated_at)
 values(btrim(new.customer_name),btrim(new.customer_tax_id),btrim(new.customer_address),case when nullif(p,'') is null then '{}'::text[] else array[p] end,new.issued_at)
 on conflict(tax_key) do update set
 name=case when excluded.updated_at>=parking_invoice_customers.updated_at then excluded.name else parking_invoice_customers.name end,
 tax_id=case when excluded.updated_at>=parking_invoice_customers.updated_at then excluded.tax_id else parking_invoice_customers.tax_id end,
 address=case when excluded.updated_at>=parking_invoice_customers.updated_at then excluded.address else parking_invoice_customers.address end,
 plates=array(select distinct unnest(parking_invoice_customers.plates||excluded.plates)),
 updated_at=greatest(parking_invoice_customers.updated_at,excluded.updated_at);
 return new;
end $$;
revoke all on function private.remember_simplified_invoice_customer() from public,anon,authenticated;
create trigger remember_simplified_invoice_customer after insert or update of customer_name,customer_tax_id,customer_address on public.parking_simplified_invoices for each row execute function private.remember_simplified_invoice_customer();

-- Remember previously completed receipts without changing issued documents or subscription plates.
do $$
declare r record;
begin
 for r in select s.*,regexp_replace(upper(m.plate),'[^A-Z0-9]','','g') fiscal_plate from public.parking_simplified_invoices s join public.parking_cash_movements m on m.id=s.movement_id
 where nullif(btrim(s.customer_name),'') is not null and nullif(regexp_replace(upper(s.customer_tax_id),'[^A-Z0-9]','','g'),'') is not null and nullif(btrim(s.customer_address),'') is not null order by s.issued_at
 loop
 insert into public.parking_invoice_customers(name,tax_id,address,plates,updated_at)
 values(btrim(r.customer_name),btrim(r.customer_tax_id),btrim(r.customer_address),case when nullif(r.fiscal_plate,'') is null then '{}'::text[] else array[r.fiscal_plate] end,r.issued_at)
 on conflict(tax_key) do update set
 plates=array(select distinct unnest(parking_invoice_customers.plates||excluded.plates));
 end loop;
end $$;

create or replace function public.parking_search_invoice_customers(p_query text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare q text:=private.parking_customer_name_key(p_query);result jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if q='' or length(btrim(coalesce(p_query,'')))<2 then return '[]'::jsonb;end if;
 -- Fiscal records must remain searchable even when their CIF belongs to a subscriber.
 -- These plates are invoice lookup history, never subscription authorizations.
 with candidates as (
 select c.source_id id,c.name,c.tax_id,c.address,c.plates,c.aliases,c.legacy_code,1 priority
 from private.parking_all_customer_profiles() c
 union all
 select f.id,f.name,f.tax_id,f.address,f.plates,'{}'::text[],null::text,0 from public.parking_invoice_customers f
 ), matching as (
 select c.*,case when nullif(regexp_replace(upper(c.tax_id),'[^A-Z0-9]','','g'),'') is not null then 'tax:'||regexp_replace(upper(c.tax_id),'[^A-Z0-9]','','g') else 'name:'||private.parking_customer_name_key(c.name) end identity_key
 from candidates c where position(q in private.parking_customer_name_key(c.name))>0 or position(q in private.parking_customer_name_key(c.tax_id))>0 or exists(select 1 from unnest(c.plates||c.aliases)p where position(q in private.parking_customer_name_key(p))>0)
 ), unique_customers as (
 select distinct on(identity_key) * from matching order by identity_key,priority,name,id
 )
 select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) into result from (
 select id,name,tax_id,address,plates,legacy_code,(coalesce(tax_id,'')='' or coalesce(address,'')='') pending_fiscal_data from unique_customers order by name,id limit 20)t;
 return result;
end $$;
revoke all on function public.parking_search_invoice_customers(text) from public,anon;
grant execute on function public.parking_search_invoice_customers(text) to authenticated;
