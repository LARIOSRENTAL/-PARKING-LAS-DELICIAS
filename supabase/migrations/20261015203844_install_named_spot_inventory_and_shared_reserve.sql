alter table public.parking_spots add column spot_class text not null default 'ESTÁNDAR', add column inventory_state text not null default 'available' check(inventory_state in ('available','fixed','blocked','legacy')), add column polyvalent boolean not null default false;
-- Existing generic codes are retained for history and existing assignments only.
update public.parking_spots p set inventory_state='legacy', active=exists(select 1 from public.reservations r where r.assigned_spot_id=p.id and r.status in ('confirmed','checked_in','pending_payment')) or exists(select 1 from public.parking_sessions s where s.spot_id=p.id and s.status='inside');
insert into public.parking_spots(code,zone,spot_class,inventory_state,polyvalent,vehicle_type_id,sort_order)
select x.code,x.zone,x.cls,x.state,x.poly,v.id,x.ord from (values
('J-1','J','XL','fixed',false,'XL',1),
('J-2','J','XL','blocked',false,'XL',2),
('J-3','J','XL','blocked',false,'XL',3),
('J-4','J','XL','blocked',false,'XL',4),
('J-5','J','XL','available',false,'XL',5),
('J-6','J','XL','available',false,'XL',6),
('J-7','J','XL','fixed',false,'XL',7),
('J-8','J','XL','available',false,'XL',8),
('J-9','J','XL','available',false,'XL',9),
('J-10','J','XL','available',false,'XL',10),
('J-11','J','XL','available',false,'XL',11),
('J-12','J','XL','available',false,'XL',12),
('J-13','J','XL','fixed',false,'XL',13),
('J-14','J','XL','available',false,'XL',14),
('J-15','J','XL','available',false,'XL',15),
('J-16','J','XL','available',false,'XL',16),
('J-17','J','XL','available',false,'XL',17),
('J-18','J','XL','available',false,'XL',18),
('J-19','J','XL','available',false,'XL',19),
('J-20','J','XL','available',false,'XL',20),
('J-21','J','XL','available',false,'XL',21),
('J-22','J','XL','fixed',false,'XL',22),
('J-23','J','XL','available',false,'XL',23),
('J-24','J','XL','available',false,'XL',24),
('J-25','J','XL','available',false,'XL',25),
('J-26','J','XL','fixed',false,'XL',26),
('J-27','J','XL','blocked',false,'XL',27),
('J-28','J','XL','blocked',false,'XL',28),
('J-29','J','XL','available',false,'XL',29),
('J-30','J','XL','available',false,'XL',30),
('J-31','J','XL','available',false,'XL',31),
('J-32','J','XL','available',false,'XL',32),
('J-33','J','XL','available',false,'XL',33),
('J-34','J','XL','available',false,'XL',34),
('J-35','J','XL','available',false,'XL',35),
('J-36','J','XL','available',false,'XL',36),
('J-37','J','XL','fixed',false,'XL',37),
('J-38','J','XL','blocked',false,'XL',38),
('J-39','J','XL','fixed',false,'XL',39),
('J-40','J','XL','available',false,'XL',40),
('J-41','J','XL','fixed',false,'XL',41),
('J-42','J','XL','available',false,'XL',42),
('J-43','J','PEQUEÑO-XL','available',false,'XL',43),
('J-44','J','XL','fixed',false,'XL',44),
('J-45','J','XL','blocked',false,'XL',45),
('J-46','J','PEQUEÑO-XL','available',false,'XL',46),
('J-47','J','XL','available',false,'XL',47),
('J-48','J','XL','available',false,'XL',48),
('J-49','J','XL','available',false,'XL',49),
('J-50','J','XL','available',false,'XL',50),
('J-51','J','XL','available',false,'XL',51),
('J-52','J','XL','available',false,'XL',52),
('J-53','J','XL','available',false,'XL',53),
('J-54','J','XL','fixed',false,'XL',54),
('J-55','J','XL','available',false,'XL',55),
('J-56','J','XL','available',false,'XL',56),
('J-57','J','XL','available',false,'XL',57),
('J-58','J','XL','available',false,'XL',58),
('J-59','J','XL','available',false,'XL',59),
('J-60','J','XL','available',false,'XL',60),
('J-61','J','XL','fixed',false,'XL',61),
('J-62','J','XL','fixed',false,'XL',62),
('B-3','B','XL','fixed',false,'XL',63),
('B-4','B','XL','fixed',false,'XL',64),
('B-5','B','XL','fixed',false,'XL',65),
('B-6','B','XL','fixed',false,'XL',66),
('B-7','B','XL','fixed',false,'XL',67),
('B-8','B','XL','fixed',false,'XL',68),
('B-9','B','XL','fixed',false,'XL',69),
('B-10','B','XL','fixed',false,'XL',70),
('B-11','B','XL','fixed',false,'XL',71),
('B-12','B','XL','fixed',false,'XL',72),
('B-13','B','XL','fixed',false,'XL',73),
('B-14','B','PEQUEÑO-XL','available',false,'XL',74),
('B-15','B','PEQUEÑO-XL','available',false,'XL',75),
('B-16','B','XL','fixed',false,'XL',76),
('B-17','B','XL','fixed',false,'XL',77),
('B-18','B','XL','fixed',false,'XL',78),
('B-19','B','XL','fixed',false,'XL',79),
('B-20','B','XL','available',false,'XL',80),
('B-21','B','XL','available',false,'XL',81),
('B-22','B','PEQUEÑO-XL','available',false,'XL',82),
('B-23','B','PEQUEÑO-XL','available',false,'XL',83),
('B-24','B','PEQUEÑO-XL','available',false,'XL',84),
('B-25','B','PEQUEÑO-XL','available',false,'XL',85),
('B-26','B','XL','fixed',false,'XL',86),
('B-27','B','XL','fixed',false,'XL',87),
('B-28','B','XL','fixed',false,'XL',88),
('B-29','B','XL','fixed',false,'XL',89),
('B-30','B','XL','available',false,'XL',90),
('B-31','B','XL','fixed',false,'XL',91),
('B-32','B','XL','fixed',false,'XL',92),
('B-33','B','XL','fixed',false,'XL',93),
('B-34','B','XL','fixed',false,'XL',94),
('B-35','B','XL','fixed',false,'XL',95),
('B-36','B','XL','fixed',false,'XL',96),
('B-37','B','XXL','available',false,'XXL',97),
('B-38','B','XXL','available',false,'XXL',98),
('B-39','B','PEQUEÑO-XL','available',false,'XL',99),
('B-40','B','XXL','available',false,'XXL',100),
('B-41','B','XXL','available',false,'XXL',101),
('B-42','B','XL','available',false,'XL',102),
('B-43','B','XL','available',false,'XL',103),
('B-44','B','XL','fixed',false,'XL',104),
('C-2','C','XL','available',false,'XL',105),
('C-3','C','XL','fixed',false,'XL',106),
('C-4','C','XL','fixed',false,'XL',107),
('C-5','C','PEQUEÑO-XL','available',false,'XL',108),
('C-6','C','XL','fixed',false,'XL',109),
('C-7','C','PEQUEÑO-XL','available',false,'XL',110),
('C-8','C','XL','fixed',false,'XL',111),
('C-9','C','XL','fixed',false,'XL',112),
('C-10','C','XL','blocked',false,'XL',113),
('C-11','C','XL','fixed',false,'XL',114),
('C-12','C','XL','fixed',false,'XL',115),
('C-13','C','XL','fixed',false,'XL',116),
('C-14','C','XL','fixed',false,'XL',117),
('C-15','C','XL','fixed',false,'XL',118),
('C-16','C','XL','fixed',false,'XL',119),
('C-17','C','XL','fixed',false,'XL',120),
('C-18','C','XL','fixed',false,'XL',121),
('C-19','C','XL','fixed',false,'XL',122),
('C-20','C','XL','fixed',false,'XL',123),
('C-21','C','PEQUEÑO-XL','available',false,'XL',124),
('C-22','C','XL','fixed',false,'XL',125),
('C-23','C','PEQUEÑO-XL','available',false,'XL',126),
('C-24','C','XL','fixed',false,'XL',127),
('C-25','C','XL','fixed',false,'XL',128),
('C-26','C','XL','fixed',false,'XL',129),
('C-27','C','XL','fixed',false,'XL',130),
('C-28','C','XL','fixed',false,'XL',131),
('P-1','P','XL','available',false,'XL',132),
('P-2','P','XL','available',false,'XL',133),
('P-3','P','XL','fixed',false,'XL',134),
('P-4','P','XL','fixed',false,'XL',135),
('P-5','P','XL','available',false,'XL',136),
('P-6','P','XL','fixed',false,'XL',137),
('P-7','P','PEQUEÑO-XL','available',false,'XL',138),
('P-8','P','XL','fixed',false,'XL',139),
('P-9','P','PEQUEÑO-XL','available',false,'XL',140),
('P-10','P','XL','fixed',false,'XL',141),
('P-11','P','XXL','available',false,'XXL',142),
('M-1','M','ESTÁNDAR','available',false,'TURISMO',143),
('M-2','M','ESTÁNDAR','available',false,'TURISMO',144),
('M-3','M','ESTÁNDAR','available',false,'TURISMO',145),
('M-4','M','ESTÁNDAR','available',false,'TURISMO',146),
('M-5','M','ESTÁNDAR','available',false,'TURISMO',147),
('M-6','M','ESTÁNDAR','available',false,'TURISMO',148),
('M-7','M','ESTÁNDAR','available',false,'TURISMO',149),
('M-8','M','ESTÁNDAR','available',false,'TURISMO',150),
('A-1','A','ESTÁNDAR','fixed',false,'TURISMO',151),
('A-2','A','PEQUEÑO','available',false,'TURISMO',152),
('A-3','A','PEQUEÑO','available',false,'TURISMO',153),
('A-4','A','PEQUEÑO','available',false,'TURISMO',154),
('A-5','A','PEQUEÑO','available',false,'TURISMO',155),
('A-6','A','ESTÁNDAR','available',false,'TURISMO',156),
('A-7','A','ESTÁNDAR','available',false,'TURISMO',157),
('A-8','A','ESTÁNDAR','available',false,'TURISMO',158),
('A-9','A','ESTÁNDAR','available',false,'TURISMO',159),
('A-10','A','ESTÁNDAR','available',false,'TURISMO',160),
('A-11','A','ESTÁNDAR','available',false,'TURISMO',161),
('A-12','A','ESTÁNDAR','available',false,'TURISMO',162),
('A-13','A','ESTÁNDAR','available',false,'TURISMO',163),
('A-14','A','ESTÁNDAR','available',false,'TURISMO',164),
('A-15','A','ESTÁNDAR','available',false,'TURISMO',165),
('A-16','A','ESTÁNDAR','available',false,'TURISMO',166),
('A-17','A','ESTÁNDAR','available',false,'TURISMO',167),
('A-18','A','ESTÁNDAR','available',false,'TURISMO',168),
('A-19','A','ESTÁNDAR','available',false,'TURISMO',169),
('A-20','A','ESTÁNDAR','available',false,'TURISMO',170),
('A-21','A','ESTÁNDAR','available',false,'TURISMO',171),
('A-22','A','ESTÁNDAR','available',false,'TURISMO',172),
('A-23','A','ESTÁNDAR','available',false,'TURISMO',173),
('A-24','A','ESTÁNDAR','available',false,'TURISMO',174),
('A-25','A','ESTÁNDAR','available',false,'TURISMO',175),
('A-26','A','ESTÁNDAR','available',false,'TURISMO',176),
('A-27','A','ESTÁNDAR','available',false,'TURISMO',177),
('A-28','A','ESTÁNDAR','available',false,'TURISMO',178),
('A-29','A','ESTÁNDAR','available',false,'TURISMO',179),
('A-30','A','ESTÁNDAR','available',false,'TURISMO',180),
('A-31','A','ESTÁNDAR','available',false,'TURISMO',181),
('A-32','A','ESTÁNDAR','available',false,'TURISMO',182),
('A-33','A','ESTÁNDAR','available',false,'TURISMO',183),
('A-34','A','ESTÁNDAR','available',false,'TURISMO',184),
('A-35','A','ESTÁNDAR','available',false,'TURISMO',185),
('A-36','A','ESTÁNDAR','available',false,'TURISMO',186),
('A-37','A','ESTÁNDAR','available',false,'TURISMO',187),
('LL-4','LL','ESTÁNDAR','available',false,'TURISMO',188),
('LL-5','LL','ESTÁNDAR','available',false,'TURISMO',189),
('LL-6','LL','ESTÁNDAR','available',false,'TURISMO',190),
('LL-39','LL','ESTÁNDAR','available',false,'TURISMO',191),
('LL-40','LL','ESTÁNDAR','available',false,'TURISMO',192),
('LL-41','LL','ESTÁNDAR','available',false,'TURISMO',193),
('LL-42','LL','ESTÁNDAR','available',false,'TURISMO',194),
('LL-44','LL','ESTÁNDAR','available',false,'TURISMO',195),
('LL-45','LL','ESTÁNDAR','available',false,'TURISMO',196),
('LL-46','LL','ESTÁNDAR','available',false,'TURISMO',197),
('LL-47','LL','ESTÁNDAR','available',false,'TURISMO',198),
('LL-71','LL','ESTÁNDAR','available',false,'TURISMO',199),
('LL-72','LL','ESTÁNDAR','available',false,'TURISMO',200),
('LL-73','LL','ESTÁNDAR','available',false,'TURISMO',201),
('LL-74','LL','ESTÁNDAR','available',false,'TURISMO',202),
('LL-75','LL','ESTÁNDAR','available',false,'TURISMO',203),
('LL-76','LL','ESTÁNDAR','available',false,'TURISMO',204),
('LL-77','LL','ESTÁNDAR','available',false,'TURISMO',205),
('LL-90','LL','ESTÁNDAR','available',false,'TURISMO',206),
('LL-91','LL','ESTÁNDAR','available',false,'TURISMO',207),
('LL-92','LL','ESTÁNDAR','available',false,'TURISMO',208),
('LL-93','LL','ESTÁNDAR','available',false,'TURISMO',209),
('LL-94','LL','ESTÁNDAR','available',false,'TURISMO',210),
('LL-103','LL','ESTÁNDAR','available',false,'TURISMO',211),
('LL-104','LL','ESTÁNDAR','available',false,'TURISMO',212),
('LL-105','LL','ESTÁNDAR','available',false,'TURISMO',213),
('MOTO 1','MOTO','MOTO','fixed',false,'MOTO',214),
('MOTO 2','MOTO','MOTO','fixed',false,'MOTO',215),
('MOTO 3','MOTO','MOTO','fixed',false,'MOTO',216),
('MOTO 4','MOTO','MOTO','available',false,'MOTO',217),
('MOTO 5','MOTO','MOTO','available',false,'MOTO',218),
('RESERVA-01','RESERVA','POLIVALENTE','available',true,'XL',219),
('RESERVA-02','RESERVA','POLIVALENTE','available',true,'XL',220),
('RESERVA-03','RESERVA','POLIVALENTE','available',true,'XL',221),
('RESERVA-04','RESERVA','POLIVALENTE','available',true,'XL',222),
('RESERVA-05','RESERVA','POLIVALENTE','available',true,'XL',223),
('RESERVA-06','RESERVA','POLIVALENTE','available',true,'XL',224),
('RESERVA-07','RESERVA','POLIVALENTE','available',true,'XL',225),
('RESERVA-08','RESERVA','POLIVALENTE','available',true,'XL',226),
('RESERVA-09','RESERVA','POLIVALENTE','available',true,'XL',227),
('RESERVA-10','RESERVA','POLIVALENTE','available',true,'XL',228),
('RESERVA-11','RESERVA','POLIVALENTE','available',true,'XL',229),
('RESERVA-12','RESERVA','POLIVALENTE','available',true,'XL',230),
('RESERVA-13','RESERVA','POLIVALENTE','available',true,'XL',231),
('RESERVA-14','RESERVA','POLIVALENTE','available',true,'XL',232),
('RESERVA-15','RESERVA','POLIVALENTE','available',true,'XL',233),
('RESERVA-16','RESERVA','POLIVALENTE','available',true,'XL',234),
('RESERVA-17','RESERVA','POLIVALENTE','available',true,'XL',235),
('RESERVA-18','RESERVA','POLIVALENTE','available',true,'XL',236),
('RESERVA-19','RESERVA','POLIVALENTE','available',true,'XL',237),
('RESERVA-20','RESERVA','POLIVALENTE','available',true,'XL',238),
('RESERVA-21','RESERVA','POLIVALENTE','available',true,'XL',239),
('RESERVA-22','RESERVA','POLIVALENTE','available',true,'XL',240),
('RESERVA-23','RESERVA','POLIVALENTE','available',true,'XL',241),
('RESERVA-24','RESERVA','POLIVALENTE','available',true,'XL',242),
('RESERVA-25','RESERVA','POLIVALENTE','available',true,'XL',243),
('RESERVA-26','RESERVA','POLIVALENTE','available',true,'XL',244),
('RESERVA-27','RESERVA','POLIVALENTE','available',true,'XL',245),
('RESERVA-28','RESERVA','POLIVALENTE','available',true,'XL',246),
('RESERVA-29','RESERVA','POLIVALENTE','available',true,'XL',247),
('RESERVA-30','RESERVA','POLIVALENTE','available',true,'XL',248)) x(code,zone,cls,state,poly,vt,ord) join public.vehicle_types v on v.code=x.vt
on conflict(code) do update set zone=excluded.zone,spot_class=excluded.spot_class,inventory_state=excluded.inventory_state,polyvalent=excluded.polyvalent,sort_order=excluded.sort_order,active=true;
create or replace function private.spot_accepts_vehicle(p_spot_id uuid,p_vehicle_type_id uuid) returns boolean language sql stable security invoker set search_path=public,private as $$
select exists(select 1 from public.parking_spots p where p.id=p_spot_id and p.active and p.inventory_state not in ('fixed','blocked') and (p.polyvalent or p.vehicle_type_id=p_vehicle_type_id));$$;
revoke all on function private.spot_accepts_vehicle(uuid,uuid) from public;
grant execute on function private.spot_accepts_vehicle(uuid,uuid) to authenticated;
CREATE OR REPLACE FUNCTION public.backoffice_check_in(p_reservation_id uuid, p_spot_id uuid, p_actual_entry_at timestamp with time zone DEFAULT now())
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private'
AS $function$
declare
  r public.reservations%rowtype;
  s public.parking_sessions%rowtype;
  spot_type uuid;
