-- Physical size is independent of the customer's paid tariff.
create function private.parking_size_fits(p_space text,p_vehicle text) returns boolean
language sql immutable security invoker set search_path='' as $$
 select case upper(p_vehicle) when 'MOTO' then upper(p_space) in ('MOTO','TURISMO','XL','XXL','POLIVALENTE')
 when 'TURISMO' then upper(p_space) in ('TURISMO','XL','XXL','POLIVALENTE')
 when 'XL' then upper(p_space) in ('XL','XXL','POLIVALENTE')
 when 'XXL' then upper(p_space) in ('XXL','POLIVALENTE') else false end
$$;
revoke all on function private.parking_size_fits(text,text) from public,anon;
grant execute on function private.parking_size_fits(text,text) to authenticated;
-- A larger physical size keeps an occupied rotation claim valid.
create or replace function private.guard_rotation_inventory_state() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.rotation_sessions where spot_id=new.id and status='inside' and not billing_only)
 and (not new.active or new.inventory_state<>'available' or not private.parking_size_fits(
 case when new.polyvalent then 'POLIVALENTE' else (select code from public.vehicle_types where id=new.vehicle_type_id) end,
 case when old.polyvalent then 'POLIVALENTE' else (select code from public.vehicle_types where id=old.vehicle_type_id) end)) then
 raise exception 'La plaza tiene un vehículo de Rotación dentro; no se puede bloquear, desactivar ni reducir su tamaño';end if;
 return new;
end$$;
revoke all on function private.guard_rotation_inventory_state() from public,anon,authenticated;
update public.parking_spots set spot_class='XL',vehicle_type_id=(select id from public.vehicle_types where code='XL') where zone='M';
update public.parking_spots set spot_class='XXL',vehicle_type_id=(select id from public.vehicle_types where code='XXL') where zone='LL';

create or replace function private.spot_accepts_vehicle(p_spot_id uuid,p_vehicle_type_id uuid) returns boolean
language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.parking_spots p join public.vehicle_types s on s.id=p.vehicle_type_id
 join public.vehicle_types v on v.id=p_vehicle_type_id where p.id=p_spot_id and p.active and p.inventory_state='available'
 and private.parking_size_fits(case when p.polyvalent then 'POLIVALENTE' else s.code end,v.code))
$$;
create or replace function private.rotation_spot_accepts_tariff(p_spot_id uuid,p_tariff_code text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.parking_spots p join public.vehicle_types v on v.id=p.vehicle_type_id
 where p.id=p_spot_id and p.active and p.inventory_state='available'
 and private.parking_size_fits(case when p.polyvalent then 'POLIVALENTE' else v.code end,
 case upper(p_tariff_code) when 'COCHERA' then 'XL' when 'CAMION' then 'XXL' else upper(p_tariff_code) end))
$$;

-- Keep the existing operator checks and claim locks in all rotation RPCs.
do $$declare f record;d text;begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='public' and p.proname in ('parking_available_rotation_spots','rotation_check_in','rotation_update_active'))
 or (n.nspname='private' and p.proname='guard_rotation_spot_claim') loop
 d:=pg_get_functiondef(f.oid);
 d:=replace(d,'p.zone is distinct from ''A''','p.zone not in (''A'',''M'')');
 d:=replace(d,'z is distinct from ''A''','z not in (''A'',''M'')');
 execute d;
 end loop;
end$$;
-- The total physical capacity uses the same upward-compatible size rule.
do $$declare d text;begin
 d:=pg_get_functiondef('private.get_available_spaces(uuid,timestamptz,timestamptz,uuid)'::regprocedure);
 d:=replace(d,'p_vehicle_type_id is null or polyvalent or vehicle_type_id=p_vehicle_type_id',
 'p_vehicle_type_id is null or private.spot_accepts_vehicle(id,p_vehicle_type_id)');
 execute d;
end$$;

