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
 -- Old settled months predate this policy. Never recalculate them as late payments.
 late:=not paid and p_at>=cutoff;
 price:=round(coalesce(s.price_eur,0),2);rate:=coalesce(s.vat_pct,21);
 discount:=case when late then 0 else least(price,greatest(0,coalesce(s.discount_amount_eur,round(price*coalesce(s.discount_pct,0)/100,2)))) end;
 if exists(select 1 from private.parking_monthly_receipt_only where subscriber_id=s.id) then price:=s.total_eur;discount:=0;rate:=0;end if;
 vat:=round(greatest(0,price-discount)*rate/100,2);total:=greatest(0,price-discount)+vat;
 review:=not paid and exists(select 1 from public.parking_invoices i where i.entity_type='subscriber' and i.entity_id=p_id and i.billing_month=p_month and i.is_production=(p_at>=timestamptz '2026-10-31 22:00 Europe/Madrid') and i.total_eur<>total);
 return jsonb_build_object('price',price,'discount',discount,'vat_pct',rate,'vat_eur',vat,'total_eur',total,'discount_forfeited',late and coalesce(s.discount_amount_eur,round(price*coalesce(s.discount_pct,0)/100,2))>0,'discount_deadline',cutoff,'alert_from',alert_at,'paid',paid,'overdue_alert',s.active and total>0 and not paid and p_at>=alert_at,'invoice_requires_review',review);
end$function$
;

