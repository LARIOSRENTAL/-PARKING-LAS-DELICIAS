-- Version matches the migration applied to the production database.
alter table public.reservations add column finished_at timestamptz,add column finished_by uuid;

-- Retain the production check-in, inventory and audit logic; change only expiry rules.
do $migration$
declare d text;old_text text;new_text text;
begin
 d:=pg_get_functiondef('public.record_parking_movement(uuid,text)'::regprocedure);
 old_text:=$old$  if v_direction='IN' and v_now > v_res.exit_at then
    raise exception 'La estancia ya ha finalizado';
  end if;$old$;
 if strpos(d,old_text)=0 then raise exception 'Unexpected movement expiry rule';end if;
 new_text:=$new$  if v_direction='IN' and v_now > v_res.exit_at and not exists(select 1 from public.parking_sessions where reservation_id=v_res.id) then
    raise exception 'La reserva no llegó a iniciarse dentro de su periodo previsto';
  end if;$new$;
 d:=replace(d,old_text,new_text);
 d:=replace(d,'if v_res.status = ''cancelled'' then','if v_res.status in (''cancelled'',''completed'',''expired'') or v_res.finished_at is not null or v_res.rotation_pending then');
 old_text:=$old$set status=case
          when v_now < v_res.exit_at then 'confirmed'
          else 'completed'
        end,$old$;
 if strpos(d,old_text)=0 then raise exception 'Unexpected temporary exit status rule';end if;
 d:=replace(d,old_text,'set status=''confirmed'',');execute d;

 d:=pg_get_functiondef('public.backoffice_check_out(uuid,timestamp with time zone)'::regprocedure);
 old_text:=$old$set status = case
      when p_actual_exit_at < r.exit_at then 'confirmed'
      else 'completed'
    end,$old$;
 if strpos(d,old_text)=0 then raise exception 'Unexpected checkout expiry rule';end if;
 d:=replace(d,old_text,'set status = ''confirmed'',');execute d;

 d:=pg_get_functiondef('public.backoffice_check_in(uuid,uuid,timestamp with time zone)'::regprocedure);
 if strpos(d,'if p_actual_entry_at > r.exit_at then')=0 then raise exception 'Unexpected check-in expiry rule';end if;
 d:=replace(d,'if p_actual_entry_at > r.exit_at then','if p_actual_entry_at > r.exit_at and not exists(select 1 from public.parking_sessions where reservation_id=r.id) then');
 d:=replace(d,'if r.status = ''cancelled'' then','if r.status in (''cancelled'',''completed'',''expired'') or r.finished_at is not null or r.rotation_pending then');
 d:=replace(d,'and rr.exit_at > p_actual_entry_at','and rr.finished_at is null and not rr.rotation_pending');execute d;

 d:=pg_get_functiondef('public.backoffice_move_spot(uuid,uuid)'::regprocedure);
 if strpos(d,'and rr.exit_at > now()')=0 then raise exception 'Unexpected move-space expiry rule';end if;
 d:=replace(d,'and rr.exit_at > now()','and rr.finished_at is null and not rr.rotation_pending');execute d;

 d:=pg_get_functiondef('public.transition_reservation_to_rotation(uuid)'::regprocedure);
 old_text:='v_ctx := public.rotation_operator_context();';
 if strpos(d,old_text)=0 then raise exception 'Unexpected rotation transition authorization';end if;
 d:=replace(d,old_text,old_text||$new$
  if current_setting('parking.manual_finish_id',true) is distinct from p_reservation_id::text then
    raise exception 'Pulsa Finalizar estancia para liberar la plaza y gestionar el tiempo excedido';
  end if;
$new$);execute d;
end $migration$;

