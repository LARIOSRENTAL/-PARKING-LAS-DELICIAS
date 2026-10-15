-- Missing provider configuration is not an attempted delivery; retry safely after setup.
create or replace function public.parking_claim_bank_invoice_mail()returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$declare j public.parking_invoice_mail_jobs;v jsonb;begin
 select * into j from public.parking_invoice_mail_jobs where (status='queued'or(status='provider_unconfigured'and updated_at<clock_timestamp()-interval '15 minutes')or(status='error'and attempts<5 and updated_at<clock_timestamp()-interval '2 minutes')or(status='sending'and lease_until<clock_timestamp()and created_at>clock_timestamp()-interval '23 hours'))order by created_at for update skip locked limit 1;
 if not found then return null;end if;
 if j.status='sending'then update public.parking_invoice_mail_jobs set status='queued'where id=j.id;end if;
 perform private.prepare_parking_invoice_mail(j.id);
 select * into j from public.parking_invoice_mail_jobs where id=j.id;
 if j.status<>'queued'then return jsonb_build_object('skipped',true);end if;
 update public.parking_invoice_mail_jobs set status='sending',attempts=attempts+1,lease_until=clock_timestamp()+interval '5 minutes',updated_at=clock_timestamp()where id=j.id returning * into j;
 select to_jsonb(i)into v from public.parking_invoices i where i.id=j.invoice_id;
 return jsonb_build_object('id',j.id,'recipient',j.recipient,'invoice',v);
end $$;
create or replace function public.parking_complete_bank_invoice_mail(p_job_id uuid,p_status text,p_provider_id text default null,p_error text default null)returns void language plpgsql security definer set search_path=public,private,pg_temp as $$begin
 if p_status not in ('sent','error','provider_unconfigured')then raise exception 'Estado inválido';end if;
 update public.parking_invoice_mail_jobs set status=p_status,attempts=case when p_status='provider_unconfigured'then greatest(0,attempts-1)else attempts end,provider_id=coalesce(p_provider_id,provider_id),last_error=left(p_error,1000),sent_at=case when p_status='sent'then clock_timestamp()else sent_at end,lease_until=null,updated_at=clock_timestamp()where id=p_job_id and status='sending';
end $$;
select cron.schedule('parking-bank-invoice-mail','* * * * *',$cron$select private.dispatch_parking_invoice_mail()where exists(select 1 from public.parking_invoice_mail_jobs where status='queued'or(status='provider_unconfigured'and updated_at<clock_timestamp()-interval '15 minutes')or(status='error'and attempts<5 and updated_at<clock_timestamp()-interval '2 minutes')or(status='sending'and lease_until<clock_timestamp()and created_at>clock_timestamp()-interval '23 hours'));$cron$);
