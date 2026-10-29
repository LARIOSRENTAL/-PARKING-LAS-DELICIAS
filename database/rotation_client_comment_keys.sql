create or replace function private.parking_client_comment_keys() returns trigger language plpgsql set search_path='' as $$
begin
 if nullif(btrim(coalesce(new.client_text,'')),'') is not null then new.leaves_keys:=true;end if;
 return new;
end;$$;
revoke all on function private.parking_client_comment_keys() from public;
drop trigger if exists zz_parking_client_comment_keys on public.rotation_sessions;
create trigger zz_parking_client_comment_keys before insert or update of client_text,spot_id,leaves_keys on public.rotation_sessions for each row execute function private.parking_client_comment_keys();
