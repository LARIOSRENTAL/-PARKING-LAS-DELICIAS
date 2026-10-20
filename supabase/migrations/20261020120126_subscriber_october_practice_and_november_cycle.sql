-- Temporary, isolated October practice. Actual payments, cashbooks and invoices stay unchanged.
create table private.parking_subscriber_training (
 subscriber_id uuid primary key references public.monthly_subscribers(id),
 billing_month date not null default '2026-10-01' check(billing_month='2026-10-01'),
 payment_id uuid not null unique default gen_random_uuid(),
 original_payment jsonb,
 pricing_snapshot jsonb not null,
 paid_at timestamptz,
 paid_by uuid,
 payment_method text check(payment_method in ('cash','card')),
 created_at timestamptz not null default clock_timestamp()
);
alter table private.parking_subscriber_training enable row level security;
revoke all on private.parking_subscriber_training from public,anon,authenticated;

create function private.subscriber_training_window(p_month date,p_at timestamptz default clock_timestamp()) returns boolean language sql stable set search_path='' as $$
 select p_month=date '2026-10-01' and p_at>=timestamptz '2026-10-20 00:00 Europe/Madrid' and p_at<timestamptz '2026-10-25 00:00 Europe/Madrid'
$$;
revoke all on function private.subscriber_training_window(date,timestamptz) from public,anon,authenticated;

insert into private.parking_subscriber_training(subscriber_id,original_payment,pricing_snapshot)
select s.id,to_jsonb(p),private.subscriber_month_quote(s.id,'2026-10-01')
from public.monthly_subscribers s left join public.monthly_subscription_payments p on p.subscriber_id=s.id and p.billing_month='2026-10-01'
where s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in('cash','card');

-- Keep the production collector unchanged behind the existing public RPC.
alter function public.mark_monthly_subscription_paid(uuid,date,text) set schema private;
alter function private.mark_monthly_subscription_paid(uuid,date,text) rename to mark_monthly_subscription_paid_live;
revoke all on function private.mark_monthly_subscription_paid_live(uuid,date,text) from public,anon,authenticated;

create function public.mark_monthly_subscription_paid(p_subscriber_id uuid,p_billing_month date,p_payment_method text) returns public.monthly_subscription_payments language plpgsql security definer set search_path='' as $$
declare t private.parking_subscriber_training; s public.monthly_subscribers; r public.monthly_subscription_payments; ctx jsonb; role_name text;
begin
 select role into role_name from public.staff_profiles where user_id=auth.uid() and active;
 if auth.uid() is null or role_name is null then raise exception 'No autorizado';end if;
 if private.subscriber_training_window(p_billing_month) then
  select * into s from public.monthly_subscribers where id=p_subscriber_id and active for update;
  if found and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in('cash','card') then
   select * into t from private.parking_subscriber_training where subscriber_id=s.id for update;
   if found then
    if p_payment_method is null or p_payment_method not in('cash','card') then raise exception 'Las pruebas solo admiten efectivo o tarjeta';end if;
    ctx:=public.monthly_subscriber_write_context();
    if t.paid_at is null then
     update private.parking_subscriber_training set paid_at=clock_timestamp(),paid_by=auth.uid(),payment_method=p_payment_method where subscriber_id=s.id returning * into t;
     insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)
     values(nullif(ctx->>'shift_id','')::uuid,auth.uid(),'subscriber_training_payment','monthly_subscribers',s.id,jsonb_build_object('billing_month',p_billing_month,'payment_method',p_payment_method,'training',true,'real_cash_movement',false));
    end if;
    r.id:=t.payment_id;r.subscriber_id:=s.id;r.billing_month:=p_billing_month;r.payment_method:=t.payment_method;r.paid_at:=t.paid_at;r.paid_by:=t.paid_by;r.created_at:=t.created_at;r.pricing_snapshot:=t.pricing_snapshot||jsonb_build_object('training',true,'paid',true);
    return r;
   end if;
  end if;
 end if;
 return private.mark_monthly_subscription_paid_live(p_subscriber_id,p_billing_month,p_payment_method);
end$$;
revoke all on function public.mark_monthly_subscription_paid(uuid,date,text) from public,anon;
grant execute on function public.mark_monthly_subscription_paid(uuid,date,text) to authenticated;

create or replace function public.parking_monthly_subscribers(p_month date) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_role text; practice boolean;
begin
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if auth.uid() is null or v_role is null then raise exception 'No autorizado';end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'Mes no válido';end if;
 practice:=coalesce(private.subscriber_training_window(p_month),false);
 return(select coalesce(jsonb_agg(to_jsonb(s)||jsonb_build_object(
  'monthly_charge',case when practice and t.subscriber_id is not null and s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in('cash','card') then t.pricing_snapshot||jsonb_build_object('paid',t.paid_at is not null,'overdue_alert',false,'discount_forfeited',false,'invoice_requires_review',false,'training',true) else private.subscriber_month_quote(s.id,p_month) end,
  'training',case when practice and t.subscriber_id is not null and s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in('cash','card') then jsonb_build_object('active',true,'ends_at',timestamptz '2026-10-25 00:00 Europe/Madrid','payment',case when t.paid_at is not null then jsonb_build_object('id',t.payment_id,'subscriber_id',s.id,'billing_month',p_month,'payment_method',t.payment_method,'paid_at',t.paid_at,'training',true) else null end) else null end
 ) order by s.customer_name,s.plate),'[]'::jsonb)
 from public.monthly_subscribers s left join private.parking_subscriber_training t on t.subscriber_id=s.id
 where v_role in('admin','manager') or (s.active and not coalesce(s.auto_email_bank,false) and coalesce(s.preferred_payment_method,'cash') in('cash','card') and case when practice and t.subscriber_id is not null then t.paid_at is null else not exists(select 1 from public.monthly_subscription_payments p where p.subscriber_id=s.id and p.billing_month=p_month) end));
end$$;
revoke all on function public.parking_monthly_subscribers(date) from public,anon;
grant execute on function public.parking_monthly_subscribers(date) to authenticated;
