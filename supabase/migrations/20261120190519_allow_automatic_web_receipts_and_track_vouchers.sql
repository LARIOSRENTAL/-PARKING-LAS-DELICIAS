alter table public.parking_simplified_invoices
  add constraint parking_simplified_invoices_issuer_required
  check (issued_by is not null or coalesce(snapshot->>'entity_type' = 'reservation' and snapshot->>'payment_method' = 'online', false));
alter table public.parking_simplified_invoices alter column issued_by drop not null;

alter table public.reservations
  add column web_voucher_customer_message_id text,
  add column web_voucher_office_message_id text;
