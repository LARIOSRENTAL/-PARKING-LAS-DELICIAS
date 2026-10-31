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
 select coalesce(jsonb_agg(to_jsonb(m) order by m.paid_at,m.id),'[]'::jsonb) into v_rows from public.parking_cash_movements m where m.shift_id=s.id;
 return v_saved||jsonb_build_object('rows',v_rows,'cashbook_number',s.shift_number+107,'date',p_date,'shift_code',p_shift_code);end if;
 elsif v_role not in ('admin','manager') then raise exception 'Selecciona tu turno';end if;
 v_start:=(case p_shift_code when 1 then p_date::timestamp-interval '2 hours' when 2 then p_date::timestamp+interval '6 hours' else p_date::timestamp+interval '14 hours' end) at time zone 'Europe/Madrid';
 v_end:=(case p_shift_code when 1 then p_date::timestamp+interval '6 hours' when 2 then p_date::timestamp+interval '14 hours' else p_date::timestamp+interval '22 hours' end) at time zone 'Europe/Madrid';
 select coalesce(jsonb_agg(to_jsonb(m) order by m.paid_at,m.id),'[]'::jsonb) into v_rows from public.parking_cash_movements m where (v_id is not null and m.shift_id=v_id) or (v_id is null and m.paid_at>=v_start and m.paid_at<v_end);
 select coalesce(jsonb_agg(to_jsonb(w) order by w.created_at,w.id),'[]'::jsonb),coalesce(sum(w.amount_eur),0) into v_withdrawals,v_withdrawal_total from public.parking_cash_withdrawals w where (v_id is not null and w.shift_id=v_id) or (v_id is null and w.created_at>=v_start and w.created_at<v_end);
 return jsonb_build_object('cashbook_number',case when s.id is not null then s.shift_number+107 else null end,'date',p_date,'shift_code',p_shift_code,'shift_id',v_id,'employee_name',coalesce(v_name,''),'opened_at',s.opened_at,'closed_at',s.closed_at,'generated_at',clock_timestamp(),'from',v_start,'to',v_end,'rows',v_rows,'withdrawals',v_withdrawals,'withdrawal_total_eur',v_withdrawal_total,'cash_state',case when v_id is not null then private.parking_cash_state(v_id) else null end);
end $function$
;
