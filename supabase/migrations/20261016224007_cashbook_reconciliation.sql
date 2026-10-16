-- Counted money, expenses and cash IOUs belong to the actual employee shift.
create table public.parking_cash_counts(
 shift_id uuid primary key references public.staff_shifts(id),
 opening_balance numeric(12,2) not null check(opening_balance>=0),
 loose_coins numeric(12,2) not null check(loose_coins>=0),
 wrapped_coins numeric(12,2) not null check(wrapped_coins>=0),
 banknotes numeric(12,2) not null check(banknotes>=0),
 vouchers numeric(12,2) not null check(vouchers>=0),
 updated_by uuid not null references public.staff_profiles(user_id),
 updated_at timestamptz not null default clock_timestamp(),final_report jsonb
);
create table public.parking_cash_entries(
 id uuid primary key default gen_random_uuid(),entry_number bigint generated always as identity unique,
 request_id uuid not null unique,shift_id uuid not null references public.staff_shifts(id),
 created_by uuid not null references public.staff_profiles(user_id),employee_name text not null,
 kind text not null check(kind in ('expense','voucher')),description text not null,
 amount_eur numeric(12,2) not null check(amount_eur>0 and amount_eur<10000000000),
 created_at timestamptz not null default clock_timestamp()
);
create index parking_cash_entries_shift_idx on public.parking_cash_entries(shift_id,created_at);
create index parking_cash_entries_user_idx on public.parking_cash_entries(created_by);
create index parking_cash_counts_user_idx on public.parking_cash_counts(updated_by);
alter table public.parking_cash_counts enable row level security;
alter table public.parking_cash_entries enable row level security;
revoke all on public.parking_cash_counts,public.parking_cash_entries from public,anon,authenticated;
grant select on public.parking_cash_counts,public.parking_cash_entries to authenticated;
create policy cash_counts_read on public.parking_cash_counts for select to authenticated using(
 (select private.is_staff()) and (updated_by=(select auth.uid()) or exists(select 1 from public.staff_profiles where user_id=(select auth.uid()) and active and role in ('admin','manager'))));
create policy cash_entries_read on public.parking_cash_entries for select to authenticated using(
 (select private.is_staff()) and (created_by=(select auth.uid()) or exists(select 1 from public.staff_profiles where user_id=(select auth.uid()) and active and role in ('admin','manager'))));

create function private.parking_cash_amount(p_text text) returns numeric language plpgsql immutable set search_path='' as $$
declare v numeric;
begin
 if p_text is null or p_text!~'^[0-9]+([.][0-9]{1,2})?$' then raise exception 'Importe no válido: usa como máximo dos decimales';end if;
 v:=p_text::numeric;if v<0 or v>=10000000000 then raise exception 'Importe fuera de rango';end if;return v;
end $$;
revoke all on function private.parking_cash_amount(text) from public,anon,authenticated;

