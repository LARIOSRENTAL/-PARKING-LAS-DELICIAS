-- Preserve the historical opening IOU balance and record each redemption separately.
-- No sale, expense, debtor or new voucher is invented for unitemized opening amounts.
create table private.parking_legacy_voucher_returns(
 request_id uuid primary key,
 shift_id uuid not null references public.staff_shifts(id),
 returned_by uuid not null references public.staff_profiles(user_id),
 employee_name text not null,
 amount_eur numeric(12,2) not null check(amount_eur>0),
 returned_at timestamptz not null default clock_timestamp()
);
create index parking_legacy_voucher_returns_shift on private.parking_legacy_voucher_returns(shift_id,returned_at);
alter table private.parking_legacy_voucher_returns enable row level security;
revoke all on private.parking_legacy_voucher_returns from public,anon,authenticated;
create function private.parking_legacy_voucher_balance(p_at timestamptz default clock_timestamp()) returns numeric language sql stable set search_path='' as $$
 select coalesce((select amount_eur from private.parking_legacy_vouchers where singleton),0)-coalesce((select sum(amount_eur)from private.parking_legacy_voucher_returns where returned_at<=p_at),0)
$$;
revoke all on function private.parking_legacy_voucher_balance(timestamptz) from public,anon,authenticated;
create or replace function private.parking_cash_state(p_shift_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;v_active jsonb;v_total numeric;v_legacy numeric;v_until timestamptz;v_returns jsonb;v_detail jsonb;
begin
 v:=private.parking_cash_state_before_vouchers(p_shift_id);
 select denomination_breakdown into v_detail from public.parking_cash_counts where shift_id=p_shift_id;
 if v_detail is null and nullif(v->>'inherited_from_shift','') is not null then
  select denomination_breakdown into v_detail from public.parking_cash_counts where shift_id=(v->>'inherited_from_shift')::uuid;
 end if;
 select coalesce(closed_at,clock_timestamp()) into v_until from public.staff_shifts where id=p_shift_id;
 v_legacy:=private.parking_legacy_voucher_balance(v_until);
 select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at,e.id),'[]'::jsonb),coalesce(sum(e.amount_eur),0)+v_legacy into v_active,v_total
 from public.parking_cash_entries e where e.kind='voucher' and e.created_at<=v_until and not exists(select 1 from public.parking_cash_voucher_returns r where r.voucher_id=e.id and r.returned_at<=v_until);
 select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('entry_number',e.entry_number) order by r.returned_at),'[]'::jsonb) into v_returns from public.parking_cash_voucher_returns r join public.parking_cash_entries e on e.id=r.voucher_id where r.shift_id=p_shift_id;
 select v_returns||coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('legacy',true)),'[]'::jsonb) into v_returns from private.parking_legacy_voucher_returns r where r.shift_id=p_shift_id;
 return v||jsonb_build_object('denomination_breakdown',coalesce(v_detail,'{}'::jsonb),'vouchers',v_total,'legacy_vouchers',v_legacy,'active_vouchers',v_active,'voucher_returns',v_returns,'counted_total',(v->>'cash_total')::numeric+v_total,'difference',(v->>'cash_total')::numeric+v_total-(v->>'expected_balance')::numeric);
end $$;
revoke all on function private.parking_cash_state(uuid) from public,anon,authenticated;


create or replace function public.parking_active_cash_vouchers() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at,e.id),'[]'::jsonb)from public.parking_cash_entries e where e.kind='voucher' and not exists(select 1 from public.parking_cash_voucher_returns r where r.voucher_id=e.id)),'legacy_vouchers',private.parking_legacy_voucher_balance());
end$$;
revoke all on function public.parking_active_cash_vouchers() from public,anon;
grant execute on function public.parking_active_cash_vouchers() to authenticated;

create function public.parking_cancel_legacy_cash_vouchers(p_shift_id uuid,p_request_id uuid,p_amount_eur numeric) returns jsonb language plpgsql security definer set search_path='' as $$
declare r private.parking_legacy_voucher_returns;v jsonb;amount numeric;remaining numeric;v_name text;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if p_request_id is null then raise exception 'Falta la referencia de la devolución';end if;
 amount:=private.parking_cash_amount(p_amount_eur::text);
 if amount<=0 then raise exception 'Introduce un importe positivo';end if;
 perform 1 from public.staff_shifts where id=p_shift_id and user_id=auth.uid() for update;
 if not found then raise exception 'Necesitas tu turno abierto para cancelar el vale';end if;
 -- One shared opening-balance lock prevents two shifts redeeming the same money.
 perform 1 from private.parking_legacy_vouchers where singleton for update;
 select * into r from private.parking_legacy_voucher_returns where request_id=p_request_id;
 if found then
  if r.returned_by<>auth.uid() or r.shift_id<>p_shift_id or r.amount_eur<>amount then raise exception 'La referencia corresponde a otra devolución';end if;
  return to_jsonb(r);
 end if;
 perform 1 from public.staff_shifts where id=p_shift_id and user_id=auth.uid() and closed_at is null;
 if not found then raise exception 'Necesitas tu turno abierto para cancelar el vale';end if;
 remaining:=private.parking_legacy_voucher_balance();
 if amount>remaining then raise exception 'El importe supera los vales anteriores pendientes (% €). Actualiza la caja',remaining;end if;
 v:=private.parking_cash_state(p_shift_id);
 select full_name into v_name from public.staff_profiles where user_id=auth.uid();
 insert into private.parking_legacy_voucher_returns(request_id,shift_id,returned_by,employee_name,amount_eur)
 values(p_request_id,p_shift_id,auth.uid(),coalesce(v_name,''),amount) returning * into r;
 insert into public.parking_cash_counts(shift_id,opening_balance,loose_coins,wrapped_coins,banknotes,vouchers,updated_by)
 values(p_shift_id,(v->>'opening_balance')::numeric,(v->>'loose_coins')::numeric,(v->>'wrapped_coins')::numeric,(v->>'banknotes')::numeric+amount,(v->>'vouchers')::numeric-amount,auth.uid())
 on conflict(shift_id)do update set banknotes=excluded.banknotes,vouchers=excluded.vouchers,updated_by=excluded.updated_by,updated_at=clock_timestamp();
 insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details)
 values(p_shift_id,auth.uid(),'legacy_cash_voucher_returned','cash_count',p_shift_id,to_jsonb(r));
 return to_jsonb(r);
end$$;
revoke all on function public.parking_cancel_legacy_cash_vouchers(uuid,uuid,numeric) from public,anon;
grant execute on function public.parking_cancel_legacy_cash_vouchers(uuid,uuid,numeric) to authenticated;
