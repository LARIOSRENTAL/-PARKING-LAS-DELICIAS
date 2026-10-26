DO $$declare pay uuid;receipt_pay uuid;doc jsonb;before_count bigint;begin
 select p.id into pay from public.monthly_subscription_payments p join public.monthly_subscribers s on s.id=p.subscriber_id where s.customer_name='QA MONTHLY';
 select count(*) into before_count from public.parking_invoices;
 update public.staff_profiles set role='employee' where user_id=auth.uid();
 doc:=public.parking_monthly_payment_document(pay);
 if doc->>'number'<>'OFM 260001' or doc->>'doc_kind'<>'invoice' then raise exception 'Own employee payment did not return numbered OFM';end if;
 perform public.parking_monthly_payment_document(pay);
 if (select count(*) from public.parking_invoices)<>before_count then raise exception 'Print retry duplicated invoice';end if;
 select p.id into receipt_pay from public.monthly_subscription_payments p join public.monthly_subscribers s on s.id=p.subscriber_id where s.customer_name='QA RECEIPT ONLY';
 doc:=public.parking_monthly_payment_document(receipt_pay);
 if doc->>'doc_kind'<>'monthly_receipt' or (doc->>'amount_eur')::numeric<>150 then raise exception 'Wrong receipt document or changed price';end if;
 insert into public.staff_profiles(user_id,full_name,role,active)values('00000000-0000-0000-0000-000000000002','QA OTHER EMPLOYEE','employee',true);
 perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
 begin perform public.parking_monthly_payment_document(pay);raise exception using errcode='ZX009',message='Other employee accessed payment';exception when sqlstate 'P0001' then if sqlerrm not ilike '%No autorizado%' then raise;end if;end;
 perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
 update public.staff_profiles set role='admin' where user_id=auth.uid();
end$$;
