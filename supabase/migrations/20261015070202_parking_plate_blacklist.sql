-- Staff-managed entry restrictions. Removing a restriction keeps its audit fields.
create table public.parking_plate_blacklist (
 plate text primary key check(plate ~ '^[A-Z0-9]{3,16}$'),
 observation text not null check(length(btrim(observation)) between 1 and 1000),
 active boolean not null default true,
 created_at timestamptz not null default clock_timestamp(),
 created_by uuid not null,
 updated_at timestamptz not null default clock_timestamp(),
 updated_by uuid not null
);
alter table public.parking_plate_blacklist enable row level security;
create policy blacklist_staff_read on public.parking_plate_blacklist for select to authenticated using(private.is_staff());
revoke all on public.parking_plate_blacklist from anon,authenticated;
grant select on public.parking_plate_blacklist to authenticated;

create function public.parking_check_plate_block(p_plate text) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select jsonb_build_object('plate',plate,'observation',observation) into v from public.parking_plate_blacklist where plate=regexp_replace(upper(coalesce(p_plate,'')),'[^A-Z0-9]','','g') and active;
 return v;
end $$;

create function public.parking_set_plate_block(p_plate text,p_observation text,p_active boolean default true) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;v_plate text:=regexp_replace(upper(coalesce(p_plate,'')),'[^A-Z0-9]','','g');v_note text:=btrim(coalesce(p_observation,''));v public.parking_plate_blacklist;
begin
 ctx:=public.rotation_operator_context();
 if v_plate !~ '^[A-Z0-9]{3,16}$' then raise exception 'Introduce una matrícula válida (de 3 a 16 caracteres)';end if;
 if length(v_note) not between 1 and 1000 then raise exception 'Indica una observación de hasta 1000 caracteres';end if;
 if p_active is null then raise exception 'Estado inválido';end if;
 perform pg_advisory_xact_lock(hashtextextended('blocked-plate:'||v_plate,0));
 insert into public.parking_plate_blacklist(plate,observation,active,created_by,updated_by)
 values(v_plate,v_note,p_active,auth.uid(),auth.uid()) on conflict(plate) do update set observation=excluded.observation,active=excluded.active,updated_by=excluded.updated_by,updated_at=clock_timestamp() returning * into v;
 return to_jsonb(v);
end $$;

create function private.prevent_blocked_parking_entry() returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_plate text:=regexp_replace(upper(coalesce(new.plate,'')),'[^A-Z0-9]','','g');v_note text;
begin
 if new.status<>'inside' then return new;end if;
 -- A pending overstay charge is not a new vehicle entry.
 if tg_table_name='rotation_sessions' then if new.billing_only then return new;end if;end if;
 if tg_op='UPDATE' then
  if old.status='inside' and regexp_replace(upper(coalesce(old.plate,'')),'[^A-Z0-9]','','g')=v_plate then return new;end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('blocked-plate:'||v_plate,0));
 select observation into v_note from public.parking_plate_blacklist where plate=v_plate and active;
 if found then raise exception 'ENTRADA BLOQUEADA · % · %. No emitir ticket ni dar entrada al vehículo.',v_plate,v_note;end if;
 return new;
end $$;
create trigger prevent_blocked_rotation_entry before insert or update on public.rotation_sessions for each row execute function private.prevent_blocked_parking_entry();
create trigger prevent_blocked_stay_entry before insert or update on public.parking_sessions for each row execute function private.prevent_blocked_parking_entry();
revoke all on function public.parking_check_plate_block(text),public.parking_set_plate_block(text,text,boolean) from public,anon;
grant execute on function public.parking_check_plate_block(text),public.parking_set_plate_block(text,text,boolean) to authenticated;
revoke all on function private.prevent_blocked_parking_entry() from public,anon,authenticated;