begin
  if not private.is_staff() then raise exception 'Not authorized'; end if;

  select * into r
  from public.reservations
  where id = p_reservation_id
  for update;

  if not found then raise exception 'Reservation not found'; end if;
  if r.status = 'cancelled' then raise exception 'Reservation is cancelled'; end if;
  if p_actual_entry_at > r.exit_at then raise exception 'La estancia ya ha finalizado'; end if;
  if r.status not in ('confirmed','checked_in') then raise exception 'Reservation is not ready for check-in'; end if;

  if coalesce(trim(r.plate),'') = '' or coalesce(trim(r.vehicle_make_model),'') = '' then
    raise exception 'Completa matrícula y modelo antes de dar entrada';
  end if;

  perform 1 from public.parking_spots where id=p_spot_id for update;

  select vehicle_type_id into spot_type
  from public.parking_spots
  where id=p_spot_id and active=true;

  if spot_type is null then raise exception 'Parking spot not found'; end if;
  if not private.spot_accepts_vehicle(p_spot_id,r.vehicle_type_id) then raise exception 'Parking spot category does not match reservation'; end if;

  if exists(
    select 1
    from public.capacity_blocks b
    where b.spot_id = p_spot_id
      and b.active = true
      and b.starts_at <= p_actual_entry_at
      and b.ends_at > p_actual_entry_at
  ) then
    raise exception 'La plaza seleccionada está bloqueada';
  end if;

  -- A vehicle that has temporarily left keeps its assigned space reserved
  -- until its stay ends.
  if exists(
    select 1
    from public.reservations rr
    where rr.assigned_spot_id = p_spot_id
      and rr.id <> p_reservation_id
      and rr.exit_at > p_actual_entry_at
      and rr.status in ('confirmed','checked_in')
      and exists (
        select 1
        from public.parking_sessions ps
        where ps.reservation_id = rr.id
      )
  ) then
    raise exception 'La plaza está reservada por otra estancia vigente';
  end if;

  if exists(
    select 1
    from public.parking_sessions
    where spot_id=p_spot_id
      and status='inside'
      and reservation_id is distinct from p_reservation_id
  ) then
    raise exception 'Parking spot is occupied';
  end if;

  select * into s
  from public.parking_sessions
  where reservation_id=p_reservation_id
  order by created_at desc
  limit 1
  for update;

  if found then
    if s.status='inside' then raise exception 'Vehicle is already inside'; end if;

    update public.parking_sessions
    set spot_id=p_spot_id,
        plate=r.plate,
        vehicle_make_model=r.vehicle_make_model,
        customer_name=r.customer_name,
        customer_phone=r.customer_phone,
        actual_entry_at=coalesce(actual_entry_at,p_actual_entry_at),
        actual_exit_at=null,
        status='inside',
        updated_at=now()
    where id=s.id
    returning * into s;
  else
    insert into public.parking_sessions(
      reservation_id,vehicle_type_id,spot_id,plate,vehicle_make_model,
      customer_name,customer_phone,planned_entry_at,planned_exit_at,
      actual_entry_at,status,billing_mode,source,created_by
    )
    values(
      r.id,r.vehicle_type_id,p_spot_id,r.plate,r.vehicle_make_model,
      r.customer_name,r.customer_phone,r.entry_at,r.exit_at,
      p_actual_entry_at,'inside','reservation','reservation',auth.uid()
    )
    returning * into s;
  end if;

  update public.reservations
  set status='checked_in',
      assigned_spot_id=p_spot_id,
      updated_at=now()
  where id=r.id;

  insert into public.parking_events(
    session_id,event_type,event_at,new_spot_id,created_by
  )
  values(
    s.id,'check_in',p_actual_entry_at,p_spot_id,auth.uid()
  );

  return s.id;
