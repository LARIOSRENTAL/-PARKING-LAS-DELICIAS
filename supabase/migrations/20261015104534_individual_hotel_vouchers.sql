-- Individual, single-use one-day hotel vouchers. Historical references stay intact.
create table private.parking_registration_counters(kind text primary key,last_number bigint not null);
insert into private.parking_registration_counters(kind,last_number)select 'E',coalesce(max(substring(reference from 3)::bigint),0)from public.reservations where reference ~ '^E-[1-9][0-9]*$';
create table public.parking_hotel_vouchers(
 number bigint primary key,
 code text generated always as ('H-'||number::text) stored unique,
 batch_id uuid not null references public.parking_hotel_batches(id),
 redeemed_reservation_id uuid references public.reservations(id),
 redeemed_at timestamptz,redeemed_by uuid,
 check((redeemed_reservation_id is null)=(redeemed_at is null))
);
create index hotel_vouchers_batch_idx on public.parking_hotel_vouchers(batch_id,number);
create index hotel_vouchers_redemption_idx on public.parking_hotel_vouchers(redeemed_reservation_id) where redeemed_reservation_id is not null;
alter table public.parking_hotel_vouchers enable row level security;
create policy vouchers_staff_read on public.parking_hotel_vouchers for select to authenticated using(private.is_staff());
revoke all on public.parking_hotel_vouchers from anon,authenticated;
grant select on public.parking_hotel_vouchers to authenticated;
alter table public.parking_hotel_batches add column registration_first text,add column registration_last text;

create function private.allocate_hotel_batch_vouchers(p_id uuid) returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare b public.parking_hotel_batches;v_last bigint;
begin
 select * into b from public.parking_hotel_batches where id=p_id for update;
 if not found or exists(select 1 from public.parking_hotel_vouchers where batch_id=p_id) then return;end if;
 insert into private.parking_registration_counters(kind,last_number)values('H',b.days) on conflict(kind)do update set last_number=parking_registration_counters.last_number+excluded.last_number returning last_number into v_last;
 insert into public.parking_hotel_vouchers(number,batch_id)select n,b.id from generate_series(v_last-b.days+1,v_last)n;
 update public.parking_hotel_batches set registration_first='H-'||(v_last-b.days+1),registration_last='H-'||v_last where id=b.id;
end $$;
create function private.number_hotel_batch() returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$begin perform private.allocate_hotel_batch_vouchers(new.id);return new;end $$;
create trigger number_hotel_batch after insert on public.parking_hotel_batches for each row execute function private.number_hotel_batch();
-- Materialize existing purchases and match historical redemptions FIFO, preserving balances.
do $$declare batch_record record;r record;n integer;begin
 for batch_record in select id from public.parking_hotel_batches order by created_at,id loop perform private.allocate_hotel_batch_vouchers(batch_record.id);end loop;
 for r in select * from public.parking_hotel_redemptions order by redeemed_at,reservation_id loop
  with chosen as(select v.number from public.parking_hotel_vouchers v join public.parking_hotel_batches b on b.id=v.batch_id where b.hotel_id=r.hotel_id and v.redeemed_reservation_id is null order by v.number limit r.days)
  update public.parking_hotel_vouchers v set redeemed_reservation_id=r.reservation_id,redeemed_at=r.redeemed_at from chosen where v.number=chosen.number;
  get diagnostics n=row_count;if n<>r.days then raise exception 'El saldo histórico de bonos requiere revisión antes de numerar';end if;
 end loop;
end $$;

create function private.number_parking_stay() returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$declare n bigint;begin
 insert into private.parking_registration_counters(kind,last_number)values('E',1)on conflict(kind)do update set last_number=parking_registration_counters.last_number+1 returning last_number into n;
 new.reference:='E-'||n;return new;
end $$;
alter table public.reservations alter column reference drop default;
create trigger number_parking_stay before insert on public.reservations for each row execute function private.number_parking_stay();

