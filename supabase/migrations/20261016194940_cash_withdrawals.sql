-- Cash withdrawals are separate from sales; reprints never write another withdrawal.
create table public.parking_cash_withdrawals (
 id uuid primary key default gen_random_uuid(),
 withdrawal_number bigint generated always as identity unique not null,
 request_id uuid not null unique,
 shift_id uuid not null references public.staff_shifts(id),
 created_by uuid not null references public.staff_profiles(user_id),
 employee_name text not null,
 amount_eur numeric(12,2) not null check(amount_eur>0 and amount_eur<10000000000),
 created_at timestamptz not null default clock_timestamp()
);
create index parking_cash_withdrawals_shift_date_idx on public.parking_cash_withdrawals(shift_id,created_at);
create index parking_cash_withdrawals_created_by_idx on public.parking_cash_withdrawals(created_by);
create index parking_cash_withdrawals_created_at_idx on public.parking_cash_withdrawals(created_at);
alter table public.parking_cash_withdrawals enable row level security;
revoke all on public.parking_cash_withdrawals from public,anon,authenticated;
grant select on public.parking_cash_withdrawals to authenticated;
create policy cash_withdrawals_read on public.parking_cash_withdrawals for select to authenticated using (
 (select private.is_staff()) and (created_by=(select auth.uid()) or exists(select 1 from public.staff_profiles p where p.user_id=(select auth.uid()) and p.active and p.role in ('admin','manager')))
);

create function public.parking_register_cash_withdrawal(p_amount_eur numeric,p_request_id uuid,p_shift_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_shift public.staff_shifts;v_row public.parking_cash_withdrawals;v_name text;
begin
 if v_user is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if p_amount_eur is null or p_amount_eur::text in ('NaN','Infinity','-Infinity') or p_amount_eur<=0 or p_amount_eur>=10000000000 or p_amount_eur<>round(p_amount_eur,2) then raise exception 'Introduce un importe positivo con un máximo de dos decimales';end if;
 if p_request_id is null or p_shift_id is null then raise exception 'Falta identificar la retirada o el turno';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_request_id::text,0));
 select * into v_row from public.parking_cash_withdrawals where request_id=p_request_id;
 if found then
  if v_row.created_by<>v_user or v_row.shift_id<>p_shift_id or v_row.amount_eur<>p_amount_eur then raise exception 'La solicitud corresponde a otra retirada';end if;
  return to_jsonb(v_row);
 end if;
 select * into v_shift from public.staff_shifts where id=p_shift_id and user_id=v_user and closed_at is null for update;
 if not found then raise exception 'Necesitas tu turno abierto para registrar una retirada';end if;
 select full_name into v_name from public.staff_profiles where user_id=v_user and active;
 insert into public.parking_cash_withdrawals(request_id,shift_id,created_by,employee_name,amount_eur)
 values(p_request_id,v_shift.id,v_user,coalesce(v_name,''),p_amount_eur) returning * into v_row;
 insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)
 values(v_shift.id,v_user,'cash_withdrawal','cash_withdrawal',v_row.id,jsonb_build_object('withdrawal_number',v_row.withdrawal_number,'amount_eur',v_row.amount_eur));
 return to_jsonb(v_row);
end $$;
revoke all on function public.parking_register_cash_withdrawal(numeric,uuid,uuid) from public,anon,authenticated;
grant execute on function public.parking_register_cash_withdrawal(numeric,uuid,uuid) to authenticated;

create or replace function public.parking_cashbook(p_date date,p_shift_code integer,p_shift_id uuid default null) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_role text;v_start timestamptz;v_end timestamptz;v_rows jsonb;v_withdrawals jsonb;v_withdrawal_total numeric;v_shift public.staff_shifts;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if p_shift_code not in (1,2,3) or p_date is null then raise exception 'Turno no válido';end if;
 if p_shift_id is not null then
  select * into v_shift from public.staff_shifts where id=p_shift_id;
  if not found or (v_role not in ('admin','manager') and v_shift.user_id<>auth.uid()) then raise exception 'No autorizado para este turno';end if;
 elsif v_role not in ('admin','manager') then raise exception 'Selecciona tu turno';end if;
 v_start:=(case p_shift_code when 1 then p_date::timestamp-interval '2 hours' when 2 then p_date::timestamp+interval '6 hours' else p_date::timestamp+interval '14 hours' end) at time zone 'Europe/Madrid';
 v_end:=(case p_shift_code when 1 then p_date::timestamp+interval '6 hours' when 2 then p_date::timestamp+interval '14 hours' else p_date::timestamp+interval '22 hours' end) at time zone 'Europe/Madrid';
 select coalesce(jsonb_agg(to_jsonb(m) order by m.paid_at),'[]'::jsonb) into v_rows from public.parking_cash_movements m where (p_shift_id is not null and m.shift_id=p_shift_id) or (p_shift_id is null and m.paid_at>=v_start and m.paid_at<v_end);
 select coalesce(jsonb_agg(to_jsonb(w) order by w.created_at),'[]'::jsonb),coalesce(sum(w.amount_eur),0) into v_withdrawals,v_withdrawal_total from public.parking_cash_withdrawals w where (p_shift_id is not null and w.shift_id=p_shift_id) or (p_shift_id is null and w.created_at>=v_start and w.created_at<v_end);
 return jsonb_build_object('date',p_date,'shift_code',p_shift_code,'shift_id',p_shift_id,'from',v_start,'to',v_end,'rows',v_rows,'withdrawals',v_withdrawals,'withdrawal_total_eur',v_withdrawal_total);
end $$;
revoke all on function public.parking_cashbook(date,integer,uuid) from public,anon;
grant execute on function public.parking_cashbook(date,integer,uuid) to authenticated;
