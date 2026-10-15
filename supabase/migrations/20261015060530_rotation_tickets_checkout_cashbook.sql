-- Payments are recorded once independently of invoice generation or printing.
create table public.parking_cash_movements (
 id uuid primary key default gen_random_uuid(), source_key text not null unique,
 category text not null check(category in ('subscriber','stay','rotation')),
 entity_type text not null, entity_id uuid not null, reference text not null,
 plate text, description text not null, amount_eur numeric(12,2) not null check(amount_eur>=0),
 payment_method text not null check(payment_method in ('cash','card','bank','online')),
 paid_at timestamptz not null default clock_timestamp(), user_id uuid, shift_id uuid references public.staff_shifts(id),
 employee_name text, details jsonb not null default '{}'::jsonb
);
create index parking_cash_movements_shift_idx on public.parking_cash_movements(shift_id,paid_at);
create index parking_cash_movements_date_idx on public.parking_cash_movements(paid_at);
alter table public.parking_cash_movements enable row level security;
create policy cash_read_staff on public.parking_cash_movements for select to authenticated using (private.is_staff() and (exists(select 1 from public.staff_profiles where user_id=auth.uid() and role in ('admin','manager') and active) or shift_id in(select id from public.staff_shifts where user_id=auth.uid())));
grant select on public.parking_cash_movements to authenticated;
revoke all on public.parking_cash_movements from anon;
create table private.parking_receipt_counters(year integer primary key, last_number bigint not null);
create table public.parking_simplified_invoices (
 id uuid primary key default gen_random_uuid(), number text not null unique,
 movement_id uuid not null unique references public.parking_cash_movements(id),
 issued_at timestamptz not null default clock_timestamp(), issued_by uuid not null,
 amount_before_vat numeric(12,2) not null, vat_rate numeric not null default 21,
 vat_eur numeric(12,2) not null, total_eur numeric(12,2) not null,
 full_invoice_id uuid references public.parking_invoices(id), snapshot jsonb not null
);
alter table public.parking_simplified_invoices enable row level security;
create policy receipt_read_staff on public.parking_simplified_invoices for select to authenticated using (private.is_staff());
grant select on public.parking_simplified_invoices to authenticated;
revoke all on public.parking_simplified_invoices from anon;
alter table public.rotation_sessions add column converted_reservation_id uuid references public.reservations(id), add column manual_final_amount_eur numeric(12,2), add column adjustment_note text;
alter table public.reservations add column print_payment_ticket boolean not null default false;
alter table public.parking_hotel_batches add column payment_method text not null default 'cash' check(payment_method in ('cash','card','bank'));

