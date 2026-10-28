create or replace function public.parking_convert_rotation_stay(p_session_id uuid,p_vehicle_type_id uuid,p_spot_id uuid,p_days integer,p_model text,p_method text default 'hotel_voucher',p_codes text[] default '{}',p_difference_method text default 'cash',p_print_ticket boolean default false,p_commit boolean default false,p_expected_amount numeric default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.rotation_sessions;r jsonb;doc jsonb;rot jsonb;rid uuid;covered integer:=0;price numeric:=0;difference numeric:=0;v_now timestamptz:=clock_timestamp();covered_until timestamptz;planned_exit timestamptz;charge_until timestamptz;tariff text;info jsonb;v_code text;i integer;
begin
 perform public.rotation_operator_context();
 select * into s from public.rotation_sessions where id=p_session_id for update;
 if not found then raise exception 'Ticket inexistente';end if;
 if s.converted_reservation_id is not null then return jsonb_build_object('id',s.converted_reservation_id,'already_converted',true);end if;
 if s.status<>'inside' or s.billing_only then raise exception 'El ticket no está dentro de Rotación';end if;
 if p_days is null or p_days not between 1 and 24 then raise exception 'Selecciona entre 1 y 24 días';end if;
 if p_method is null or p_method not in ('cash','card','hotel_voucher','hotel_voucher_old') then raise exception 'Forma de pago inválida';end if;
 if length(btrim(coalesce(p_model,'')))<2 then raise exception 'Completa marca/modelo';end if;
 perform 1 from public.parking_spots p where p.id=p_spot_id and p.active and private.spot_accepts_vehicle(p.id,p_vehicle_type_id) for update;
 if not found then raise exception 'Selecciona una plaza compatible';end if;
 planned_exit:=s.entry_at+p_days*interval '24 hours';
 if p_method in ('hotel_voucher','hotel_voucher_old') then
  if not exists(select 1 from public.vehicle_types where id=p_vehicle_type_id and vehicle_types.code='TURISMO') then raise exception 'Bonos hotel: solo turismos';end if;
  covered:=coalesce(cardinality(p_codes),0);
  if covered<1 or covered>p_days then raise exception 'Indica entre 1 y % bonos',p_days;end if;
  if p_method='hotel_voucher' then info:=private.resolve_hotel_voucher_codes(p_codes,false);
  else
   if (select count(distinct upper(btrim(x))) from unnest(p_codes) x)<>covered then raise exception 'Hay bonos antiguos repetidos';end if;
   foreach v_code in array p_codes loop if nullif(btrim(v_code),'') is null or length(v_code)>80 then raise exception 'Número de bono antiguo inválido';end if;end loop;
  end if;
  covered_until:=s.entry_at+covered*interval '24 hours';charge_until:=greatest(v_now,planned_exit);
  select t.code into tariff from public.rotation_tariffs t where t.id=s.tariff_id;
  if charge_until>covered_until then difference:=(public.calculate_rotation_amount(tariff,covered_until,charge_until)->>'amount_eur')::numeric;end if;
 else
  if coalesce(cardinality(p_codes),0)>0 then raise exception 'No introduzcas bonos para efectivo o tarjeta';end if;
  price:=private.stay_price(p_vehicle_type_id,p_days,s.entry_at);
  if price is null then raise exception 'Tarifa de estancia inexistente';end if;
 end if;
 if not p_commit then return jsonb_build_object('stay_amount',price,'difference_amount',difference,'total',price+difference,'entry_at',s.entry_at,'exit_at',planned_exit,'covered_until',covered_until,'charge_until',charge_until,'covered_days',covered);end if;
 if p_expected_amount is null or abs(round(p_expected_amount,2)-round(price+difference,2))>0.001 then raise exception 'El importe ha cambiado. Recalcula antes de confirmar';end if;
 if difference>0 then
  if p_difference_method is null or p_difference_method not in ('cash','card') then raise exception 'Selecciona el pago de la diferencia';end if;
  rot:=public.parking_checkout_rotation(s.id,difference,p_difference_method,p_print_ticket,'Diferencia al convertir a estancia; bonos: '||covered||'; cobertura hasta '||covered_until::text,null);
 else
  update public.rotation_sessions set status='cancelled',updated_at=v_now where id=s.id;
 end if;
 if p_method='hotel_voucher' then
  r:=public.parking_create_stay_from_vouchers(p_codes,p_vehicle_type_id,s.entry_at,covered,s.plate,p_model,s.client_text,null,null,'Convertida desde ticket '||s.ticket_number);
  rid:=(r->>'id')::uuid;
  update public.reservations set duration_days=p_days,exit_at=planned_exit where id=rid;
 else
  r:=public.parking_create_unpaid_stay(s.id,jsonb_build_object('vehicle_type_id',p_vehicle_type_id,'entry_at',s.entry_at,'days',p_days,'plate',s.plate,'model',p_model,'name',s.client_text,'notes','Convertida desde ticket '||s.ticket_number));rid:=(r->>'id')::uuid;
  if p_method in ('cash','card') then doc:=public.parking_collect_stay(rid,p_method,p_print_ticket);
  else
   for i in 1..covered loop insert into public.parking_legacy_hotel_vouchers(reservation_id,hotel_voucher_number,day_number,recorded_by) values(rid,upper(btrim(p_codes[i])),i,auth.uid());end loop;
   update public.reservations set amount_eur=0,manual_price_override=true,payment_method='hotel_voucher_old',payment_status='paid' where id=rid;
  end if;
 end if;
 perform public.backoffice_check_in(rid,p_spot_id,s.entry_at);
 update public.rotation_sessions set converted_reservation_id=rid,updated_at=v_now where id=s.id;
 return jsonb_build_object('id',rid,'receipt',doc->'receipt','rotation_receipt',rot->'receipt','difference_amount',difference);
end;$$;
revoke all on function public.parking_convert_rotation_stay(uuid,uuid,uuid,integer,text,text,text[],text,boolean,boolean,numeric) from public,anon;
grant execute on function public.parking_convert_rotation_stay(uuid,uuid,uuid,integer,text,text,text[],text,boolean,boolean,numeric) to authenticated;
