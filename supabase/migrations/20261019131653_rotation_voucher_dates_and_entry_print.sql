-- A hotel voucher covers exactly 24 hours from the original rotation entry.
create or replace function public.parking_rotation_to_stay_with_vouchers(p_session_id uuid,p_vehicle_type_id uuid,p_spot_id uuid,p_days integer,p_model text,p_codes text[]) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;s public.rotation_sessions;r jsonb;
begin
 ctx:=public.rotation_operator_context();select * into s from public.rotation_sessions where id=p_session_id for update;
 if not found then raise exception 'Ticket inexistente';end if;
 if s.converted_reservation_id is not null then return jsonb_build_object('id',s.converted_reservation_id,'already_converted',true);end if;
 if s.status<>'inside' or s.billing_only then raise exception 'Este ticket no se puede convertir a estancia';end if;
 p_days:=cardinality(p_codes);
 if p_days is null or p_days<1 or p_days>24 then raise exception 'Indica entre 1 y 24 bonos de hotel';end if;
 if s.entry_at+p_days*interval '24 hours'<=clock_timestamp() then raise exception 'Los bonos indicados no cubren hasta después de la hora actual';end if;
 perform 1 from public.parking_spots p where p.id=p_spot_id and private.spot_accepts_vehicle(p.id,p_vehicle_type_id) for update;
 if not found then raise exception 'Selecciona una plaza válida para el tamaño del vehículo';end if;
 update public.rotation_sessions set status='cancelled' where id=s.id;
 r:=public.parking_create_stay_from_vouchers(p_codes,p_vehicle_type_id,s.entry_at,p_days,s.plate,p_model,s.client_text,null,null,'Convertida desde ticket de rotación '||s.ticket_number);
 perform public.backoffice_check_in((r->>'id')::uuid,p_spot_id,s.entry_at);
 update public.rotation_sessions set status='cancelled',converted_reservation_id=(r->>'id')::uuid,updated_at=clock_timestamp() where id=s.id;
 return r;
end $$;
revoke all on function public.parking_rotation_to_stay_with_vouchers(uuid,uuid,uuid,integer,text,text[]) from public,anon;
grant execute on function public.parking_rotation_to_stay_with_vouchers(uuid,uuid,uuid,integer,text,text[]) to authenticated;