create function private.capture_parking_cash() returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_key text;v_category text;v_type text;v_entity uuid;v_ref text;v_plate text;v_desc text;v_amount numeric;v_method text;v_paid timestamptz;v_user uuid;v_shift uuid;v_name text;v_details jsonb:='{}';
begin
 if tg_table_name='rotation_sessions' then
  if new.status<>'departed' or new.paid_at is null then return new;end if;
  v_key:='rotation:'||new.id;v_category:='rotation';v_type:='rotation';v_entity:=new.id;v_ref:=new.ticket_number::text;v_plate:=new.plate;v_desc:='Estacionamiento por horas';v_amount:=new.amount_eur;v_method:=new.payment_method;v_paid:=new.paid_at;v_user:=new.exit_user_id;v_shift:=new.exit_shift_id;v_name:=new.exit_employee_name;
  v_details:=jsonb_build_object('entry_at',new.entry_at,'exit_at',new.exit_at,'tariff_amount_eur',new.tariff_amount_eur,'discount_bono_eur',new.discount_bono_eur);
 elsif tg_table_name='monthly_subscription_payments' then
  if tg_op='UPDATE' then return new;end if;
  v_key:='subscriber:'||new.id;v_category:='subscriber';v_type:='subscriber_payment';v_entity:=new.id;v_ref:=to_char(new.billing_month,'YYYY-MM');
  select greatest(0,price_eur-coalesce(discount_amount_eur,round(price_eur*coalesce(discount_pct,0)/100,2)))*(1+coalesce(vat_pct,21)/100),plate,customer_name into v_amount,v_plate,v_desc from public.monthly_subscribers where id=new.subscriber_id;
  v_desc:='Abono mensual · '||coalesce(v_desc,'');v_method:=new.payment_method;v_paid:=new.paid_at;v_user:=new.paid_by;
 elsif tg_table_name='parking_hotel_batches' then
  v_key:='hotel_batch:'||new.id;v_category:='stay';v_type:='hotel_batch';v_entity:=new.id;v_ref:=new.first_control::text;v_amount:=new.days*new.unit_price_eur;v_method:=new.payment_method;v_paid:=new.created_at;v_user:=new.created_by;
  select 'Compra de '||new.days||' bonos · '||name into v_desc from public.parking_hotels where id=new.hotel_id;
  if tg_op='UPDATE' then update public.parking_cash_movements set payment_method=new.payment_method where source_key=v_key;return new;end if;
 elsif tg_table_name='reservations' then
  if new.payment_status<>'paid' or coalesce(new.payment_method,'') not in ('cash','card','online') or new.amount_eur is null then return new;end if;
  if tg_op='UPDATE' and old.payment_status='paid' then return new;end if;
  v_key:='reservation:'||new.id;v_category:='stay';v_type:='reservation';v_entity:=new.id;v_ref:=new.reference;v_plate:=new.plate;v_desc:='Estancia por días';v_amount:=new.amount_eur;v_method:=new.payment_method;v_paid:=clock_timestamp();v_user:=coalesce(auth.uid(),new.created_by);
  v_details:=jsonb_build_object('entry_at',new.entry_at,'exit_at',new.exit_at);
 end if;
 if v_amount is null or v_method is null then return new;end if;
 if v_shift is null then select id into v_shift from public.staff_shifts where user_id=v_user and closed_at is null order by opened_at desc limit 1;end if;
 if v_name is null then select full_name into v_name from public.staff_profiles where user_id=v_user;end if;
 insert into public.parking_cash_movements(source_key,category,entity_type,entity_id,reference,plate,description,amount_eur,payment_method,paid_at,user_id,shift_id,employee_name,details)
 values(v_key,v_category,v_type,v_entity,coalesce(v_ref,''),v_plate,coalesce(v_desc,''),round(v_amount,2),v_method,v_paid,v_user,v_shift,v_name,v_details) on conflict(source_key) do nothing;
 return new;
end $$;
create trigger parking_cash_rotation after insert or update on public.rotation_sessions for each row execute function private.capture_parking_cash();
create trigger parking_cash_subscriber after insert on public.monthly_subscription_payments for each row execute function private.capture_parking_cash();
create trigger parking_cash_reservation after insert or update on public.reservations for each row execute function private.capture_parking_cash();
create trigger parking_cash_hotel after insert or update of payment_method on public.parking_hotel_batches for each row execute function private.capture_parking_cash();

create function public.parking_issue_simplified(p_entity_type text,p_entity_id uuid) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare m public.parking_cash_movements; r public.parking_simplified_invoices; v_year integer;v_num bigint;v_full uuid;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select * into m from public.parking_cash_movements where entity_type=p_entity_type and entity_id=p_entity_id order by paid_at desc limit 1 for update;
 if not found then raise exception 'Primero registra el cobro. Los bonos hotel canjeados no generan un segundo cobro';end if;
 select * into r from public.parking_simplified_invoices where movement_id=m.id;if found then return to_jsonb(r);end if;
 if m.amount_eur>3000 then raise exception 'Para este importe debes emitir una factura completa';end if;
 select id into v_full from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id order by issued_at desc limit 1;
 v_year:=extract(year from clock_timestamp() at time zone 'Europe/Madrid');
 insert into private.parking_receipt_counters(year,last_number) values(v_year,1) on conflict(year) do update set last_number=parking_receipt_counters.last_number+1 returning last_number into v_num;
 insert into public.parking_simplified_invoices(number,movement_id,issued_by,amount_before_vat,vat_eur,total_eur,full_invoice_id,snapshot)
 values('PLDFS-'||v_year||'-'||lpad(v_num::text,7,'0'),m.id,auth.uid(),round(m.amount_eur/1.21,2),m.amount_eur-round(m.amount_eur/1.21,2),m.amount_eur,v_full,to_jsonb(m)) returning * into r;
 return to_jsonb(r);
