-- First production numbers explicitly supplied by the parking operator.
-- This configuration does not allocate or renumber any fiscal document.
do $$begin
 if exists(select 1 from private.parking_fiscal_counters) then
 raise exception 'Ya hay numeración real asignada. Revisar antes de cambiar el formato del contador';end if;
end $$;
create table private.parking_fiscal_series_starts(
 series text not null check(series in('ONH','OTH','OFH','OND','OTD','OFD','OFM')),
 year integer not null,
 first_number bigint not null check(first_number>0),
 primary key(series,year)
);
alter table private.parking_fiscal_series_starts enable row level security;
revoke all on private.parking_fiscal_series_starts from public,anon,authenticated;
insert into private.parking_fiscal_series_starts(series,year,first_number) values
('ONH',2026,45541),
('OTH',2026,24541),
('OFH',2026,2664691),
('OND',2026,260001),
('OTD',2026,260001),
('OFD',2026,260001),
('OFM',2026,2664721),
('ONH',2027,270001),
('OTH',2027,270001),
('OFH',2027,270001),
('OND',2027,27001),
('OTD',2027,27001),
('OFD',2027,27001),
('OFM',2027,2027001);
create or replace function private.parking_fiscal_serial(p_series text,p_at timestamptz)
returns text language plpgsql security definer set search_path to '' as $$
declare n bigint;first_value bigint;y integer:=extract(year from p_at at time zone 'Europe/Madrid');
begin
 if p_series is null or p_series not in('ONH','OTH','OFH','OND','OTD','OFD','OFM') or p_at is null then raise exception 'Serie o fecha fiscal no válida';end if;
 if p_at<timestamptz '2026-10-31 22:00 Europe/Madrid' then
  insert into private.parking_test_fiscal_counters(series,year,last_number) values(p_series,y,1)
  on conflict(series,year) do update set last_number=parking_test_fiscal_counters.last_number+1 returning last_number into n;
  return to_char(y%100,'FM00')||lpad(n::text,greatest(4,length(n::text)),'0');
 end if;
 select s.first_number into first_value from private.parking_fiscal_series_starts s where s.series=p_series and s.year=y;
 first_value:=coalesce(first_value,(y%100)::bigint*10000+1);
 -- Production counters store the complete printed number, without a second year prefix.
 insert into private.parking_fiscal_counters(series,year,last_number) values(p_series,y,first_value)
 on conflict(series,year) do update set last_number=parking_fiscal_counters.last_number+1 returning last_number into n;
 return n::text;
end $$;
revoke all on function private.parking_fiscal_serial(text,timestamptz) from public,anon,authenticated;