-- Resolve and optionally lock the exact submitted vouchers. Never choose vouchers automatically.
create function private.resolve_hotel_voucher_codes(p_codes text[],p_lock boolean) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare codes text[];hotels uuid[];n integer;hotel uuid;hotel_name text;used_code text;
begin
 if coalesce(cardinality(p_codes),0) not between 1 and 24 then raise exception 'Escanea o escribe entre 1 y 24 bonos';end if;
 if exists(select 1 from unnest(p_codes)c where c is null or upper(btrim(c)) !~ '^(H-?)?[1-9][0-9]*$')then raise exception 'Código inválido. Utiliza H-1, H-2…';end if;
 select array_agg('H-'||regexp_replace(upper(btrim(c)),'^H-?','')) into codes from unnest(p_codes)c;
 if (select count(distinct c)from unnest(codes)c)<>cardinality(codes)then raise exception 'Hay códigos de bono repetidos';end if;
 select count(*),array_agg(distinct b.hotel_id)into n,hotels from public.parking_hotel_vouchers v join public.parking_hotel_batches b on b.id=v.batch_id where v.code=any(codes);
 if n<>cardinality(codes)then raise exception 'Algún bono no existe. Revisa sus números de registro';end if;
 if cardinality(hotels)<>1 then raise exception 'Todos los bonos de una estancia deben pertenecer al mismo hotel o apartamento';end if;
 hotel:=hotels[1];
 if p_lock then
  perform 1 from public.parking_hotels where id=hotel and active for update;
 else perform 1 from public.parking_hotels where id=hotel and active;end if;
 if not found then raise exception 'El hotel de estos bonos está desactivado';end if;
 if p_lock then perform 1 from public.parking_hotel_vouchers where code=any(codes) order by number for update;end if;
 select code into used_code from public.parking_hotel_vouchers where code=any(codes)and redeemed_reservation_id is not null order by number limit 1;
 if found then raise exception 'El bono % ya está utilizado y no puede volver a canjearse',used_code;end if;
 select name into hotel_name from public.parking_hotels where id=hotel;
 return jsonb_build_object('hotel_id',hotel,'hotel_name',hotel_name,'codes',codes,'days',n,'available_days',(select available_days from public.parking_hotel_balances where id=hotel));
end $$;
create function public.parking_resolve_hotel_vouchers(p_codes text[])returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$begin
 if auth.uid() is null or not private.is_staff()then raise exception 'No autorizado';end if;
 return private.resolve_hotel_voucher_codes(p_codes,false);end $$;

-- Keep legacy implementations private; old screens must not redeem a hotel's generic balance.
alter function public.create_hotel_paid_reservation(uuid,uuid,timestamptz,integer,text,text,text,text,text,text)set schema private;
alter function public.extend_hotel_paid_reservation(uuid,integer,uuid)set schema private;
revoke all on function private.create_hotel_paid_reservation(uuid,uuid,timestamptz,integer,text,text,text,text,text,text),private.extend_hotel_paid_reservation(uuid,integer,uuid)from public,anon,authenticated;
create function public.create_hotel_paid_reservation(p_hotel_id uuid,p_vehicle_type_id uuid,p_entry_at timestamptz,p_days integer,p_plate text,p_model text,p_customer_name text default null,p_phone text default null,p_email text default null,p_notes text default null)returns jsonb language plpgsql set search_path=public,pg_temp as $$begin raise exception 'Debes escanear o escribir los números de los bonos hotel. Actualiza el backoffice';end $$;
create function public.extend_hotel_paid_reservation(p_reservation_id uuid,p_new_days integer,p_hotel_id uuid)returns jsonb language plpgsql set search_path=public,pg_temp as $$begin raise exception 'Debes indicar los bonos individuales de la ampliación. Actualiza el backoffice';end $$;

create function public.parking_create_stay_from_vouchers(p_codes text[],p_vehicle_type_id uuid,p_entry_at timestamptz,p_days integer,p_plate text,p_model text,p_customer_name text default null,p_phone text default null,p_email text default null,p_notes text default null)returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;info jsonb;r jsonb;
begin
 ctx:=public.rotation_operator_context();info:=private.resolve_hotel_voucher_codes(p_codes,true);
 if p_days is null or p_days<>(info->>'days')::integer then raise exception 'Debes aportar un bono por cada día de estancia';end if;
 r:=private.create_hotel_paid_reservation((info->>'hotel_id')::uuid,p_vehicle_type_id,p_entry_at,p_days,p_plate,p_model,p_customer_name,p_phone,p_email,p_notes);
 update public.parking_hotel_vouchers set redeemed_reservation_id=(r->>'id')::uuid,redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where code in(select jsonb_array_elements_text(info->'codes'));
 return r||jsonb_build_object('hotel_name',info->>'hotel_name','voucher_codes',info->'codes');
end $$;
create function public.parking_extend_stay_from_vouchers(p_reservation_id uuid,p_new_days integer,p_codes text[])returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;r public.reservations;info jsonb;result jsonb;
begin
 ctx:=public.rotation_operator_context();select * into r from public.reservations where id=p_reservation_id for update;if not found then raise exception 'Reserva inexistente';end if;
 info:=private.resolve_hotel_voucher_codes(p_codes,true);
 if p_new_days is null or p_new_days-r.duration_days<>(info->>'days')::integer then raise exception 'Aporta un bono por cada día adicional';end if;
 result:=private.extend_hotel_paid_reservation(r.id,p_new_days,(info->>'hotel_id')::uuid);
 update public.parking_hotel_vouchers set redeemed_reservation_id=r.id,redeemed_at=clock_timestamp(),redeemed_by=auth.uid()where code in(select jsonb_array_elements_text(info->'codes'));
 return result||jsonb_build_object('voucher_codes',info->'codes');
