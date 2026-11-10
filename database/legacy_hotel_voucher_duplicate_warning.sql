create or replace function private.parking_legacy_voucher_duplicate_warning() returns trigger language plpgsql security definer set search_path='' as $fn$
declare used record;
begin
 perform pg_advisory_xact_lock(hashtextextended('legacy-hotel-voucher:'||new.hotel_voucher_number,0));
 select v.id,r.reference,r.plate,r.entry_at into used from public.parking_legacy_hotel_vouchers v left join public.reservations r on r.id=v.reservation_id where v.hotel_voucher_number=new.hotel_voucher_number limit 1;
 if found then raise exception 'El bono antiguo % ya consta en la estancia %, matrícula %, entrada %. Revisa ese registro si el número se anotó por error.',new.hotel_voucher_number,coalesce(used.reference,'sin referencia'),coalesce(used.plate,'sin matrícula'),coalesce(to_char(used.entry_at at time zone 'Europe/Madrid','DD/MM/YYYY'),'sin fecha');end if;
 return new;
end $fn$;
revoke all on function private.parking_legacy_voucher_duplicate_warning() from public;
create trigger aaa_legacy_voucher_duplicate_warning before insert on public.parking_legacy_hotel_vouchers for each row execute function private.parking_legacy_voucher_duplicate_warning();