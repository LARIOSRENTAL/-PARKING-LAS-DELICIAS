CREATE OR REPLACE FUNCTION public.log_staff_activity_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'auth', 'pg_temp'
AS $function$
declare
  v_user uuid := auth.uid();
  v_shift uuid;
  v_action text;
  v_id uuid;
  v_entity_type text := tg_table_name;
  v_details jsonb := '{}'::jsonb;
begin
  if v_user is null or not private.is_staff() then
    return coalesce(new,old);
  end if;

  select id into v_shift
  from public.staff_shifts
  where user_id=v_user and closed_at is null
  order by opened_at desc
  limit 1;

  if v_shift is null then
    return coalesce(new,old);
  end if;

  if tg_table_name='reservations' then
    v_id := coalesce(new.id,old.id);
    v_action := case when tg_op='INSERT' then 'reservation_created' else 'reservation_updated' end;
    v_details := jsonb_build_object(
      'reference',coalesce(new.reference,old.reference),
      'plate',coalesce(new.plate,old.plate),
      'status',coalesce(new.status,old.status),
      'amount_eur',coalesce(new.amount_eur,old.amount_eur)
    );
  elsif tg_table_name='parking_events' then
    v_id := coalesce(new.session_id,old.session_id);
    v_entity_type := 'parking_sessions';
    v_action := 'parking_'||coalesce(new.event_type,old.event_type);
    v_details := jsonb_build_object(
      'event_id',coalesce(new.id,old.id),
      'session_id',coalesce(new.session_id,old.session_id),
      'event_at',coalesce(new.event_at,old.event_at)
    );
  elsif tg_table_name='capacity_blocks' then
    v_id := coalesce(new.id,old.id);
    v_action := case
      when tg_op='INSERT' then 'spot_block_created'
      when coalesce(new.active,false)=false and coalesce(old.active,false)=true then 'spot_block_removed'
      else 'spot_block_updated'
    end;
    v_details := jsonb_build_object(
      'spot_id',coalesce(new.spot_id,old.spot_id),
      'blocked_spaces',coalesce(new.blocked_spaces,old.blocked_spaces)
    );
  else
    return coalesce(new,old);
  end if;

  insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)
  values(v_shift,v_user,v_action,v_entity_type,v_id,v_details);

  return coalesce(new,old);
end
$function$;
