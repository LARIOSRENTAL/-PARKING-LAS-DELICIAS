CREATE OR REPLACE FUNCTION private.parking_web_available(p_type uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_exclude uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with points as(select p_start t union select r.entry_at from public.reservations r where r.assigned_spot_id is null and r.entry_at>=p_start and r.entry_at<p_end union select b.starts_at from public.capacity_blocks b where b.active and b.spot_id is null and b.starts_at>=p_start and b.starts_at<p_end),
 demand as(select (select count(*) from public.reservations r where r.assigned_spot_id is null and r.vehicle_type_id=p_type and r.id is distinct from p_exclude and r.entry_at<=t and r.exit_at>t and (r.status in ('confirmed','checked_in') or (r.status='pending_payment' and coalesce(r.expires_at,now()+interval '1 second')>now())))+coalesce((select sum(b.blocked_spaces) from public.capacity_blocks b where b.active and b.spot_id is null and b.vehicle_type_id=p_type and b.starts_at<=t and b.ends_at>t),0) n from points)
 select case
   -- Semana Santa de Málaga 2027. La salida y la reapertura pueden coincidir con los límites.
   when p_start < timestamptz '2027-03-26 17:00 Europe/Madrid'
    and p_end > timestamptz '2027-03-24 17:00 Europe/Madrid' then 0
   else greatest(0,least((select count(*) from private.parking_web_free_spots(p_type,p_start,p_end,p_exclude))-coalesce((select max(n) from demand),0),private.get_available_spaces(null,p_start,p_end,p_exclude)))::integer
 end
$function$;