end $$;
create function public.parking_rotation_to_stay_with_vouchers(p_session_id uuid,p_vehicle_type_id uuid,p_spot_id uuid,p_days integer,p_model text,p_codes text[])returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;s public.rotation_sessions;r jsonb;
begin
 ctx:=public.rotation_operator_context();select * into s from public.rotation_sessions where id=p_session_id for update;
 if not found then raise exception 'Ticket inexistente';end if;
 if s.converted_reservation_id is not null then return jsonb_build_object('id',s.converted_reservation_id,'already_converted',true);end if;
 if s.status<>'inside' or s.billing_only then raise exception 'Este ticket no se puede convertir a estancia';end if;
 if s.entry_at+make_interval(days=>p_days)<=clock_timestamp()then raise exception 'La estancia debe cubrir hasta después de la hora actual';end if;
 perform 1 from public.parking_spots where id=p_spot_id and vehicle_type_id=p_vehicle_type_id and active for update;if not found then raise exception 'Selecciona una plaza válida';end if;
 r:=public.parking_create_stay_from_vouchers(p_codes,p_vehicle_type_id,s.entry_at,p_days,s.plate,p_model,s.client_text,null,null,'Convertida desde ticket de rotación '||s.ticket_number);
 perform public.backoffice_check_in((r->>'id')::uuid,p_spot_id,s.entry_at);
 update public.rotation_sessions set status='cancelled',converted_reservation_id=(r->>'id')::uuid,updated_at=clock_timestamp()where id=s.id;
 return r;
end $$;
create function public.parking_hotel_batch_vouchers(p_batch_id uuid)returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$declare r jsonb;begin
 if auth.uid()is null or not private.is_staff()then raise exception 'No autorizado';end if;
 select jsonb_build_object('id',b.id,'hotel_name',h.name,'unit_price_eur',b.unit_price_eur,'registration_first',b.registration_first,'registration_last',b.registration_last,'vouchers',(select jsonb_agg(jsonb_build_object('code',v.code,'used',v.redeemed_reservation_id is not null)order by v.number)from public.parking_hotel_vouchers v where v.batch_id=b.id))into r from public.parking_hotel_batches b join public.parking_hotels h on h.id=b.hotel_id where b.id=p_batch_id;
 if r is null then raise exception 'Compra de bonos inexistente';end if;return r;
end $$;
-- Deferred integrity checks also reject direct/legacy attempts to pay without exact vouchers.
create function private.validate_hotel_voucher_redemption()returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_id uuid;r public.reservations;n integer;d integer;h uuid;
begin
 if tg_table_name='reservations'then v_id:=new.id;elsif tg_op='DELETE'then v_id:=old.reservation_id;else v_id:=new.reservation_id;end if;
 select * into r from public.reservations where id=v_id;
 if not found or r.payment_method is distinct from 'hotel_voucher'then return null;end if;
 select days,hotel_id into d,h from public.parking_hotel_redemptions where reservation_id=v_id;
 select count(*)into n from public.parking_hotel_vouchers v join public.parking_hotel_batches b on b.id=v.batch_id where v.redeemed_reservation_id=v_id and b.hotel_id=r.hotel_id;
 if d is distinct from r.duration_days or h is distinct from r.hotel_id or n<>r.duration_days then raise exception 'El pago con bonos hotel requiere un bono individual válido por cada día';end if;
 return null;
end $$;
create constraint trigger valid_reservation_hotel_vouchers after insert or update on public.reservations deferrable initially deferred for each row execute function private.validate_hotel_voucher_redemption();
create constraint trigger valid_hotel_redemption_codes after insert or update or delete on public.parking_hotel_redemptions deferrable initially deferred for each row execute function private.validate_hotel_voucher_redemption();
revoke all on function public.parking_resolve_hotel_vouchers(text[]),public.parking_create_stay_from_vouchers(text[],uuid,timestamptz,integer,text,text,text,text,text,text),public.parking_extend_stay_from_vouchers(uuid,integer,text[]),public.parking_rotation_to_stay_with_vouchers(uuid,uuid,uuid,integer,text,text[]),public.parking_hotel_batch_vouchers(uuid),public.create_hotel_paid_reservation(uuid,uuid,timestamptz,integer,text,text,text,text,text,text),public.extend_hotel_paid_reservation(uuid,integer,uuid)from public,anon;
grant execute on function public.parking_resolve_hotel_vouchers(text[]),public.parking_create_stay_from_vouchers(text[],uuid,timestamptz,integer,text,text,text,text,text,text),public.parking_extend_stay_from_vouchers(uuid,integer,text[]),public.parking_rotation_to_stay_with_vouchers(uuid,uuid,uuid,integer,text,text[]),public.parking_hotel_batch_vouchers(uuid),public.create_hotel_paid_reservation(uuid,uuid,timestamptz,integer,text,text,text,text,text,text),public.extend_hotel_paid_reservation(uuid,integer,uuid)to authenticated;
revoke all on function private.allocate_hotel_batch_vouchers(uuid),private.number_hotel_batch(),private.number_parking_stay(),private.resolve_hotel_voucher_codes(text[],boolean),private.validate_hotel_voucher_redemption()from public,anon,authenticated;