end
$function$;

CREATE OR REPLACE FUNCTION public.backoffice_move_spot(p_session_id uuid, p_new_spot_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private'
AS $function$
declare
  s public.parking_sessions%rowtype;
  spot_type uuid;
begin
  if not private.is_staff() then raise exception 'Not authorized'; end if;

  select * into s
  from public.parking_sessions
  where id=p_session_id
  for update;

  if not found or s.status <> 'inside' then raise exception 'Vehicle is not currently inside'; end if;

  perform 1 from public.parking_spots where id=p_new_spot_id for update;

  select vehicle_type_id into spot_type
  from public.parking_spots
  where id=p_new_spot_id and active=true;

  if spot_type is null then raise exception 'Parking spot not found'; end if;
  if not private.spot_accepts_vehicle(p_new_spot_id,s.vehicle_type_id) then raise exception 'Parking spot category does not match vehicle'; end if;

  if exists(
    select 1
    from public.capacity_blocks b
    where b.spot_id=p_new_spot_id
      and b.active=true
      and b.starts_at <= now()
      and b.ends_at > now()
  ) then
    raise exception 'La plaza seleccionada está bloqueada';
  end if;

  if exists(
    select 1
    from public.reservations rr
    where rr.assigned_spot_id = p_new_spot_id
      and rr.id is distinct from s.reservation_id
      and rr.exit_at > now()
      and rr.status in ('confirmed','checked_in')
      and exists (
        select 1
        from public.parking_sessions ps
        where ps.reservation_id = rr.id
      )
  ) then
    raise exception 'La plaza está reservada por otra estancia vigente';
  end if;

  if exists(
    select 1
    from public.parking_sessions
    where spot_id=p_new_spot_id
      and status='inside'
      and id<>s.id
  ) then
    raise exception 'Parking spot is occupied';
  end if;

  update public.parking_sessions
  set spot_id=p_new_spot_id,
      updated_at=now()
  where id=s.id;

  if s.reservation_id is not null then
    update public.reservations
    set assigned_spot_id=p_new_spot_id,
        updated_at=now()
    where id=s.reservation_id;
  end if;

  insert into public.parking_events(
    session_id,event_type,old_spot_id,new_spot_id,created_by
  )
  values(
    s.id,'spot_changed',s.spot_id,p_new_spot_id,auth.uid()
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.assign_web_reservation_spot()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_spot uuid;
begin
 if new.source <> 'web' then return new; end if;
 if new.status not in ('pending_payment','confirmed','checked_in') then return new; end if;
 if new.assigned_spot_id is not null then return new; end if;
 perform pg_advisory_xact_lock(hashtext('parking_inventory')::bigint);
 select p.id into v_spot from public.parking_spots p
 where p.active and p.inventory_state='available' and (p.polyvalent or p.vehicle_type_id=new.vehicle_type_id)
 and not exists(select 1 from public.capacity_blocks b where b.active and b.spot_id=p.id and b.starts_at<new.exit_at and b.ends_at>new.entry_at)
 and not exists(select 1 from public.reservations r where r.assigned_spot_id=p.id and r.id is distinct from new.id and r.status in ('confirmed','checked_in','pending_payment') and (r.status<>'pending_payment' or coalesce(r.expires_at,now()+interval '1 second')>now()) and r.entry_at<new.exit_at and r.exit_at>new.entry_at)
 and not exists(select 1 from public.parking_sessions ps where ps.spot_id=p.id and ps.status='inside' and (ps.planned_exit_at is null or ps.planned_exit_at>new.entry_at))
 order by random() limit 1;
 if v_spot is null then raise exception 'No hay una plaza libre para asignar durante las fechas solicitadas'; end if;
 new.assigned_spot_id:=v_spot;
 return new;
end;$function$;

create or replace function private.get_available_spaces(p_vehicle_type_id uuid,p_start timestamptz,p_end timestamptz,p_exclude_reservation_id uuid default null) returns integer language sql stable security definer set search_path=public,private as $$
with compatible as (select * from public.parking_spots where active and inventory_state='available' and (p_vehicle_type_id is null or polyvalent or vehicle_type_id=p_vehicle_type_id)),
points as (select p_start t union select entry_at from public.reservations where entry_at>=p_start and entry_at<p_end union select starts_at from public.capacity_blocks where active and starts_at>=p_start and starts_at<p_end),
counts as (select t,
(select count(*) from compatible p where not exists(select 1 from public.capacity_blocks b where b.active and b.spot_id=p.id and b.starts_at<=t and b.ends_at>t)
and not exists(select 1 from public.parking_sessions s where s.spot_id=p.id and s.status='inside' and s.reservation_id is distinct from p_exclude_reservation_id and (s.planned_exit_at is null or s.planned_exit_at>t))
and not exists(select 1 from public.reservations r where r.assigned_spot_id=p.id and r.id is distinct from p_exclude_reservation_id and r.entry_at<=t and r.exit_at>t and (r.status in ('confirmed','checked_in') or (r.status='pending_payment' and r.expires_at>now()))))
- (select count(*) from public.reservations r where (p_vehicle_type_id is null or r.vehicle_type_id=p_vehicle_type_id) and (r.assigned_spot_id is null or exists(select 1 from public.parking_spots l where l.id=r.assigned_spot_id and l.inventory_state='legacy')) and r.id is distinct from p_exclude_reservation_id and r.entry_at<=t and r.exit_at>t and (r.status in ('confirmed','checked_in') or (r.status='pending_payment' and r.expires_at>now())))
- coalesce((select sum(blocked_spaces) from public.capacity_blocks b where b.active and b.spot_id is null and (p_vehicle_type_id is null or b.vehicle_type_id=p_vehicle_type_id) and b.starts_at<=t and b.ends_at>t),0) available from points)
select greatest(0,coalesce(min(available),0))::integer from counts;$$;
update public.vehicle_types v set base_capacity=(select count(*) from public.parking_spots p where p.vehicle_type_id=v.id and p.active and p.inventory_state='available' and not p.polyvalent);
create or replace function public.prevent_overbooking() returns trigger language plpgsql set search_path=public,private as $$
declare v_available integer;begin
 if not (new.status in ('confirmed','checked_in') or (new.status='pending_payment' and coalesce(new.expires_at,now()+interval '1 second')>now())) then return new; end if;
 if tg_op='UPDATE' and new.vehicle_type_id=old.vehicle_type_id and new.entry_at=old.entry_at and new.exit_at=old.exit_at and old.status in ('confirmed','checked_in') then return new; end if;
 perform pg_advisory_xact_lock(hashtext('parking_inventory')::bigint);
 v_available:=least(private.get_available_spaces(new.vehicle_type_id,new.entry_at,new.exit_at,case when tg_op='UPDATE' then old.id else null end),private.get_available_spaces(null,new.entry_at,new.exit_at,case when tg_op='UPDATE' then old.id else null end));
 if coalesce(v_available,0)<1 then raise exception 'No hay plazas disponibles para todo el intervalo solicitado'; end if;
 return new;end;$$;
