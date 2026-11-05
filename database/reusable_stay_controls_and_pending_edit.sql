-- Reuse operational E controls without deleting cancelled reservations or fiscal history.
create table if not exists private.parking_available_stay_controls(
 control_number bigint primary key check(control_number>0),released_at timestamptz not null default clock_timestamp());
create table if not exists private.parking_stay_control_releases(
 id uuid primary key default gen_random_uuid(),reservation_id uuid not null,control_number bigint not null,original_reference text not null,
 reason text not null check(reason in('cancelled','hotel')),released_at timestamptz not null default clock_timestamp(),released_by uuid);
alter table private.parking_available_stay_controls enable row level security;
alter table private.parking_stay_control_releases enable row level security;
revoke all on private.parking_available_stay_controls,private.parking_stay_control_releases from public,anon,authenticated;

create or replace function private.take_stay_control()
returns text language plpgsql security invoker set search_path='' as $$
declare n bigint;
begin
 perform pg_advisory_xact_lock(hashtextextended('parking-stay-operational-control',0));
 loop
  delete from private.parking_available_stay_controls where control_number=(select min(control_number) from private.parking_available_stay_controls) returning control_number into n;
  if n is null then
   insert into private.parking_registration_counters(kind,last_number)values('E',1)
   on conflict(kind)do update set last_number=parking_registration_counters.last_number+1 returning last_number into n;
  end if;
  if not exists(select 1 from public.reservations where reference='E-'||n) then return 'E-'||n;end if;
 end loop;
end $$;
create or replace function private.release_stay_control(p_id uuid,p_reference text,p_reason text)
returns void language plpgsql security invoker set search_path='' as $$
declare n bigint;
begin
 if p_reference is null or p_reference!~'^E-[1-9][0-9]*$' then return;end if;
 n:=substring(p_reference from 3)::bigint;
 perform pg_advisory_xact_lock(hashtextextended('parking-stay-operational-control',0));
 insert into private.parking_stay_control_releases(reservation_id,control_number,original_reference,reason,released_by)
 values(p_id,n,p_reference,p_reason,auth.uid());
 insert into private.parking_available_stay_controls(control_number)values(n)on conflict do nothing;
end $$;
create or replace function private.number_parking_stay()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' then
  if new.status='cancelled' then new.reference:='ANULADA-'||new.id;
  elsif new.payment_method in('hotel_voucher','hotel_voucher_old') then new.reference:='BH-'||new.id;
  else new.reference:=private.take_stay_control();end if;
 elsif new.status='cancelled' then
  if old.reference~'^E-[1-9][0-9]*$' then
   perform private.release_stay_control(old.id,old.reference,'cancelled');
   new.reference:='ANULADA-'||old.reference||'-'||new.id;
  end if;
 elsif new.payment_method in('hotel_voucher','hotel_voucher_old') then
  if old.reference~'^E-[1-9][0-9]*$' then
   perform private.release_stay_control(old.id,old.reference,'hotel');new.reference:='BH-'||new.id;
  end if;
 elsif old.reference like 'BH-%' or old.reference like 'ANULADA-%' then new.reference:=private.take_stay_control();
 end if;
 return new;
end $$;
drop trigger if exists number_parking_stay on public.reservations;
create trigger number_parking_stay before insert or update of status,payment_method on public.reservations for each row execute function private.number_parking_stay();
revoke all on function private.take_stay_control(),private.release_stay_control(uuid,text,text),private.number_parking_stay() from public,anon,authenticated;

