DO $$declare free_id uuid;paid_id uuid;q jsonb;begin
 insert into public.monthly_subscribers(customer_name,price_eur,discount_amount_eur,vat_pct,total_eur,active)values('QA FREE',0,0,21,0,true)returning id into free_id;
 q:=private.subscriber_month_quote(free_id,date '2026-11-01',timestamptz '2026-11-16 12:00 Europe/Madrid');
 if (q->>'overdue_alert')::boolean or (q->>'total_eur')::numeric<>0 then raise exception 'Zero subscription incorrectly overdue or repriced';end if;
 insert into public.monthly_subscribers(customer_name,price_eur,discount_amount_eur,vat_pct,total_eur,active)values('QA NORMAL UNPAID',100,0,21,121,true)returning id into paid_id;
 q:=private.subscriber_month_quote(paid_id,date '2026-11-01',timestamptz '2026-11-16 12:00 Europe/Madrid');
 if not (q->>'overdue_alert')::boolean then raise exception 'Normal unpaid subscription lost overdue alert';end if;
end$$;
