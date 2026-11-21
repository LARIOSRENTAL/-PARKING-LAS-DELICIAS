-- Keep newly prepared voucher stock out of balances and redemption until it has been paid and printed.
create or replace view public.parking_hotel_balances as
select h.id,h.name,h.active,
 coalesce((select sum(b.days) from public.parking_hotel_batches b where b.hotel_id=h.id and not b.is_void and (not b.hold_until_paid_for_print or (b.payment_status='paid' and b.vouchers_printed_at is not null))),0)::integer as purchased_days,
 coalesce((select sum(x.days) from public.parking_hotel_redemptions x where x.hotel_id=h.id),0)::integer as used_days,
 (coalesce((select sum(b.days) from public.parking_hotel_batches b where b.hotel_id=h.id and not b.is_void and (not b.hold_until_paid_for_print or (b.payment_status='paid' and b.vouchers_printed_at is not null))),0)-coalesce((select sum(x.days) from public.parking_hotel_redemptions x where x.hotel_id=h.id),0))::integer as available_days
from public.parking_hotels h;

create or replace function private.resolve_hotel_voucher_codes(p_codes text[],p_lock boolean)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare codes text[];hotels uuid[];n integer;hotel uuid;hotel_name text;used_code text;
begin
 p_codes:=array(select private.parking_normalize_hotel_voucher_code(raw_code) from unnest(p_codes) raw_code);
 if coalesce(cardinality(p_codes),0) not between 1 and 24 then raise exception 'Escanea o escribe entre 1 y 24 bonos';end if;
 if exists(select 1 from unnest(p_codes)c where c is null or upper(btrim(c)) !~ '^(H-?)?[1-9][0-9]*$')then raise exception 'Código inválido. Utiliza H-1, H-2…';end if;
 select array_agg('H-'||regexp_replace(upper(btrim(c)),'^H-?','')) into codes from unnest(p_codes)c;
 if (select count(distinct c)from unnest(codes)c)<>cardinality(codes)then raise exception 'Hay códigos de bono repetidos';end if;
 if exists(select 1 from public.parking_hotel_vouchers v join public.parking_hotel_batches b on b.id=v.batch_id where v.code=any(codes) and b.hold_until_paid_for_print and (b.payment_status<>'paid' or b.vouchers_printed_at is null) and not b.is_void) then raise exception 'Estos bonos están pendientes de pago o impresión y todavía no se pueden utilizar';end if;
 select count(*),array_agg(distinct b.hotel_id)into n,hotels from public.parking_hotel_vouchers v join public.parking_hotel_batches b on b.id=v.batch_id where not b.is_void and v.code=any(codes);
 if n<>cardinality(codes)then raise exception 'Algún bono no existe. Revisa sus números de registro';end if;
 if cardinality(hotels)<>1 then raise exception 'Todos los bonos de una estancia deben pertenecer al mismo hotel o apartamento';end if;
 hotel:=hotels[1];
 if p_lock then perform 1 from public.parking_hotels where id=hotel and active for update;else perform 1 from public.parking_hotels where id=hotel and active;end if;
 if not found then raise exception 'El hotel de estos bonos está desactivado';end if;
 if p_lock then perform 1 from public.parking_hotel_vouchers where code=any(codes) order by number for update;end if;
 select code into used_code from public.parking_hotel_vouchers where code=any(codes)and redeemed_reservation_id is not null order by number limit 1;
 if found then raise exception 'El bono % ya está utilizado y no puede volver a canjearse',used_code;end if;
 select name into hotel_name from public.parking_hotels where id=hotel;
 return jsonb_build_object('hotel_id',hotel,'hotel_name',hotel_name,'codes',codes,'days',n,'available_days',(select available_days from public.parking_hotel_balances where id=hotel));
end $$;

create or replace function private.parking_redeem_registered_legacy_hotel_voucher()
returns trigger language plpgsql security definer set search_path='' as $$
declare entered text:=private.parking_normalize_hotel_voucher_code(new.hotel_voucher_number);canonical text;v public.parking_hotel_vouchers;b public.parking_hotel_batches;
begin
 if entered !~ '^(H-?)?[0-9]+$' then return new;end if;
 canonical:='H-'||((regexp_replace(entered,'^H-?',''))::numeric)::text;
 select * into v from public.parking_hotel_vouchers hv where hv.code=canonical for update;
 if not found then return new;end if;
 select * into b from public.parking_hotel_batches hb where hb.id=v.batch_id;
 if b.is_void then raise exception 'El bono % pertenece a una compra anulada',v.code;end if;
 if b.hold_until_paid_for_print and (b.payment_status<>'paid' or b.vouchers_printed_at is null) then raise exception 'Estos bonos están pendientes de pago o impresión y todavía no se pueden utilizar';end if;
 if not exists(select 1 from public.parking_hotels h where h.id=b.hotel_id and h.active) then raise exception 'El hotel del bono % está desactivado',v.code;end if;
 if v.redeemed_reservation_id is not null then raise exception 'El bono % ya está utilizado y no puede volver a canjearse',v.code;end if;
 update public.parking_hotel_vouchers hv set redeemed_reservation_id=new.reservation_id,redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where hv.number=v.number;
 return new;
end $$;

create or replace function public.parking_hotel_available_batches()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return(select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object(
  'invoice_id',(select id from public.parking_invoices where entity_type='hotel_batch' and entity_id=b.id order by issued_at desc limit 1),
  'invoice_number',(select coalesce(display_number,number::text) from public.parking_invoices where entity_type='hotel_batch' and entity_id=b.id order by issued_at desc limit 1),
  'available_days',case when b.hold_until_paid_for_print and (b.payment_status<>'paid' or b.vouchers_printed_at is null) then 0 else v.available end,
  'used_days',v.used,
  'available_codes',case when b.hold_until_paid_for_print and (b.payment_status<>'paid' or b.vouchers_printed_at is null) then '[]'::jsonb else v.codes end) order by (b.payment_status='pending') desc,b.created_at desc,b.id),'[]'::jsonb)
 from public.parking_hotel_batches b cross join lateral(
  select count(*)filter(where redeemed_reservation_id is null)::integer as available,
   count(*)filter(where redeemed_reservation_id is not null)::integer as used,
   coalesce(jsonb_agg(code order by number)filter(where redeemed_reservation_id is null),'[]'::jsonb) as codes
  from public.parking_hotel_vouchers where batch_id=b.id) v
 where not b.is_void and (v.available>0 or b.payment_status='pending' or b.bank_transfer_invoice or b.hold_until_paid_for_print));
end $$;
