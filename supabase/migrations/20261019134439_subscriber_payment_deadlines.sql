-- Pricing is per billing month. Existing settled payments and profile discounts stay intact.
alter table public.monthly_subscription_payments add column pricing_snapshot jsonb;
create function private.subscriber_month_quote(p_id uuid,p_month date,p_at timestamptz default clock_timestamp()) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
 vat:=round(greatest(0,price-discount)*rate/100,2);total:=greatest(0,price-discount)+vat;
 review:=not paid and exists(select 1 from public.parking_invoices i where i.entity_type='subscriber' and i.entity_id=p_id and i.billing_month=p_month and i.total_eur<>total);
 return jsonb_build_object('price',price,'discount',discount,'vat_pct',rate,'vat_eur',vat,'total_eur',total,'discount_forfeited',late and coalesce(s.discount_amount_eur,round(price*coalesce(s.discount_pct,0)/100,2))>0,'discount_deadline',cutoff,'alert_from',alert_at,'paid',paid,'overdue_alert',s.active and not paid and p_at>=alert_at,'invoice_requires_review',review);
end$$;
revoke all on function private.subscriber_month_quote(uuid,date,timestamptz) from public,anon,authenticated;

-- Freeze the actual monthly collection before cashbook and invoice-mail triggers execute.
create function private.snapshot_subscriber_month_payment() returns trigger language plpgsql security definer set search_path='' as $$
declare q jsonb;
begin
 perform 1 from public.monthly_subscribers where id=new.subscriber_id for update;
 q:=private.subscriber_month_quote(new.subscriber_id,new.billing_month,clock_timestamp());
 if (q->>'invoice_requires_review')::boolean then raise exception 'La factura de este mes tiene un importe diferente. Revisa su rectificación antes de cobrar la cuota actualizada';end if;
 new.pricing_snapshot:=q;
 return new;
end$$;
revoke all on function private.snapshot_subscriber_month_payment() from public,anon,authenticated;
create trigger snapshot_subscriber_month_payment before insert on public.monthly_subscription_payments for each row execute function private.snapshot_subscriber_month_payment();

create or replace function public.parking_monthly_subscribers(p_month date) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_role text;
begin
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if v_role is null then raise exception 'No autorizado';end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'Mes no válido';end if;
 return(select coalesce(jsonb_agg(to_jsonb(s)||jsonb_build_object('monthly_charge',private.subscriber_month_quote(s.id,p_month)) order by s.customer_name,s.plate),'[]'::jsonb) from public.monthly_subscribers s where v_role in ('admin','manager') or (s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in ('cash','card') and not exists(select 1 from public.monthly_subscription_payments p where p.subscriber_id=s.id and p.billing_month=p_month)));
end$$;
revoke all on function public.parking_monthly_subscribers(date) from public,anon;
grant execute on function public.parking_monthly_subscribers(date) to authenticated;

-- Retain every other cash/invoice workflow and its existing permission checks.
do $migration$ declare d text;old_text text;begin
 d:=pg_get_functiondef('private.capture_parking_cash()'::regprocedure);
 old_text:='v_desc:=''Abono mensual · ''||coalesce(v_desc,'''');';
 if strpos(d,old_text)=0 then raise exception 'Unexpected subscriber cash capture';end if;
 d:=replace(d,old_text,'v_amount:=coalesce((new.pricing_snapshot->>''total_eur'')::numeric,v_amount);v_details:=coalesce(new.pricing_snapshot,''{}''::jsonb);'||old_text);execute d;
 d:=pg_get_functiondef('private.queue_parking_bank_invoice()'::regprocedure);
 old_text:='jsonb_build_object(''price'',s.price_eur,''discount'',coalesce(s.discount_amount_eur,round(s.price_eur*coalesce(s.discount_pct,0)/100,2)),''vat_pct'',coalesce(s.vat_pct,21))';
 if strpos(d,old_text)=0 then raise exception 'Unexpected bank invoice pricing';end if;
 d:=replace(d,old_text,'coalesce(new.pricing_snapshot,'||old_text||')');execute d;
 d:=pg_get_functiondef('public.issue_parking_invoice(text,uuid,date,text,text)'::regprocedure);
 old_text:='v_price:=s.price_eur; v_discount:=coalesce(s.discount_amount_eur,round(s.price_eur*s.discount_pct/100,2));';
 if strpos(d,old_text)=0 then raise exception 'Unexpected subscriber invoice pricing';end if;
 d:=replace(d,old_text,'v_price:=(private.subscriber_month_quote(s.id,p_billing_month)->>''price'')::numeric;v_discount:=(private.subscriber_month_quote(s.id,p_billing_month)->>''discount'')::numeric;');
 d:=replace(d,'v_vat:=round((v_price-v_discount)*s.vat_pct/100,2);v_total:=v_price-v_discount+v_vat;','v_vat:=(private.subscriber_month_quote(s.id,p_billing_month)->>''vat_eur'')::numeric;v_total:=(private.subscriber_month_quote(s.id,p_billing_month)->>''total_eur'')::numeric;');execute d;
end $migration$;
