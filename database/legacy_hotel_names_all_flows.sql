create or replace function private.legacy_stay_hotel(p_name text)
returns uuid language plpgsql security invoker set search_path='' as $$
declare v_name text:=upper(regexp_replace(btrim(coalesce(p_name,'')),'[[:space:]]+',' ','g'));hotel uuid;
begin
 if length(v_name)<2 or length(v_name)>120 then raise exception 'Es obligatorio indicar el nombre del hotel (2 a 120 caracteres)';end if;
 select h.id into hotel from public.parking_hotels h where upper(regexp_replace(btrim(h.name),'[[:space:]]+',' ','g'))=v_name order by h.id limit 1;
 if hotel is null then insert into public.parking_hotels(name)values(v_name)on conflict(name)do update set name=excluded.name returning id into hotel;end if;
 return hotel;
end $$;
revoke all on function private.legacy_stay_hotel(text) from public,anon,authenticated;

create or replace function public.parking_convert_rotation_stay_named_hotel(
 p_session_id uuid,p_vehicle_type_id uuid,p_spot_id uuid,p_days integer,p_model text,p_method text default 'hotel_voucher',p_codes text[] default '{}',p_difference_method text default 'cash',p_print_ticket boolean default false,p_commit boolean default false,p_expected_amount numeric default null,p_hotel_name text default null,p_notes text default null,p_finish boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;hotel uuid;previous uuid;
begin
 perform public.rotation_operator_context();
 if p_method='hotel_voucher_old' and (length(btrim(coalesce(p_hotel_name,'')))<2 or length(btrim(p_hotel_name))>120) then raise exception 'Es obligatorio indicar el nombre del hotel';end if;
 select converted_reservation_id into previous from public.rotation_sessions where id=p_session_id for update;
 if p_finish then result:=public.parking_finish_hotel_rotation(p_session_id,p_vehicle_type_id,p_spot_id,p_days,p_model,p_method,p_codes,p_difference_method,p_print_ticket,p_commit,p_expected_amount);
 else result:=public.parking_convert_rotation_stay(p_session_id,p_vehicle_type_id,p_spot_id,p_days,p_model,p_method,p_codes,p_difference_method,p_print_ticket,p_commit,p_expected_amount);end if;
 if p_commit and previous is null and result->>'id' is not null then
  if p_method='hotel_voucher_old' then hotel:=private.legacy_stay_hotel(p_hotel_name);end if;
  update public.reservations set hotel_id=coalesce(hotel,hotel_id),notes=case when nullif(btrim(p_notes),'') is not null then concat_ws(E'\n',btrim(p_notes),nullif(notes,'')) else notes end,updated_at=clock_timestamp() where id=(result->>'id')::uuid;
 end if;
 return result;
end $$;

create or replace function public.parking_pay_enter_stay_named_hotel_notes(
 p_reservation_id uuid,p_spot_id uuid,p_exit_at timestamptz,p_method text,p_amount_override numeric,p_adjustment_reason text,p_codes text[] default '{}',p_print_ticket boolean default false,p_invoice_customer jsonb default null,p_hotel_name text default null,p_notes text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=public.parking_pay_enter_stay_named_hotel(p_reservation_id,p_spot_id,p_exit_at,p_method,p_amount_override,p_adjustment_reason,p_codes,p_print_ticket,p_invoice_customer,p_hotel_name);
 update public.reservations set notes=nullif(btrim(p_notes),''),updated_at=clock_timestamp() where id=p_reservation_id;
 return result;
end $$;
revoke all on function public.parking_convert_rotation_stay_named_hotel(uuid,uuid,uuid,integer,text,text,text[],text,boolean,boolean,numeric,text,text,boolean),public.parking_pay_enter_stay_named_hotel_notes(uuid,uuid,timestamptz,text,numeric,text,text[],boolean,jsonb,text,text) from public,anon;
grant execute on function public.parking_convert_rotation_stay_named_hotel(uuid,uuid,uuid,integer,text,text,text[],text,boolean,boolean,numeric,text,text,boolean),public.parking_pay_enter_stay_named_hotel_notes(uuid,uuid,timestamptz,text,numeric,text,text[],boolean,jsonb,text,text) to authenticated;

-- Deferred guards let the conversion wrapper attach the hotel atomically, before commit.
-- Historical movements/notes are still editable; new legacy redemptions always require a hotel.
create or replace function private.require_legacy_stay_hotel()
returns trigger language plpgsql security definer set search_path='' as $$
declare rid uuid;check_name boolean:=false;
begin
 if tg_table_name='reservations' then
  if new.payment_method='hotel_voucher_old' and new.payment_status='paid' then
   if tg_op='INSERT' then check_name:=true;
   else check_name:=old.payment_method is distinct from new.payment_method or old.payment_status is distinct from new.payment_status or old.hotel_id is distinct from new.hotel_id;end if;
  end if;
  if not check_name then return new;end if;rid:=new.id;
 else rid:=new.reservation_id;end if;
 if not exists(select 1 from public.reservations r join public.parking_hotels h on h.id=r.hotel_id where r.id=rid and length(btrim(h.name))>=2) then raise exception 'Los bonos hotel antiguos necesitan el nombre del hotel. Abre la ficha y complétalo antes de guardar';end if;
 return new;
end $$;
drop trigger if exists require_legacy_stay_hotel on public.reservations;
create constraint trigger require_legacy_stay_hotel after insert or update on public.reservations deferrable initially deferred for each row execute function private.require_legacy_stay_hotel();
drop trigger if exists require_legacy_stay_hotel on public.parking_legacy_hotel_vouchers;
create constraint trigger require_legacy_stay_hotel after insert on public.parking_legacy_hotel_vouchers deferrable initially deferred for each row execute function private.require_legacy_stay_hotel();
revoke all on function private.require_legacy_stay_hotel() from public,anon,authenticated;
CREATE OR REPLACE FUNCTION public.parking_save_stay_changes(p_request_id uuid, p_reservation_id uuid, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare ctx jsonb;r public.reservations;updated public.reservations;c public.parking_stay_changes;info jsonb;invoice jsonb;receipt jsonb;days integer:=(p_data->>'days')::integer;type_id uuid:=(p_data->>'vehicle_type_id')::uuid;method text:=p_data->>'payment_method';amount numeric:=round((p_data->>'amount_eur')::numeric,2);diff numeric;added integer;entry_time timestamptz:=(p_data->>'entry_at')::timestamptz;legacy_hotel uuid;legacy_code text;legacy_position integer;legacy_codes text[];
begin
 ctx:=public.rotation_operator_context();if p_request_id is null then raise exception 'Falta el identificador de operación';end if;
 perform pg_advisory_xact_lock(hashtextextended('stay-change:'||p_request_id,0));
 select * into c from public.parking_stay_changes where id=p_request_id;
 if found then
  if c.created_by<>auth.uid() or c.reservation_id<>p_reservation_id then raise exception 'No autorizado';end if;
  select * into updated from public.reservations where id=c.reservation_id;
 else
  select * into r from public.reservations where id=p_reservation_id for update;
  if not found or r.status not in ('confirmed','checked_in','pending_payment') or r.rotation_pending or r.finished_at is not null then raise exception 'Esta estancia no se puede modificar';end if;
  if (p_data->>'expected_updated_at')::timestamptz is distinct from r.updated_at then raise exception 'La reserva ha cambiado. Actualiza la ficha antes de guardar';end if;
  if method is null or method not in ('cash','card','hotel_voucher','hotel_voucher_old') or days is null or days<1 or days>24 or entry_time is null or amount is null or amount<0 or amount>999999 then raise exception 'Revisa duración, precio, entrada y forma de pago';end if;
  if length(btrim(coalesce(p_data->>'plate','')))<3 or length(btrim(coalesce(p_data->>'model','')))<1 then raise exception 'Completa matrícula y marca/modelo';end if;
  if exists(select 1 from public.parking_sessions where reservation_id=r.id) and entry_time<>r.entry_at then raise exception 'No se puede cambiar la entrada inicial de una estancia iniciada';end if;
  if r.assigned_spot_id is not null and not private.spot_accepts_vehicle(r.assigned_spot_id,type_id) then raise exception 'La plaza actual no admite este tamaño. Cambia primero a una plaza compatible';end if;
  if private.stay_price(type_id,days,entry_time) is null then raise exception 'No existe tarifa para esta categoría y duración';end if;
  added:=days-r.duration_days;
  if method='hotel_voucher' then
   if not exists(select 1 from public.vehicle_types where id=type_id and code='TURISMO') then raise exception 'Los bonos hotel solo son válidos para turismos';end if;
   if added<0 then raise exception 'Los bonos canjeados no se pueden devolver desde esta ficha';end if;
   if added>0 then
    info:=private.resolve_hotel_voucher_codes(array(select jsonb_array_elements_text(p_data->'codes')),true);
    if (info->>'available_days')::integer<added then raise exception 'Bonos insuficientes';end if;
    if (info->>'days')::integer<>added then raise exception 'Aporta un bono por cada día adicional';end if;
    if r.hotel_id is not null and r.hotel_id<>(info->>'hotel_id')::uuid then raise exception 'Utiliza bonos del mismo hotel';end if;
    perform 1 from public.parking_hotels where id=(info->>'hotel_id')::uuid for update;
    insert into public.parking_hotel_redemptions(reservation_id,hotel_id,days) values(r.id,(info->>'hotel_id')::uuid,added)
    on conflict(reservation_id) do update set days=parking_hotel_redemptions.days+excluded.days;
    update public.parking_hotel_vouchers set redeemed_reservation_id=r.id,redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where code in(select jsonb_array_elements_text(info->'codes'));
   end if;
   amount:=r.amount_eur;diff:=0;
  elsif method='hotel_voucher_old' then
   if not exists(select 1 from public.vehicle_types where id=type_id and code='TURISMO') then raise exception 'Los bonos hotel solo son válidos para turismos';end if;
   if added<0 then raise exception 'Los bonos canjeados no se pueden devolver desde esta ficha';end if;
   legacy_hotel:=private.legacy_stay_hotel(p_data->>'hotel_name');
   if r.payment_method='hotel_voucher' and r.hotel_id is not null and r.hotel_id<>legacy_hotel then raise exception 'Utiliza bonos del mismo hotel';end if;
   update public.reservations set hotel_id=legacy_hotel where id=r.id;
   legacy_codes:=array(select upper(btrim(x)) from jsonb_array_elements_text(coalesce(p_data->'codes','[]'::jsonb)) x);
   if coalesce(cardinality(legacy_codes),0)<>added or (select count(distinct x) from unnest(legacy_codes)x)<>added then raise exception 'Aporta un bono antiguo distinto por cada día adicional';end if;
   select coalesce(max(day_number),0) into legacy_position from public.parking_legacy_hotel_vouchers where reservation_id=r.id;
   foreach legacy_code in array legacy_codes loop
    if length(legacy_code)<1 or length(legacy_code)>80 then raise exception 'Número de bono antiguo incorrecto';end if;
    legacy_position:=legacy_position+1;
    insert into public.parking_legacy_hotel_vouchers(reservation_id,hotel_voucher_number,day_number,recorded_by)values(r.id,legacy_code,legacy_position,auth.uid());
   end loop;
   amount:=r.amount_eur;diff:=0;
  else
   diff:=round(amount-r.amount_eur,2);
   if diff<0 then raise exception 'El precio no puede ser inferior al ya abonado. La devolución requiere una rectificación';end if;
   if diff>0 and r.payment_status<>'paid' then raise exception 'El pago inicial no consta registrado. Verifica ese pago antes de cobrar una ampliación';end if;
  end if;
  update public.reservations set vehicle_type_id=type_id,entry_at=entry_time,duration_days=days,amount_eur=amount,manual_price_override=true,plate=upper(btrim(p_data->>'plate')),vehicle_make_model=upper(btrim(p_data->>'model')),customer_name=nullif(btrim(p_data->>'name'),''),customer_phone=nullif(btrim(p_data->>'phone'),''),customer_email=nullif(btrim(p_data->>'email'),''),notes=nullif(btrim(p_data->>'notes'),''),hotel_id=coalesce(legacy_hotel,r.hotel_id,(info->>'hotel_id')::uuid),updated_at=clock_timestamp() where id=r.id returning * into updated;
  update public.parking_sessions set vehicle_type_id=updated.vehicle_type_id,plate=updated.plate,vehicle_make_model=updated.vehicle_make_model,customer_name=updated.customer_name,customer_phone=updated.customer_phone,planned_exit_at=updated.exit_at,updated_at=clock_timestamp() where reservation_id=r.id;
  insert into public.parking_stay_changes(id,reservation_id,created_by,payment_method,amount_eur,before_data,after_data) values(p_request_id,r.id,auth.uid(),method,coalesce(diff,0),to_jsonb(r),to_jsonb(updated)) returning * into c;
  if diff>0 then
   insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,reference,plate,description,amount_eur,payment_method,user_id,shift_id,employee_name,details)
   values('stay_change:'||c.id,'stay','stay_change',c.id,r.reference,updated.plate,'Ampliación / modificación de estancia',diff,method,auth.uid(),nullif(ctx->>'shift_id','')::uuid,ctx->>'employee_name',jsonb_build_object('reservation_id',r.id,'entry_at',updated.entry_at,'exit_at',updated.exit_at,'old_exit_at',r.exit_at));
  end if;
 end if;
 if c.amount_eur>0 then
  if p_data->'invoice_customer' is not null and p_data->'invoice_customer'<>'null'::jsonb then
   invoice:=public.parking_issue_full_invoice('stay_change',c.id,null,p_data->'invoice_customer'->>'name',p_data->'invoice_customer'->>'tax_id',p_data->'invoice_customer'->>'address');
  elsif coalesce((p_data->>'print_ticket')::boolean,false) or c.payment_method='card' then receipt:=public.parking_issue_simplified('stay_change',c.id);end if;
 end if;
 if c.amount_eur>0 and c.payment_method='card' and receipt is null then receipt:=public.parking_issue_simplified('stay_change',c.id);end if;
 return jsonb_build_object('reservation',to_jsonb(updated),'change',to_jsonb(c),'receipt',receipt,'invoice',invoice);
end $function$;

create or replace view public.reservation_backoffice with (security_invoker=true) as
 WITH last_movement AS (
         SELECT DISTINCT ON (s.reservation_id) s.reservation_id,
            e.event_type,
            e.event_at
           FROM parking_sessions s
             JOIN parking_events e ON e.session_id = s.id
          WHERE s.reservation_id IS NOT NULL AND (e.event_type = ANY (ARRAY['check_in'::text, 'check_out'::text]))
          ORDER BY s.reservation_id, e.event_at DESC, e.id DESC
        )
 SELECT r.id,
    r.reference,
    r.vehicle_type_id,
    vt.code AS vehicle_type_code,
    vt.name AS vehicle_type_name,
    r.entry_at,
    r.exit_at,
    r.duration_days,
    r.customer_name,
    r.customer_email,
    r.customer_phone,
    r.plate,
    r.vehicle_make_model,
    r.status,
    r.payment_status,
    r.amount_eur,
    r.source,
    r.notes,
    r.created_at,
    r.updated_at,
    0::numeric(8,2) AS overstay_rate_hour_eur,
    0::bigint AS overstay_minutes,
    0::numeric AS overstay_total_eur,
    0::numeric AS overstay_due_eur,
    NULL::timestamp with time zone AS overstay_paid_at,
    0::numeric(10,2) AS overstay_paid_amount_eur,
        CASE
            WHEN lm.event_type = 'check_in'::text THEN 'DENTRO'::text
            ELSE 'FUERA'::text
        END AS vehicle_presence,
    lm.event_at AS last_movement_at,
        CASE
            WHEN r.status = 'cancelled'::text THEN 'finished'::text
            WHEN r.rotation_pending THEN 'rotation_pending'::text
            WHEN lm.event_type = 'check_in'::text AND clock_timestamp() > r.exit_at THEN 'overdue'::text
            WHEN (r.status <> ALL (ARRAY['completed'::text, 'cancelled'::text])) AND clock_timestamp() >= (r.exit_at - '03:00:00'::interval) AND clock_timestamp() <= r.exit_at THEN 'due_soon'::text
            ELSE 'normal'::text
        END AS attention_state,
    r.assigned_spot_id,
    r.payment_method,
    r.tariff_amount_eur,
    r.manual_price_override,
    r.rotation_pending,
    r.rotation_session_id,
        CASE
            WHEN r.payment_method = 'hotel_voucher'::text THEN COALESCE(( SELECT string_agg(COALESCE(v.number::text, v.code), ', '::text ORDER BY v.number) AS string_agg
               FROM parking_hotel_vouchers v
              WHERE v.redeemed_reservation_id = r.id), r.reference)
            WHEN r.payment_method = 'hotel_voucher_old'::text THEN COALESCE(( SELECT string_agg(v.hotel_voucher_number, ', '::text ORDER BY v.day_number) AS string_agg
               FROM parking_legacy_hotel_vouchers v
              WHERE v.reservation_id = r.id), r.reference)
            ELSE r.reference
        END AS control_reference,
    r.hotel_id,
    (select h.name from public.parking_hotels h where h.id=r.hotel_id) as hotel_name
   FROM reservations r
     JOIN vehicle_types vt ON vt.id = r.vehicle_type_id
     LEFT JOIN last_movement lm ON lm.reservation_id = r.id;
