create or replace function public.parking_invoice_customer_list(p_query text default '',p_offset integer default 0,p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;q text:=private.parking_customer_name_key(left(coalesce(p_query,''),200));off integer:=greatest(coalesce(p_offset,0),0);lim integer:=least(greatest(coalesce(p_limit,100),1),200);
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 with docs as (
  select 'F:'||i.id::text doc_id,i.customer_name name,coalesce(i.customer_tax_id,'') tax_id,coalesce(i.customer_address,'') address,i.plate,i.issued_at,coalesce(i.display_number,i.number::text) number
  from public.parking_invoices i where nullif(btrim(i.customer_name),'') is not null
  union all
  select 'T:'||r.id::text,r.customer_name,coalesce(r.customer_tax_id,''),coalesce(r.customer_address,''),m.plate,r.issued_at,r.number
  from public.parking_simplified_invoices r join public.parking_cash_movements m on m.id=r.movement_id where nullif(btrim(r.customer_name),'') is not null
 ), keyed as (
  select d.*,regexp_replace(upper(tax_id),'[^A-Z0-9]','','g') tax_key,
   case when nullif(regexp_replace(upper(tax_id),'[^A-Z0-9]','','g'),'') is not null then 'tax:'||regexp_replace(upper(tax_id),'[^A-Z0-9]','','g') else 'name:'||private.parking_customer_name_key(name) end client_key from docs d
 ), latest as (
  select distinct on(client_key) * from keyed order by client_key,issued_at desc,doc_id desc
 ), clients as (
  select l.client_key,coalesce(c.name,l.name) name,coalesce(c.tax_id,l.tax_id) tax_id,coalesce(c.address,l.address) address,
   array(select distinct plate from (
    select nullif(regexp_replace(upper(k.plate),'[^A-Z0-9]','','g'),'') plate from keyed k where k.client_key=l.client_key
    union all select nullif(regexp_replace(upper(p),'[^A-Z0-9]','','g'),'') from unnest(coalesce(c.plates,'{}'::text[])) p
   ) plates where plate is not null order by plate) plates,
   (select count(*) from keyed k where k.client_key=l.client_key) invoice_count,l.issued_at last_invoice_at,l.number last_invoice_number
  from latest l left join public.parking_invoice_customers c on c.tax_key=l.tax_key and l.tax_key<>''
 ), filtered as (
  select * from clients where q='' or position(q in private.parking_customer_name_key(name))>0 or exists(select 1 from unnest(plates) p where position(q in private.parking_customer_name_key(p))>0)
 ), page as (
  select * from filtered order by private.parking_customer_name_key(name),client_key offset off limit lim
 )
 select jsonb_build_object('customers',coalesce((select jsonb_agg(to_jsonb(p) order by private.parking_customer_name_key(p.name),p.client_key) from page p),'[]'::jsonb),
 'total',(select count(*) from filtered),'offset',off,'limit',lim,'has_more',off+lim<(select count(*) from filtered)) into result;
 return result;
end $$;
revoke all on function public.parking_invoice_customer_list(text,integer,integer) from public,anon;
grant execute on function public.parking_invoice_customer_list(text,integer,integer) to authenticated;
