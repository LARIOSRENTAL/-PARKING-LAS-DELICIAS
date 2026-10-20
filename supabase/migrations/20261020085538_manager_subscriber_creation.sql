CREATE OR REPLACE FUNCTION public.create_monthly_subscriber(p_customer_name text, p_tax_id text, p_address text, p_postal_code text, p_city text, p_phone text, p_vehicle text, p_plate text, p_price_eur numeric, p_discount_pct numeric DEFAULT 0, p_vat_pct numeric DEFAULT 21, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'auth', 'pg_temp'
AS $function$
declare
  v_ctx jsonb;
  v_id uuid;
  v_price numeric(10,2);
  v_discount numeric(6,2);
  v_vat_pct numeric(6,2);
  v_taxable numeric(10,2);
  v_vat numeric(10,2);
  v_total numeric(10,2);
  v_plate text := upper(trim(coalesce(p_plate,'')));
begin
  if auth.uid() is null or not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in ('admin','manager')) then raise exception 'Solo administradores y gerentes pueden dar de alta abonados';end if;
  v_ctx := jsonb_build_object('user_id',auth.uid(),'shift_id',(select id from public.staff_shifts where user_id=auth.uid() and closed_at is null order by opened_at desc limit 1));

  if length(trim(coalesce(p_customer_name,''))) < 2 then raise exception 'Introduce el nombre del cliente'; end if;
  if length(trim(coalesce(p_vehicle,''))) < 2 then raise exception 'Introduce el vehículo'; end if;
  if length(v_plate) < 3 then raise exception 'Introduce una matrícula válida'; end if;

  v_price := greatest(coalesce(p_price_eur,0),0);
  v_discount := least(greatest(coalesce(p_discount_pct,0),0),100);
  v_vat_pct := least(greatest(coalesce(p_vat_pct,21),0),100);
  v_taxable := round(v_price * (1 - v_discount/100.0),2);
  v_vat := round(v_taxable * v_vat_pct/100.0,2);
  v_total := round(v_taxable + v_vat,2);

  insert into public.monthly_subscribers(
    customer_name,tax_id,address,postal_code,city,phone,vehicle,plate,
    price_eur,discount_pct,vat_pct,vat_amount_eur,total_eur,notes,
    created_by,source
  )
  values(
    trim(p_customer_name),nullif(trim(coalesce(p_tax_id,'')),''),
    nullif(trim(coalesce(p_address,'')),''),nullif(trim(coalesce(p_postal_code,'')),''),
    nullif(trim(coalesce(p_city,'')),''),nullif(trim(coalesce(p_phone,'')),''),
    trim(p_vehicle),v_plate,v_price,v_discount,v_vat_pct,v_vat,v_total,
    nullif(trim(coalesce(p_notes,'')),''),
    (v_ctx->>'user_id')::uuid,'backoffice'
  )
  returning id into v_id;

  insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)
  values(
    nullif(v_ctx->>'shift_id','')::uuid,
    (v_ctx->>'user_id')::uuid,
    'monthly_subscriber_created','monthly_subscribers',v_id,
    jsonb_build_object('customer_name',trim(p_customer_name),'plate',v_plate,'total_eur',v_total)
  );

  return jsonb_build_object(
    'ok',true,'id',v_id,'price_eur',v_price,'discount_pct',v_discount,
    'vat_pct',v_vat_pct,'vat_amount_eur',v_vat,'total_eur',v_total
  );
end
$function$;
