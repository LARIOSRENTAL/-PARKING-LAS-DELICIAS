-- Outstanding IOUs are shared drawer assets; redemption exchanges the IOU for cash, never sales income.
create table public.parking_cash_voucher_returns (
 voucher_id uuid primary key references public.parking_cash_entries(id),
 shift_id uuid not null references public.staff_shifts(id),
 returned_by uuid not null references public.staff_profiles(user_id),
 employee_name text not null,
 amount_eur numeric(12,2) not null check(amount_eur>0),
 returned_at timestamptz not null default clock_timestamp()
);
create index parking_cash_voucher_returns_shift on public.parking_cash_voucher_returns(shift_id,returned_at);
alter table public.parking_cash_voucher_returns enable row level security;
revoke all on public.parking_cash_voucher_returns from anon,authenticated;
grant select on public.parking_cash_voucher_returns to authenticated;
create policy voucher_returns_read on public.parking_cash_voucher_returns for select to authenticated using(private.is_staff() and (returned_by=auth.uid() or exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in ('admin','manager'))));
-- Preserve the unitemized opening IOUs. Do not invent individual debtors or new income.
create table private.parking_legacy_vouchers(singleton boolean primary key default true check(singleton),amount_eur numeric(12,2) not null check(amount_eur>=0));
revoke all on private.parking_legacy_vouchers from public,anon,authenticated;
insert into private.parking_legacy_vouchers(singleton,amount_eur)
select true,greatest(0,coalesce((select c.vouchers-(select coalesce(sum(e.amount_eur),0) from public.parking_cash_entries e where e.kind='voucher' and e.created_at<=c.updated_at) from public.parking_cash_counts c order by c.updated_at desc limit 1),0));

alter function private.parking_cash_state(uuid) rename to parking_cash_state_before_vouchers;
create function private.parking_cash_state(p_shift_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;v_active jsonb;v_total numeric;v_legacy numeric;v_until timestamptz;v_returns jsonb;
begin
 v:=private.parking_cash_state_before_vouchers(p_shift_id);
 select coalesce(closed_at,clock_timestamp()) into v_until from public.staff_shifts where id=p_shift_id;
 select amount_eur into v_legacy from private.parking_legacy_vouchers where singleton;
 select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at,e.id),'[]'::jsonb),coalesce(sum(e.amount_eur),0)+v_legacy into v_active,v_total
 from public.parking_cash_entries e where e.kind='voucher' and e.created_at<=v_until and not exists(select 1 from public.parking_cash_voucher_returns r where r.voucher_id=e.id and r.returned_at<=v_until);
 select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('entry_number',e.entry_number) order by r.returned_at),'[]'::jsonb) into v_returns from public.parking_cash_voucher_returns r join public.parking_cash_entries e on e.id=r.voucher_id where r.shift_id=p_shift_id;
 return v||jsonb_build_object('vouchers',v_total,'legacy_vouchers',v_legacy,'active_vouchers',v_active,'voucher_returns',v_returns,'counted_total',(v->>'cash_total')::numeric+v_total,'difference',(v->>'cash_total')::numeric+v_total-(v->>'expected_balance')::numeric);
end $$;
revoke all on function private.parking_cash_state(uuid) from public,anon,authenticated;

create function public.parking_active_cash_vouchers() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at,e.id),'[]'::jsonb) from public.parking_cash_entries e where e.kind='voucher' and not exists(select 1 from public.parking_cash_voucher_returns r where r.voucher_id=e.id)),'legacy_vouchers',(select amount_eur from private.parking_legacy_vouchers where singleton));
end $$;
revoke all on function public.parking_active_cash_vouchers() from public,anon;
grant execute on function public.parking_active_cash_vouchers() to authenticated;

