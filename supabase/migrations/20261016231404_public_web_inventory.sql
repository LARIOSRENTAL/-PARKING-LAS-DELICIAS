-- Public web inventory is a subset; the complete operating inventory stays intact.
create table public.parking_web_spots(spot_id uuid primary key references public.parking_spots(id),vehicle_type_id uuid not null references public.vehicle_types(id),web_code text not null);
create index parking_web_spots_type_idx on public.parking_web_spots(vehicle_type_id);
alter table public.parking_web_spots enable row level security;
revoke all on public.parking_web_spots from public,anon,authenticated;
grant select on public.parking_web_spots to authenticated;
create policy web_spots_managers_read on public.parking_web_spots for select to authenticated using(exists(select 1 from public.staff_profiles where user_id=(select auth.uid()) and active and role in ('admin','manager')));
insert into public.parking_web_spots(spot_id,vehicle_type_id,web_code)
select p.id,v.id,x.web_code from (values
('MOTO 1','MOTO','M-1'),('MOTO 2','MOTO','M-2'),('MOTO 3','MOTO','M-3'),('MOTO 4','MOTO','M-4'),('MOTO 5','MOTO','M-5'),
('B-37','XXL','B-37'),('B-38','XXL','B-38'),('B-40','XXL','B-40'),('B-41','XXL','B-41'),
('J-2','XL','J-2'),('J-3','XL','J-3'),('J-8','XL','J-8'),('J-9','XL','J-9'),('J-10','XL','J-10'),('J-11','XL','J-11'),('J-40','XL','J-40'),('J-44','XL','J-44'),('J-46','XL','J-46'),('J-47','XL','J-47'),
('P-1','XL','P-1'),('P-2','XL','P-2'),('P-5','XL','P-5'),('P-7','XL','P-7'),('P-9','XL','P-9'),('P-11','XL','P-11'),
('LL-44','TURISMO','LL-44'),('LL-71','TURISMO','LL-71'),('LL-72','TURISMO','LL-72'),('LL-73','TURISMO','LL-73'),('LL-90','TURISMO','LL-90'),('LL-103','TURISMO','LL-103'),('LL-104','TURISMO','LL-104'),('LL-105','TURISMO','LL-105')) x(code,vt,web_code)
join public.parking_spots p on p.code=x.code join public.vehicle_types v on v.code=x.vt;
do $$begin if (select count(*) from public.parking_web_spots)<>33 then raise exception 'Faltan plazas reales del listado web';end if;end$$;

create function private.parking_web_free_spots(p_type uuid,p_start timestamptz,p_end timestamptz,p_exclude uuid default null) returns setof uuid language sql stable security definer set search_path='' as $$
 select p.id from public.parking_web_spots w join public.parking_spots p on p.id=w.spot_id
 where w.vehicle_type_id=p_type and p.active and p.inventory_state='available'
 and not exists(select 1 from public.capacity_blocks b where b.active and b.spot_id=p.id and b.starts_at<p_end and b.ends_at>p_start)
 and not exists(select 1 from public.rotation_sessions r where r.spot_id=p.id and r.status='inside' and not r.billing_only)
 and not exists(select 1 from public.parking_sessions ps where ps.spot_id=p.id and ps.status='inside' and ps.reservation_id is distinct from p_exclude)
 and not exists(select 1 from public.reservations r where r.assigned_spot_id=p.id and r.id is distinct from p_exclude and r.entry_at<p_end and ((r.status in ('confirmed','checked_in') and (r.exit_at>p_start or (r.finished_at is null and not r.rotation_pending and exists(select 1 from public.parking_sessions ps where ps.reservation_id=r.id)))) or (r.status='pending_payment' and coalesce(r.expires_at,now()+interval '1 second')>now() and r.exit_at>p_start)))
 order by p.sort_order,p.code
$$;
revoke all on function private.parking_web_free_spots(uuid,timestamptz,timestamptz,uuid) from public,anon,authenticated;
create function private.parking_web_available(p_type uuid,p_start timestamptz,p_end timestamptz,p_exclude uuid default null) returns integer language sql stable security definer set search_path='' as $$
 with points as(select p_start t union select r.entry_at from public.reservations r where r.assigned_spot_id is null and r.entry_at>=p_start and r.entry_at<p_end union select b.starts_at from public.capacity_blocks b where b.active and b.spot_id is null and b.starts_at>=p_start and b.starts_at<p_end),
 demand as(select (select count(*) from public.reservations r where r.assigned_spot_id is null and r.vehicle_type_id=p_type and r.id is distinct from p_exclude and r.entry_at<=t and r.exit_at>t and (r.status in ('confirmed','checked_in') or (r.status='pending_payment' and coalesce(r.expires_at,now()+interval '1 second')>now())))+coalesce((select sum(b.blocked_spaces) from public.capacity_blocks b where b.active and b.spot_id is null and b.vehicle_type_id=p_type and b.starts_at<=t and b.ends_at>t),0) n from points)
 select greatest(0,least((select count(*) from private.parking_web_free_spots(p_type,p_start,p_end,p_exclude))-coalesce((select max(n) from demand),0),private.get_available_spaces(null,p_start,p_end,p_exclude)))::integer
$$;
revoke all on function private.parking_web_available(uuid,timestamptz,timestamptz,uuid) from public,anon,authenticated;

