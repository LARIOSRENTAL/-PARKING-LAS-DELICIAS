-- Preserve historical totals; store denomination amounts only when actually entered.
alter table public.parking_cash_counts add column denomination_breakdown jsonb not null default '{}'::jsonb check(jsonb_typeof(denomination_breakdown)='object');

create or replace function private.parking_cash_state(p_shift_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;v_active jsonb;v_total numeric;v_legacy numeric;v_until timestamptz;v_returns jsonb;v_detail jsonb;
begin
 v:=private.parking_cash_state_before_vouchers(p_shift_id);
 select denomination_breakdown into v_detail from public.parking_cash_counts where shift_id=p_shift_id;
 if v_detail is null and nullif(v->>'inherited_from_shift','') is not null then
  select denomination_breakdown into v_detail from public.parking_cash_counts where shift_id=(v->>'inherited_from_shift')::uuid;
 end if;
 select coalesce(closed_at,clock_timestamp()) into v_until from public.staff_shifts where id=p_shift_id;
 select amount_eur into v_legacy from private.parking_legacy_vouchers where singleton;
 select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at,e.id),'[]'::jsonb),coalesce(sum(e.amount_eur),0)+v_legacy into v_active,v_total
 from public.parking_cash_entries e where e.kind='voucher' and e.created_at<=v_until and not exists(select 1 from public.parking_cash_voucher_returns r where r.voucher_id=e.id and r.returned_at<=v_until);
 select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('entry_number',e.entry_number) order by r.returned_at),'[]'::jsonb) into v_returns from public.parking_cash_voucher_returns r join public.parking_cash_entries e on e.id=r.voucher_id where r.shift_id=p_shift_id;
 return v||jsonb_build_object('denomination_breakdown',coalesce(v_detail,'{}'::jsonb),'vouchers',v_total,'legacy_vouchers',v_legacy,'active_vouchers',v_active,'voucher_returns',v_returns,'counted_total',(v->>'cash_total')::numeric+v_total,'difference',(v->>'cash_total')::numeric+v_total-(v->>'expected_balance')::numeric);
end $$;
revoke all on function private.parking_cash_state(uuid) from public,anon,authenticated;

create or replace function public.parking_save_cash_count(p_shift_id uuid,p_values jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;d jsonb:=coalesce(p_values->'denomination_breakdown','{}'::jsonb);g text;k text;amount numeric;total numeric;allowed text[];
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 perform 1 from public.staff_shifts where id=p_shift_id and user_id=auth.uid() and closed_at is null for update;
 if not found then raise exception 'Necesitas tu turno abierto para guardar el arqueo';end if;
 if jsonb_typeof(d)<>'object' then raise exception 'Desglose no válido';end if;
 for g in select jsonb_object_keys(d) loop
  if g not in ('loose_coins','wrapped_coins','banknotes') then raise exception 'Grupo de desglose no válido';end if;
  if jsonb_typeof(d->g)<>'object' then raise exception 'Desglose no válido';end if;
  allowed:=case when g='banknotes' then array['5','10','20','50','100','200','500','unallocated'] else array['0.01','0.02','0.05','0.10','0.20','0.50','1','2','unallocated'] end;
  total:=0;
  for k in select jsonb_object_keys(d->g) loop
   if not(k=any(allowed)) then raise exception 'Denominación no válida';end if;
   amount:=private.parking_cash_amount(d->g->>k);total:=total+amount;
  end loop;
  if total<>private.parking_cash_amount(p_values->>g) then raise exception 'El desglose de % no coincide con su subtotal',g;end if;
 end loop;
 v:=private.parking_cash_state(p_shift_id);
 perform private.parking_save_cash_count_before_vouchers(p_shift_id,p_values||jsonb_build_object('vouchers',v->'vouchers'));
 update public.parking_cash_counts set denomination_breakdown=d where shift_id=p_shift_id;
 return private.parking_cash_state(p_shift_id);
end $$;
revoke all on function public.parking_save_cash_count(uuid,jsonb) from public,anon;
grant execute on function public.parking_save_cash_count(uuid,jsonb) to authenticated;
