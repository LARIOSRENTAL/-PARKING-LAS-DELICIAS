-- Inventory derives from individual redemption records, never the original purchase quantity.
create function public.parking_hotel_available_batches() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return(select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object('available_days',v.available,'used_days',v.used,'available_codes',v.codes) order by (b.payment_status='pending') desc,b.created_at desc,b.id),'[]'::jsonb)
 from public.parking_hotel_batches b cross join lateral(
 select count(*)filter(where redeemed_reservation_id is null)::integer as available,count(*)filter(where redeemed_reservation_id is not null)::integer as used,
 coalesce(jsonb_agg(code order by number)filter(where redeemed_reservation_id is null),'[]'::jsonb) as codes
 from public.parking_hotel_vouchers where batch_id=b.id) v
 where not b.is_void and (v.available>0 or b.payment_status='pending'));
end $$;
revoke all on function public.parking_hotel_available_batches() from public,anon;
grant execute on function public.parking_hotel_available_batches() to authenticated;
