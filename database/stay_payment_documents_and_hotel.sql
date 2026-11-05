-- Documents use the recorded payment, never the current total including extensions.
create or replace function private.stay_payment_rows(p_reservation_id uuid)
returns setof public.parking_cash_movements language sql stable security invoker set search_path='' as $$
 select m.* from public.parking_cash_movements m
 where (m.entity_type='reservation' and m.entity_id=p_reservation_id)
 or (m.entity_type='stay_change' and exists(select 1 from public.parking_stay_changes c where c.id=m.entity_id and c.reservation_id=p_reservation_id));
$$;

create or replace function public.parking_stay_payment_documents(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if not exists(select 1 from public.reservations where id=p_reservation_id) then raise exception 'Estancia inexistente';end if;
 select coalesce(jsonb_agg(jsonb_build_object('entity_type',m.entity_type,'entity_id',m.entity_id,
  'amount_eur',m.amount_eur,'paid_at',m.paid_at,'payment_method',m.payment_method,
  'invoice',coalesce((select to_jsonb(i)||jsonb_build_object('number',coalesce(i.display_number,i.number::text)) from public.parking_invoices i where i.entity_type=m.entity_type and i.entity_id=m.entity_id and i.is_production=private.parking_is_production(m.entity_type,m.entity_id,null) order by i.issued_at desc limit 1),
   (select private.parking_receipt_json(s.id) from public.parking_simplified_invoices s where s.movement_id=m.id and s.series in('OTH','OTD') and nullif(btrim(s.customer_name),'') is not null and nullif(btrim(s.customer_tax_id),'') is not null and nullif(btrim(s.customer_address),'') is not null order by s.issued_at desc limit 1)))
  order by case when m.entity_type='reservation' then 0 else 1 end,m.paid_at,m.id),'[]'::jsonb)
 into result from private.stay_payment_rows(p_reservation_id) m;
 return result;
end $$;

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
 -- Reuse existing fiscal documents before requesting customer data or issuing a number.
 select * into i from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is null
 and is_production=private.parking_is_production(p_entity_type,p_entity_id,null) order by issued_at desc limit 1;
 if found then return to_jsonb(i)||jsonb_build_object('number',coalesce(i.display_number,i.number::text));end if;
 select * into s from public.parking_simplified_invoices where movement_id=m.id for update;
 if found and s.series in('OTH','OTD') and nullif(btrim(s.customer_name),'') is not null and nullif(btrim(s.customer_tax_id),'') is not null and nullif(btrim(s.customer_address),'') is not null then return private.parking_receipt_json(s.id);end if;
 if v_name is null or v_tax is null or v_address is null then raise exception 'Completa nombre, NIF/CIF y domicilio para generar la factura';end if;
 if length(v_name)>200 or length(v_tax)>40 or length(v_address)>500 then raise exception 'Datos fiscales demasiado largos';end if;
 if s.id is not null and s.series in('OTH','OTD') then
  update public.parking_simplified_invoices set customer_name=v_name,customer_tax_id=v_tax,customer_address=v_address where id=s.id;
  return private.parking_receipt_json(s.id);
 end if;
 insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
 values(p_entity_type,p_entity_id,v_name,v_tax,v_address,
 case when p_entity_type='reservation' then 'Estancia inicial ' else 'Ampliación de estancia ' end||m.reference,m.plate,
 round(m.amount_eur/1.21,2),0,m.amount_eur-round(m.amount_eur/1.21,2),m.amount_eur) returning * into i;
 update public.parking_simplified_invoices set full_invoice_id=i.id where movement_id=m.id;
 return to_jsonb(i)||jsonb_build_object('number',coalesce(i.display_number,i.number::text));
end $$;

-- Keep hotel naming and payment/check-in in one transaction.
create or replace function public.parking_pay_enter_stay_named_hotel(
 p_reservation_id uuid,p_spot_id uuid,p_exit_at timestamptz,p_method text,p_amount_override numeric,p_adjustment_reason text,
 p_codes text[] default '{}',p_print_ticket boolean default false,p_invoice_customer jsonb default null,p_hotel_name text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare hotel uuid;hotel_name text:=upper(regexp_replace(btrim(coalesce(p_hotel_name,'')),'[[:space:]]+',' ','g'));r public.reservations;
begin
 perform public.rotation_operator_context();
 select * into r from public.reservations where id=p_reservation_id for update;
 if not found or r.status not in('confirmed','pending_payment') or r.payment_status='paid' or r.finished_at is not null then raise exception 'Reserva no disponible para cobro y entrada';end if;
 if p_method='hotel_voucher_old' then
  if length(hotel_name)<2 or length(hotel_name)>120 then raise exception 'Indica el nombre del hotel (2 a 120 caracteres)';end if;
  select id into hotel from public.parking_hotels where upper(regexp_replace(btrim(name),'[[:space:]]+',' ','g'))=hotel_name order by id limit 1;
  if hotel is null then insert into public.parking_hotels(name) values(hotel_name) on conflict(name) do update set name=excluded.name returning id into hotel;end if;
  update public.reservations set hotel_id=hotel where id=p_reservation_id;
 end if;
 return public.parking_pay_enter_stay_documents_adjusted(p_reservation_id,p_spot_id,p_exit_at,p_method,p_amount_override,p_adjustment_reason,p_codes,p_print_ticket,p_invoice_customer);
end $$;

revoke all on function private.stay_payment_rows(uuid) from public,anon,authenticated;
revoke all on function public.parking_stay_payment_documents(uuid) from public,anon;
revoke all on function public.parking_stay_payment_document(uuid,text,uuid,text,jsonb) from public,anon;
revoke all on function public.parking_pay_enter_stay_named_hotel(uuid,uuid,timestamptz,text,numeric,text,text[],boolean,jsonb,text) from public,anon;
grant execute on function public.parking_stay_payment_documents(uuid),public.parking_stay_payment_document(uuid,text,uuid,text,jsonb),public.parking_pay_enter_stay_named_hotel(uuid,uuid,timestamptz,text,numeric,text,text[],boolean,jsonb,text) to authenticated;