-- Web reservations and capacity forecasts must retain the same occupied space.
do $migration$
declare d text;
begin
 d:=pg_get_functiondef('public.assign_web_reservation_spot()'::regprocedure);
 if strpos(d,'r.exit_at>new.entry_at')=0 then raise exception 'Unexpected web allocation overlap';end if;
 d:=replace(d,'r.exit_at>new.entry_at','(r.exit_at>new.entry_at or (r.finished_at is null and not r.rotation_pending and exists(select 1 from public.parking_sessions held where held.reservation_id=r.id)))');
 d:=replace(d,'(ps.planned_exit_at is null or ps.planned_exit_at>new.entry_at)','true');execute d;
 d:=pg_get_functiondef('private.get_available_spaces(uuid,timestamp with time zone,timestamp with time zone,uuid)'::regprocedure);
 if strpos(d,'r.exit_at>t')=0 then raise exception 'Unexpected availability overlap';end if;
 d:=replace(d,'r.exit_at>t','(r.exit_at>t or (r.finished_at is null and not r.rotation_pending and exists(select 1 from public.parking_sessions held where held.reservation_id=r.id)))');
 d:=replace(d,'(s.planned_exit_at is null or s.planned_exit_at>t)','true');execute d;
end $migration$;

-- Occupancy remains enforced in PostgreSQL even with an outdated browser.
create function private.guard_unfinished_stay_spot() returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_spot uuid;v_reservation uuid;
begin
 if tg_table_name='parking_sessions' then
  if new.status<>'inside' or new.spot_id is null then return new;end if;
  v_spot:=new.spot_id;v_reservation:=new.reservation_id;
 else
  if new.assigned_spot_id is null or new.status not in('confirmed','checked_in') or new.finished_at is not null or new.rotation_pending then return new;end if;
  v_spot:=new.assigned_spot_id;v_reservation:=new.id;
 end if;
 perform 1 from public.parking_spots where id=v_spot for update;
 if exists(select 1 from public.reservations r where r.id is distinct from v_reservation and r.assigned_spot_id=v_spot
  and r.status in('confirmed','checked_in') and r.finished_at is null and not r.rotation_pending
  and exists(select 1 from public.parking_sessions s where s.reservation_id=r.id)) then
  raise exception 'La plaza está reservada hasta pulsar Finalizar estancia, aunque el vehículo esté fuera';
 end if;
 return new;
end $$;
revoke all on function private.guard_unfinished_stay_spot() from public,anon,authenticated;
create trigger guard_unfinished_stay_session before insert or update of status,spot_id on public.parking_sessions for each row execute function private.guard_unfinished_stay_spot();
create trigger guard_unfinished_stay_reservation before insert or update of status,assigned_spot_id on public.reservations for each row execute function private.guard_unfinished_stay_spot();

create function public.parking_finish_stay(p_reservation_id uuid) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;r public.reservations;s public.parking_sessions;extra jsonb;v_now timestamptz:=clock_timestamp();
begin
 ctx:=public.rotation_operator_context();
 select * into r from public.reservations where id=p_reservation_id for update;
 if not found then raise exception 'Estancia no encontrada';end if;
 if r.finished_at is not null then return jsonb_build_object('already_finished',true,'reservation_id',r.id,'finished_at',r.finished_at);end if;
 if r.status not in('confirmed','checked_in') or r.rotation_pending then raise exception 'La estancia ya no está activa';end if;
 select * into s from public.parking_sessions where reservation_id=r.id order by created_at desc limit 1 for update;
 if not found then raise exception 'La estancia todavía no ha tenido ninguna entrada';end if;
 if s.spot_id is not null then perform 1 from public.parking_spots where id=s.spot_id for update;end if;
 if s.status='inside' then
  if v_now>r.exit_at then
   perform set_config('parking.manual_finish_id',r.id::text,true);
   extra:=public.transition_reservation_to_rotation(r.id);
  else
   perform public.record_parking_movement(r.id,'OUT');
  end if;
 end if;
 update public.reservations set status='completed',assigned_spot_id=null,finished_at=clock_timestamp(),finished_by=auth.uid(),updated_at=clock_timestamp() where id=r.id returning * into r;
 insert into public.parking_events(session_id,event_type,event_at,old_spot_id,created_by,note)
 values(s.id,'note',clock_timestamp(),s.spot_id,auth.uid(),'ESTANCIA FINALIZADA MANUALMENTE · Plaza liberada');
 return jsonb_build_object('already_finished',false,'reservation_id',r.id,'finished_at',r.finished_at,'rotation',extra);
end $$;
revoke all on function public.parking_finish_stay(uuid) from public,anon;
grant execute on function public.parking_finish_stay(uuid) to authenticated;
