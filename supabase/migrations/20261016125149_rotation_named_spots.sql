-- Every new physical rotation entry claims one real, shared inventory space.
-- Existing tickets remain unchanged and can still be checked out normally.
alter table public.rotation_sessions add column spot_id uuid references public.parking_spots(id),add column spot_code text;
create unique index rotation_one_vehicle_per_spot on public.rotation_sessions(spot_id) where status='inside' and not billing_only and spot_id is not null;

create function private.rotation_spot_accepts_tariff(p_spot_id uuid,p_tariff_code text) returns boolean language sql stable security definer set search_path=public,private,pg_temp as $$
 select exists(select 1 from public.parking_spots p join public.vehicle_types v on v.id=p.vehicle_type_id
 where p.id=p_spot_id and p.active and p.inventory_state='available'
 and (p.polyvalent or v.code=case upper(p_tariff_code) when 'COCHERA' then 'XL' when 'CAMION' then 'XXL' else upper(p_tariff_code) end));
$$;
create function private.rotation_spot_is_free(p_spot_id uuid,p_exclude_rotation uuid default null) returns boolean language sql stable security definer set search_path=public,private,pg_temp as $$
 select not exists(select 1 from public.rotation_sessions s where s.spot_id=p_spot_id and s.id is distinct from p_exclude_rotation and s.status='inside' and not s.billing_only)
 and not exists(select 1 from public.parking_sessions s where s.spot_id=p_spot_id and s.status='inside')
 and not exists(select 1 from public.capacity_blocks b where b.spot_id=p_spot_id and b.active and b.starts_at<=now() and b.ends_at>now())
 and not exists(select 1 from public.reservations r where r.assigned_spot_id=p_spot_id
   and ((r.status in('confirmed','checked_in') and r.finished_at is null and not r.rotation_pending)
      or (r.status='pending_payment' and r.expires_at>now()))
   and ((r.entry_at<=now() and r.exit_at>now()) or exists(select 1 from public.parking_sessions held where held.reservation_id=r.id)));
$$;
revoke all on function private.rotation_spot_accepts_tariff(uuid,text),private.rotation_spot_is_free(uuid,uuid) from public,anon,authenticated;

create function public.parking_available_rotation_spots(p_tariff_code text default null) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'zone',p.zone,'spot_class',p.spot_class,'vehicle_type',v.code,'polyvalent',p.polyvalent,'leaves_keys',p.zone is distinct from 'A') order by p.sort_order,p.code),'[]'::jsonb)
 from public.parking_spots p join public.vehicle_types v on v.id=p.vehicle_type_id
 where p.active and p.inventory_state='available' and (p_tariff_code is null or private.rotation_spot_accepts_tariff(p.id,p_tariff_code)) and private.rotation_spot_is_free(p.id));
end $$;
revoke all on function public.parking_available_rotation_spots(text) from public,anon;
grant execute on function public.parking_available_rotation_spots(text) to authenticated;

create function private.guard_rotation_spot_claim() returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare t_code text;z text;c text;
begin
 if new.status<>'inside' or new.billing_only then return new;end if;
 if new.spot_id is null then
   if tg_op='INSERT' then raise exception 'Selecciona una plaza real disponible';end if;
   return new; -- Historical tickets with no assigned spot retain their normal checkout.
 end if;
 select code,zone into c,z from public.parking_spots where id=new.spot_id for update;
 select code into t_code from public.rotation_tariffs where id=new.tariff_id;
 if not private.rotation_spot_accepts_tariff(new.spot_id,t_code) then raise exception 'La plaza no corresponde al tamaño seleccionado o no está disponible';end if;
 if not private.rotation_spot_is_free(new.spot_id,new.id) then raise exception 'La plaza ya está ocupada, bloqueada o reservada por una estancia';end if;
 new.spot_code:=c;new.key_number:=c;new.leaves_keys:=z is distinct from 'A';
 return new;
end $$;
revoke all on function private.guard_rotation_spot_claim() from public,anon,authenticated;
create trigger guard_rotation_shared_spot before insert or update of status,spot_id,tariff_id on public.rotation_sessions for each row execute function private.guard_rotation_spot_claim();

