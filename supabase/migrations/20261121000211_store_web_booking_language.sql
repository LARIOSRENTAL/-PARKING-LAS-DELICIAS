alter table public.reservations add column if not exists booking_language text not null default 'es' check (booking_language in ('es','en','fr','it','de'));
