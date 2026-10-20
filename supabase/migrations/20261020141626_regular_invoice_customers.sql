-- Private source records preserve the legacy customer codes without inventing fiscal data.
create table private.parking_regular_customers (
 id uuid primary key default gen_random_uuid(),
 legacy_code text not null unique,
 name text not null,
 plates text[] not null default '{}',
 aliases text[] not null default '{}',
 tax_key text,
 source text not null default 'Listado de clientes habituales · 20/10/2026',
 imported_at timestamptz not null default clock_timestamp()
);
alter table private.parking_regular_customers enable row level security;
revoke all on private.parking_regular_customers from public,anon,authenticated;

create or replace function private.parking_customer_name_key(p_name text) returns text language sql immutable set search_path=pg_catalog as $$
 select regexp_replace(translate(upper(coalesce(p_name,'')),'ÁÉÍÓÚÜÑ','AEIOUUN'),'[^A-Z0-9]','','g')
$$;
revoke all on function private.parking_customer_name_key(text) from public,anon,authenticated;

create or replace function public.parking_search_invoice_customers(p_query text) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_query text:=btrim(p_query);v_key text:=regexp_replace(upper(p_query),'[^A-Z0-9]','','g');v_name text:=private.parking_customer_name_key(p_query);
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if coalesce(length(v_query),0)<2 then return '[]'::jsonb;end if;
 return coalesce((with regular as (
  select coalesce(c.id,r.id) id,coalesce(c.name,r.name) name,coalesce(c.tax_id,'') tax_id,coalesce(c.address,'') address,
   array(select distinct p from unnest(r.plates||coalesce(c.plates,'{}')) p order by p) plates,
   r.aliases,r.legacy_code,c.id fiscal_id,coalesce(c.updated_at,r.imported_at) updated_at
  from private.parking_regular_customers r
  left join lateral (
   select i.* from public.parking_invoice_customers i
   where (r.tax_key is not null and i.tax_key=r.tax_key)
    or (r.tax_key is null and private.parking_customer_name_key(i.name)=private.parking_customer_name_key(r.name)
     and (select count(*) from public.parking_invoice_customers n where private.parking_customer_name_key(n.name)=private.parking_customer_name_key(r.name))=1)
   order by (i.tax_key=r.tax_key) desc nulls last,i.updated_at desc,i.id limit 1
  ) c on true
 ), directory as (
  select id,name,tax_id,address,plates,aliases,legacy_code,updated_at from regular
  union all
  select i.id,i.name,i.tax_id,i.address,i.plates,'{}'::text[],null::text,i.updated_at
   from public.parking_invoice_customers i where not exists(select 1 from regular r where r.fiscal_id=i.id)
 ), matches as (
  select id,name,tax_id,address,plates,legacy_code,(tax_id='' or address='') pending_fiscal_data
  from directory d where
   (length(v_name)>0 and position(v_name in private.parking_customer_name_key(d.name))>0)
   or (length(v_key)>0 and (position(v_key in regexp_replace(upper(d.tax_id),'[^A-Z0-9]','','g'))>0
    or exists(select 1 from unnest(d.plates||d.aliases) p where position(v_key in regexp_replace(upper(p),'[^A-Z0-9]','','g'))>0)))
  order by (exists(select 1 from unnest(d.plates) p where p=v_key)) desc,d.name,d.id limit 20
 ) select jsonb_agg(to_jsonb(matches)) from matches),'[]'::jsonb);
end $$;
revoke all on function public.parking_search_invoice_customers(text) from public,anon;
grant execute on function public.parking_search_invoice_customers(text) to authenticated;
