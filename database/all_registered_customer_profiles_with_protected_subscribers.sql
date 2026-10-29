
alter table private.parking_regular_customers add column if not exists tax_id text;
alter table private.parking_regular_customers add column if not exists address text;
alter table private.parking_regular_customers add column if not exists updated_at timestamptz;
alter table private.parking_regular_customers add column if not exists updated_by uuid;
create table private.parking_customer_profile_edits(id uuid primary key default gen_random_uuid(),source_kind text not null,source_id uuid not null,changed_by uuid not null,changed_at timestamptz not null default clock_timestamp(),before_data jsonb not null,after_data jsonb not null);
alter table private.parking_customer_profile_edits enable row level security;
revoke all on private.parking_customer_profile_edits from public,anon,authenticated;
create or replace function private.parking_customer_is_subscriber(p_tax text,p_name text,p_plates text[])
returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.monthly_subscribers s where
 (nullif(regexp_replace(upper(p_tax),'[^A-Z0-9]','','g'),'') is not null and regexp_replace(upper(s.tax_id),'[^A-Z0-9]','','g')=regexp_replace(upper(p_tax),'[^A-Z0-9]','','g'))
 or (private.parking_customer_name_key(p_name)<>'' and private.parking_customer_name_key(s.customer_name)=private.parking_customer_name_key(p_name))
 or exists(select 1 from unnest(coalesce(p_plates,'{}')) p where regexp_replace(upper(p),'[^A-Z0-9]','','g')=regexp_replace(upper(s.plate),'[^A-Z0-9]','','g') or exists(select 1 from public.monthly_subscriber_extra_plates e where e.subscriber_id=s.id and regexp_replace(upper(e.plate),'[^A-Z0-9]','','g')=regexp_replace(upper(p),'[^A-Z0-9]','','g')))
 );
$$;
create or replace function private.parking_all_customer_profiles()
returns table(client_key text,source_kind text,source_id uuid,name text,tax_id text,address text,plates text[],aliases text[],subscriber_id uuid,legacy_code text)
language sql stable set search_path='' as $$
 with regular as (
  select r.id,c.id fiscal_id,coalesce(c.name,r.name) name,coalesce(c.tax_id,r.tax_id,r.tax_key,'') tax_id,coalesce(c.address,r.address,'') address,
   array(select distinct regexp_replace(upper(p),'[^A-Z0-9]','','g') from unnest(coalesce(r.plates,'{}')||coalesce(c.plates,'{}')) p where nullif(btrim(p),'') is not null order by 1) plates,coalesce(r.aliases,'{}') aliases,r.legacy_code
  from private.parking_regular_customers r
  left join lateral(select i.* from public.parking_invoice_customers i where
   (coalesce(nullif(regexp_replace(upper(r.tax_id),'[^A-Z0-9]','','g'),''),r.tax_key) is not null and i.tax_key=coalesce(nullif(regexp_replace(upper(r.tax_id),'[^A-Z0-9]','','g'),''),r.tax_key))
   or (r.tax_key is null and nullif(r.tax_id,'') is null and private.parking_customer_name_key(i.name)=private.parking_customer_name_key(r.name)
    and(select count(*) from public.parking_invoice_customers n where private.parking_customer_name_key(n.name)=private.parking_customer_name_key(r.name))=1)
   order by i.updated_at desc,i.id limit 1)c on true
 ), seeds as (
  select 'subscriber:'||s.id::text client_key,'subscriber'::text source_kind,s.id source_id,s.customer_name name,coalesce(s.tax_id,'') tax_id,concat_ws(' ',s.address,s.postal_code,s.city) address,
   array(select distinct regexp_replace(upper(p),'[^A-Z0-9]','','g') from unnest(array[s.plate]||array(select e.plate from public.monthly_subscriber_extra_plates e where e.subscriber_id=s.id))p where nullif(btrim(p),'') is not null order by 1) plates,
   '{}'::text[] aliases,s.id subscriber_id,null::text legacy_code
  from public.monthly_subscribers s
  union all
  select 'regular:'||r.id,'regular',r.id,r.name,r.tax_id,r.address,r.plates,r.aliases,null::uuid,r.legacy_code from regular r
   where not private.parking_customer_is_subscriber(r.tax_id,r.name,r.plates)
  union all
  select 'fiscal:'||c.id,'fiscal',c.id,c.name,c.tax_id,c.address,c.plates,'{}'::text[],null::uuid,null::text from public.parking_invoice_customers c
   where not exists(select 1 from regular r where r.fiscal_id=c.id) and not private.parking_customer_is_subscriber(c.tax_id,c.name,c.plates)
 ), docs as (
  select 'invoice'::text source_kind,i.id source_id,i.customer_name name,coalesce(i.customer_tax_id,'') tax_id,coalesce(i.customer_address,'') address,array[i.plate] plates,i.issued_at stamp from public.parking_invoices i where nullif(btrim(i.customer_name),'') is not null
  union all
  select 'receipt',r.id,r.customer_name,coalesce(r.customer_tax_id,''),coalesce(r.customer_address,''),array[m.plate],r.issued_at from public.parking_simplified_invoices r join public.parking_cash_movements m on m.id=r.movement_id where nullif(btrim(r.customer_name),'') is not null
 ), fallback as (
  select distinct on(case when nullif(d.tax_id,'') is not null then regexp_replace(upper(d.tax_id),'[^A-Z0-9]','','g') else private.parking_customer_name_key(d.name) end)
   d.* from docs d where not exists(select 1 from seeds s where
    (nullif(d.tax_id,'') is not null and regexp_replace(upper(d.tax_id),'[^A-Z0-9]','','g')=regexp_replace(upper(s.tax_id),'[^A-Z0-9]','','g'))
    or private.parking_customer_name_key(d.name)=private.parking_customer_name_key(s.name))
   and not private.parking_customer_is_subscriber(d.tax_id,d.name,d.plates)
   order by case when nullif(d.tax_id,'') is not null then regexp_replace(upper(d.tax_id),'[^A-Z0-9]','','g') else private.parking_customer_name_key(d.name) end,d.stamp desc,d.source_id
 )
 select * from seeds
 union all select f.source_kind||':'||f.source_id,f.source_kind,f.source_id,f.name,f.tax_id,f.address,
 array(select distinct regexp_replace(upper(p),'[^A-Z0-9]','','g') from unnest(f.plates)p where nullif(btrim(p),'') is not null),'{}'::text[],null::uuid,null::text from fallback f;
