-- Operator correction of hourly fiscal series at the start of the first real shift.
-- Guard against changing starts after a real number has been allocated.
begin;
lock table public.parking_invoices,public.parking_simplified_invoices,private.parking_fiscal_counters,private.parking_fiscal_series_starts in share row exclusive mode;
do $$begin
 if exists(select 1 from private.parking_fiscal_counters where year=2026 and series in('ONH','OTH','OFH'))
 or exists(select 1 from public.parking_invoices where is_production and series in('ONH','OTH','OFH') and issued_at>=timestamptz '2026-10-31 22:00 Europe/Madrid')
 or exists(select 1 from public.parking_simplified_invoices where is_production and series in('ONH','OTH','OFH') and issued_at>=timestamptz '2026-10-31 22:00 Europe/Madrid')
 then raise exception 'Se ha emitido un documento real durante la revisión. Recalcular antes de cambiar la numeración';end if;
end $$;
update private.parking_fiscal_series_starts s set first_number=v.n
from(values('ONH',44477::bigint),('OTH',24545::bigint),('OFH',2664687::bigint))v(series,n)
where s.year=2026 and s.series=v.series;
commit;
