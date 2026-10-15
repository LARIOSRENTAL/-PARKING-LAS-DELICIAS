-- Retired, unused test stock remains auditable but cannot be printed or redeemed.
alter table public.parking_hotel_batches add column is_void boolean not null default false;
create or replace view public.parking_hotel_balances as select h.id,h.name,h.active,coalesce((select sum(b.days)from public.parking_hotel_batches b where b.hotel_id=h.id and not b.is_void),0)::integer as purchased_days,coalesce((select sum(x.days)from public.parking_hotel_redemptions x where x.hotel_id=h.id),0)::integer as used_days,(coalesce((select sum(b.days)from public.parking_hotel_batches b where b.hotel_id=h.id and not b.is_void),0)-coalesce((select sum(x.days)from public.parking_hotel_redemptions x where x.hotel_id=h.id),0))::integer as available_days from public.parking_hotels h;
create or replace function private.resolve_hotel_voucher_codes(p_codes text[],p_lock boolean) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare codes text[];hotels uuid[];n integer;hotel uuid;hotel_name text;used_code text;
begin
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
end $$;
create or replace function public.parking_hotel_batch_vouchers(p_batch_id uuid)returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$declare r jsonb;begin
 if auth.uid()is null or not private.is_staff()then raise exception 'No autorizado';end if;
 select jsonb_build_object('id',b.id,'is_test',b.is_test,'hotel_name',h.name,'unit_price_eur',b.unit_price_eur,'registration_first',b.registration_first,'registration_last',b.registration_last,'vouchers',(select jsonb_agg(jsonb_build_object('code',v.code,'used',v.redeemed_reservation_id is not null)order by v.number)from public.parking_hotel_vouchers v where v.batch_id=b.id))into r from public.parking_hotel_batches b join public.parking_hotels h on h.id=b.hotel_id where b.id=p_batch_id and not b.is_void;
 if r is null then raise exception 'Compra de bonos inexistente';end if;return r;
end $$;
alter policy vouchers_staff_read on public.parking_hotel_vouchers using(private.is_staff()and exists(select 1 from public.parking_hotel_batches b where b.id=batch_id and not b.is_void));
