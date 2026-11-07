alter table public.parking_stay_changes drop constraint parking_stay_changes_payment_method_check;
alter table public.parking_stay_changes add constraint parking_stay_changes_payment_method_check check (payment_method in ('cash','card','hotel_voucher','hotel_voucher_old'));
