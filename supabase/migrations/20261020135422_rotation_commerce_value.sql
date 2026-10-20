CREATE OR REPLACE FUNCTION private.capture_parking_cash()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_key text;v_category text;v_type text;v_entity uuid;v_ref text;v_plate text;v_desc text;v_amount numeric;v_method text;v_paid timestamptz;v_user uuid;v_shift uuid;v_name text;v_details jsonb:='{}';
begin
 if tg_table_name='rotation_sessions' then
  if new.status<>'departed' or new.paid_at is null then return new;end if;
  v_key:='rotation:'||new.id;v_category:='rotation';v_type:='rotation';v_entity:=new.id;v_ref:=new.ticket_number::text;v_plate:=new.plate;v_desc:='Estacionamiento por horas';v_amount:=new.amount_eur;v_method:=new.payment_method;v_paid:=new.paid_at;v_user:=new.exit_user_id;v_shift:=new.exit_shift_id;v_name:=new.exit_employee_name;
  v_details:=jsonb_build_object('entry_at',new.entry_at,'exit_at',new.exit_at,'tariff_amount_eur',new.tariff_amount_eur,'discount_bono_eur',new.discount_bono_eur);
 elsif tg_table_name='monthly_subscription_payments' then
  if tg_op='UPDATE' then return new;end if;
  v_key:='subscriber:'||new.id;v_category:='subscriber';v_type:='subscriber_payment';v_entity:=new.id;v_ref:=to_char(new.billing_month,'YYYY-MM');
  select greatest(0,price_eur-coalesce(discount_amount_eur,round(price_eur*coalesce(discount_pct,0)/100,2)))*(1+coalesce(vat_pct,21)/100),plate,customer_name into v_amount,v_plate,v_desc from public.monthly_subscribers where id=new.subscriber_id;
  v_amount:=coalesce((new.pricing_snapshot->>'total_eur')::numeric,v_amount);v_details:=coalesce(new.pricing_snapshot,'{}'::jsonb);v_desc:='Abono mensual · '||coalesce(v_desc,'');v_method:=new.payment_method;v_paid:=new.paid_at;v_user:=new.paid_by;

 elsif tg_table_name='parking_hotel_batches' then
  if new.is_test or new.is_void or new.payment_status<>'paid' then return new;end if;
  v_key:='hotel_batch:'||new.id;v_category:='stay';v_type:='hotel_batch';v_entity:=new.id;
  v_ref:=coalesce(new.registration_first,new.first_control::text);v_amount:=new.days*new.unit_price_eur;
  v_method:=new.payment_method;v_paid:=new.paid_at;v_user:=new.paid_by;v_shift:=new.paid_shift_id;
  select 'Compra de '||new.days||' bonos · '||name into v_desc from public.parking_hotels where id=new.hotel_id;
  v_details:=jsonb_build_object('days',new.days,'unit_price_eur',new.unit_price_eur,'prepared_at',new.created_at,'registration_first',new.registration_first,'registration_last',new.registration_last);
 elsif tg_table_name='reservations' then
  if new.payment_status<>'paid' or coalesce(new.payment_method,'') not in ('cash','card','online') or new.amount_eur is null then return new;end if;
  if tg_op='UPDATE' and old.payment_status='paid' then return new;end if;
  v_key:='reservation:'||new.id;v_category:='stay';v_type:='reservation';v_entity:=new.id;v_ref:=new.reference;v_plate:=new.plate;v_desc:='Estancia por días';v_amount:=new.amount_eur;v_method:=new.payment_method;v_paid:=clock_timestamp();v_user:=coalesce(auth.uid(),new.created_by);
  v_details:=jsonb_build_object('entry_at',new.entry_at,'exit_at',new.exit_at);
 end if;
 if v_amount is null or (v_method is null and not(v_type='rotation' and v_amount=0)) then return new;end if;
 if v_shift is null then select id into v_shift from public.staff_shifts where user_id=v_user and closed_at is null order by opened_at desc limit 1;end if;
 if v_name is null then select full_name into v_name from public.staff_profiles where user_id=v_user;end if;
 insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,reference,plate,description,amount_eur,payment_method,paid_at,user_id,shift_id,employee_name,details)
 values(v_key,v_category,v_type,v_entity,coalesce(v_ref,''),v_plate,coalesce(v_desc,''),round(v_amount,2),v_method,v_paid,v_user,v_shift,v_name,v_details) on conflict(source_key) do nothing;
 return new;
