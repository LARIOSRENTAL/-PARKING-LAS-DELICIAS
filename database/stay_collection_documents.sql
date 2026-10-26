create or replace function public.parking_pay_enter_stay_documents(p_reservation_id uuid,p_spot_id uuid,p_exit_at timestamptz,p_method text,p_codes text[] default '{}'::text[],p_print_ticket boolean default false,p_invoice_customer jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;invoice jsonb;
begin
 perform public.rotation_operator_context();
 if p_invoice_customer is not null then
  if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager')) then raise exception 'Solo administradores y gerentes pueden generar facturas de estancias';end if;
  if p_method not in('cash','card') then raise exception 'Los bonos hotel ya están pagados y no generan otra factura al canjearse';end if;
  if nullif(btrim(p_invoice_customer->>'name'),'') is null or nullif(btrim(p_invoice_customer->>'tax_id'),'') is null or nullif(btrim(p_invoice_customer->>'address'),'') is null then raise exception 'Completa nombre, NIF/CIF y domicilio para la factura';end if;
 end if;
 result:=public.parking_pay_and_enter_stay_with_exit(p_reservation_id,p_spot_id,p_exit_at,p_method,p_codes,p_print_ticket);
 if p_invoice_customer is not null then
  invoice:=public.parking_issue_full_invoice('reservation',p_reservation_id,null,p_invoice_customer->>'name',p_invoice_customer->>'tax_id',p_invoice_customer->>'address');
 end if;
 return result||jsonb_build_object('invoice',invoice);
end;$$;
revoke all on function public.parking_pay_enter_stay_documents(uuid,uuid,timestamptz,text,text[],boolean,jsonb) from public,anon;
grant execute on function public.parking_pay_enter_stay_documents(uuid,uuid,timestamptz,text,text[],boolean,jsonb) to authenticated;
