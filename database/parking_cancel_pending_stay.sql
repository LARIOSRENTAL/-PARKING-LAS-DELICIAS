create or replace function public.parking_cancel_pending_stay(p_reservation_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.reservations;ctx jsonb;begin
 ctx:=public.rotation_operator_context();
 select * into r from public.reservations where id=p_reservation_id for update;
 if not found then raise exception 'Reserva no encontrada';end if;
 if r.status='cancelled' then return jsonb_build_object('cancelled',true,'already_cancelled',true);end if;
 if r.status not in('pending_payment','confirmed') or exists(select 1 from public.parking_sessions where reservation_id=r.id) then raise exception 'Solo se pueden anular reservas sin entrada. Para una estancia iniciada utiliza Finalizar estancia';end if;
 update public.reservations set status='cancelled',assigned_spot_id=null,updated_at=clock_timestamp() where id=r.id;
 insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)values(nullif(ctx->>'shift_id','')::uuid,auth.uid(),'reservation_cancelled','reservation',r.id,jsonb_build_object('reference',r.reference,'plate',r.plate,'previous_status',r.status,'payment_status',r.payment_status,'reason','Anulación manual desde Reservas','payments_preserved',true));
 return jsonb_build_object('cancelled',true,'reservation_id',r.id,'payment_status',r.payment_status);
end;$$;
revoke all on function public.parking_cancel_pending_stay(uuid) from public,anon;
grant execute on function public.parking_cancel_pending_stay(uuid) to authenticated;
