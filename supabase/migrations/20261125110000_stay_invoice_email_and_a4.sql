-- Full invoices requested for completed stay payments must stay A4 even when a fiscalized simplified receipt exists.
create or replace function public.parking_stay_payment_document(p_reservation_id uuid,p_entity_type text,p_entity_id uuid,p_kind text,p_customer jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.parking_cash_movements;s public.parking_simplified_invoices;i public.parking_invoices;
 v_name text:=nullif(btrim(p_customer->>'name'),'');v_tax text:=nullif(btrim(p_customer->>'tax_id'),'');v_address text:=nullif(btrim(p_customer->>'address'),'');
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if p_entity_type not in('reservation','stay_change') or p_kind not in('ticket','invoice') or p_kind is null then raise exception 'Documento no válido';end if;
 select * into m from public.parking_cash_movements where id in(select id from private.stay_payment_rows(p_reservation_id))
 and entity_type=p_entity_type and entity_id=p_entity_id order by paid_at desc limit 1 for update;
 if not found then raise exception 'Este pago no consta registrado en la estancia. No se ha realizado ningún cobro';end if;
 if p_kind='ticket' then return public.parking_issue_simplified(p_entity_type,p_entity_id);end if;
 select * into i from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is null
 and is_production=private.parking_is_production(p_entity_type,p_entity_id,null) order by issued_at desc limit 1;
 if found then return to_jsonb(i)||jsonb_build_object('number',coalesce(i.display_number,i.number::text));end if;
 select * into s from public.parking_simplified_invoices where movement_id=m.id for update;
 if v_name is null or v_tax is null or v_address is null then raise exception 'Completa nombre, NIF/CIF y domicilio para generar la factura';end if;
 if length(v_name)>200 or length(v_tax)>40 or length(v_address)>500 then raise exception 'Datos fiscales demasiado largos';end if;
 insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
 values(p_entity_type,p_entity_id,v_name,v_tax,v_address,
 case when p_entity_type='reservation' then 'Estancia inicial ' else 'Ampliación de estancia ' end||m.reference,m.plate,
 round(m.amount_eur/1.21,2),0,m.amount_eur-round(m.amount_eur/1.21,2),m.amount_eur) returning * into i;
 if s.id is not null then update public.parking_simplified_invoices set full_invoice_id=i.id where id=s.id;end if;
 return to_jsonb(i)||jsonb_build_object('number',coalesce(i.display_number,i.number::text));
end $$;

alter table public.parking_invoice_customers add column if not exists email text;

create or replace function public.parking_invoice_customer_email(p_tax_id text)
returns text language plpgsql security definer set search_path='' as $$
declare value text;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select email into value from public.parking_invoice_customers
 where tax_key=regexp_replace(upper(coalesce(p_tax_id,'')),'[^A-Z0-9]','','g') limit 1;
 return value;
end $$;

create or replace function public.parking_save_invoice_customer_email(p_tax_id text,p_email text)
returns text language plpgsql security definer set search_path='' as $$
declare value text:=nullif(lower(btrim(p_email)),'');
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if value is not null and (length(value)>254 or value !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'Introduce un correo electrónico válido';end if;
 update public.parking_invoice_customers set email=value,updated_at=clock_timestamp()
 where tax_key=regexp_replace(upper(coalesce(p_tax_id,'')),'[^A-Z0-9]','','g');
 if not found then raise exception 'No se encontró la ficha fiscal del cliente';end if;
 return value;
end $$;
revoke all on function public.parking_invoice_customer_email(text),public.parking_save_invoice_customer_email(text,text) from public,anon;
grant execute on function public.parking_invoice_customer_email(text),public.parking_save_invoice_customer_email(text,text) to authenticated;
revoke all on function public.parking_stay_payment_document(uuid,text,uuid,text,jsonb) from public,anon;
grant execute on function public.parking_stay_payment_document(uuid,text,uuid,text,jsonb) to authenticated;
