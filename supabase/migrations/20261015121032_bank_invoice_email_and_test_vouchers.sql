alter table public.parking_hotel_batches add column is_test boolean not null default false;
create or replace function private.capture_parking_cash() returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
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
  v_desc:='Abono mensual · '||coalesce(v_desc,'');v_method:=new.payment_method;v_paid:=new.paid_at;v_user:=new.paid_by;
 elsif tg_table_name='parking_hotel_batches' then
  if new.is_test then return new;end if;
  v_key:='hotel_batch:'||new.id;v_category:='stay';v_type:='hotel_batch';v_entity:=new.id;v_ref:=new.first_control::text;v_amount:=new.days*new.unit_price_eur;v_method:=new.payment_method;v_paid:=new.created_at;v_user:=new.created_by;
  select 'Compra de '||new.days||' bonos · '||name into v_desc from public.parking_hotels where id=new.hotel_id;
  if tg_op='UPDATE' then update public.parking_cash_movements set payment_method=new.payment_method where source_key=v_key;return new;end if;
 elsif tg_table_name='reservations' then
  if new.payment_status<>'paid' or coalesce(new.payment_method,'') not in ('cash','card','online') or new.amount_eur is null then return new;end if;
  if tg_op='UPDATE' and old.payment_status='paid' then return new;end if;
  v_key:='reservation:'||new.id;v_category:='stay';v_type:='reservation';v_entity:=new.id;v_ref:=new.reference;v_plate:=new.plate;v_desc:='Estancia por días';v_amount:=new.amount_eur;v_method:=new.payment_method;v_paid:=clock_timestamp();v_user:=coalesce(auth.uid(),new.created_by);
  v_details:=jsonb_build_object('entry_at',new.entry_at,'exit_at',new.exit_at);
 end if;
 if v_amount is null or v_method is null then return new;end if;
 if v_shift is null then select id into v_shift from public.staff_shifts where user_id=v_user and closed_at is null order by opened_at desc limit 1;end if;
 if v_name is null then select full_name into v_name from public.staff_profiles where user_id=v_user;end if;
 insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,reference,plate,description,amount_eur,payment_method,paid_at,user_id,shift_id,employee_name,details)
 values(v_key,v_category,v_type,v_entity,coalesce(v_ref,''),v_plate,coalesce(v_desc,''),round(v_amount,2),v_method,v_paid,v_user,v_shift,v_name,v_details) on conflict(source_key) do nothing;
 return new;
end $$;
create or replace function public.parking_hotel_batch_vouchers(p_batch_id uuid)returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$declare r jsonb;begin
 if auth.uid()is null or not private.is_staff()then raise exception 'No autorizado';end if;
 select jsonb_build_object('id',b.id,'is_test',b.is_test,'hotel_name',h.name,'unit_price_eur',b.unit_price_eur,'registration_first',b.registration_first,'registration_last',b.registration_last,'vouchers',(select jsonb_agg(jsonb_build_object('code',v.code,'used',v.redeemed_reservation_id is not null)order by v.number)from public.parking_hotel_vouchers v where v.batch_id=b.id))into r from public.parking_hotel_batches b join public.parking_hotels h on h.id=b.hotel_id where b.id=p_batch_id;
 if r is null then raise exception 'Compra de bonos inexistente';end if;return r;
end $$;

-- Automatic bank-invoice mail is opt-in per verified subscriber from the supplied list.
alter table public.monthly_subscribers add column auto_email_bank boolean not null default false;
create table public.parking_invoice_mail_jobs(
 id uuid primary key default gen_random_uuid(),payment_id uuid not null unique references public.monthly_subscription_payments(id),
 subscriber_id uuid not null references public.monthly_subscribers(id),billing_month date not null,
 invoice_id uuid references public.parking_invoices(id),recipient text,
 pricing_snapshot jsonb not null default '{}'::jsonb,
 status text not null default 'queued' check(status in ('queued','missing_email','missing_fiscal','provider_unconfigured','sending','sent','error')),
 attempts integer not null default 0,last_error text,provider_id text,created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),sent_at timestamptz,lease_until timestamptz
);
create index parking_mail_status_idx on public.parking_invoice_mail_jobs(status,updated_at);
alter table public.parking_invoice_mail_jobs enable row level security;
create policy invoice_mail_staff_read on public.parking_invoice_mail_jobs for select to authenticated using(private.is_staff());
revoke all on public.parking_invoice_mail_jobs from anon,authenticated;
grant select on public.parking_invoice_mail_jobs to authenticated;
create table private.parking_mail_config(
 singleton boolean primary key default true check(singleton),
 worker_token text not null default(gen_random_uuid()::text||gen_random_uuid()::text),
 busy_until timestamptz not null default '-infinity',lease_token uuid
);
insert into private.parking_mail_config(singleton)values(true);
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
create function private.dispatch_parking_invoice_mail()returns bigint language plpgsql security definer set search_path=public,private,net,pg_temp as $$declare n bigint;t text;begin
 select worker_token into t from private.parking_mail_config where singleton;
 select net.http_post(url:='https://vcwbfljcqpqkmuzcpboi.supabase.co/functions/v1/bank-invoice-mail',headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||t),body:='{"action":"process"}'::jsonb,timeout_milliseconds:=120000)into n;return n;
