CREATE OR REPLACE FUNCTION public.create_parking_hotel_batch(p_hotel_id uuid, p_days integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_start bigint; v_id uuid; v_price numeric;
begin
 if not private.is_staff() then raise exception 'Acceso no autorizado'; end if;
 if p_days is null or p_days<10 then raise exception 'Mínimo 10 días'; end if;
 perform 1 from public.parking_hotels where id=p_hotel_id and active=true for update;
 if not found then raise exception 'Hotel no válido'; end if;
 v_price:=case when p_days>=200 then 12 else 13 end;
 v_start:=nextval('public.parking_hotel_control_seq');
 insert into public.parking_hotel_batches(hotel_id,first_control,days,unit_price_eur)
 values(p_hotel_id,v_start,p_days,v_price) returning id into v_id;
 return jsonb_build_object('id',v_id,'first_control',v_start,'days',p_days,'unit_price_eur',v_price,'total_eur',p_days*v_price);
end $function$;

CREATE OR REPLACE FUNCTION public.create_parking_hotel_batch_by_name(p_hotel_name text, p_days integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_name text; v_hotel_id uuid; v_first bigint; v_batch uuid; v_price numeric;
begin
 if not private.is_staff() then raise exception 'Acceso no autorizado'; end if;
 v_name:=upper(regexp_replace(btrim(coalesce(p_hotel_name,'')),'[[:space:]]+',' ','g'));
 if length(v_name)<2 or length(v_name)>120 then raise exception 'Introduce un nombre de hotel válido (2 a 120 caracteres)'; end if;
 if p_days is null or p_days<10 then raise exception 'La compra mínima es de 10 días'; end if;
 select id into v_hotel_id from public.parking_hotels
 where upper(regexp_replace(btrim(name),'[[:space:]]+',' ','g'))=v_name limit 1;
 if v_hotel_id is null then
  insert into public.parking_hotels(name) values(v_name)
  on conflict(name) do update set name=excluded.name returning id into v_hotel_id;
 end if;
 perform 1 from public.parking_hotels where id=v_hotel_id and active for update;
 if not found then raise exception 'Este hotel está desactivado'; end if;
 v_price:=case when p_days>=200 then 12 else 13 end;
 v_first:=nextval('public.parking_hotel_control_seq');
 insert into public.parking_hotel_batches(hotel_id,first_control,days,unit_price_eur)
 values(v_hotel_id,v_first,p_days,v_price) returning id into v_batch;
 return jsonb_build_object('id',v_batch,'hotel_id',v_hotel_id,'hotel_name',v_name,'first_control',v_first,'days',p_days,'unit_price_eur',v_price,'total_eur',p_days*v_price);
end $function$;
