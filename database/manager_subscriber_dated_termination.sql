alter table public.monthly_subscribers add column if not exists scheduled_end_date date;
create or replace function private.guard_manager_subscriber_edit() returns trigger language plpgsql security definer set search_path='' as $$
declare allowed text[]:=array['customer_name','tax_id','address','postal_code','city','phone','email','vehicle','plate','parking_space_label','membership_start_date','price_eur','discount_amount_eur','vat_amount_eur','total_eur','vat_pct','discount_total_rate','discount_seniority_rate','discount_ca_rate','discount_pp_rate','discount_pct','preferred_payment_method','situation','notes','updated_at'];
begin
 if exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role='manager') then
  if current_setting('parking.subscriber_termination',true)='on' and old.active and (not new.active or new.active=old.active) and (to_jsonb(new)-array['active','ended_at','ended_by','scheduled_end_date','updated_at']) is not distinct from (to_jsonb(old)-array['active','ended_at','ended_by','scheduled_end_date','updated_at']) then return new;end if;
  if (to_jsonb(new)-allowed) is distinct from (to_jsonb(old)-allowed) then raise exception 'El gerente debe gestionar la baja desde el botón Dar de baja';end if;
 end if;return new;
end;$$;
create or replace function public.parking_schedule_subscriber_end(p_subscriber_id uuid,p_end_date date) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.monthly_subscribers;cutoff timestamptz;v_role text;v_shift uuid;
begin
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if auth.uid() is null or v_role is null or v_role not in ('admin','manager') then raise exception 'Solo administrador o gerente pueden gestionar bajas';end if;
 if p_end_date is null then raise exception 'Selecciona la fecha de baja';end if;
 select * into r from public.monthly_subscribers where id=p_subscriber_id for update;
 if not found or not r.active then raise exception 'Abonado inexistente o ya dado de baja';end if;
 cutoff:=(p_end_date+1)::timestamp at time zone 'Europe/Madrid';
 select id into v_shift from public.staff_shifts where user_id=auth.uid() and closed_at is null order by opened_at desc limit 1;
 perform set_config('parking.subscriber_termination','on',true);
 update public.monthly_subscribers set active=cutoff>clock_timestamp(),ended_at=cutoff,ended_by=auth.uid(),scheduled_end_date=p_end_date,updated_at=clock_timestamp() where id=r.id;
 perform set_config('parking.subscriber_termination','',true);
 insert into public.staff_activity_log(shift_id,user_id,action,entity_type,entity_id,details) values(v_shift,auth.uid(),case when cutoff>clock_timestamp() then 'monthly_subscriber_end_scheduled' else 'monthly_subscriber_deactivated' end,'monthly_subscribers',r.id,jsonb_build_object('end_date',p_end_date,'effective_at',cutoff,'previous_end_date',r.scheduled_end_date,'role',v_role));
 return jsonb_build_object('id',r.id,'end_date',p_end_date,'active',cutoff>clock_timestamp());
end;$$;
revoke all on function public.parking_schedule_subscriber_end(uuid,date) from public,anon;
grant execute on function public.parking_schedule_subscriber_end(uuid,date) to authenticated;
create or replace function private.parking_apply_subscriber_ends() returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 with ended as (update public.monthly_subscribers set active=false,updated_at=clock_timestamp() where active and scheduled_end_date<(clock_timestamp() at time zone 'Europe/Madrid')::date returning id,ended_by,scheduled_end_date)
 insert into public.staff_activity_log(user_id,action,entity_type,entity_id,details) select ended_by,'monthly_subscriber_end_effective','monthly_subscribers',id,jsonb_build_object('end_date',scheduled_end_date) from ended;
 get diagnostics n=row_count;return n;
end;$$;
revoke all on function private.parking_apply_subscriber_ends() from public,anon,authenticated;
select cron.schedule('parking-subscriber-scheduled-ends','* * * * *','select private.parking_apply_subscriber_ends()');
