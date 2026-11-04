CREATE OR REPLACE FUNCTION public.record_parking_movement(p_reservation_id uuid, p_direction text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'auth', 'pg_temp'
AS $function$
declare
  v_now timestamptz := clock_timestamp();
  v_user uuid := auth.uid();
  v_res public.reservations%rowtype;
  v_session public.parking_sessions%rowtype;
  v_last_event text;
  v_direction text := upper(trim(coalesce(p_direction,'')));
begin
  if v_user is null or not private.is_staff() then
    raise exception 'Acceso no autorizado';
  end if;

  if v_direction not in ('IN','OUT') then
    raise exception 'Movimiento no válido';
  end if;

  select * into v_res
  from public.reservations
  where id = p_reservation_id
  for update;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  if v_res.status in ('cancelled','completed','expired') or v_res.finished_at is not null or v_res.rotation_pending then
    raise exception 'La reserva está cancelada';
  end if;

  if v_direction='IN' and v_now > v_res.exit_at and not exists(select 1 from public.parking_sessions where reservation_id=v_res.id) then
    raise exception 'La reserva no llegó a iniciarse dentro de su periodo previsto';
  end if;

  select * into v_session
  from public.parking_sessions
  where reservation_id = p_reservation_id
  order by created_at desc
  limit 1
  for update;

  if not found then
    if v_direction = 'OUT' then
      raise exception 'El vehículo ya está fuera';
    end if;

    insert into public.parking_sessions(
      reservation_id, vehicle_type_id, spot_id, plate, vehicle_make_model,
      customer_name, customer_phone, planned_entry_at, planned_exit_at,
      status, billing_mode, source, created_by
    )
    values(
      v_res.id, v_res.vehicle_type_id, v_res.assigned_spot_id, v_res.plate, v_res.vehicle_make_model,
      v_res.customer_name, v_res.customer_phone, v_res.entry_at, v_res.exit_at,
      'expected', 'reservation', 'reservation', v_user
    )
    returning * into v_session;
  end if;

  select e.event_type into v_last_event
  from public.parking_events e
  where e.session_id = v_session.id
    and e.event_type in ('check_in','check_out')
  order by e.event_at desc, e.id desc
  limit 1;

  if v_direction = 'IN' then
    if v_last_event = 'check_in' or v_session.status = 'inside' then
      raise exception 'El vehículo ya está dentro';
    end if;

    insert into public.parking_events(session_id,event_type,event_at,new_spot_id,created_by)
    values(v_session.id,'check_in',v_now,v_session.spot_id,v_user);

    update public.parking_sessions
      set status='inside',
          actual_entry_at=coalesce(actual_entry_at,v_now),
          actual_exit_at=null,
          updated_at=v_now
    where id=v_session.id;

    update public.reservations
      set status='checked_in', updated_at=v_now
    where id=v_res.id;
  else
    if coalesce(v_last_event,'') <> 'check_in' and v_session.status <> 'inside' then
      raise exception 'El vehículo ya está fuera';
    end if;

    insert into public.parking_events(session_id,event_type,event_at,old_spot_id,created_by)
    values(v_session.id,'check_out',v_now,v_session.spot_id,v_user);

    update public.parking_sessions
      set status='departed',
          actual_exit_at=v_now,
          updated_at=v_now
    where id=v_session.id;

    update public.reservations
      set status='confirmed',
        updated_at=v_now
    where id=v_res.id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'reservation_id', v_res.id,
    'direction', v_direction,
    'event_at', v_now
  );
end
$function$

