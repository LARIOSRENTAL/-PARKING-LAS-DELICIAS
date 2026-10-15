-- Five-unit test purchases are administrative fixtures; real purchases keep the ten-day minimum.
alter table public.parking_hotel_batches drop constraint parking_hotel_batches_days_check;
alter table public.parking_hotel_batches add constraint parking_hotel_batches_days_check check(days>=10 or (is_test and days between 1 and 9));
-- Preserve historical EUR 12 purchases while allowing the configured EUR 13 price below 200 units.
alter table public.parking_hotel_batches drop constraint parking_hotel_batches_unit_price_eur_check;
alter table public.parking_hotel_batches add constraint parking_hotel_batches_unit_price_eur_check check(unit_price_eur in(12,13));
