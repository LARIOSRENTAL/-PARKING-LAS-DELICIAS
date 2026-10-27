create or replace function public.parking_finish_outside_stay(p_reservation_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.reservations;s public.parking_sessions;result jsonb;begin
 perform public.rotation_operator_context();
 select * into r from public.reservations where id=p_reservation_id for update;
 if not found then raise exception 'Estancia no encontrada';end if;
 if r.finished_at is not null then return jsonb_build_object('already_finished',true);end if;
 select * into s from public.parking_sessions where reservation_id=r.id order by created_at desc limit 1 for update;
 if not found or s.status='inside' then raise exception 'El vehículo debe estar fuera para eliminar la estancia activa';end if;
 result:=public.parking_finish_stay(r.id);
 update public.reservations set status='completed',assigned_spot_id=null,finished_at=clock_timestamp(),finished_by=auth.uid(),updated_at=clock_timestamp() where id=r.id;
 insert into public.parking_events(session_id,event_type,event_at,old_spot_id,created_by,note)values(s.id,'note',clock_timestamp(),s.spot_id,auth.uid(),'FINALIZACIÓN DEFINITIVA · Retirada de estancias activas por confirmación del operador');
 return result||jsonb_build_object('early_release',false,'removed_from_active',true);
end;$$;
revoke all on function public.parking_finish_outside_stay(uuid) from public,anon;
grant execute on function public.parking_finish_outside_stay(uuid) to authenticated;