create or replace function public.rotation_check_in(p_tariff_code text,p_plate text,p_client_text text default null,p_authorized_text text default null,p_leaves_keys boolean default false,p_key_number text default null)
returns jsonb language plpgsql security definer set search_path=public,private,auth,pg_temp as $$
declare ctx jsonb;t public.rotation_tariffs;s public.rotation_sessions;p public.parking_spots;v_plate text:=regexp_replace(upper(coalesce(p_plate,'')),'[^A-Z0-9]','','g');v_capacity int;v_inside int;
begin
 ctx:=public.rotation_operator_context();
 if length(v_plate)<3 then raise exception 'Introduce una matrícula válida';end if;
 perform pg_advisory_xact_lock(hashtext('rotation_plate'),hashtext(v_plate));
 if exists(select 1 from public.rotation_sessions where status='inside' and regexp_replace(upper(plate),'[^A-Z0-9]','','g')=v_plate) then raise exception 'Este vehículo ya consta dentro de Rotación';end if;
 select * into t from public.rotation_tariffs where code=upper(trim(p_tariff_code)) and active;
 if not found then raise exception 'Tarifa de Rotación no encontrada';end if;
 select * into p from public.parking_spots where upper(regexp_replace(code,'[^A-Za-z0-9]','','g'))=upper(regexp_replace(coalesce(p_key_number,''),'[^A-Za-z0-9]','','g')) and active and inventory_state='available' for update;
 if not found then raise exception 'Escribe una plaza real disponible de su grupo, por ejemplo A-2 o J-18';end if;
 if not private.rotation_spot_accepts_tariff(p.id,t.code) then raise exception 'La plaza no corresponde al tamaño seleccionado';end if;
 if not private.rotation_spot_is_free(p.id) then raise exception 'La plaza ya está ocupada, bloqueada o reservada';end if;
 insert into public.rotation_sessions(tariff_id,plate,client_text,authorized_text,leaves_keys,key_number,spot_id,spot_code,entry_user_id,entry_employee_name,entry_shift_id,entry_shift_code,entry_shift_date,billing_only)
 values(t.id,v_plate,nullif(trim(p_client_text),''),nullif(trim(p_authorized_text),''),p.zone is distinct from 'A',p.code,p.id,p.code,(ctx->>'user_id')::uuid,ctx->>'employee_name',nullif(ctx->>'shift_id','')::uuid,nullif(ctx->>'shift_code','')::smallint,(ctx->>'shift_date')::date,false) returning * into s;
 select count(*) into v_capacity from public.parking_spots where private.rotation_spot_accepts_tariff(id,t.code);
 select count(*) into v_inside from public.rotation_sessions where tariff_id=t.id and status='inside' and not billing_only;
 return to_jsonb(s)||jsonb_build_object('ok',true,'tariff_code',t.code,'tariff_name',t.name,'capacity',v_capacity,'occupied_after',v_inside,'employee_name',ctx->>'employee_name','shift_code',ctx->>'shift_code','shift_date',ctx->>'shift_date','access_mode',ctx->>'access_mode');
end $$;

create or replace function public.rotation_update_active(p_session_id uuid,p_client_text text default null,p_authorized_text text default null,p_leaves_keys boolean default false,p_key_number text default null)
returns void language plpgsql security definer set search_path=public,private,auth,pg_temp as $$
declare s public.rotation_sessions;p public.parking_spots;t_code text;
begin
 perform public.rotation_operator_context();
 select * into s from public.rotation_sessions where id=p_session_id and status='inside' for update;
 if not found then raise exception 'Ticket de Rotación no encontrado o finalizado';end if;
 if s.billing_only then
   update public.rotation_sessions set client_text=nullif(trim(p_client_text),''),authorized_text=nullif(trim(p_authorized_text),''),updated_at=now() where id=s.id;return;
 end if;
 select * into p from public.parking_spots where upper(regexp_replace(code,'[^A-Za-z0-9]','','g'))=upper(regexp_replace(coalesce(p_key_number,''),'[^A-Za-z0-9]','','g')) and active and inventory_state='available' for update;
 if not found then raise exception 'Selecciona una plaza real disponible';end if;
 select code into t_code from public.rotation_tariffs where id=s.tariff_id;
 if not private.rotation_spot_accepts_tariff(p.id,t_code) then raise exception 'La plaza no corresponde al tamaño del vehículo';end if;
 update public.rotation_sessions set client_text=nullif(trim(p_client_text),''),authorized_text=nullif(trim(p_authorized_text),''),spot_id=p.id,spot_code=p.code,key_number=p.code,leaves_keys=p.zone is distinct from 'A',updated_at=now() where id=s.id;
end $$;

-- A stay cannot claim a space held by rotation, even through a stale client.
create function private.guard_stay_against_rotation() returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_spot uuid;
begin
 if tg_table_name='parking_sessions' then
   if new.status<>'inside' then return new;end if;v_spot:=new.spot_id;
 else
   if new.status not in('confirmed','checked_in','pending_payment') or new.finished_at is not null or new.rotation_pending then return new;end if;v_spot:=new.assigned_spot_id;
 end if;
 if v_spot is null then return new;end if;
 perform 1 from public.parking_spots where id=v_spot for update;
 if exists(select 1 from public.rotation_sessions where spot_id=v_spot and status='inside' and not billing_only) then raise exception 'La plaza está ocupada por un vehículo de Rotación';end if;
 return new;
