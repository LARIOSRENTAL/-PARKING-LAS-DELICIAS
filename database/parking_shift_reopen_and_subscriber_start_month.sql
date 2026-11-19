CREATE OR REPLACE FUNCTION private.parking_open_staff_shift(p_opening_balance numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'auth', 'pg_temp'
AS $function$
declare
  v_user uuid := auth.uid();
  v_shift public.staff_shifts%rowtype;
  v_now timestamptz;
  v_slot jsonb;
  v_next_slot jsonb;
  v_next_code smallint;
  v_next_date date;
  v_code smallint;
  v_date date;
  v_name text;
  v_role text;
  v_previous public.staff_shifts%rowtype;
begin
  if v_user is null or not private.is_staff() then
    raise exception 'Acceso no autorizado';
  end if;

  select full_name, role into v_name, v_role
  from public.staff_profiles
  where user_id=v_user and active=true;

  if v_name is null then
    raise exception 'Usuario no autorizado';
  end if;

  if v_role='admin' then
    raise exception 'El administrador utiliza acceso libre y no participa en turnos';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('parking-open-shift:'||v_user::text,0));
  select * into v_shift
  from public.staff_shifts
  where user_id=v_user and closed_at is null
  order by opened_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'ok',true,'already_open',true,'id',v_shift.id,
      'shift_number',v_shift.shift_code,
      'shift_code',v_shift.shift_code,
      'shift_date',v_shift.shift_date,
      'opened_at',v_shift.opened_at,
      'employee_name',v_name
    );
  end if;

  -- Serialize the handover and let the clock bound early openings.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('parking-business-day-shifts',0));
  v_now := clock_timestamp();
  v_slot := private.parking_shift_slot(v_now);
  v_code := (v_slot->>'shift_code')::smallint;
  v_date := (v_slot->>'shift_date')::date;

  select * into v_previous from public.staff_shifts order by opened_at desc limit 1;
  if found then
    if v_previous.closed_at is null then
      raise exception 'El turno anterior sigue abierto; debe cerrarse antes de iniciar otro';
    end if;
    -- Reopening the latest shift keeps the same cashbook and opening balance.
    if v_previous.user_id=v_user and v_previous.closed_at >= v_now-interval '15 minutes' then
      update public.staff_shifts set closed_at=null where id=v_previous.id returning * into v_shift;
      insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)
      values(v_shift.id,v_user,'shift_reopened','shift',v_shift.id,
        jsonb_build_object('shift_code',v_shift.shift_code,'shift_date',v_shift.shift_date,
          'employee_name',v_name,'previous_closed_at',v_previous.closed_at));
      return jsonb_build_object('ok',true,'already_open',false,'reopened',true,'id',v_shift.id,
        'shift_number',v_shift.shift_code,'shift_code',v_shift.shift_code,
        'shift_date',v_shift.shift_date,'opened_at',v_shift.opened_at,'employee_name',v_name);
    end if;
    v_next_code := case when v_previous.shift_code=3 then 1 else v_previous.shift_code+1 end;
    v_next_date := v_previous.shift_date + case when v_previous.shift_code=3 then 1 else 0 end;
    v_next_slot := private.parking_shift_slot(v_now + interval '15 minutes');
    if (v_next_date, v_next_code) = ((v_next_slot->>'shift_date')::date, (v_next_slot->>'shift_code')::smallint) then
      v_date := v_next_date;
      v_code := v_next_code;
    end if;
  end if;
  if exists(select 1 from public.staff_shifts where shift_date=v_date and shift_code=v_code) then
    raise exception 'El turno % de la jornada % ya esta asignado', v_code,v_date;
  end if;

  if v_date=date '2026-11-01' and v_code=1 and (p_opening_balance is null or p_opening_balance<0 or p_opening_balance>=10000000000 or p_opening_balance<>round(p_opening_balance,2)) then
    raise exception 'Introduce el saldo de caja a la entrada para iniciar el turno 1 del 1/11';
  end if;

  insert into public.staff_shifts(user_id,shift_code,shift_date)
  values(v_user,v_code,v_date)
  returning * into v_shift;

  if v_date=date '2026-11-01' and v_code=1 then
    perform private.parking_initialise_cash_opening(v_shift.id,p_opening_balance);
  end if;

  insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)
  values(v_shift.id,v_user,'shift_opened','shift',v_shift.id,
    jsonb_build_object(
      'shift_number',v_code,
      'shift_code',v_code,
      'shift_date',v_date,
      'employee_name',v_name
    ));

  return jsonb_build_object(
    'ok',true,'already_open',false,'id',v_shift.id,
    'shift_number',v_code,
    'shift_code',v_code,
    'shift_date',v_date,
    'opened_at',v_shift.opened_at,
    'employee_name',v_name
  );
