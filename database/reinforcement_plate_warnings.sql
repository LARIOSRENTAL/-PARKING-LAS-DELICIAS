create or replace function public.parking_reinforcement_check_plate(p_code text,p_plate text) returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_plate text:=regexp_replace(upper(coalesce(p_plate,'')),'[^A-Z0-9]','','g'); v_block jsonb;v_authorized jsonb;
begin
 if not exists(select 1 from public.parking_reinforcement_access where token_hash=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex') and revoked_at is null and expires_at>now()) then raise exception 'Código no válido o caducado';end if;
 if length(v_plate) not between 3 and 16 then raise exception 'Matrícula incorrecta';end if;
 select jsonb_build_object('plate',plate,'observation',observation) into v_block from public.parking_plate_blacklist where plate=v_plate and active;
 select jsonb_build_object('plate',plate,'observation',observation) into v_authorized from public.parking_authorized_plates where plate=v_plate and active;
 return jsonb_build_object('blocked',v_block,'authorized',v_authorized);
end $fn$;
revoke all on function public.parking_reinforcement_check_plate(text,text) from public;
grant execute on function public.parking_reinforcement_check_plate(text,text) to anon,authenticated;