end $$;
create function private.prepare_parking_invoice_mail(p_job_id uuid)returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
declare j public.parking_invoice_mail_jobs;p public.monthly_subscription_payments;s public.monthly_subscribers;v public.parking_invoices;price numeric;discount numeric;vat numeric;recipient_email text;
begin
 select * into j from public.parking_invoice_mail_jobs where id=p_job_id for update;
 if not found or j.status in ('sent','sending')then return;end if;
 select * into p from public.monthly_subscription_payments where id=j.payment_id;
 select * into s from public.monthly_subscribers where id=j.subscriber_id;
 if p.payment_method<>'bank'or not s.auto_email_bank then update public.parking_invoice_mail_jobs set status='error',last_error='El pago ya no es por banco o el envío automático está desactivado',updated_at=clock_timestamp()where id=j.id;return;end if;
 recipient_email:=lower(nullif(btrim(s.email),''));
 if nullif(btrim(s.customer_name),'')is null or nullif(btrim(s.tax_id),'')is null or nullif(btrim(s.address),'')is null then update public.parking_invoice_mail_jobs set status='missing_fiscal',recipient=recipient_email,last_error='Faltan nombre, NIF/CIF o domicilio de facturación',updated_at=clock_timestamp()where id=j.id;return;end if;
 perform pg_advisory_xact_lock(hashtextextended('monthly-invoice:'||s.id||':'||p.billing_month,0));
 select * into v from public.parking_invoices where entity_type='subscriber'and entity_id=s.id and billing_month=p.billing_month;
 if not found then
  price:=coalesce((j.pricing_snapshot->>'price')::numeric,s.price_eur);discount:=coalesce((j.pricing_snapshot->>'discount')::numeric,s.discount_amount_eur,round(s.price_eur*coalesce(s.discount_pct,0)/100,2));vat:=round((price-discount)*coalesce((j.pricing_snapshot->>'vat_pct')::numeric,s.vat_pct,21)/100,2);
  insert into public.parking_invoices(entity_type,entity_id,billing_month,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur,issued_by)
  values('subscriber',s.id,p.billing_month,s.customer_name,s.tax_id,concat_ws(' ',s.address,s.postal_code,s.city),s.vehicle,s.plate,price,discount,vat,price-discount+vat,p.paid_by)
  on conflict(entity_type,entity_id,billing_month)do nothing;
  select * into v from public.parking_invoices where entity_type='subscriber'and entity_id=s.id and billing_month=p.billing_month;
 end if;
 update public.parking_invoice_mail_jobs set invoice_id=v.id,recipient=recipient_email,status=case when recipient_email is null or recipient_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'then 'missing_email'else 'queued'end,last_error=case when recipient_email is null then 'Falta email del cliente'else null end,updated_at=clock_timestamp()where id=j.id;
end $$;
create function private.queue_parking_bank_invoice()returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$declare j uuid;begin
 if new.payment_method<>'bank'or not exists(select 1 from public.monthly_subscribers where id=new.subscriber_id and auto_email_bank)then return new;end if;
 insert into public.parking_invoice_mail_jobs(payment_id,subscriber_id,billing_month,pricing_snapshot)select new.id,new.subscriber_id,new.billing_month,jsonb_build_object('price',s.price_eur,'discount',coalesce(s.discount_amount_eur,round(s.price_eur*coalesce(s.discount_pct,0)/100,2)),'vat_pct',coalesce(s.vat_pct,21))from public.monthly_subscribers s where s.id=new.subscriber_id on conflict(payment_id)do nothing returning id into j;
 if j is null then select id into j from public.parking_invoice_mail_jobs where payment_id=new.id;end if;
 begin
  perform private.prepare_parking_invoice_mail(j);
  if exists(select 1 from public.parking_invoice_mail_jobs where id=j and status='queued')then perform private.dispatch_parking_invoice_mail();end if;
 exception when others then update public.parking_invoice_mail_jobs set status='error',last_error='Pago registrado; preparación del correo pendiente: '||sqlerrm,updated_at=clock_timestamp()where id=j and status<>'sent';end;
 return new;
end $$;
create trigger queue_bank_invoice_mail after insert or update on public.monthly_subscription_payments for each row execute function private.queue_parking_bank_invoice();
create function private.refresh_missing_invoice_mail()returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$declare j record;begin
 for j in select id from public.parking_invoice_mail_jobs where subscriber_id=new.id and status in ('missing_email','missing_fiscal')loop perform private.prepare_parking_invoice_mail(j.id);end loop;
 if exists(select 1 from public.parking_invoice_mail_jobs where subscriber_id=new.id and status='queued')then begin perform private.dispatch_parking_invoice_mail();exception when others then null;end;end if;return new;