end
$function$;

CREATE OR REPLACE FUNCTION private.subscriber_month_quote(p_id uuid, p_month date, p_at timestamp with time zone DEFAULT clock_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.monthly_subscribers;m public.monthly_subscription_payments;paid boolean;late boolean;price numeric;discount numeric;vat numeric;total numeric;rate numeric;cutoff timestamptz;alert_at timestamptz;review boolean;
begin
 if p_month is null or extract(day from p_month)<>1 then raise exception 'Mes no válido';end if;
 select * into s from public.monthly_subscribers where id=p_id;
 if not found then raise exception 'Abonado inexistente';end if;
 select * into m from public.monthly_subscription_payments where subscriber_id=p_id and billing_month=p_month;paid:=found;
 cutoff:=(p_month+9)::timestamp at time zone 'Europe/Madrid';alert_at:=(p_month+14)::timestamp at time zone 'Europe/Madrid';
 if paid and m.pricing_snapshot is not null then return m.pricing_snapshot||jsonb_build_object('paid',true,'overdue_alert',false);end if;
 if not paid and s.membership_start_date >= (p_month + interval '1 month')::date then
  return jsonb_build_object('price',0,'discount',0,'vat_pct',coalesce(s.vat_pct,21),'vat_eur',0,'total_eur',0,'discount_forfeited',false,'paid',false,'overdue_alert',false,'invoice_requires_review',false,'not_started',true);
 end if;
 -- Old settled months predate this policy. Never recalculate them as late payments.
 late:=not paid and p_at>=cutoff;
 price:=round(coalesce(s.price_eur,0),2);rate:=coalesce(s.vat_pct,21);
 discount:=case when late then 0 else least(price,greatest(0,coalesce(s.discount_amount_eur,round(price*coalesce(s.discount_pct,0)/100,2)))) end;
 if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then discount:=greatest(0,coalesce(s.discount_amount_eur,0));price:=s.total_eur+discount;rate:=0;end if;
 vat:=round(greatest(0,price-discount)*rate/100,2);total:=greatest(0,price-discount)+vat;
 review:=not paid and exists(select 1 from public.parking_invoices i where i.entity_type='subscriber' and i.entity_id=p_id and i.billing_month=p_month and i.is_production=(p_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') and i.total_eur<>total);
 return jsonb_build_object('price',price,'discount',discount,'vat_pct',rate,'vat_eur',vat,'total_eur',total,'discount_forfeited',late and coalesce(s.discount_amount_eur,round(price*coalesce(s.discount_pct,0)/100,2))>0,'discount_deadline',cutoff,'alert_from',alert_at,'paid',paid,'overdue_alert',s.active and total>0 and not paid and p_at>=alert_at and (s.membership_start_date is null or s.membership_start_date <= (p_at at time zone 'Europe/Madrid')::date),'invoice_requires_review',review,'receipt_discount_eur',case when exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then discount else null end);
end$function$;

CREATE OR REPLACE FUNCTION public.issue_parking_invoice(p_entity_type text, p_entity_id uuid, p_billing_month date DEFAULT NULL::date, p_customer_tax_id text DEFAULT NULL::text, p_customer_address text DEFAULT NULL::text)
 RETURNS parking_invoices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.parking_invoices; s public.monthly_subscribers; r public.reservations; v_price numeric; v_discount numeric; v_vat numeric; v_total numeric;
begin
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active=true and role in ('admin','manager')) and not(p_entity_type='reservation' and exists(select 1 from public.parking_cash_movements m where m.entity_type='reservation' and m.entity_id=p_entity_id and m.user_id=auth.uid() and m.shift_id=nullif(public.rotation_operator_context()->>'shift_id','')::uuid)) then raise exception 'Solo administradores y gerentes pueden emitir facturas';end if;
 if p_entity_type='subscriber' and exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=p_entity_id) then raise exception 'Este abonado recibe un recibo mensual sin factura';end if;
 if exists(select 1 from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month and is_production=private.parking_is_production(p_entity_type,p_entity_id,p_billing_month)) then select * into v from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month and is_production=private.parking_is_production(p_entity_type,p_entity_id,p_billing_month) order by issued_at desc limit 1;return v;end if;
 if p_entity_type='subscriber' then
  select * into s from public.monthly_subscribers where id=p_entity_id;
  if not found then raise exception 'Abonado inexistente';end if;
  if p_billing_month is null then raise exception 'Indica mes de facturación';end if;
  if s.membership_start_date >= (p_billing_month + interval '1 month')::date then raise exception 'El abono todavía no estaba de alta en ese mes'; end if;
  v_price:=(private.subscriber_month_quote(s.id,p_billing_month)->>'price')::numeric;v_discount:=(private.subscriber_month_quote(s.id,p_billing_month)->>'discount')::numeric;
  v_vat:=(private.subscriber_month_quote(s.id,p_billing_month)->>'vat_eur')::numeric;v_total:=(private.subscriber_month_quote(s.id,p_billing_month)->>'total_eur')::numeric;
  insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  values('subscriber',p_entity_id,p_billing_month,s.customer_name,coalesce(nullif(p_customer_tax_id,''),s.tax_id),coalesce(nullif(p_customer_address,''),concat_ws(' ',s.address,s.postal_code,s.city)),s.vehicle,s.plate,v_price,v_discount,v_vat,v_total)
  on conflict do nothing;
 elsif p_entity_type='reservation' then
  select * into r from public.reservations where id=p_entity_id;
  if not found then raise exception 'Estancia inexistente';end if;
  v_total:=r.amount_eur;v_price:=round(v_total/1.21,2);v_discount:=0;v_vat:=v_total-v_price;
  insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  values('reservation',p_entity_id,null,coalesce(r.customer_name,'Cliente sin identificar'),nullif(p_customer_tax_id,''),nullif(p_customer_address,''),r.vehicle_make_model,r.plate,v_price,v_discount,v_vat,v_total)
  on conflict do nothing;
 else raise exception 'Tipo de factura no válido';end if;
 select * into v from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month and is_production=private.parking_is_production(p_entity_type,p_entity_id,p_billing_month) order by issued_at desc limit 1;
 return v;
end;$function$;

CREATE OR REPLACE FUNCTION private.snapshot_subscriber_month_payment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q jsonb;
begin
 perform 1 from public.monthly_subscribers where id=new.subscriber_id for update;
 q:=private.subscriber_month_quote(new.subscriber_id,new.billing_month,clock_timestamp());
 if (q->>'not_started')::boolean then raise exception 'El abono todavía no estaba de alta en ese mes'; end if;
 if (q->>'invoice_requires_review')::boolean then raise exception 'La factura de este mes tiene un importe diferente. Revisa su rectificación antes de cobrar la cuota actualizada';end if;
 new.pricing_snapshot:=q;
 return new;
end$function$;