end $$;

-- One request includes payment, optional full invoice and optional simplified ticket.
create function public.parking_checkout_rotation(p_session_id uuid,p_final_amount_eur numeric,p_payment_method text,p_print_ticket boolean default false,p_adjustment_note text default null,p_invoice_customer jsonb default null) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;s public.rotation_sessions;t public.rotation_tariffs;calc jsonb;v_now timestamptz:=clock_timestamp();v_total numeric;receipt jsonb;invoice jsonb;
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
  update public.rotation_sessions set status='departed',exit_at=v_now,paid_at=v_now,raw_amount_eur=(calc->>'raw_amount_eur')::numeric,tariff_amount_eur=(calc->>'amount_eur')::numeric,discount_bono_eur=greatest(0,(calc->>'amount_eur')::numeric-v_total),amount_eur=v_total,manual_final_amount_eur=v_total,adjustment_note=nullif(btrim(p_adjustment_note),''),payment_method=p_payment_method,exit_user_id=(ctx->>'user_id')::uuid,exit_employee_name=ctx->>'employee_name',exit_shift_id=nullif(ctx->>'shift_id','')::uuid,exit_shift_code=nullif(ctx->>'shift_code','')::smallint,exit_shift_date=(ctx->>'shift_date')::date,updated_at=v_now where id=s.id returning * into s;
  if s.source_reservation_id is not null then update public.reservations set status='completed',rotation_pending=false,assigned_spot_id=null,updated_at=v_now where id=s.source_reservation_id;end if;
 end if;
 if p_invoice_customer is not null then invoice:=public.parking_issue_full_invoice('rotation',s.id,null,p_invoice_customer->>'name',p_invoice_customer->>'tax_id',p_invoice_customer->>'address');end if;
 if p_print_ticket then receipt:=public.parking_issue_simplified('rotation',s.id);end if;
 return jsonb_build_object('session',to_jsonb(s),'receipt',receipt,'invoice',invoice);
end $$;

create function public.parking_rotation_to_stay(p_session_id uuid,p_hotel_id uuid,p_vehicle_type_id uuid,p_spot_id uuid,p_days integer,p_model text) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;s public.rotation_sessions;v_res jsonb;
begin
 ctx:=public.rotation_operator_context();select * into s from public.rotation_sessions where id=p_session_id for update;
 if not found then raise exception 'Ticket inexistente';end if;
 if s.converted_reservation_id is not null then return jsonb_build_object('id',s.converted_reservation_id,'already_converted',true);end if;
 if s.status<>'inside' or s.billing_only then raise exception 'Este ticket no se puede convertir a estancia';end if;
 if nullif(btrim(p_model),'') is null then raise exception 'Indica marca y modelo';end if;
 if s.entry_at+make_interval(days=>p_days)<=clock_timestamp() then raise exception 'La estancia debe cubrir hasta después de la hora actual';end if;
 perform 1 from public.parking_spots where id=p_spot_id and vehicle_type_id=p_vehicle_type_id and active for update;if not found then raise exception 'Selecciona una plaza válida';end if;
 v_res:=public.create_hotel_paid_reservation(p_hotel_id,p_vehicle_type_id,s.entry_at,p_days,s.plate,p_model,s.client_text,null,null,'Convertida desde ticket de rotación '||s.ticket_number);
 perform public.backoffice_check_in((v_res->>'id')::uuid,p_spot_id,s.entry_at);
 update public.rotation_sessions set status='cancelled',converted_reservation_id=(v_res->>'id')::uuid,updated_at=clock_timestamp() where id=s.id;
 return v_res;
end $$;