end $function$
;

-- Commerce vouchers reduce the capped payable amount by the value of one hour.
create or replace function public.parking_rotation_quote(p_tariff_code text,p_entry_at timestamptz,p_exit_at timestamptz,p_free_hours integer default 0) returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare quote jsonb;hour_quote jsonb;unit_value numeric;final_amount numeric;
begin
 if p_free_hours is null or p_free_hours<0 or p_free_hours>10000 then raise exception 'Número de bonos inválido';end if;
 quote:=public.calculate_rotation_amount(p_tariff_code,p_entry_at,p_exit_at);
 hour_quote:=public.calculate_rotation_amount(p_tariff_code,p_entry_at,p_entry_at+interval '1 hour');
 unit_value:=(hour_quote->>'amount_eur')::numeric;
 final_amount:=greatest(0,round((quote->>'amount_eur')::numeric-p_free_hours*unit_value,2));
 return quote||jsonb_build_object('exit_at',p_exit_at,'commerce_hour_value_eur',unit_value,'after_commerce_eur',final_amount);
end $$;
revoke all on function public.parking_rotation_quote(text,timestamptz,timestamptz,integer) from public,anon;
grant execute on function public.parking_rotation_quote(text,timestamptz,timestamptz,integer) to authenticated;

-- Return the session and its fresh quote in one request when scanning a ticket.
create or replace function public.parking_lookup_rotation_checkout(p_plate text) returns jsonb language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare s jsonb;at_time timestamptz:=clock_timestamp();
begin
 s:=public.parking_lookup_rotation(p_plate);
 if s is null then return null;end if;
 return s||jsonb_build_object('checkout_preview',public.parking_rotation_quote(s->'rotation_tariffs'->>'code',(s->>'entry_at')::timestamptz,at_time,0));
end $$;
revoke all on function public.parking_lookup_rotation_checkout(text) from public,anon;
grant execute on function public.parking_lookup_rotation_checkout(text) to authenticated;

-- A zero collection has no payment method, but still records its voucher audit.
alter table public.parking_cash_movements alter column payment_method drop not null;
alter table public.parking_cash_movements add constraint parking_cash_payment_required check(payment_method is not null or (amount_eur=0 and category='rotation'));

