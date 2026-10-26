CREATE OR REPLACE FUNCTION public.parking_create_unpaid_stay(p_request_id uuid, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;r public.reservations;d integer:=(p_data->>'days')::integer;tid uuid:=(p_data->>'vehicle_type_id')::uuid;e timestamptz:=(p_data->>'entry_at')::timestamptz;price numeric;x timestamptz:=nullif(p_data->>'exit_at','')::timestamptz;
begin
ctx:=public.rotation_operator_context();
if p_request_id is null then raise exception 'Identificador obligatorio';end if;
perform pg_advisory_xact_lock(hashtextextended('unpaid-stay:'||p_request_id,0));
select * into r from public.reservations where creation_request_id=p_request_id;
if found then return to_jsonb(r);end if;
if x is not null then
 if e is null or x<=e then raise exception 'La salida debe ser posterior a la entrada';end if;
 d:=ceil(extract(epoch from (x-e))/86400.0)::integer;
end if;
if d is null or d not between 1 and 24 or e is null or length(trim(coalesce(p_data->>'plate','')))<3 or length(trim(coalesce(p_data->>'model','')))<2 then raise exception 'Datos de estancia incompletos';end if;
price:=private.stay_price(tid,d,e);if price is null then raise exception 'Tarifa no encontrada';end if;
insert into public.reservations(creation_request_id,vehicle_type_id,entry_at,exit_at,duration_days,plate,vehicle_make_model,customer_name,customer_phone,customer_email,notes,status,payment_status,payment_method,amount_eur,manual_price_override,source,created_by)
values(p_request_id,tid,e,x,d,upper(trim(p_data->>'plate')),upper(trim(p_data->>'model')),nullif(trim(p_data->>'name'),''),nullif(trim(p_data->>'phone'),''),nullif(trim(p_data->>'email'),''),nullif(trim(p_data->>'notes'),''),'confirmed','pending',null,price,false,'admin',auth.uid()) returning * into r;
return to_jsonb(r);
end $function$
;