create or replace function public.parking_edit_pending_stay(p_reservation_id uuid,p_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.reservations;changed public.reservations;tid uuid:=(p_data->>'vehicle_type_id')::uuid;
 v_plate text:=upper(btrim(coalesce(p_data->>'plate','')));v_model text:=upper(btrim(coalesce(p_data->>'model','')));price numeric;different_type boolean;
begin
 perform public.rotation_operator_context();
 select * into r from public.reservations where id=p_reservation_id for update;
 if not found or r.status not in('confirmed','pending_payment') or r.payment_status='paid' or r.finished_at is not null or exists(select 1 from public.parking_sessions where reservation_id=r.id) then raise exception 'La reserva ya no está pendiente. Actualiza el listado para editarla';end if;
 if r.updated_at is distinct from (p_data->>'expected_updated_at')::timestamptz then raise exception 'La reserva ha cambiado. Abre de nuevo la ficha antes de guardar';end if;
 if length(v_plate)<3 or length(v_plate)>30 or length(v_model)<1 or length(v_model)>200 then raise exception 'Completa matrícula y marca/modelo';end if;
 price:=private.stay_price(tid,r.duration_days,r.entry_at);if price is null then raise exception 'No existe una tarifa para esta categoría y duración';end if;
 different_type:=tid is distinct from r.vehicle_type_id;
 update public.reservations set vehicle_type_id=tid,plate=v_plate,vehicle_make_model=v_model,
 customer_name=nullif(btrim(p_data->>'name'),''),customer_phone=nullif(btrim(p_data->>'phone'),''),customer_email=nullif(btrim(p_data->>'email'),''),notes=nullif(btrim(p_data->>'notes'),''),
 amount_eur=case when different_type then price else r.amount_eur end,manual_price_override=case when different_type then false else r.manual_price_override end,
 assigned_spot_id=case when r.assigned_spot_id is not null and not private.spot_accepts_vehicle(r.assigned_spot_id,tid) then null else r.assigned_spot_id end,
 updated_at=clock_timestamp() where id=r.id returning * into changed;
 return to_jsonb(changed);
end $$;
revoke all on function public.parking_edit_pending_stay(uuid,jsonb) from public,anon;
grant execute on function public.parking_edit_pending_stay(uuid,jsonb) to authenticated;
create or replace view public.reservation_backoffice as
 WITH last_movement AS (
         SELECT DISTINCT ON (s.reservation_id) s.reservation_id,
            e.event_type,
            e.event_at
           FROM parking_sessions s
             JOIN parking_events e ON e.session_id = s.id
          WHERE s.reservation_id IS NOT NULL AND (e.event_type = ANY (ARRAY['check_in'::text, 'check_out'::text]))
          ORDER BY s.reservation_id, e.event_at DESC, e.id DESC
        )
 SELECT r.id,
    r.reference,
    r.vehicle_type_id,
    vt.code AS vehicle_type_code,
    vt.name AS vehicle_type_name,
    r.entry_at,
    r.exit_at,
    r.duration_days,
    r.customer_name,
    r.customer_email,
    r.customer_phone,
    r.plate,
    r.vehicle_make_model,
    r.status,
    r.payment_status,
    r.amount_eur,
    r.source,
    r.notes,
    r.created_at,
    r.updated_at,
    0::numeric(8,2) AS overstay_rate_hour_eur,
    0::bigint AS overstay_minutes,
    0::numeric AS overstay_total_eur,
    0::numeric AS overstay_due_eur,
    NULL::timestamp with time zone AS overstay_paid_at,
    0::numeric(10,2) AS overstay_paid_amount_eur,
        CASE
            WHEN lm.event_type = 'check_in'::text THEN 'DENTRO'::text
            ELSE 'FUERA'::text
        END AS vehicle_presence,
    lm.event_at AS last_movement_at,
        CASE
            WHEN r.status = 'cancelled'::text THEN 'finished'::text
            WHEN r.rotation_pending THEN 'rotation_pending'::text
            WHEN lm.event_type = 'check_in'::text AND clock_timestamp() > r.exit_at THEN 'overdue'::text
            WHEN (r.status <> ALL (ARRAY['completed'::text, 'cancelled'::text])) AND clock_timestamp() >= (r.exit_at - '03:00:00'::interval) AND clock_timestamp() <= r.exit_at THEN 'due_soon'::text
            ELSE 'normal'::text
        END AS attention_state,
    r.assigned_spot_id,
    r.payment_method,
    r.tariff_amount_eur,
    r.manual_price_override,
    r.rotation_pending,
    r.rotation_session_id,
    CASE WHEN r.payment_method='hotel_voucher' THEN coalesce((select string_agg(coalesce(v.number::text,v.code),', ' order by v.number) from public.parking_hotel_vouchers v where v.redeemed_reservation_id=r.id),r.reference)
    WHEN r.payment_method='hotel_voucher_old' THEN coalesce((select string_agg(v.hotel_voucher_number,', ' order by v.day_number) from public.parking_legacy_hotel_vouchers v where v.reservation_id=r.id),r.reference)
    ELSE r.reference END as control_reference
   FROM reservations r
     JOIN vehicle_types vt ON vt.id = r.vehicle_type_id
     LEFT JOIN last_movement lm ON lm.reservation_id = r.id;
