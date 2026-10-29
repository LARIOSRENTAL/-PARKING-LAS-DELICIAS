alter table public.parking_hotels add column if not exists invoice_customer_id uuid references public.parking_invoice_customers(id);
create index if not exists parking_hotels_invoice_customer_idx on public.parking_hotels(invoice_customer_id) where invoice_customer_id is not null;
create or replace function public.parking_hotel_invoice_customer(p_hotel_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager')) then raise exception 'No autorizado';end if;
 select jsonb_build_object('name',c.name,'tax_id',c.tax_id,'address',c.address) into result
 from public.parking_hotels h join public.parking_invoice_customers c on c.id=h.invoice_customer_id where h.id=p_hotel_id;
 return result;
end;
$$;
revoke all on function public.parking_hotel_invoice_customer(uuid) from public,anon;
grant execute on function public.parking_hotel_invoice_customer(uuid) to authenticated;