create function public.quote_public_parking(p_vehicle_type_code text,p_entry_at timestamptz,p_duration_days integer)
returns table(vehicle_type text,entry_at timestamptz,exit_at timestamptz,duration_days integer,price_eur numeric,available_spaces integer) language plpgsql stable security definer set search_path='' as $$
declare q record;v_type uuid;
begin
 if p_entry_at is null or p_duration_days is null then raise exception 'Fecha o duración no válidas';end if;
 select * into q from public.quote_parking(p_vehicle_type_code,p_entry_at,p_duration_days);
 select id into v_type from public.vehicle_types where code=upper(p_vehicle_type_code) and active;
 return query select q.vehicle_type,q.entry_at,q.exit_at,q.duration_days,q.price_eur,private.parking_web_available(v_type,q.entry_at,q.exit_at,null);
end $$;
revoke all on function public.quote_public_parking(text,timestamptz,integer) from public,anon,authenticated;
grant execute on function public.quote_public_parking(text,timestamptz,integer) to service_role;

create or replace function public.assign_web_reservation_spot() returns trigger language plpgsql security definer set search_path='' as $$
declare v_spot uuid;
begin
 if new.source<>'web' or new.status not in ('pending_payment','confirmed','checked_in') then return new;end if;
 -- Preserve existing confirmed bookings when only recording a payment, email or presence.
 if tg_op='UPDATE' and old.assigned_spot_id is not null and new.assigned_spot_id=old.assigned_spot_id and new.vehicle_type_id=old.vehicle_type_id and new.entry_at=old.entry_at and new.exit_at=old.exit_at then return new;end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('parking_inventory')::bigint);
 if private.parking_web_available(new.vehicle_type_id,new.entry_at,new.exit_at,new.id)<1 then raise exception 'No hay plazas disponibles para todo el intervalo solicitado';end if;
 select id into v_spot from private.parking_web_free_spots(new.vehicle_type_id,new.entry_at,new.exit_at,new.id) id limit 1;
 if v_spot is null then raise exception 'No hay plazas disponibles para todo el intervalo solicitado';end if;
 new.assigned_spot_id:=v_spot;return new;
end $$;
revoke all on function public.assign_web_reservation_spot() from public,anon,authenticated;

create or replace function public.prevent_overbooking() returns trigger language plpgsql security definer set search_path='' as $$
declare v_available integer;
begin
 if not(new.status in ('confirmed','checked_in') or (new.status='pending_payment' and coalesce(new.expires_at,now()+interval '1 second')>now())) then return new;end if;
 if tg_op='UPDATE' and new.vehicle_type_id=old.vehicle_type_id and new.entry_at=old.entry_at and new.exit_at=old.exit_at and old.status in ('confirmed','checked_in') then return new;end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('parking_inventory')::bigint);
 if new.source='web' then v_available:=private.parking_web_available(new.vehicle_type_id,new.entry_at,new.exit_at,case when tg_op='UPDATE' then old.id else null end);
 else v_available:=least(private.get_available_spaces(new.vehicle_type_id,new.entry_at,new.exit_at,case when tg_op='UPDATE' then old.id else null end),private.get_available_spaces(null,new.entry_at,new.exit_at,case when tg_op='UPDATE' then old.id else null end));end if;
 if coalesce(v_available,0)<1 then raise exception 'No hay plazas disponibles para todo el intervalo solicitado';end if;return new;
end $$;
revoke all on function public.prevent_overbooking() from public,anon,authenticated;

-- P-11 remains physically XXL but is offered for XL vehicles as explicitly requested.
create or replace function private.spot_accepts_vehicle(p_spot_id uuid,p_vehicle_type_id uuid) returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.parking_spots p where p.id=p_spot_id and p.active and p.inventory_state not in ('fixed','blocked') and (p.polyvalent or p.vehicle_type_id=p_vehicle_type_id or (p.code='P-11' and exists(select 1 from public.vehicle_types v where v.id=p_vehicle_type_id and v.code='XL'))))
$$;

-- The existing booking endpoint keeps its email workflow unchanged. Its preliminary
-- quote may include the explicitly compatible XXL P-11 offered to XL vehicles;
-- the INSERT trigger above always enforces the actual public subset atomically.
create or replace function public.quote_parking(p_vehicle_type_code text,p_entry_at timestamptz,p_duration_days integer)
returns table(vehicle_type text,entry_at timestamptz,exit_at timestamptz,duration_days integer,price_eur numeric,available_spaces integer)
language plpgsql stable security definer set search_path='' as $$
declare v_id uuid;v_exit timestamptz;v_price numeric(10,2);
begin
 if p_duration_days<1 or p_duration_days>24 then raise exception 'La duración debe estar entre 1 y 24 días';end if;
 select id into v_id from public.vehicle_types where code=upper(p_vehicle_type_code) and active=true;
 if v_id is null then raise exception 'Tipo de vehículo no válido';end if;
 v_exit:=p_entry_at+(p_duration_days::double precision*interval '24 hours');v_price:=private.stay_price(v_id,p_duration_days,p_entry_at);
 return query select upper(p_vehicle_type_code),p_entry_at,v_exit,p_duration_days,v_price::numeric,greatest(private.get_available_spaces(v_id,p_entry_at,v_exit,null),private.parking_web_available(v_id,p_entry_at,v_exit,null));
end $$;
