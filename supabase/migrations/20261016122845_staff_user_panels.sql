-- Remove access without deleting historical staff references from shifts and payments.
alter table public.staff_profiles add column if not exists deleted_at timestamptz;
alter table public.staff_profiles add constraint staff_deleted_is_inactive check (deleted_at is null or not active);

-- Serialize changes to administrator access, including direct administrative writes.
create or replace function private.guard_last_staff_admin()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pg_advisory_xact_lock(718304, 10);
  if old.role = 'admin' and old.active and
     (tg_op = 'DELETE' or new.role <> 'admin' or not new.active or new.deleted_at is not null) then
    if not exists (select 1 from public.staff_profiles where role = 'admin' and active and deleted_at is null and user_id <> old.user_id) then
      raise exception 'Debe quedar al menos un administrador activo';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if old.deleted_at is not null then
    raise exception 'Este acceso se ha eliminado';
  end if;
  return new;
end;
$$;
revoke all on function private.guard_last_staff_admin() from public, anon, authenticated;
create trigger staff_keep_active_admin before update or delete on public.staff_profiles
for each row execute function private.guard_last_staff_admin();