create function private.parking_cash_state(p_shift_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.parking_cash_counts;v_open numeric:=0;v_previous_vouchers numeric:=0;v_cash numeric;v_expenses numeric;v_vouchers numeric;v_withdrawals numeric;v_expected numeric;v_counted numeric;v_entries jsonb;
begin
 select * into c from public.parking_cash_counts where shift_id=p_shift_id;
 if c.shift_id is null then
  select old.opening_balance+coalesce((select sum(m.amount_eur) from public.parking_cash_movements m where m.shift_id=old.shift_id and m.payment_method='cash'),0)-coalesce((select sum(e.amount_eur) from public.parking_cash_entries e where e.shift_id=old.shift_id and e.kind='expense'),0)-coalesce((select sum(w.amount_eur) from public.parking_cash_withdrawals w where w.shift_id=old.shift_id),0),old.vouchers
  into v_open,v_previous_vouchers from public.parking_cash_counts old join public.staff_shifts s on s.id=old.shift_id
  where s.closed_at is not null and s.closed_at<=(select opened_at from public.staff_shifts where id=p_shift_id)
  order by s.closed_at desc limit 1;
 else v_open:=c.opening_balance;end if;
 select coalesce(sum(amount_eur),0) into v_cash from public.parking_cash_movements where shift_id=p_shift_id and payment_method='cash';
 select coalesce(sum(amount_eur) filter(where kind='expense'),0),coalesce(sum(amount_eur) filter(where kind='voucher'),0),coalesce(jsonb_agg(to_jsonb(e) order by created_at),'[]'::jsonb) into v_expenses,v_vouchers,v_entries from public.parking_cash_entries e where shift_id=p_shift_id;
 select coalesce(sum(amount_eur),0) into v_withdrawals from public.parking_cash_withdrawals where shift_id=p_shift_id;
 v_expected:=coalesce(v_open,0)+v_cash-v_expenses-v_withdrawals;
 v_counted:=coalesce(c.loose_coins,0)+coalesce(c.wrapped_coins,0)+coalesce(c.banknotes,0)+coalesce(c.vouchers,0);
 return jsonb_build_object('saved',c.shift_id is not null,'opening_balance',coalesce(v_open,0),'loose_coins',coalesce(c.loose_coins,0),'wrapped_coins',coalesce(c.wrapped_coins,0),'banknotes',coalesce(c.banknotes,0),'vouchers',coalesce(c.vouchers,coalesce(v_previous_vouchers,0)+v_vouchers),'cash_total',coalesce(c.loose_coins,0)+coalesce(c.wrapped_coins,0)+coalesce(c.banknotes,0),'counted_total',v_counted,'cash_income',v_cash,'expense_total',v_expenses,'voucher_total',v_vouchers,'withdrawal_total',v_withdrawals,'expected_balance',v_expected,'difference',v_counted-v_expected,'entries',v_entries,'updated_at',c.updated_at);
end $$;
revoke all on function private.parking_cash_state(uuid) from public,anon,authenticated;

create function public.parking_save_cash_count(p_shift_id uuid,p_values jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.staff_shifts;v_open numeric;v_loose numeric;v_wrapped numeric;v_notes numeric;v_vouchers numeric;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select * into s from public.staff_shifts where id=p_shift_id and user_id=auth.uid() and closed_at is null for update;
 if not found then raise exception 'Necesitas tu turno abierto para guardar el arqueo';end if;
 v_open:=private.parking_cash_amount(p_values->>'opening_balance');v_loose:=private.parking_cash_amount(p_values->>'loose_coins');v_wrapped:=private.parking_cash_amount(p_values->>'wrapped_coins');v_notes:=private.parking_cash_amount(p_values->>'banknotes');v_vouchers:=private.parking_cash_amount(p_values->>'vouchers');
 insert into public.parking_cash_counts(shift_id,opening_balance,loose_coins,wrapped_coins,banknotes,vouchers,updated_by)
 values(s.id,v_open,v_loose,v_wrapped,v_notes,v_vouchers,auth.uid()) on conflict(shift_id) do update set opening_balance=excluded.opening_balance,loose_coins=excluded.loose_coins,wrapped_coins=excluded.wrapped_coins,banknotes=excluded.banknotes,vouchers=excluded.vouchers,updated_by=excluded.updated_by,updated_at=clock_timestamp();
 insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)values(s.id,auth.uid(),'cash_count_saved','cash_count',s.id,p_values);
 return private.parking_cash_state(s.id);
end $$;
revoke all on function public.parking_save_cash_count(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.parking_save_cash_count(uuid,jsonb) to authenticated;

create function public.parking_register_cash_entry(p_shift_id uuid,p_request_id uuid,p_kind text,p_amount_eur numeric,p_description text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.staff_shifts;e public.parking_cash_entries;v_name text;v_amount numeric;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if p_kind not in ('expense','voucher') or p_kind is null or p_request_id is null then raise exception 'Tipo de movimiento no válido';end if;
 v_amount:=private.parking_cash_amount(p_amount_eur::text);if v_amount<=0 then raise exception 'El importe debe ser positivo';end if;
 if p_kind='expense' and (length(trim(coalesce(p_description,'')))=0 or length(p_description)>500) then raise exception 'Escribe la descripción del gasto (máximo 500 caracteres)';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_request_id::text,0));
 select * into e from public.parking_cash_entries where request_id=p_request_id;
 if found then
  if e.created_by<>auth.uid() or e.shift_id<>p_shift_id or e.kind<>p_kind or e.amount_eur<>p_amount_eur or (p_kind='expense' and e.description<>trim(p_description)) then raise exception 'La solicitud corresponde a otro movimiento';end if;return to_jsonb(e);
 end if;
 select * into s from public.staff_shifts where id=p_shift_id and user_id=auth.uid() and closed_at is null for update;
 if not found then raise exception 'Necesitas tu turno abierto para registrar el movimiento';end if;
 select full_name into v_name from public.staff_profiles where user_id=auth.uid() and active;
 insert into public.parking_cash_entries(request_id,shift_id,created_by,employee_name,kind,description,amount_eur)values(p_request_id,s.id,auth.uid(),coalesce(v_name,''),p_kind,case when p_kind='expense' then trim(p_description) else 'Vale de efectivo' end,v_amount) returning * into e;
 -- A vale replaces cash with an IOU in the counted drawer, and is not a second expense.
 if p_kind='voucher' then update public.parking_cash_counts set vouchers=vouchers+v_amount,updated_at=clock_timestamp() where shift_id=s.id;end if;
 insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)values(s.id,auth.uid(),'cash_'||p_kind,'cash_entry',e.id,to_jsonb(e));return to_jsonb(e);
