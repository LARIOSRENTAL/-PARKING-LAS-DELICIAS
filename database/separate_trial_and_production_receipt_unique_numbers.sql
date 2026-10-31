-- Trial and production documents have independent numbering sequences.
-- Preserve uniqueness within each environment while allowing the configured real start.
begin;
drop index public.parking_simplified_series_number_unique;
create unique index parking_simplified_series_number_unique
on public.parking_simplified_invoices(series,serial_number,is_production)
where series is not null;
commit;
