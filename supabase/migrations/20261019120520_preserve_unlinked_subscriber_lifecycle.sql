-- Preserve old unverified labels during cancellation or reactivation.
-- Only an explicit assignment edit may resolve a new physical link.
create or replace function private.resolve_subscriber_spot() returns trigger language plpgsql security definer set search_path='' as $$
declare label text;sid uuid;
begin
 if tg_op='UPDATE' and new.parking_space_label is not distinct from old.parking_space_label and new.parking_spot_id is not distinct from old.parking_spot_id then
  sid:=old.parking_spot_id;
 else
 label:=regexp_replace(upper(coalesce(new.parking_space_label,'')),'[^A-Z0-9]','','g');
 label:=regexp_replace(label,'^JAULAN?','J');
 select p.id into sid from public.parking_spots p where p.active and p.inventory_state<>'legacy'
 and regexp_replace(upper(p.code),'[^A-Z0-9]','','g')=regexp_replace(label,'^([A-Z]+)0+([0-9])','\1\2');
 if label<>'' and sid is null and label !~ '^(A|C|MOTO|SALTOBONOC)$' then
  raise exception 'Plaza no reconocida. Selecciona un código del planning (por ejemplo J-13 o B-3)';
 end if;
 end if;
 new.parking_spot_id:=sid;
 if sid is not null then
  select code into new.parking_space_label from public.parking_spots where id=sid;
  -- Serialize assignments, deactivations and rotation claims on the same physical row.
  perform 1 from public.parking_spots where id=sid for update;
  if new.active and (tg_op='INSERT' or not old.active or old.parking_spot_id is distinct from sid) then
   if exists(select 1 from public.rotation_sessions where spot_id=sid and status='inside' and not billing_only)
   or exists(select 1 from public.parking_sessions where spot_id=sid and status='inside')
   or exists(select 1 from public.reservations where assigned_spot_id=sid and finished_at is null and status in ('confirmed','checked_in','pending_payment') and (exit_at>now() or status='checked_in'))
   then raise exception 'La plaza tiene una estancia o rotación asignada. Reubícala antes de asignar el abonado';end if;
  end if;
 end if;
 if tg_op='UPDATE' and old.parking_spot_id is not null and old.parking_spot_id is distinct from sid then
  perform 1 from public.parking_spots where id=old.parking_spot_id for update;
 end if;
 return new;
end$$;