end $$;
revoke all on function public.parking_register_cash_entry(uuid,uuid,text,numeric,text) from public,anon,authenticated;
grant execute on function public.parking_register_cash_entry(uuid,uuid,text,numeric,text) to authenticated;

create function public.parking_cashbook_shifts(p_date date,p_shift_code integer) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'employee_name',p.full_name,'user_id',s.user_id,'closed_at',s.closed_at,'opened_at',s.opened_at)order by s.opened_at desc),'[]'::jsonb) from public.staff_shifts s join public.staff_profiles p on p.user_id=s.user_id where s.shift_date=p_date and s.shift_code=p_shift_code and (s.user_id=auth.uid() or exists(select 1 from public.staff_profiles a where a.user_id=auth.uid() and a.active and a.role in ('admin','manager'))));
end $$;
revoke all on function public.parking_cashbook_shifts(date,integer) from public,anon,authenticated;
grant execute on function public.parking_cashbook_shifts(date,integer) to authenticated;

create or replace function public.parking_cashbook(p_date date,p_shift_code integer,p_shift_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_role text;v_start timestamptz;v_end timestamptz;v_rows jsonb;v_withdrawals jsonb;v_withdrawal_total numeric;s public.staff_shifts;v_id uuid:=p_shift_id;v_name text;v_saved jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if p_shift_code not in (1,2,3) or p_date is null then raise exception 'Turno no válido';end if;
 if v_id is null and v_role in ('admin','manager') then
  select case when count(*)=1 then (array_agg(id))[1] end into v_id from public.staff_shifts where shift_date=p_date and shift_code=p_shift_code;
 end if;
 if v_id is not null then
  select * into s from public.staff_shifts where id=v_id;
  if not found or (v_role not in ('admin','manager') and s.user_id<>auth.uid()) then raise exception 'No autorizado para este turno';end if;
  p_date:=s.shift_date;p_shift_code:=s.shift_code;
  select full_name into v_name from public.staff_profiles where user_id=s.user_id;
  select final_report into v_saved from public.parking_cash_counts where shift_id=s.id;
  if s.closed_at is not null and v_saved is not null then return v_saved;end if;
 elsif v_role not in ('admin','manager') then raise exception 'Selecciona tu turno';end if;
 v_start:=(case p_shift_code when 1 then p_date::timestamp-interval '2 hours' when 2 then p_date::timestamp+interval '6 hours' else p_date::timestamp+interval '14 hours' end) at time zone 'Europe/Madrid';
 v_end:=(case p_shift_code when 1 then p_date::timestamp+interval '6 hours' when 2 then p_date::timestamp+interval '14 hours' else p_date::timestamp+interval '22 hours' end) at time zone 'Europe/Madrid';
 select coalesce(jsonb_agg(to_jsonb(m) order by m.paid_at,m.id),'[]'::jsonb) into v_rows from public.parking_cash_movements m where (v_id is not null and m.shift_id=v_id) or (v_id is null and m.paid_at>=v_start and m.paid_at<v_end);
 select coalesce(jsonb_agg(to_jsonb(w) order by w.created_at,w.id),'[]'::jsonb),coalesce(sum(w.amount_eur),0) into v_withdrawals,v_withdrawal_total from public.parking_cash_withdrawals w where (v_id is not null and w.shift_id=v_id) or (v_id is null and w.created_at>=v_start and w.created_at<v_end);
 return jsonb_build_object('date',p_date,'shift_code',p_shift_code,'shift_id',v_id,'employee_name',coalesce(v_name,''),'opened_at',s.opened_at,'closed_at',s.closed_at,'generated_at',clock_timestamp(),'from',v_start,'to',v_end,'rows',v_rows,'withdrawals',v_withdrawals,'withdrawal_total_eur',v_withdrawal_total,'cash_state',case when v_id is not null then private.parking_cash_state(v_id) else null end);
end $$;
revoke all on function public.parking_cashbook(date,integer,uuid) from public,anon;
grant execute on function public.parking_cashbook(date,integer,uuid) to authenticated;

create function private.parking_guard_cash_close() returns trigger language plpgsql security definer set search_path='' as $$
declare v_state jsonb;v_report jsonb;
begin
 if old.closed_at is null and new.closed_at is not null then
  v_state:=private.parking_cash_state(new.id);
  if not (v_state->>'saved')::boolean then raise exception 'Guarda el Resumen de caja antes de cerrar el turno';end if;
  if (v_state->>'difference')::numeric<>0 then raise exception 'El arqueo no coincide con el saldo de salida. Revisa el Resumen de caja antes de cerrar';end if;
  v_report:=public.parking_cashbook(new.shift_date,new.shift_code,new.id)||jsonb_build_object('generated_at',new.closed_at,'closed_at',new.closed_at);
  update public.parking_cash_counts set final_report=v_report where shift_id=new.id;
 end if;return new;
end $$;
revoke all on function private.parking_guard_cash_close() from public,anon,authenticated;
create trigger parking_cash_close_guard before update of closed_at on public.staff_shifts for each row execute function private.parking_guard_cash_close();

create function public.parking_close_cash_shift(p_shift_id uuid,p_expected jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.staff_shifts;v_fresh jsonb;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select * into s from public.staff_shifts where id=p_shift_id and user_id=auth.uid() and closed_at is null for update;
 if not found then raise exception 'No hay ningún turno abierto';end if;
 v_fresh:=public.parking_cashbook(s.shift_date,s.shift_code,s.id);
 if p_expected is null or (v_fresh-'generated_at')<>(p_expected-'generated_at') then raise exception 'La caja ha cambiado después de imprimir. Revisa el resumen y vuelve a cerrar';end if;
 return public.close_staff_shift();
end $$;
revoke all on function public.parking_close_cash_shift(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.parking_close_cash_shift(uuid,jsonb) to authenticated;

-- Serialize money received against shift closure, including a late response from another tab.
create function private.parking_guard_cash_movement() returns trigger language plpgsql security definer set search_path='' as $$
declare v_closed timestamptz;
begin
 if new.shift_id is not null then
  select closed_at into v_closed from public.staff_shifts where id=new.shift_id for update;
  if not found or v_closed is not null then raise exception 'El turno de este cobro está cerrado. Abre tu turno actual';end if;
 end if;return new;
end $$;
revoke all on function private.parking_guard_cash_movement() from public,anon,authenticated;
create trigger parking_cash_movement_open_shift before insert on public.parking_cash_movements for each row execute function private.parking_guard_cash_movement();
