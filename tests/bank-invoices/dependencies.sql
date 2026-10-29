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
 if (q->>'invoice_requires_review')::boolean then raise exception 'La factura de este mes tiene un importe diferente. Revisa su rectificación antes de cobrar la cuota actualizada';end if;
 new.pricing_snapshot:=q;
 return new;
end$function$