end $$;
revoke all on function private.guard_stay_against_rotation() from public,anon,authenticated;
create trigger zz_guard_rotation_stay_session before insert or update of status,spot_id on public.parking_sessions for each row execute function private.guard_stay_against_rotation();
create trigger zz_guard_rotation_stay_reservation before insert or update of status,assigned_spot_id on public.reservations for each row execute function private.guard_stay_against_rotation();

-- Release the physical rotation claim inside the same transaction as conversion.
-- Any failure rolls back both the release and the new stay / voucher consumption.
do $migration$
declare d text;anchor text;
begin
 d:=pg_get_functiondef('public.parking_rotation_to_stay_with_vouchers(uuid,uuid,uuid,integer,text,text[])'::regprocedure);
 anchor:='r:=public.parking_create_stay_from_vouchers';
 if strpos(d,anchor)=0 then raise exception 'Unexpected voucher conversion definition';end if;
 d:=replace(d,anchor,'update public.rotation_sessions set status=''cancelled'' where id=s.id; '||anchor);execute d;
 d:=pg_get_functiondef('public.parking_rotation_to_stay(uuid,uuid,uuid,uuid,integer,text)'::regprocedure);
 anchor:='v_res:=public.create_hotel_paid_reservation';
 if strpos(d,anchor)=0 then raise exception 'Unexpected conversion definition';end if;
 d:=replace(d,anchor,'update public.rotation_sessions set status=''cancelled'' where id=s.id; '||anchor);execute d;
 d:=pg_get_functiondef('private.get_available_spaces(uuid,timestamp with time zone,timestamp with time zone,uuid)'::regprocedure);
 anchor:='and not exists(select 1 from public.parking_sessions s where s.spot_id=p.id';
 if strpos(d,anchor)=0 then raise exception 'Unexpected shared capacity definition';end if;
 d:=replace(d,anchor,'and not exists(select 1 from public.rotation_sessions rot where rot.spot_id=p.id and rot.status=''inside'' and not rot.billing_only) '||anchor);
 -- Older physical tickets have unknown positions; retain their capacity demand
 -- until an employee assigns the real spot or checks out the vehicle.
 anchor:=' available from points)';
 if strpos(d,anchor)=0 then raise exception 'Unexpected unassigned capacity definition';end if;
 d:=replace(d,anchor,$new$ - (select count(*) from public.rotation_sessions oldrot join public.rotation_tariffs ot on ot.id=oldrot.tariff_id where oldrot.status='inside' and not oldrot.billing_only and oldrot.spot_id is null and (p_vehicle_type_id is null or exists(select 1 from public.vehicle_types vt where vt.id=p_vehicle_type_id and vt.code=case ot.code when 'COCHERA' then 'XL' when 'CAMION' then 'XXL' else ot.code end))) available from points)$new$);execute d;
 d:=pg_get_functiondef('public.assign_web_reservation_spot()'::regprocedure);
 anchor:='and not exists(select 1 from public.parking_sessions ps where ps.spot_id=p.id';
 if strpos(d,anchor)=0 then raise exception 'Unexpected web allocation definition';end if;
 d:=replace(d,anchor,'and not exists(select 1 from public.rotation_sessions rot where rot.spot_id=p.id and rot.status=''inside'' and not rot.billing_only) '||anchor);execute d;
end $migration$;

create function private.guard_rotation_inventory_state() returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
begin
 if exists(select 1 from public.rotation_sessions where spot_id=new.id and status='inside' and not billing_only)
 and (not new.active or new.inventory_state<>'available' or new.vehicle_type_id is distinct from old.vehicle_type_id or new.polyvalent is distinct from old.polyvalent) then
   raise exception 'La plaza tiene un vehículo de Rotación dentro; cambia el vehículo de plaza antes';
 end if;
 return new;
end $$;
revoke all on function private.guard_rotation_inventory_state() from public,anon,authenticated;
create trigger guard_rotation_inventory before update on public.parking_spots for each row execute function private.guard_rotation_inventory_state();

revoke all on function public.rotation_check_in(text,text,text,text,boolean,text),public.rotation_update_active(uuid,text,text,boolean,text) from public,anon;
grant execute on function public.rotation_check_in(text,text,text,text,boolean,text),public.rotation_update_active(uuid,text,text,boolean,text) to authenticated;
