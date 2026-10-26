DO $$declare r public.parking_monthly_receipts;n bigint;p uuid;sub uuid;doc jsonb;begin
 select * into r from public.parking_monthly_receipts order by issued_at,id limit 1;
 if r.order_number<>11418 then raise exception 'First receipt must be 11418';end if;
 select last_number into n from private.parking_monthly_receipt_counter;
 doc:=public.parking_get_monthly_receipt(r.subscriber_id,r.billing_month);
 if (doc->>'order_number')::bigint<>11418 or (select last_number from private.parking_monthly_receipt_counter)<>n then raise exception 'Reprint consumed a new order number';end if;
 insert into public.monthly_subscribers(customer_name,price_eur,total_eur,active)values('QA SECOND RECEIPT',100,100,true)returning id into sub;
 insert into public.monthly_subscription_payments(subscriber_id,billing_month,payment_method,paid_at,paid_by)values(sub,date '2026-12-01','cash',timestamptz '2026-12-01 10:00 Europe/Madrid',auth.uid())returning id into p;
 insert into public.parking_monthly_receipts(payment_id,subscriber_id,billing_month,customer_name,amount_eur)values(p,sub,date '2026-12-01','QA SECOND RECEIPT',100)returning * into r;
 if r.order_number<>11419 then raise exception 'Second receipt must be 11419';end if;
 insert into public.parking_monthly_receipts(payment_id,subscriber_id,billing_month,customer_name,amount_eur)values(p,sub,date '2026-12-01','QA SECOND RECEIPT',100)on conflict(payment_id)do nothing;
 if (select last_number from private.parking_monthly_receipt_counter)<>11419 then raise exception 'Duplicate receipt advanced the order counter';end if;
end$$;