create function public.parking_collect_stay(p_reservation_id uuid,p_payment_method text,p_print_ticket boolean default false) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;r public.reservations;receipt jsonb;
begin
 ctx:=public.rotation_operator_context();select * into r from public.reservations where id=p_reservation_id for update;if not found then raise exception 'Reserva inexistente';end if;
 if r.status in ('cancelled','expired') then raise exception 'Reserva cancelada o caducada';end if;
 if r.payment_method='hotel_voucher' then raise exception 'Esta estancia se paga con bonos ya comprados';end if;
 if r.payment_status<>'paid' then
  if p_payment_method not in ('cash','card') then raise exception 'Selecciona efectivo o tarjeta';end if;
  update public.reservations set payment_status='paid',payment_method=p_payment_method,updated_at=clock_timestamp() where id=r.id returning * into r;
 end if;
 if p_print_ticket then receipt:=public.parking_issue_simplified('reservation',r.id);end if;
 return jsonb_build_object('reservation',to_jsonb(r),'receipt',receipt);
end $$;
create function public.parking_check_in_and_collect(p_reservation_id uuid,p_spot_id uuid,p_actual_entry_at timestamptz) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;r public.reservations;v_session uuid;paid jsonb;
begin
 ctx:=public.rotation_operator_context();select * into r from public.reservations where id=p_reservation_id for update;
 if not found then raise exception 'Reserva inexistente';end if;
 perform 1 from public.parking_spots where id=p_spot_id for update;
 v_session:=public.backoffice_check_in(r.id,p_spot_id,p_actual_entry_at);
 if r.payment_method in ('cash','card') then paid:=public.parking_collect_stay(r.id,r.payment_method,r.print_payment_ticket);end if;
 return jsonb_build_object('session_id',v_session,'receipt',paid->'receipt');
end $$;

-- Full invoice customer data is supplied in one request; existing invoices remain immutable.
alter table public.parking_invoices drop constraint parking_invoices_entity_type_check;
alter table public.parking_invoices add constraint parking_invoices_entity_type_check check(entity_type in ('subscriber','reservation','rotation'));
create function public.parking_issue_full_invoice(p_entity_type text,p_entity_id uuid,p_billing_month date,p_customer_name text,p_customer_tax_id text,p_customer_address text) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v public.parking_invoices;s public.rotation_sessions;v_name text:=nullif(btrim(p_customer_name),'');v_tax text:=nullif(btrim(p_customer_tax_id),'');v_address text:=nullif(btrim(p_customer_address),'');
begin
 if auth.uid() is null or not exists(select 1 from public.staff_profiles where user_id=auth.uid() and active and role in ('admin','manager')) then raise exception 'Solo administradores y gerentes pueden emitir facturas';end if;
 if v_name is null or v_tax is null or v_address is null then raise exception 'Completa nombre, NIF/CIF y domicilio';end if;
 perform pg_advisory_xact_lock(hashtextextended('full-invoice:'||p_entity_type||':'||p_entity_id::text||':'||coalesce(p_billing_month::text,''),0));
 select * into v from public.parking_invoices where entity_type=p_entity_type and entity_id=p_entity_id and billing_month is not distinct from p_billing_month order by issued_at desc limit 1;
 if found then return to_jsonb(v);end if;
 if p_entity_type='rotation' then
  select * into s from public.rotation_sessions where id=p_entity_id and status='departed';if not found then raise exception 'Primero confirma el cobro de Rotación';end if;
  insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  values('rotation',s.id,v_name,v_tax,v_address,'Estacionamiento por horas',s.plate,round(s.amount_eur/1.21,2),0,s.amount_eur-round(s.amount_eur/1.21,2),s.amount_eur) returning * into v;
 else
  v:=public.issue_parking_invoice(p_entity_type,p_entity_id,p_billing_month,v_tax,v_address);
  update public.parking_invoices set customer_name=v_name where id=v.id returning * into v;
 end if;
 update public.parking_simplified_invoices set full_invoice_id=v.id where movement_id in(select id from public.parking_cash_movements where entity_type=p_entity_type and entity_id=p_entity_id);
 return to_jsonb(v);
end $$;

