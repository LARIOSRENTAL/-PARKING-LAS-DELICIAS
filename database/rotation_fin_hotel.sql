-- Finalize a hotel-backed conversion atomically using the original rotation ticket.
create or replace function public.parking_finish_hotel_rotation(
 p_session_id uuid,p_vehicle_type_id uuid,p_spot_id uuid,p_days integer,p_model text,
 p_method text default 'hotel_voucher',p_codes text[] default '{}',
 p_difference_method text default 'cash',p_print_ticket boolean default false,
 p_commit boolean default false,p_expected_amount numeric default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.rotation_sessions;r public.reservations;result jsonb;
begin
 perform public.rotation_operator_context();
 select * into s from public.rotation_sessions where id=p_session_id for update;
 if not found then raise exception 'Ticket inexistente';end if;
 -- The session lock makes retries and simultaneous clicks return the same stay.
 if s.converted_reservation_id is not null then
  select * into r from public.reservations where id=s.converted_reservation_id;
  if r.finished_at is not null and r.status='completed' then
   return jsonb_build_object('id',r.id,'finished',true,'already_finished',true,'difference_amount',s.amount_eur);
  end if;
  raise exception 'Este ticket ya tiene una estancia activa. Finalízala desde Estancias';
 end if;
 if p_method is null or p_method not in ('hotel_voucher','hotel_voucher_old') then raise exception 'FIN HOTEL solo admite bonos de hotel';end if;
 if p_days is null or p_days<>coalesce(cardinality(p_codes),0) or p_days not between 1 and 24 then raise exception 'Indica un bono por cada día de estancia';end if;
 -- With one day per voucher, the existing quote bills only time after coverage
 -- up to the actual departure, never a future interval or a second ticket.
 result:=public.parking_convert_rotation_stay(p_session_id,p_vehicle_type_id,p_spot_id,p_days,p_model,p_method,p_codes,p_difference_method,p_print_ticket,p_commit,p_expected_amount);
 if not p_commit then return result||jsonb_build_object('finish_hotel',true);end if;
 perform public.record_parking_movement((result->>'id')::uuid,'OUT');
 update public.reservations set status='completed',assigned_spot_id=null,rotation_pending=false,
  finished_at=clock_timestamp(),finished_by=auth.uid(),updated_at=clock_timestamp()
 where id=(result->>'id')::uuid;
 return result||jsonb_build_object('finished',true,'already_finished',false);
end;$$;
revoke all on function public.parking_finish_hotel_rotation(uuid,uuid,uuid,integer,text,text,text[],text,boolean,boolean,numeric) from public,anon;
grant execute on function public.parking_finish_hotel_rotation(uuid,uuid,uuid,integer,text,text,text[],text,boolean,boolean,numeric) to authenticated;
