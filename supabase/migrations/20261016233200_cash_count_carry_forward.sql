-- Carry every drawer component forward from the previous closed shift, never from an open/unreconciled shift.
create or replace function private.parking_cash_state(p_shift_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.parking_cash_counts;v_open numeric:=0;v_previous_vouchers numeric:=0;v_previous_loose numeric:=0;v_previous_wrapped numeric:=0;v_previous_notes numeric:=0;v_previous_shift uuid;v_cash numeric;v_expenses numeric;v_vouchers numeric;v_withdrawals numeric;v_expected numeric;v_counted numeric;v_entries jsonb;
begin
 select * into c from public.parking_cash_counts where shift_id=p_shift_id;
 if c.shift_id is null then
  select old.loose_coins+old.wrapped_coins+old.banknotes+old.vouchers,old.vouchers,old.loose_coins,old.wrapped_coins,old.banknotes,old.shift_id
  into v_open,v_previous_vouchers,v_previous_loose,v_previous_wrapped,v_previous_notes,v_previous_shift
  from public.parking_cash_counts old join public.staff_shifts s on s.id=old.shift_id
  where s.closed_at is not null and s.id<>p_shift_id and s.opened_at<(select opened_at from public.staff_shifts where id=p_shift_id)
  order by s.closed_at desc limit 1;
 else v_open:=c.opening_balance;end if;
 select coalesce(sum(amount_eur),0) into v_cash from public.parking_cash_movements where shift_id=p_shift_id and payment_method='cash';
 select coalesce(sum(amount_eur) filter(where kind='expense'),0),coalesce(sum(amount_eur) filter(where kind='voucher'),0),coalesce(jsonb_agg(to_jsonb(e) order by created_at),'[]'::jsonb) into v_expenses,v_vouchers,v_entries from public.parking_cash_entries e where shift_id=p_shift_id;
 select coalesce(sum(amount_eur),0) into v_withdrawals from public.parking_cash_withdrawals where shift_id=p_shift_id;
 v_expected:=coalesce(v_open,0)+v_cash-v_expenses-v_withdrawals;
 v_counted:=coalesce(c.loose_coins,v_previous_loose,0)+coalesce(c.wrapped_coins,v_previous_wrapped,0)+coalesce(c.banknotes,v_previous_notes,0)+coalesce(c.vouchers,coalesce(v_previous_vouchers,0)+v_vouchers);
 return jsonb_build_object('saved',c.shift_id is not null,'inherited_from_shift',v_previous_shift,'opening_balance',coalesce(v_open,0),'loose_coins',coalesce(c.loose_coins,v_previous_loose,0),'wrapped_coins',coalesce(c.wrapped_coins,v_previous_wrapped,0),'banknotes',coalesce(c.banknotes,v_previous_notes,0),'vouchers',coalesce(c.vouchers,coalesce(v_previous_vouchers,0)+v_vouchers),'cash_total',coalesce(c.loose_coins,v_previous_loose,0)+coalesce(c.wrapped_coins,v_previous_wrapped,0)+coalesce(c.banknotes,v_previous_notes,0),'counted_total',v_counted,'cash_income',v_cash,'expense_total',v_expenses,'voucher_total',v_vouchers,'withdrawal_total',v_withdrawals,'expected_balance',v_expected,'difference',v_counted-v_expected,'entries',v_entries,'updated_at',c.updated_at);
end $$;