create or replace function public.parking_checkout_rotation(p_session_id uuid,p_final_amount_eur numeric,p_payment_method text,p_print_ticket boolean default false,p_adjustment_note text default null,p_invoice_customer jsonb default null) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;s public.rotation_sessions;t public.rotation_tariffs;calc jsonb;v_now timestamptz:=clock_timestamp();v_total numeric;receipt jsonb;invoice jsonb;meta jsonb;hours numeric:=0;reason text;quoted_at timestamptz;expected numeric;quote jsonb;commerce_discount numeric;manual boolean;note text;
begin
 ctx:=public.rotation_operator_context();
 if p_final_amount_eur>0 and (p_payment_method is null or p_payment_method not in ('cash','card')) then raise exception 'Forma de pago inválida';end if;
 if p_final_amount_eur is null or p_final_amount_eur<0 or p_final_amount_eur>999999 then raise exception 'Importe inválido';end if;
 select * into s from public.rotation_sessions where id=p_session_id for update;
 if not found then raise exception 'Ticket inexistente';end if;
 if s.status='cancelled' then raise exception 'El ticket se ha cancelado o convertido a estancia';end if;
 if s.status='inside' then
  select * into t from public.rotation_tariffs where id=s.tariff_id;
  calc:=public.calculate_rotation_amount(t.code,s.entry_at,v_now);v_total:=round(p_final_amount_eur,2);
  if left(ltrim(coalesce(p_adjustment_note,'')),1)='{' then
   meta:=p_adjustment_note::jsonb;
   if jsonb_typeof(meta)<>'object' or coalesce(meta->>'version','') not in ('1','2') then raise exception 'Datos del ajuste no válidos';end if;
   hours:=coalesce((meta->>'commerce_free_hours')::numeric,0);reason:=nullif(btrim(meta->>'reason'),'');quoted_at:=(meta->>'quoted_exit_at')::timestamptz;
   if hours<0 or hours>10000 or hours<>trunc(hours) then raise exception 'Introduce un número entero de bonos igual o mayor que cero';end if;
   if quoted_at is null or quoted_at<s.entry_at or quoted_at>v_now+interval '1 minute' then raise exception 'Recalcula el precio antes de confirmar la salida';end if;
   quote:=public.calculate_rotation_amount(t.code,s.entry_at,quoted_at);
   if meta->>'version'='2' then expected:=(public.parking_rotation_quote(t.code,s.entry_at,quoted_at,hours::integer)->>'after_commerce_eur')::numeric;
   elsif quoted_at-hours*interval '1 hour'<=s.entry_at then expected:=0;
   else expected:=(public.calculate_rotation_amount(t.code,s.entry_at,quoted_at-hours*interval '1 hour')->>'amount_eur')::numeric;end if;
   commerce_discount:=greatest(0,(quote->>'amount_eur')::numeric-expected);manual:=v_total<>round(expected,2);
   if manual and coalesce(length(reason),0)<3 then raise exception 'Escribe el motivo del cambio manual de precio';end if;
   if not manual then reason:=null;end if;
   note:=concat_ws('; ',case when hours>0 then 'Bonos de comercio: '||hours::text||' hora(s)' end,case when manual then 'Cambio manual: '||reason end);
  else
   -- Compatibility with older open cashier tabs; their known hour count is still audited.
   hours:=coalesce(substring(p_adjustment_note from '^Horas gratis: ([0-9]+(?:[.][0-9]+)?)')::numeric,0);
   note:=p_adjustment_note;
  end if;
  update public.rotation_sessions set status='departed',exit_at=v_now,paid_at=v_now,raw_amount_eur=(calc->>'raw_amount_eur')::numeric,tariff_amount_eur=(calc->>'amount_eur')::numeric,discount_bono_eur=greatest(0,(calc->>'amount_eur')::numeric-v_total),amount_eur=v_total,manual_final_amount_eur=v_total,adjustment_note=nullif(btrim(note),''),payment_method=case when v_total=0 then null else p_payment_method end,exit_user_id=(ctx->>'user_id')::uuid,exit_employee_name=ctx->>'employee_name',exit_shift_id=nullif(ctx->>'shift_id','')::uuid,exit_shift_code=nullif(ctx->>'shift_code','')::smallint,exit_shift_date=(ctx->>'shift_date')::date,updated_at=v_now where id=s.id returning * into s;
  update public.parking_cash_movements set details=coalesce(details,'{}'::jsonb)||jsonb_build_object('commerce_free_hours',hours,'commerce_discount_eur',commerce_discount,'manual_price_adjustment',manual,'adjustment_reason',reason,'expected_after_vouchers_eur',expected,'quoted_exit_at',quoted_at)
  where entity_type='rotation' and entity_id=s.id;
  if s.source_reservation_id is not null then update public.reservations set status='completed',rotation_pending=false,assigned_spot_id=null,updated_at=v_now where id=s.source_reservation_id;end if;
 end if;
 if p_invoice_customer is not null then invoice:=public.parking_issue_full_invoice('rotation',s.id,null,p_invoice_customer->>'name',p_invoice_customer->>'tax_id',p_invoice_customer->>'address');end if;
 if p_print_ticket then receipt:=public.parking_issue_simplified('rotation',s.id);end if;
 return jsonb_build_object('session',to_jsonb(s),'receipt',receipt,'invoice',invoice);
end $$;

revoke all on function public.parking_checkout_rotation(uuid,numeric,text,boolean,text,jsonb) from public,anon;
grant execute on function public.parking_checkout_rotation(uuid,numeric,text,boolean,text,jsonb) to authenticated;