$$;
create or replace function public.parking_invoice_customer_list(p_query text default '',p_offset integer default 0,p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;q text:=private.parking_customer_name_key(left(coalesce(p_query,''),200));off integer:=greatest(coalesce(p_offset,0),0);lim integer:=least(greatest(coalesce(p_limit,100),1),200);manager boolean;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select role in('admin','manager') into manager from public.staff_profiles where user_id=auth.uid() and active;
 with filtered as (
 select c.*,(c.subscriber_id is null) can_edit,manager can_manage_subscriber from private.parking_all_customer_profiles() c
 where q='' or position(q in private.parking_customer_name_key(c.name))>0 or exists(select 1 from unnest(c.plates||c.aliases)p where position(q in private.parking_customer_name_key(p))>0)
 ), page as (select * from filtered order by private.parking_customer_name_key(name),client_key offset off limit lim)
 select jsonb_build_object('customers',coalesce((select jsonb_agg(to_jsonb(p) order by private.parking_customer_name_key(p.name),p.client_key) from page p),'[]'::jsonb),'total',(select count(*) from filtered),'offset',off,'limit',lim,'has_more',off+lim<(select count(*) from filtered)) into result;
 return result;
end $$;
create or replace function public.parking_search_invoice_customers(p_query text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare q text:=private.parking_customer_name_key(p_query);result jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if q='' or length(btrim(coalesce(p_query,'')))<2 then return '[]'::jsonb;end if;
 select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) into result from (
 select c.source_id id,c.name,c.tax_id,c.address,c.plates,c.legacy_code,(c.tax_id='' or c.address='')pending_fiscal_data
 from private.parking_all_customer_profiles() c where position(q in private.parking_customer_name_key(c.name))>0 or position(q in private.parking_customer_name_key(c.tax_id))>0 or exists(select 1 from unnest(c.plates||c.aliases)p where position(q in private.parking_customer_name_key(p))>0)
 order by c.name,c.client_key limit 20)t;return result;
end $$;
create or replace function public.parking_save_customer_profile(p_source_kind text,p_source_id uuid,p_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare oldrow record;role_name text;n text:=btrim(coalesce(p_data->>'name',''));tax text:=upper(btrim(coalesce(p_data->>'tax_id','')));addr text:=btrim(coalesce(p_data->>'address',''));ps text[];c public.parking_invoice_customers;r private.parking_regular_customers;target uuid;existing uuid;before_json jsonb;
begin
 select role into role_name from public.staff_profiles where user_id=auth.uid() and active;
 if auth.uid() is null or role_name not in('admin','manager','employee') or role_name is null then raise exception 'No autorizado';end if;
 if p_source_kind not in('regular','fiscal','invoice','receipt') then raise exception 'Los abonados solo se editan desde su ficha por gerente o administrador';end if;
 if length(n)<2 or length(n)>200 or length(tax)>40 or (tax<>'' and length(regexp_replace(tax,'[^A-Z0-9]','','g'))<3) or length(addr)>500 then raise exception 'Revisa nombre, NIF/CIF y domicilio';end if;
 if jsonb_typeof(coalesce(p_data->'plates','[]'::jsonb))<>'array' then raise exception 'Revisa las matrículas';end if;
 select coalesce(array_agg(distinct regexp_replace(upper(v),'[^A-Z0-9]','','g'))filter(where nullif(btrim(v),'') is not null),'{}') into ps from jsonb_array_elements_text(coalesce(p_data->'plates','[]'))v;
 if cardinality(ps)>50 or exists(select 1 from unnest(ps)p where length(p)<3 or length(p)>16) then raise exception 'Revisa las matrículas: entre 3 y 16 letras o números';end if;
 perform pg_advisory_xact_lock(hashtextextended('customer-profile:'||p_source_kind||':'||p_source_id::text,0));
 select * into oldrow from private.parking_all_customer_profiles() where source_kind=p_source_kind and source_id=p_source_id;
 if not found then raise exception 'Ficha inexistente o vinculada a un abonado. Actualiza el listado';end if;
 if private.parking_customer_is_subscriber(oldrow.tax_id,oldrow.name,oldrow.plates) or private.parking_customer_is_subscriber(tax,n,ps) then raise exception 'Los datos de abonados solo se editan desde su ficha por gerente o administrador';end if;
 before_json:=to_jsonb(oldrow);
 if p_source_kind='regular' then
  select * into r from private.parking_regular_customers where id=p_source_id for update;
  select * into c from public.parking_invoice_customers where (nullif(oldrow.tax_id,'') is not null and tax_key=regexp_replace(upper(oldrow.tax_id),'[^A-Z0-9]','','g'))
   or (oldrow.tax_id='' and private.parking_customer_name_key(name)=private.parking_customer_name_key(oldrow.name) and(select count(*) from public.parking_invoice_customers i where private.parking_customer_name_key(i.name)=private.parking_customer_name_key(oldrow.name))=1)
   order by updated_at desc limit 1 for update;
 elsif p_source_kind='fiscal' then select * into c from public.parking_invoice_customers where id=p_source_id for update;
 end if;
 if c.id is not null and tax='' then raise exception 'El NIF/CIF es obligatorio para este cliente fiscal';end if;
 if tax<>'' then
  select id into existing from public.parking_invoice_customers where tax_key=regexp_replace(tax,'[^A-Z0-9]','','g');
  if existing is not null and existing is distinct from c.id then raise exception 'Ya existe un cliente con ese NIF/CIF. Abre su ficha';end if;
  if c.id is null then
   insert into public.parking_invoice_customers(name,tax_id,address,plates) values(n,tax,addr,ps) returning * into c;
  else update public.parking_invoice_customers set name=n,tax_id=tax,address=addr,plates=ps,updated_at=clock_timestamp() where id=c.id;end if;
 end if;
 if p_source_kind='regular' then
  update private.parking_regular_customers set name=n,tax_id=nullif(tax,''),tax_key=nullif(regexp_replace(tax,'[^A-Z0-9]','','g'),''),address=addr,plates=ps,updated_at=clock_timestamp(),updated_by=auth.uid() where id=r.id;target:=r.id;
 elsif p_source_kind in('invoice','receipt') then
  insert into private.parking_regular_customers(name,tax_id,tax_key,address,plates,aliases,source,imported_at,updated_at,updated_by)values(n,nullif(tax,''),nullif(regexp_replace(tax,'[^A-Z0-9]','','g'),''),addr,ps,'{}','staff_customer_edit',clock_timestamp(),clock_timestamp(),auth.uid()) returning id into target;
 else target:=c.id;
 end if;
 insert into private.parking_customer_profile_edits(source_kind,source_id,changed_by,before_data,after_data)values(p_source_kind,p_source_id,auth.uid(),before_json,jsonb_build_object('name',n,'tax_id',tax,'address',addr,'plates',ps));
 return jsonb_build_object('saved',true,'id',target);
end $$;
revoke all on function private.parking_customer_is_subscriber(text,text,text[]),private.parking_all_customer_profiles() from public,anon,authenticated;
revoke all on function public.parking_invoice_customer_list(text,integer,integer),public.parking_search_invoice_customers(text),public.parking_save_customer_profile(text,uuid,jsonb) from public,anon;
grant execute on function public.parking_invoice_customer_list(text,integer,integer),public.parking_search_invoice_customers(text),public.parking_save_customer_profile(text,uuid,jsonb) to authenticated;
