-- Keep cash discrepancies visible across shifts without changing physical counts.
CREATE OR REPLACE FUNCTION private.parking_cash_state_before_vouchers(p_shift_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.parking_cash_counts;v_open numeric:=0;v_previous_vouchers numeric:=0;v_previous_loose numeric:=0;v_previous_wrapped numeric:=0;v_previous_notes numeric:=0;v_previous_shift uuid;v_cash numeric;v_expenses numeric;v_vouchers numeric;v_withdrawals numeric;v_expected numeric;v_counted numeric;v_entries jsonb;
begin
 select * into c from public.parking_cash_counts where shift_id=p_shift_id;
 if c.shift_id is null then
  select old.loose_coins+old.wrapped_coins+old.banknotes+old.vouchers,old.vouchers,old.loose_coins,old.wrapped_coins,old.banknotes,old.shift_id
  into v_open,v_previous_vouchers,v_previous_loose,v_previous_wrapped,v_previous_notes,v_previous_shift
  from public.parking_cash_counts old join public.staff_shifts s on s.id=old.shift_id
  where s.closed_at is not null and s.id<>p_shift_id and s.opened_at<(select opened_at from public.staff_shifts where id=p_shift_id)
  order by s.closed_at desc limit 1;
  -- Carry the accounting balance forward; retain the counted denominations separately.
  if v_previous_shift is not null then
   v_open:=(private.parking_cash_state_before_vouchers(v_previous_shift)->>'expected_balance')::numeric;
  end if;
 else v_open:=c.opening_balance;end if;
 select coalesce(sum(amount_eur),0) into v_cash from public.parking_cash_movements where shift_id=p_shift_id and payment_method='cash';
 select coalesce(sum(amount_eur) filter(where kind='expense'),0),coalesce(sum(amount_eur) filter(where kind='voucher'),0),coalesce(jsonb_agg(to_jsonb(e) order by created_at),'[]'::jsonb) into v_expenses,v_vouchers,v_entries from public.parking_cash_entries e where shift_id=p_shift_id;
 select coalesce(sum(amount_eur),0) into v_withdrawals from public.parking_cash_withdrawals where shift_id=p_shift_id;
 v_expected:=coalesce(v_open,0)+v_cash-v_expenses-v_withdrawals;
 v_counted:=coalesce(c.loose_coins,v_previous_loose,0)+coalesce(c.wrapped_coins,v_previous_wrapped,0)+coalesce(c.banknotes,v_previous_notes,0)+coalesce(c.vouchers,coalesce(v_previous_vouchers,0)+v_vouchers);
 return jsonb_build_object('saved',c.shift_id is not null,'inherited_from_shift',v_previous_shift,'opening_balance',coalesce(v_open,0),'loose_coins',coalesce(c.loose_coins,v_previous_loose,0),'wrapped_coins',coalesce(c.wrapped_coins,v_previous_wrapped,0),'banknotes',coalesce(c.banknotes,v_previous_notes,0),'vouchers',coalesce(c.vouchers,coalesce(v_previous_vouchers,0)+v_vouchers),'cash_total',coalesce(c.loose_coins,v_previous_loose,0)+coalesce(c.wrapped_coins,v_previous_wrapped,0)+coalesce(c.banknotes,v_previous_notes,0),'counted_total',v_counted,'cash_income',v_cash,'expense_total',v_expenses,'voucher_total',v_vouchers,'withdrawal_total',v_withdrawals,'expected_balance',v_expected,'difference',v_counted-v_expected,'entries',v_entries,'updated_at',c.updated_at);
end $function$;


CREATE OR REPLACE FUNCTION private.parking_save_cash_count_before_vouchers(p_shift_id uuid, p_values jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.staff_shifts;v_open numeric;v_loose numeric;v_wrapped numeric;v_notes numeric;v_vouchers numeric;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select * into s from public.staff_shifts where id=p_shift_id and user_id=auth.uid() and closed_at is null for update;
 if not found then raise exception 'Necesitas tu turno abierto para guardar el arqueo';end if;
 -- The opening balance comes from the ledger, never from a stale browser payload.
 v_open:=(private.parking_cash_state(p_shift_id)->>'opening_balance')::numeric;v_loose:=private.parking_cash_amount(p_values->>'loose_coins');v_wrapped:=private.parking_cash_amount(p_values->>'wrapped_coins');v_notes:=private.parking_cash_amount(p_values->>'banknotes');v_vouchers:=private.parking_cash_amount(p_values->>'vouchers');
 insert into public.parking_cash_counts(shift_id,opening_balance,loose_coins,wrapped_coins,banknotes,vouchers,updated_by)
 values(s.id,v_open,v_loose,v_wrapped,v_notes,v_vouchers,auth.uid()) on conflict(shift_id) do update set opening_balance=excluded.opening_balance,loose_coins=excluded.loose_coins,wrapped_coins=excluded.wrapped_coins,banknotes=excluded.banknotes,vouchers=excluded.vouchers,updated_by=excluded.updated_by,updated_at=clock_timestamp();
 insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)values(s.id,auth.uid(),'cash_count_saved','cash_count',s.id,p_values);
 return private.parking_cash_state(s.id);
end $function$;


CREATE OR REPLACE FUNCTION public.parking_cashbook(p_date date, p_shift_code integer, p_shift_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if s.closed_at is not null and v_saved is not null then
 select coalesce(jsonb_agg((to_jsonb(m)||jsonb_build_object('subscriber_receipt_p',m.category='subscriber' and m.entity_type='subscriber_payment' and exists(select 1 from public.parking_monthly_receipts r where r.payment_id=m.entity_id))) order by m.paid_at,m.id),'[]'::jsonb) into v_rows from public.parking_cash_movements m where m.shift_id=s.id;
 return v_saved||jsonb_build_object('rows',v_rows,'cash_state',private.parking_cash_state(s.id),'cashbook_number',s.shift_number+108,'date',p_date,'shift_code',p_shift_code);end if;
 elsif v_role not in ('admin','manager') then raise exception 'Selecciona tu turno';end if;
 v_start:=(case p_shift_code when 1 then p_date::timestamp-interval '2 hours' when 2 then p_date::timestamp+interval '6 hours' else p_date::timestamp+interval '14 hours' end) at time zone 'Europe/Madrid';
 v_end:=(case p_shift_code when 1 then p_date::timestamp+interval '6 hours' when 2 then p_date::timestamp+interval '14 hours' else p_date::timestamp+interval '22 hours' end) at time zone 'Europe/Madrid';
 select coalesce(jsonb_agg((to_jsonb(m)||jsonb_build_object('subscriber_receipt_p',m.category='subscriber' and m.entity_type='subscriber_payment' and exists(select 1 from public.parking_monthly_receipts r where r.payment_id=m.entity_id))) order by m.paid_at,m.id),'[]'::jsonb) into v_rows from public.parking_cash_movements m where (v_id is not null and m.shift_id=v_id) or (v_id is null and m.paid_at>=v_start and m.paid_at<v_end);
 select coalesce(jsonb_agg(to_jsonb(w) order by w.created_at,w.id),'[]'::jsonb),coalesce(sum(w.amount_eur),0) into v_withdrawals,v_withdrawal_total from public.parking_cash_withdrawals w where (v_id is not null and w.shift_id=v_id) or (v_id is null and w.created_at>=v_start and w.created_at<v_end);
 return jsonb_build_object('cashbook_number',case when s.id is not null then s.shift_number+108 else null end,'date',p_date,'shift_code',p_shift_code,'shift_id',v_id,'employee_name',coalesce(v_name,''),'opened_at',s.opened_at,'closed_at',s.closed_at,'generated_at',clock_timestamp(),'from',v_start,'to',v_end,'rows',v_rows,'withdrawals',v_withdrawals,'withdrawal_total_eur',v_withdrawal_total,'cash_state',case when v_id is not null then private.parking_cash_state(v_id) else null end);
end $function$;
