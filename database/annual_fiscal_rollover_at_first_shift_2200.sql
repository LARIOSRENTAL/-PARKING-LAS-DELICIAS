-- Annual fiscal series roll over at the start of shift 1, not at midnight.
CREATE OR REPLACE FUNCTION private.parking_fiscal_serial(p_series text, p_at timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n bigint;first_value bigint;y integer:=extract(year from p_at at time zone 'Europe/Madrid');
begin
 if p_series is null or p_series not in('ONH','OTH','OFH','OND','OTD','OFD','OFM') or p_at is null then raise exception 'Serie o fecha fiscal no válida';end if;
 if p_at<timestamptz '2026-10-31 22:00 Europe/Madrid' then
  insert into private.parking_test_fiscal_counters(series,year,last_number) values(p_series,y,1)
  on conflict(series,year) do update set last_number=parking_test_fiscal_counters.last_number+1 returning last_number into n;
  return to_char(y%100,'FM00')||lpad(n::text,greatest(4,length(n::text)),'0');
 end if;
 -- The operational day starts at 22:00 Madrid (shift 1 of the following day).
 y:=extract(year from ((p_at at time zone 'Europe/Madrid')+interval '2 hours'));
 select s.first_number into first_value from private.parking_fiscal_series_starts s where s.series=p_series and s.year=y;
 first_value:=coalesce(first_value,(y%100)::bigint*10000+1);
 -- Production counters store the complete printed number, without a second year prefix.
 insert into private.parking_fiscal_counters(series,year,last_number) values(p_series,y,first_value)
 on conflict(series,year) do update set last_number=parking_fiscal_counters.last_number+1 returning last_number into n;
 return n::text;
end $function$
;