end $$;
create trigger refresh_missing_bank_invoice_mail after update of email,tax_id,address,customer_name on public.monthly_subscribers for each row execute function private.refresh_missing_invoice_mail();

-- These RPCs are internal to the server worker, not available to browser clients.
create function public.parking_mail_worker_authorized(p_token text)returns boolean language sql security definer set search_path=public,private,pg_temp as $$select exists(select 1 from private.parking_mail_config where singleton and worker_token=p_token)$$;
create function public.parking_mail_worker_start()returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$declare t uuid:=gen_random_uuid();begin update private.parking_mail_config set busy_until=clock_timestamp()+interval '2 minutes',lease_token=t where singleton and busy_until<clock_timestamp();if found then return t;end if;return null;end $$;
create function public.parking_mail_worker_finish(p_lease uuid)returns void language plpgsql security definer set search_path=public,private,pg_temp as $$begin update private.parking_mail_config set busy_until='-infinity',lease_token=null where singleton and lease_token=p_lease;end $$;
create function public.parking_claim_bank_invoice_mail()returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$declare j public.parking_invoice_mail_jobs;v jsonb;begin
 select * into j from public.parking_invoice_mail_jobs where (status='queued'or(status='error'and attempts<5 and updated_at<clock_timestamp()-interval '2 minutes')or(status='sending'and lease_until<clock_timestamp()and created_at>clock_timestamp()-interval '23 hours'))order by created_at for update skip locked limit 1;
 if not found then return null;end if;
 if j.status='sending'then update public.parking_invoice_mail_jobs set status='queued'where id=j.id;end if;
 perform private.prepare_parking_invoice_mail(j.id);
 select * into j from public.parking_invoice_mail_jobs where id=j.id;
 if j.status<>'queued'then return jsonb_build_object('skipped',true);end if;
 update public.parking_invoice_mail_jobs set status='sending',attempts=attempts+1,lease_until=clock_timestamp()+interval '5 minutes',updated_at=clock_timestamp()where id=j.id returning * into j;
 select to_jsonb(i)into v from public.parking_invoices i where i.id=j.invoice_id;
 return jsonb_build_object('id',j.id,'recipient',j.recipient,'invoice',v);
end $$;
create function public.parking_complete_bank_invoice_mail(p_job_id uuid,p_status text,p_provider_id text default null,p_error text default null)returns void language plpgsql security definer set search_path=public,private,pg_temp as $$begin
 if p_status not in ('sent','error','provider_unconfigured')then raise exception 'Estado inválido';end if;
 update public.parking_invoice_mail_jobs set status=p_status,provider_id=coalesce(p_provider_id,provider_id),last_error=left(p_error,1000),sent_at=case when p_status='sent'then clock_timestamp()else sent_at end,lease_until=null,updated_at=clock_timestamp()where id=p_job_id and status='sending';
end $$;
create function public.parking_retry_bank_invoice_mail(p_job_id uuid)returns void language plpgsql security definer set search_path=public,private,pg_temp as $$declare ctx jsonb;j public.parking_invoice_mail_jobs;begin
 ctx:=public.rotation_operator_context();select * into j from public.parking_invoice_mail_jobs where id=p_job_id for update;
 if not found then raise exception 'Correo inexistente';end if;
 if j.status='sent'then return;end if;
 if j.status='sending'or(j.attempts>0 and j.created_at<clock_timestamp()-interval '23 hours')then raise exception 'Revisa el envío antes de reintentarlo para evitar duplicados';end if;
 perform private.prepare_parking_invoice_mail(j.id);perform private.dispatch_parking_invoice_mail();
end $$;
revoke all on function public.parking_mail_worker_authorized(text),public.parking_mail_worker_start(),public.parking_mail_worker_finish(uuid),public.parking_claim_bank_invoice_mail(),public.parking_complete_bank_invoice_mail(uuid,text,text,text)from public,anon,authenticated;
grant execute on function public.parking_mail_worker_authorized(text),public.parking_mail_worker_start(),public.parking_mail_worker_finish(uuid),public.parking_claim_bank_invoice_mail(),public.parking_complete_bank_invoice_mail(uuid,text,text,text)to service_role;
revoke all on function public.parking_retry_bank_invoice_mail(uuid)from public,anon;
grant execute on function public.parking_retry_bank_invoice_mail(uuid)to authenticated;
revoke all on function private.dispatch_parking_invoice_mail(),private.prepare_parking_invoice_mail(uuid),private.queue_parking_bank_invoice(),private.refresh_missing_invoice_mail()from public,anon,authenticated;
select cron.schedule('parking-bank-invoice-mail','* * * * *',$cron$select private.dispatch_parking_invoice_mail()where exists(select 1 from public.parking_invoice_mail_jobs where status='queued'or(status='error'and attempts<5 and updated_at<clock_timestamp()-interval '2 minutes')or(status='sending'and lease_until<clock_timestamp()and created_at>clock_timestamp()-interval '23 hours'));$cron$);