alter table public.monthly_subscribers add column parking_spot_id uuid references public.parking_spots(id);
create index monthly_subscribers_parking_spot_idx on public.monthly_subscribers(parking_spot_id) where active;
create function private.resolve_subscriber_spot() returns trigger language plpgsql security definer set search_path='' as $$
declare label text;sid uuid;
begin
 label:=regexp_replace(upper(coalesce(new.parking_space_label,'')),'[^A-Z0-9]','','g');
 label:=regexp_replace(label,'^JAULAN?','J');
 select p.id into sid from public.parking_spots p where p.active and p.inventory_state<>'legacy'
 and regexp_replace(upper(p.code),'[^A-Z0-9]','','g')=regexp_replace(label,'^([A-Z]+)0+([0-9])','\1\2');
 if label<>'' and sid is null and label !~ '^(A|C|MOTO|SALTOBONOC)$' then
  raise exception 'Plaza no reconocida. Selecciona un código del planning (por ejemplo J-13 o B-3)';
 end if;
 new.parking_spot_id:=sid;
 if sid is not null then
  select code into new.parking_space_label from public.parking_spots where id=sid;
  -- Serialize assignments, deactivations and rotation claims on the same physical row.
  perform 1 from public.parking_spots where id=sid for update;
  if new.active and (tg_op='INSERT' or not old.active or old.parking_spot_id is distinct from sid) then
   if exists(select 1 from public.rotation_sessions where spot_id=sid and status='inside' and not billing_only)
   or exists(select 1 from public.parking_sessions where spot_id=sid and status='inside')
   or exists(select 1 from public.reservations where assigned_spot_id=sid and finished_at is null and status in ('confirmed','checked_in','pending_payment') and (exit_at>now() or status='checked_in'))
   then raise exception 'La plaza tiene una estancia o rotación asignada. Reubícala antes de asignar el abonado';end if;
  end if;
 end if;
 if tg_op='UPDATE' and old.parking_spot_id is not null and old.parking_spot_id is distinct from sid then
  perform 1 from public.parking_spots where id=old.parking_spot_id for update;
 end if;
 return new;
end$$;
revoke all on function private.resolve_subscriber_spot() from public,anon,authenticated;
create trigger zz_resolve_subscriber_spot before insert or update of parking_space_label,active,parking_spot_id on public.monthly_subscribers
for each row execute function private.resolve_subscriber_spot();

create function private.sync_subscriber_spot() returns trigger language plpgsql security definer set search_path='' as $$
declare sid uuid;ids uuid[];
begin
 if tg_op='INSERT' then ids:=array[new.parking_spot_id];
 elsif tg_op='DELETE' then ids:=array[old.parking_spot_id];
 else ids:=array[old.parking_spot_id,new.parking_spot_id];end if;
 for sid in select distinct x from unnest(ids) x where x is not null loop
  perform 1 from public.parking_spots where id=sid for update;
  if exists(select 1 from public.monthly_subscribers where parking_spot_id=sid and active) then
   update public.parking_spots set inventory_state='fixed' where id=sid;
  else
   update public.parking_spots set inventory_state='available' where id=sid and inventory_state='fixed';
  end if;
 end loop;
 return null;
end$$;
revoke all on function private.sync_subscriber_spot() from public,anon,authenticated;
create trigger sync_subscriber_spot after insert or update of active,parking_spot_id,parking_space_label or delete on public.monthly_subscribers
for each row execute function private.sync_subscriber_spot();

-- Only operational identification is exposed to staff, regardless of billing filters.
create function public.parking_fixed_assignments() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'spot_id',parking_spot_id,'customer_name',customer_name,'plate',plate,'label',parking_space_label) order by customer_name),'[]'::jsonb)
 from public.monthly_subscribers where active);
end$$;
revoke all on function public.parking_fixed_assignments() from public,anon;
grant execute on function public.parking_fixed_assignments() to authenticated;

-- A linked fixed space can only be released through its subscriber's lifecycle.
create function private.guard_fixed_spot_release() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.inventory_state<>'fixed' and exists(select 1 from public.monthly_subscribers where parking_spot_id=new.id and active) then
 raise exception 'Esta plaza pertenece a un abonado activo. Cambia su plaza o tramita su baja desde Abonados';end if;
 return new;
end$$;
revoke all on function private.guard_fixed_spot_release() from public,anon,authenticated;
create trigger guard_fixed_spot_release before update of inventory_state on public.parking_spots for each row execute function private.guard_fixed_spot_release();

-- Current active tickets in the no-key groups follow the same physical rule.
update public.rotation_sessions r set leaves_keys=false from public.parking_spots p where p.id=r.spot_id and p.zone in ('A','M') and r.status='inside' and not r.billing_only;
