DO $$declare sub uuid;pay uuid;q jsonb;r public.parking_monthly_receipts;before_counter bigint;cfg record;begin
 for cfg in select * from (values(152::numeric,8::numeric,160::numeric),(114.75::numeric,20.25::numeric,135::numeric))as v(total,discount,price) loop
  insert into public.monthly_subscribers(customer_name,price_eur,discount_amount_eur,vat_pct,total_eur,active)values('QA RECEIPT DISCOUNT',100,cfg.discount,21,cfg.total,true)returning id into sub;
  perform public.parking_set_monthly_receipt_only(sub,true);
  q:=private.subscriber_month_quote(sub,date '2026-11-01',timestamptz '2026-11-16 10:00 Europe/Madrid');
  if (q->>'price')::numeric<>cfg.price or (q->>'discount')::numeric<>cfg.discount or (q->>'total_eur')::numeric<>cfg.total or (q->>'vat_eur')::numeric<>0 then raise exception 'Receipt breakdown changed agreed total or lost discount: %',q;end if;
  insert into public.monthly_subscription_payments(subscriber_id,billing_month,payment_method,paid_at,paid_by,pricing_snapshot)values(sub,date '2026-11-01','cash',timestamptz '2026-11-16 10:00 Europe/Madrid',auth.uid(),q)returning id into pay;
  insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,amount_eur,payment_method,paid_at,user_id)values(gen_random_uuid()::text,'subscriber','subscriber_payment',pay,cfg.total,'cash',timestamptz '2026-11-16 10:00 Europe/Madrid',auth.uid());
  set constraints automatic_production_fiscal_document immediate;
  select * into r from public.parking_monthly_receipts where payment_id=pay;
  if r.price_eur<>cfg.price or r.discount_eur<>cfg.discount or r.amount_eur<>cfg.total then raise exception 'Receipt failed to snapshot price and discount';end if;
  select last_number into before_counter from private.parking_monthly_receipt_counter;
  update public.monthly_subscribers set discount_amount_eur=0 where id=sub;
  q:=public.parking_get_monthly_receipt(sub,date '2026-11-01');
  if (q->>'discount_eur')::numeric<>cfg.discount or (select last_number from private.parking_monthly_receipt_counter)<>before_counter then raise exception 'Reprint changed discount or number';end if;
  set constraints automatic_production_fiscal_document deferred;
 end loop;
end$$;