alter function public.parking_save_cash_count(uuid,jsonb) set schema private;
alter function private.parking_save_cash_count(uuid,jsonb) rename to parking_save_cash_count_before_vouchers;
revoke all on function private.parking_save_cash_count_before_vouchers(uuid,jsonb) from public,anon,authenticated;
create function public.parking_save_cash_count(p_shift_id uuid,p_values jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 perform 1 from public.staff_shifts where id=p_shift_id and user_id=auth.uid() and closed_at is null for update;
 if not found then raise exception 'Necesitas tu turno abierto para guardar el arqueo';end if;
 v:=private.parking_cash_state(p_shift_id);
 return private.parking_save_cash_count_before_vouchers(p_shift_id,p_values||jsonb_build_object('vouchers',v->'vouchers'));
end $$;
revoke all on function public.parking_save_cash_count(uuid,jsonb) from public,anon;
grant execute on function public.parking_save_cash_count(uuid,jsonb) to authenticated;

create function public.parking_cancel_cash_voucher(p_voucher_id uuid,p_shift_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.parking_cash_entries;r public.parking_cash_voucher_returns;v jsonb;v_name text;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 -- Same lock order as cash count / shift closing. Voucher row serializes competing redemptions.
 perform 1 from public.staff_shifts where id=p_shift_id and user_id=auth.uid() and closed_at is null for update;
 if not found then raise exception 'Necesitas tu turno abierto para cancelar el vale';end if;
 select * into e from public.parking_cash_entries where id=p_voucher_id and kind='voucher' for update;
 if not found then raise exception 'Vale no válido';end if;
 select * into r from public.parking_cash_voucher_returns where voucher_id=e.id;
 if found then return to_jsonb(r);end if;
 v:=private.parking_cash_state(p_shift_id);
 select full_name into v_name from public.staff_profiles where user_id=auth.uid();
 insert into public.parking_cash_voucher_returns(voucher_id,shift_id,returned_by,employee_name,amount_eur)values(e.id,p_shift_id,auth.uid(),coalesce(v_name,''),e.amount_eur) returning * into r;
 -- Returned cash is provisionally included in banknotes; the employee can recount its denominations.
 insert into public.parking_cash_counts(shift_id,opening_balance,loose_coins,wrapped_coins,banknotes,vouchers,updated_by)
 values(p_shift_id,(v->>'opening_balance')::numeric,(v->>'loose_coins')::numeric,(v->>'wrapped_coins')::numeric,(v->>'banknotes')::numeric+e.amount_eur,(v->>'vouchers')::numeric-e.amount_eur,auth.uid())
 on conflict(shift_id) do update set banknotes=excluded.banknotes,vouchers=excluded.vouchers,updated_by=excluded.updated_by,updated_at=clock_timestamp();
 insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)values(p_shift_id,auth.uid(),'cash_voucher_returned','cash_entry',e.id,to_jsonb(r));
 return to_jsonb(r);
end $$;
revoke all on function public.parking_cancel_cash_voucher(uuid,uuid) from public,anon;
grant execute on function public.parking_cancel_cash_voucher(uuid,uuid) to authenticated;

create or replace function public.parking_billing_movements(p_from timestamp,p_to timestamp) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_from timestamptz;v_to timestamptz;v_rows jsonb;
begin
 if not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in ('admin','manager')) then raise exception 'No autorizado para Facturación';end if;
 if p_from is null or p_to is null or p_to<p_from then raise exception 'Revisa el intervalo de fechas y horas';end if;
 -- Inputs are Madrid wall times, irrespective of the browser or database timezone.
 v_from:=date_trunc('minute',p_from) at time zone 'Europe/Madrid';v_to:=(date_trunc('minute',p_to)+interval '1 minute') at time zone 'Europe/Madrid';
 with movements as (
 select m.id,'income'::text as kind,m.category,m.paid_at as event_at,m.reference,m.plate,m.description,m.amount_eur,m.payment_method,m.employee_name,m.shift_id,m.entity_type,m.entity_id,
 coalesce((select string_agg(i.number,', ' order by i.issued_at) from public.parking_invoices i where (i.entity_type=m.entity_type and i.entity_id=m.entity_id) or (m.entity_type='subscriber_payment' and i.entity_type='subscriber' and exists(select 1 from public.monthly_subscription_payments mp where mp.id=m.entity_id and mp.subscriber_id=i.entity_id and mp.billing_month=i.billing_month))),'') as invoice_number
 from public.parking_cash_movements m where m.paid_at>=v_from and m.paid_at<v_to
 union all select w.id,'withdrawal','withdrawal',w.created_at,'R-'||w.withdrawal_number,null,'Retirada de efectivo',w.amount_eur,'cash',w.employee_name,w.shift_id,'cash_withdrawal',w.id,'' from public.parking_cash_withdrawals w where w.created_at>=v_from and w.created_at<v_to
 union all select e.id,e.kind,e.kind,e.created_at,case when e.kind='voucher' then 'V-' else 'G-' end||e.entry_number,null,e.description,e.amount_eur,'cash',e.employee_name,e.shift_id,'cash_entry',e.id,'' from public.parking_cash_entries e where e.created_at>=v_from and e.created_at<v_to
 union all select r.voucher_id,'voucher_return','voucher_return',r.returned_at,'V-'||e.entry_number,null,'Cancelación de vale · devolución a caja',r.amount_eur,'cash',r.employee_name,r.shift_id,'cash_voucher_return',r.voucher_id,'' from public.parking_cash_voucher_returns r join public.parking_cash_entries e on e.id=r.voucher_id where r.returned_at>=v_from and r.returned_at<v_to
 ) select coalesce(jsonb_agg(to_jsonb(m)||jsonb_build_object('shift_code',s.shift_code,'shift_date',s.shift_date)order by m.event_at,m.kind,m.id),'[]'::jsonb) into v_rows from movements m left join public.staff_shifts s on s.id=m.shift_id;
 return jsonb_build_object('from',v_from,'to_exclusive',v_to,'from_local',p_from,'to_local',p_to,'rows',v_rows,'generated_at',clock_timestamp());
end $$;
revoke all on function public.parking_billing_movements(timestamp,timestamp) from public,anon;
grant execute on function public.parking_billing_movements(timestamp,timestamp) to authenticated;
