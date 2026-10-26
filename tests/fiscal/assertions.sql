insert into public.staff_profiles(user_id,full_name,role,active) values('00000000-0000-0000-0000-000000000001','QA ADMIN','admin',true);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
DO $$declare t text;k text;mid uuid;eid uuid;r jsonb;f jsonb;ser text;num text;before_count bigint;begin
 foreach t in array array['rotation','reservation'] loop
  foreach k in array array['cash-hidden','cash-print','card-print','full'] loop
   eid:=gen_random_uuid();
   insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,reference,plate,description,amount_eur,payment_method,paid_at,user_id) values(gen_random_uuid()::text,case when t='rotation' then 'rotation' else 'stay' end,t,eid,'QA','1234QA','QA TEST',24.2,case when k='card-print' then 'card' else 'cash' end,timestamptz '2026-11-01 10:00 Europe/Madrid',auth.uid()) returning id into mid;
   if k='full' then
    if t='rotation' then insert into public.rotation_sessions(id,status,plate,amount_eur) values(eid,'departed','1234QA',24.2);else insert into public.reservations(id,status,plate,vehicle_make_model,amount_eur) values(eid,'checked_in','1234QA','QA CAR',24.2);end if;
    f:=public.parking_issue_full_invoice(t,eid,null,'QA CUSTOMER','QA123','QA ADDRESS');
    if f->>'series'<>(case when t='rotation' then 'OFH' else 'OFD' end) then raise exception 'Wrong full series: %',f;end if;
    r:=public.parking_issue_simplified(t,eid);if r->>'number'<>f->>'number' then raise exception 'Full invoice copy has a second fiscal number';end if;
   elsif k in('cash-print','card-print') then
    r:=public.parking_issue_simplified(t,eid);
    if r->>'series'<>(case when t='rotation' then 'OTH' else 'OTD' end) then raise exception 'Wrong printed receipt series';end if;
    num:=r->>'number';before_count:=(select count(*) from public.parking_invoices);
    f:=public.parking_issue_full_invoice(t,eid,null,'ENRICHED CUSTOMER','QA456','QA ADDRESS');
    if f->>'number'<>num or f->>'customer_name'<>'ENRICHED CUSTOMER' or (select count(*) from public.parking_invoices)<>before_count then raise exception 'Receipt enrichment changed identity or created another invoice';end if;
   end if;
   set constraints automatic_production_fiscal_document immediate;
   if k='cash-hidden' then select series,serial_number into ser,num from public.parking_simplified_invoices where movement_id=mid;if ser<>(case when t='rotation' then 'ONH' else 'OND' end) or num<>'260001' then raise exception 'Wrong automatic no-print receipt: %, %',ser,num;end if;end if;
   set constraints automatic_production_fiscal_document deferred;
  end loop;
 end loop;
 if private.parking_fiscal_serial('OFD',timestamptz '2027-01-01 10:00 Europe/Madrid')<>'270001' then raise exception 'Annual numbering did not restart';end if;
end$$;
DO $$declare sub uuid;pay uuid;mid uuid;receipt_sub uuid;report jsonb;shift uuid;begin
 insert into public.monthly_subscribers(customer_name,price_eur,discount_pct,discount_amount_eur,vat_pct,total_eur,active,tax_id,address) values('QA MONTHLY',100,0,0,21,121,true,'QA-M','QA STREET') returning id into sub;
 insert into public.monthly_subscription_payments(subscriber_id,billing_month,payment_method,paid_at,paid_by,pricing_snapshot) values(sub,date '2026-11-01','cash',timestamptz '2026-11-01 10:00 Europe/Madrid',auth.uid(),'{"price":100,"discount":0,"vat_pct":21,"vat_eur":21,"total_eur":121}') returning id into pay;
 insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,reference,description,amount_eur,payment_method,paid_at,user_id) values(gen_random_uuid()::text,'subscriber','subscriber_payment',pay,'QA-M','Monthly payment',121,'cash',timestamptz '2026-11-01 10:00 Europe/Madrid',auth.uid()) returning id into mid;
 set constraints automatic_production_fiscal_document immediate;
 if not exists(select 1 from public.parking_invoices where entity_type='subscriber' and entity_id=sub and series='OFM' and serial_number='260001' and total_eur=121) then raise exception 'Monthly OFM not generated';end if;
 set constraints automatic_production_fiscal_document deferred;
 insert into public.monthly_subscribers(customer_name,price_eur,discount_pct,discount_amount_eur,vat_pct,total_eur,active,tax_id,address) values('QA RECEIPT ONLY',100,0,0,21,150,true,'QA-R','QA STREET') returning id into receipt_sub;
 perform public.parking_set_monthly_receipt_only(receipt_sub,true);
 report:=private.subscriber_month_quote(receipt_sub,date '2026-11-01',timestamptz '2026-11-01 10:00 Europe/Madrid');
 if (report->>'vat_eur')::numeric<>0 or (report->>'total_eur')::numeric<>150 then raise exception 'Receipt-only quote changed agreed total or added VAT';end if;
 insert into public.monthly_subscription_payments(subscriber_id,billing_month,payment_method,paid_at,paid_by,pricing_snapshot) values(receipt_sub,date '2026-11-01','cash',timestamptz '2026-11-01 10:00 Europe/Madrid',auth.uid(),report) returning id into pay;
 insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,reference,description,amount_eur,payment_method,paid_at,user_id) values(gen_random_uuid()::text,'subscriber','subscriber_payment',pay,'QA-R','Monthly receipt',150,'cash',timestamptz '2026-11-01 10:00 Europe/Madrid',auth.uid());
 set constraints automatic_production_fiscal_document immediate;
 if not exists(select 1 from public.parking_monthly_receipts where payment_id=pay and amount_eur=150) or exists(select 1 from public.parking_invoices where entity_type='subscriber' and entity_id=receipt_sub) then raise exception 'Receipt-only subscriber incorrectly invoiced';end if;
 set constraints automatic_production_fiscal_document deferred;
 report:=public.parking_billing_movements(timestamp '2026-11-01 00:00',timestamp '2026-11-01 23:59');
 if exists(select 1 from jsonb_array_elements(report->'rows') r where r->>'kind'='income' and r->>'document_kind' is null) then raise exception 'Fiscal export is missing a document';end if;
 if not exists(select 1 from jsonb_array_elements(report->'rows') r where r->>'document_series'='OFD' and r->>'document_number'='260001' and r->>'document_date'='2026-11-01') then raise exception 'Export series/number/date separation failed';end if;
 insert into public.staff_shifts(user_id,shift_date,shift_code,opened_at) values(auth.uid(),date '2026-11-01',1,timestamptz '2026-11-01 08:00 Europe/Madrid') returning id into shift;
 perform set_config('sandbox.difference','5',true);
 begin update public.staff_shifts set closed_at=timestamptz '2026-11-01 14:00 Europe/Madrid' where id=shift;raise exception using errcode='ZX002',message='Unbalanced production shift closed';exception when sqlstate 'P0001' then if sqlerrm not ilike '%descuadrada%' then raise;end if;end;
 perform set_config('sandbox.difference','0',true);update public.staff_shifts set closed_at=timestamptz '2026-11-01 14:00 Europe/Madrid' where id=shift;
 if not exists(select 1 from public.staff_shifts where id=shift and closed_at is not null) then raise exception 'Balanced shift failed to close';end if;
end$$;
