create or replace function private.parking_normalize_hotel_voucher_code(p_code text)
returns text language sql immutable strict set search_path to '' as $$
select regexp_replace(upper(btrim(p_code)), $rx$['’‘´‐‑‒–—−]$rx$, '-', 'g');
$$;
revoke all on function private.parking_normalize_hotel_voucher_code(text) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION private.parking_redeem_registered_legacy_hotel_voucher()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare entered text:=private.parking_normalize_hotel_voucher_code(new.hotel_voucher_number);canonical text;v public.parking_hotel_vouchers;b public.parking_hotel_batches;
begin
 if entered !~ '^(H-?)?[0-9]+$' then return new;end if;
 canonical:='H-'||((regexp_replace(entered,'^H-?',''))::numeric)::text;
 select * into v from public.parking_hotel_vouchers hv where hv.code=canonical for update;
 if not found then return new;end if;
 select * into b from public.parking_hotel_batches hb where hb.id=v.batch_id;
 if b.is_void then raise exception 'El bono % pertenece a una compra anulada',v.code;end if;
 if not exists(select 1 from public.parking_hotels h where h.id=b.hotel_id and h.active) then raise exception 'El hotel del bono % está desactivado',v.code;end if;
 if v.redeemed_reservation_id is not null then raise exception 'El bono % ya está utilizado y no puede volver a canjearse',v.code;end if;
 update public.parking_hotel_vouchers hv set redeemed_reservation_id=new.reservation_id,redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where hv.number=v.number;
 return new;
end $function$
;
CREATE OR REPLACE FUNCTION private.resolve_hotel_voucher_codes(p_codes text[], p_lock boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare codes text[];hotels uuid[];n integer;hotel uuid;hotel_name text;used_code text;
begin
 p_codes:=array(select private.parking_normalize_hotel_voucher_code(raw_code) from unnest(p_codes) raw_code);
 if coalesce(cardinality(p_codes),0) not between 1 and 24 then raise exception 'Escanea o escribe entre 1 y 24 bonos';end if;
 if exists(select 1 from unnest(p_codes)c where c is null or upper(btrim(c)) !~ '^(H-?)?[1-9][0-9]*$')then raise exception 'Código inválido. Utiliza H-1, H-2…';end if;
 select array_agg('H-'||regexp_replace(upper(btrim(c)),'^H-?','')) into codes from unnest(p_codes)c;
 if (select count(distinct c)from unnest(codes)c)<>cardinality(codes)then raise exception 'Hay códigos de bono repetidos';end if;
 select count(*),array_agg(distinct b.hotel_id)into n,hotels from public.parking_hotel_vouchers v join public.parking_hotel_batches b on b.id=v.batch_id where not b.is_void and v.code=any(codes);
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
end $function$
;
CREATE OR REPLACE FUNCTION public.parking_pay_stay_hotel_vouchers(p_reservation_id uuid, p_codes text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;r public.reservations;info jsonb;affected integer;
begin
ctx:=public.rotation_operator_context();
select * into r from public.reservations where id=p_reservation_id for update;
if not found or r.status not in('confirmed','pending_payment') or r.payment_status='paid' then raise exception 'Reserva no disponible para cobro';end if;
if not exists(select 1 from public.vehicle_types where id=r.vehicle_type_id and code='TURISMO') then raise exception 'Bonos solo para turismos';end if;
info:=private.resolve_hotel_voucher_codes(p_codes,true);
if (info->>'days')::integer<>r.duration_days then raise exception 'Se requiere un bono por día';end if;
update public.parking_hotel_vouchers set redeemed_reservation_id=r.id,redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where code in(select jsonb_array_elements_text(info->'codes')) and redeemed_reservation_id is null;
get diagnostics affected=row_count;
if affected<>cardinality(p_codes) then raise exception 'No se han canjeado todos los bonos';end if;
insert into public.parking_hotel_redemptions(reservation_id,hotel_id,days)
values(r.id,(info->>'hotel_id')::uuid,r.duration_days)
on conflict(reservation_id) do update set hotel_id=excluded.hotel_id,days=excluded.days;
update public.reservations set payment_method='hotel_voucher',payment_status='paid',hotel_id=(info->>'hotel_id')::uuid,updated_at=clock_timestamp() where id=r.id returning * into r;
return to_jsonb(r);
end $function$
;
