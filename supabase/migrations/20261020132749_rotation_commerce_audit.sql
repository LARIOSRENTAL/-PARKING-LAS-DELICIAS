create or replace function public.parking_checkout_rotation(p_session_id uuid,p_final_amount_eur numeric,p_payment_method text,p_print_ticket boolean default false,p_adjustment_note text default null,p_invoice_customer jsonb default null) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;s public.rotation_sessions;t public.rotation_tariffs;calc jsonb;v_now timestamptz:=clock_timestamp();v_total numeric;receipt jsonb;invoice jsonb;meta jsonb;hours numeric:=0;reason text;quoted_at timestamptz;expected numeric;quote jsonb;commerce_discount numeric;manual boolean;note text;
begin
 ctx:=public.rotation_operator_context();
 if p_payment_method not in ('cash','card') then raise exception 'Forma de pago inválida';end if;
 if p_final_amount_eur is null or p_final_amount_eur<0 or p_final_amount_eur>999999 then raise exception 'Importe inválido';end if;
 select * into s from public.rotation_sessions where id=p_session_id for update;
 if not found then raise exception 'Ticket inexistente';end if;
 if s.status='cancelled' then raise exception 'El ticket se ha cancelado o convertido a estancia';end if;
 if s.status='inside' then
  select * into t from public.rotation_tariffs where id=s.tariff_id;
  calc:=public.calculate_rotation_amount(t.code,s.entry_at,v_now);v_total:=round(p_final_amount_eur,2);
  if left(ltrim(coalesce(p_adjustment_note,'')),1)='{' then
   meta:=p_adjustment_note::jsonb;
   if jsonb_typeof(meta)<>'object' or meta->>'version'<>'1' then raise exception 'Datos del ajuste no válidos';end if;
   hours:=coalesce((meta->>'commerce_free_hours')::numeric,0);reason:=nullif(btrim(meta->>'reason'),'');quoted_at:=(meta->>'quoted_exit_at')::timestamptz;
   if hours<0 or hours>10000 or hours<>trunc(hours) then raise exception 'Introduce un número entero de bonos igual o mayor que cero';end if;
   if quoted_at is null or quoted_at<s.entry_at or quoted_at>v_now+interval '1 minute' then raise exception 'Recalcula el precio antes de confirmar la salida';end if;
   quote:=public.calculate_rotation_amount(t.code,s.entry_at,quoted_at);
   if quoted_at-hours*interval '1 hour'<=s.entry_at then expected:=0;
   else expected:=(public.calculate_rotation_amount(t.code,s.entry_at,quoted_at-hours*interval '1 hour')->>'amount_eur')::numeric;end if;
   commerce_discount:=greatest(0,(quote->>'amount_eur')::numeric-expected);manual:=v_total<>round(expected,2);
   if manual and coalesce(length(reason),0)<3 then raise exception 'Escribe el motivo del cambio manual de precio';end if;
   if not manual then reason:=null;end if;
   note:=concat_ws('; ',case when hours>0 then 'Bonos de comercio: '||hours::text||' hora(s)' end,case when manual then 'Cambio manual: '||reason end);
  else
   -- Compatibility with older open cashier tabs; their known hour count is still audited.
   hours:=coalesce(substring(p_adjustment_note from '^Horas gratis: ([0-9]+(?:[.][0-9]+)?)')::numeric,0);
   note:=p_adjustment_note;
  end if;
  update public.rotation_sessions set status='departed',exit_at=v_now,paid_at=v_now,raw_amount_eur=(calc->>'raw_amount_eur')::numeric,tariff_amount_eur=(calc->>'amount_eur')::numeric,discount_bono_eur=greatest(0,(calc->>'amount_eur')::numeric-v_total),amount_eur=v_total,manual_final_amount_eur=v_total,adjustment_note=nullif(btrim(note),''),payment_method=p_payment_method,exit_user_id=(ctx->>'user_id')::uuid,exit_employee_name=ctx->>'employee_name',exit_shift_id=nullif(ctx->>'shift_id','')::uuid,exit_shift_code=nullif(ctx->>'shift_code','')::smallint,exit_shift_date=(ctx->>'shift_date')::date,updated_at=v_now where id=s.id returning * into s;
  update public.parking_cash_movements set details=coalesce(details,'{}'::jsonb)||jsonb_build_object('commerce_free_hours',hours,'commerce_discount_eur',commerce_discount,'manual_price_adjustment',manual,'adjustment_reason',reason,'expected_after_vouchers_eur',expected,'quoted_exit_at',quoted_at)
  where entity_type='rotation' and entity_id=s.id;
  if s.source_reservation_id is not null then update public.reservations set status='completed',rotation_pending=false,assigned_spot_id=null,updated_at=v_now where id=s.source_reservation_id;end if;
 end if;
 if p_invoice_customer is not null then invoice:=public.parking_issue_full_invoice('rotation',s.id,null,p_invoice_customer->>'name',p_invoice_customer->>'tax_id',p_invoice_customer->>'address');end if;
 if p_print_ticket then receipt:=public.parking_issue_simplified('rotation',s.id);end if;
 return jsonb_build_object('session',to_jsonb(s),'receipt',receipt,'invoice',invoice);
end $$;

revoke all on function public.parking_checkout_rotation(uuid,numeric,text,boolean,text,jsonb) from public,anon;
grant execute on function public.parking_checkout_rotation(uuid,numeric,text,boolean,text,jsonb) to authenticated;

-- Recover only facts present in historical notes, without altering amounts or fiscal snapshots.
update public.parking_cash_movements m set details=coalesce(m.details,'{}'::jsonb)||jsonb_build_object('commerce_free_hours',substring(s.adjustment_note from '^Horas gratis: ([0-9]+(?:[.][0-9]+)?)')::numeric)
from public.rotation_sessions s where m.entity_type='rotation' and m.entity_id=s.id and not(coalesce(m.details,'{}'::jsonb)?'commerce_free_hours') and s.adjustment_note~'^Horas gratis: [0-9]+' and substring(s.adjustment_note from '^Horas gratis: ([0-9]+(?:[.][0-9]+)?)')::numeric>0;
