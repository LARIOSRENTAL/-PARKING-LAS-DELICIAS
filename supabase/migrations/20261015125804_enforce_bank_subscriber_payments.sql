-- Bank-designated subscribers keep the same payment method in every collection path.
create or replace function private.parking_force_subscriber_bank_method()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'monthly_subscribers' then
    if new.auto_email_bank then new.preferred_payment_method := 'bank'; end if;
  else
    if exists(select 1 from public.monthly_subscribers s where s.id = new.subscriber_id and s.auto_email_bank) then
      new.payment_method := 'bank';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.parking_force_subscriber_bank_method() from public, anon, authenticated;
create trigger parking_force_subscriber_bank_method before insert or update on public.monthly_subscribers
for each row execute function private.parking_force_subscriber_bank_method();
create trigger parking_force_monthly_payment_bank before insert or update on public.monthly_subscription_payments
for each row execute function private.parking_force_subscriber_bank_method();
