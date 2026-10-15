CREATE OR REPLACE FUNCTION public.extend_hotel_paid_reservation(p_reservation_id uuid, p_new_days integer, p_hotel_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_r public.reservations; v_old_days integer;v_add integer;v_available integer;
begin
 if not private.is_staff() then raise exception 'Acceso no autorizado';end if;
 select * into v_r from public.reservations where id=p_reservation_id for update;
 if not found then raise exception 'Reserva inexistente';end if;
 if v_r.status in ('cancelled','completed','expired') then raise exception 'No se puede ampliar una reserva finalizada';end if;
 if p_new_days<=v_r.duration_days or p_new_days>24 then raise exception 'Introduce una duración mayor y hasta 24 días';end if;
 v_add:=p_new_days-v_r.duration_days;
 perform 1 from public.parking_hotels where id=p_hotel_id and active=true for update;
 if not found then raise exception 'Hotel no válido';end if;
 select available_days into v_available from public.parking_hotel_balances where id=p_hotel_id;
 if v_available<v_add then raise exception 'Bonos insuficientes: quedan % días',v_available;end if;
 if v_r.hotel_id is distinct from p_hotel_id and v_r.hotel_id is not null then raise exception 'La estancia ya está asociada a otro hotel';end if;
 insert into public.parking_hotel_redemptions(reservation_id,hotel_id,days) values(p_reservation_id,p_hotel_id,v_add)
 on conflict(reservation_id) do update set days=public.parking_hotel_redemptions.days+excluded.days;
 update public.reservations set duration_days=p_new_days,exit_at=v_r.entry_at+(p_new_days || ' days')::interval,hotel_id=p_hotel_id,payment_method='hotel_voucher',payment_status='paid',amount_eur=0,updated_at=now() where id=p_reservation_id;
 return jsonb_build_object('added_days',v_add,'remaining',v_available-v_add);
end $function$

