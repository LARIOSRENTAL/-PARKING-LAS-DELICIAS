-- One availability predicate for Refuerzo, Rotación and Estancias.
create or replace function private.parking_spot_is_available(p_spot uuid,p_exclude_reservation uuid default null,p_exclude_rotation uuid default null)
returns boolean language sql volatile security definer set search_path='' as $$
 select exists(select 1 from public.parking_spots p where p.id=p_spot and p.active and p.inventory_state='available'
 and not exists(select 1 from public.monthly_subscribers m where m.active and (m.parking_spot_id=p.id or regexp_replace(upper(coalesce(m.parking_space_label,'')),'[^A-Z0-9]','','g')=regexp_replace(upper(p.code),'[^A-Z0-9]','','g'))))
 and not exists(select 1 from public.rotation_sessions s where s.spot_id=p_spot and s.id is distinct from p_exclude_rotation and s.status='inside' and not s.billing_only)
 and not exists(select 1 from public.parking_sessions s where s.spot_id=p_spot and (p_exclude_reservation is null or s.reservation_id is distinct from p_exclude_reservation) and s.status='inside')
 and not exists(select 1 from public.capacity_blocks b where b.spot_id=p_spot and b.active and b.starts_at<=now() and b.ends_at>now())
 and not exists(select 1 from public.reservations r where r.assigned_spot_id=p_spot and r.id is distinct from p_exclude_reservation
 and ((r.status in('confirmed','checked_in') and r.finished_at is null and not r.rotation_pending) or (r.status='pending_payment' and r.expires_at>now()))
 and ((r.entry_at<=now() and r.exit_at>now()) or exists(select 1 from public.parking_sessions held where held.reservation_id=r.id)));
$$;
revoke all on function private.parking_spot_is_available(uuid,uuid,uuid) from public,anon,authenticated;

create or replace function private.rotation_spot_is_free(p_spot_id uuid,p_exclude_rotation uuid default null)
returns boolean language sql volatile security definer set search_path='' as $$
 select private.parking_spot_is_available(p_spot_id,null,p_exclude_rotation);
$$;

create or replace function public.parking_available_stay_spots()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 return (select coalesce(jsonb_agg(p.id order by p.sort_order,p.code),'[]'::jsonb) from public.parking_spots p where private.parking_spot_is_available(p.id));
end;$$;
revoke all on function public.parking_available_stay_spots() from public,anon;
grant execute on function public.parking_available_stay_spots() to authenticated;

create or replace function private.guard_shared_stay_space()
returns trigger language plpgsql security definer set search_path='' as $$
declare target uuid;own_res uuid;
begin
 if tg_table_name='parking_sessions' then
  if new.status<>'inside' then return new;end if;
  if tg_op='UPDATE' then if old.status='inside' and new.spot_id is not distinct from old.spot_id then return new;end if;end if;
  target:=new.spot_id;own_res:=new.reservation_id;
 else
  if new.status not in('confirmed','checked_in','pending_payment') or new.finished_at is not null or new.rotation_pending then return new;end if;
  if tg_op='UPDATE' then if new.assigned_spot_id is not distinct from old.assigned_spot_id then return new;end if;end if;
  target:=new.assigned_spot_id;own_res:=new.id;
 end if;
 if target is null then return new;end if;
 perform 1 from public.parking_spots where id=target for update;
 if not private.parking_spot_is_available(target,own_res,null) then raise exception 'La plaza está ocupada, bloqueada o asignada a otro abono o estancia';end if;
 return new;
end;$$;
revoke all on function private.guard_shared_stay_space() from public,anon,authenticated;
drop trigger if exists zzz_guard_shared_stay_space on public.parking_sessions;
create trigger zzz_guard_shared_stay_space before insert or update of status,spot_id on public.parking_sessions for each row execute function private.guard_shared_stay_space();
drop trigger if exists zzz_guard_shared_stay_space on public.reservations;
create trigger zzz_guard_shared_stay_space before insert or update of status,assigned_spot_id on public.reservations for each row execute function private.guard_shared_stay_space();

-- Existing RLS plus the existing admin/manager-only plate RPC; all writes atomic.
create or replace function public.parking_save_subscriber_profile(p_subscriber_id uuid,p_data jsonb,p_plates text[])
returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.monthly_subscribers;v public.monthly_subscribers;
begin
 if auth.uid() is null or not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in('admin','manager')) then raise exception 'No autorizado';end if;
 select * into m from public.monthly_subscribers where id=p_subscriber_id for update;
 if not found then raise exception 'Abonado inexistente';end if;
 v:=jsonb_populate_record(m,p_data);
 if length(trim(v.customer_name))<2 or regexp_replace(upper(coalesce(v.plate,'')),'[^A-Z0-9]','','g') !~ '^[A-Z0-9]{3,16}$' then raise exception 'Nombre o matrícula incorrectos';end if;
 update public.monthly_subscribers set customer_name=v.customer_name,tax_id=v.tax_id,address=v.address,postal_code=v.postal_code,city=v.city,phone=v.phone,email=v.email,vehicle=v.vehicle,plate=regexp_replace(upper(v.plate),'[^A-Z0-9]','','g'),parking_space_label=v.parking_space_label,membership_start_date=v.membership_start_date,price_eur=v.price_eur,discount_amount_eur=v.discount_amount_eur,vat_amount_eur=v.vat_amount_eur,total_eur=v.total_eur,vat_pct=v.vat_pct,discount_total_rate=v.discount_total_rate,discount_seniority_rate=v.discount_seniority_rate,discount_ca_rate=v.discount_ca_rate,discount_pp_rate=v.discount_pp_rate,discount_pct=v.discount_pct,preferred_payment_method=case when m.auto_email_bank then 'bank' else v.preferred_payment_method end,situation=v.situation,notes=v.notes,updated_at=now() where id=p_subscriber_id returning * into m;
 if not found then raise exception 'No se permite editar este abonado';end if;
 perform public.parking_set_subscriber_extra_plates(p_subscriber_id,p_plates);
 return to_jsonb(m);
end;$$;
revoke all on function public.parking_save_subscriber_profile(uuid,jsonb,text[]) from public,anon;
grant execute on function public.parking_save_subscriber_profile(uuid,jsonb,text[]) to authenticated;