create function public.parking_cashbook(p_date date,p_shift_code integer,p_shift_id uuid default null) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_role text;v_start timestamptz;v_end timestamptz;v_rows jsonb;v_shift public.staff_shifts;
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 select role into v_role from public.staff_profiles where user_id=auth.uid() and active;
 if p_shift_code not in (1,2,3) or p_date is null then raise exception 'Turno no válido';end if;
 if p_shift_id is not null then
  select * into v_shift from public.staff_shifts where id=p_shift_id;
  if not found or (v_role not in ('admin','manager') and v_shift.user_id<>auth.uid()) then raise exception 'No autorizado para este turno';end if;
 elsif v_role not in ('admin','manager') then raise exception 'Selecciona tu turno';end if;
 v_start:=(case p_shift_code when 1 then p_date::timestamp-interval '2 hours' when 2 then p_date::timestamp+interval '6 hours' else p_date::timestamp+interval '14 hours' end) at time zone 'Europe/Madrid';
 v_end:=(case p_shift_code when 1 then p_date::timestamp+interval '6 hours' when 2 then p_date::timestamp+interval '14 hours' else p_date::timestamp+interval '22 hours' end) at time zone 'Europe/Madrid';
 select coalesce(jsonb_agg(to_jsonb(m) order by m.paid_at),'[]'::jsonb) into v_rows from public.parking_cash_movements m where (p_shift_id is not null and m.shift_id=p_shift_id) or (p_shift_id is null and m.paid_at>=v_start and m.paid_at<v_end);
 return jsonb_build_object('date',p_date,'shift_code',p_shift_code,'shift_id',p_shift_id,'from',v_start,'to',v_end,'rows',v_rows);
end $$;
create function public.parking_buy_hotel_batch(p_hotel_name text,p_days integer,p_payment_method text) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;r jsonb;
begin
 ctx:=public.rotation_operator_context();if p_payment_method not in ('cash','card','bank') then raise exception 'Forma de pago inválida';end if;
 r:=public.create_parking_hotel_batch_by_name(p_hotel_name,p_days);
 update public.parking_hotel_batches set payment_method=p_payment_method where id=(r->>'id')::uuid;return r;
end $$;

-- Only staff sessions may call these operations; the function body checks role/shift as well.
revoke all on function public.parking_issue_simplified(text,uuid),public.parking_checkout_rotation(uuid,numeric,text,boolean,text,jsonb),public.parking_rotation_to_stay(uuid,uuid,uuid,uuid,integer,text),public.parking_collect_stay(uuid,text,boolean),public.parking_check_in_and_collect(uuid,uuid,timestamptz),public.parking_issue_full_invoice(text,uuid,date,text,text,text),public.parking_cashbook(date,integer,uuid),public.parking_buy_hotel_batch(text,integer,text) from public,anon;
grant execute on function public.parking_issue_simplified(text,uuid),public.parking_checkout_rotation(uuid,numeric,text,boolean,text,jsonb),public.parking_rotation_to_stay(uuid,uuid,uuid,uuid,integer,text),public.parking_collect_stay(uuid,text,boolean),public.parking_check_in_and_collect(uuid,uuid,timestamptz),public.parking_issue_full_invoice(text,uuid,date,text,text,text),public.parking_cashbook(date,integer,uuid),public.parking_buy_hotel_batch(text,integer,text) to authenticated;
create function public.parking_lookup_rotation(p_plate text) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v jsonb;v_count integer;v_plate text:=regexp_replace(upper(coalesce(p_plate,'')),'[^A-Z0-9]','','g');
begin
 if auth.uid() is null or not private.is_staff() then raise exception 'No autorizado';end if;
 if length(v_plate)<3 then return null;end if;
 select count(*) into v_count from public.rotation_sessions where status='inside' and regexp_replace(upper(plate),'[^A-Z0-9]','','g')=v_plate;
 if v_count>1 then raise exception 'Hay varios tickets activos con esa matrícula; revisa los tickets antes de cobrar';end if;
 select to_jsonb(r)||jsonb_build_object('rotation_tariffs',to_jsonb(t)) into v from public.rotation_sessions r join public.rotation_tariffs t on t.id=r.tariff_id where r.status='inside' and regexp_replace(upper(r.plate),'[^A-Z0-9]','','g')=v_plate;
 return v;
end $$;
revoke all on function public.parking_lookup_rotation(text) from public,anon;
grant execute on function public.parking_lookup_rotation(text) to authenticated;
