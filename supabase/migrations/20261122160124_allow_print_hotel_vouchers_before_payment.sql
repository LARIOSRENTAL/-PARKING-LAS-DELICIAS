-- Printing may happen before collection; redemption still remains blocked until paid and printed.
create or replace function public.parking_hotel_batch_vouchers(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare r jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select jsonb_build_object('id',b.id,'is_test',b.is_test,'hotel_name',h.name,'unit_price_eur',b.unit_price_eur,'registration_first',b.registration_first,'registration_last',b.registration_last,'vouchers',(select jsonb_agg(jsonb_build_object('code',v.code,'used',v.redeemed_reservation_id is not null)order by v.number)from public.parking_hotel_vouchers v where v.batch_id=b.id)) into r
 from public.parking_hotel_batches b join public.parking_hotels h on h.id=b.hotel_id where b.id=p_batch_id and not b.is_void;
 if r is null then raise exception 'Compra de bonos inexistente';end if;return r;
end $$;

create or replace function public.parking_mark_hotel_batch_printed(p_batch_id uuid)
returns timestamptz language plpgsql security definer set search_path=public,private,pg_temp as $$
declare printed timestamptz;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 update public.parking_hotel_batches set vouchers_printed_at=clock_timestamp()
 where id=p_batch_id and not is_void and hold_until_paid_for_print returning vouchers_printed_at into printed;
 if printed is null then raise exception 'No se pudo confirmar la impresión de esta compra';end if;
 return printed;
end $$;
