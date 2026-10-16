-- Preparing vouchers is not a collection. Existing purchases retain their history.
alter table public.parking_hotel_batches
 add column payment_status text not null default 'paid',
 add column paid_at timestamptz,
 add column paid_by uuid,
 add column paid_shift_id uuid references public.staff_shifts(id);
update public.parking_hotel_batches b set
 paid_at=coalesce(m.paid_at,b.created_at),paid_by=coalesce(m.user_id,b.created_by),paid_shift_id=m.shift_id
from public.parking_cash_movements m where m.entity_type='hotel_batch' and m.entity_id=b.id;
update public.parking_hotel_batches set paid_at=created_at,paid_by=created_by where paid_at is null;
alter table public.parking_hotel_batches alter column payment_status set default 'pending';
alter table public.parking_hotel_batches alter column payment_method set default 'pending';
alter table public.parking_hotel_batches drop constraint parking_hotel_batches_payment_method_check;
alter table public.parking_hotel_batches add constraint parking_hotel_batches_payment_method_check check(payment_method in('pending','cash','card','bank'));
alter table public.parking_hotel_batches add constraint parking_hotel_batches_payment_state_check check(
 (payment_status='pending' and payment_method='pending' and paid_at is null and paid_by is null and paid_shift_id is null)
 or (payment_status='paid' and payment_method in('cash','card','bank') and paid_at is not null));
create index parking_hotel_batches_pending_idx on public.parking_hotel_batches(created_at) where payment_status='pending' and not is_void;

-- Preserve the other categories' capture logic; replace only the hotel branch.
do $migration$
declare d text;a integer;b integer;
begin
 d:=pg_get_functiondef('private.capture_parking_cash()'::regprocedure);
 a:=strpos(d,' elsif tg_table_name=''parking_hotel_batches'' then');
 b:=strpos(d,' elsif tg_table_name=''reservations'' then');
 if a=0 or b<=a then raise exception 'Unexpected cash capture definition';end if;
 d:=substr(d,1,a-1)||$branch$
 elsif tg_table_name='parking_hotel_batches' then
  if new.is_test or new.is_void or new.payment_status<>'paid' then return new;end if;
  v_key:='hotel_batch:'||new.id;v_category:='stay';v_type:='hotel_batch';v_entity:=new.id;
  v_ref:=coalesce(new.registration_first,new.first_control::text);v_amount:=new.days*new.unit_price_eur;
  v_method:=new.payment_method;v_paid:=new.paid_at;v_user:=new.paid_by;v_shift:=new.paid_shift_id;
  select 'Compra de '||new.days||' bonos · '||name into v_desc from public.parking_hotels where id=new.hotel_id;
  v_details:=jsonb_build_object('days',new.days,'unit_price_eur',new.unit_price_eur,'prepared_at',new.created_at,'registration_first',new.registration_first,'registration_last',new.registration_last);
$branch$||substr(d,b);
 execute d;
end $migration$;
drop trigger parking_cash_hotel on public.parking_hotel_batches;
create trigger parking_cash_hotel after insert or update of payment_status,payment_method on public.parking_hotel_batches
for each row execute function private.capture_parking_cash();

-- Paid purchases cannot be silently reassigned to another shift or repriced.
create function private.parking_guard_hotel_payment() returns trigger language plpgsql set search_path='' as $$
begin
 if old.payment_status='paid' and (new.payment_status,new.payment_method,new.paid_at,new.paid_by,new.paid_shift_id,new.days,new.unit_price_eur,new.hotel_id)
 is distinct from (old.payment_status,old.payment_method,old.paid_at,old.paid_by,old.paid_shift_id,old.days,old.unit_price_eur,old.hotel_id)
 then raise exception 'El cobro de estos bonos ya está registrado y no se puede modificar';end if;
 return new;
end $$;
revoke all on function private.parking_guard_hotel_payment() from public,anon,authenticated;
create trigger parking_guard_hotel_payment before update on public.parking_hotel_batches for each row execute function private.parking_guard_hotel_payment();
revoke insert,update,delete on public.parking_hotel_batches from authenticated;

alter table public.parking_invoices drop constraint parking_invoices_entity_type_check;
alter table public.parking_invoices add constraint parking_invoices_entity_type_check check(entity_type in('subscriber','reservation','rotation','hotel_batch'));

-- Extend the existing invoice flow without changing its authorization or numbering.
do $migration$
declare d text;needle text:=' if p_entity_type=''rotation'' then';
begin
 d:=pg_get_functiondef('public.parking_issue_full_invoice(text,uuid,date,text,text,text)'::regprocedure);
 if strpos(d,needle)=0 then raise exception 'Unexpected invoice function definition';end if;
 d:=replace(d,needle,$branch$
 if p_entity_type='hotel_batch' then
  insert into public.parking_invoices(entity_type,entity_id,customer_name,customer_tax_id,customer_address,vehicle,plate,amount_before_vat,discount_eur,vat_eur,total_eur)
  select 'hotel_batch',b.id,v_name,v_tax,v_address,b.days||' bonos hotel de 1 día · '||h.name,null,
   round(b.days*b.unit_price_eur/1.21,2),0,b.days*b.unit_price_eur-round(b.days*b.unit_price_eur/1.21,2),b.days*b.unit_price_eur
  from public.parking_hotel_batches b join public.parking_hotels h on h.id=b.hotel_id
  where b.id=p_entity_id and b.payment_status='paid' and not b.is_void and not b.is_test returning * into v;
  if not found then raise exception 'Primero registra el cobro de los bonos hotel';end if;
 elsif p_entity_type='rotation' then
$branch$);
 execute d;
end $migration$;

create function public.parking_collect_hotel_batch(p_batch_id uuid,p_payment_method text,p_print_ticket boolean default false,p_invoice_customer jsonb default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;b public.parking_hotel_batches;receipt jsonb;invoice jsonb;already_paid boolean;
begin
 ctx:=public.rotation_operator_context();
 if p_payment_method is null or p_payment_method not in('cash','card','bank') then raise exception 'Selecciona efectivo, tarjeta o banco';end if;
 select * into b from public.parking_hotel_batches where id=p_batch_id for update;
 if not found or b.is_void or b.is_test then raise exception 'Compra no válida para cobrar';end if;
 already_paid:=b.payment_status='paid';
 if not already_paid then
  update public.parking_hotel_batches set payment_status='paid',payment_method=p_payment_method,
   paid_at=clock_timestamp(),paid_by=(ctx->>'user_id')::uuid,paid_shift_id=nullif(ctx->>'shift_id','')::uuid
  where id=b.id returning * into b;
 end if;
 if p_invoice_customer is not null then
  invoice:=public.parking_issue_full_invoice('hotel_batch',b.id,null,p_invoice_customer->>'name',p_invoice_customer->>'tax_id',p_invoice_customer->>'address');
 else
  select to_jsonb(i) into invoice from public.parking_invoices i where entity_type='hotel_batch' and entity_id=b.id order by issued_at desc limit 1;
 end if;
 if p_print_ticket and invoice is null then receipt:=public.parking_issue_simplified('hotel_batch',b.id);end if;
 return jsonb_build_object('batch',to_jsonb(b),'receipt',receipt,'invoice',invoice,'already_paid',already_paid);
end $$;
revoke all on function public.parking_collect_hotel_batch(uuid,text,boolean,jsonb) from public,anon;
grant execute on function public.parking_collect_hotel_batch(uuid,text,boolean,jsonb) to authenticated;

create or replace function public.parking_buy_hotel_batch(p_hotel_name text,p_days integer,p_payment_method text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare ctx jsonb;r jsonb;paid jsonb;
begin
 ctx:=public.rotation_operator_context();
 if p_payment_method is null or p_payment_method not in('pending','cash','card','bank') then raise exception 'Forma de pago inválida';end if;
 r:=public.create_parking_hotel_batch_by_name(p_hotel_name,p_days);
 if p_payment_method<>'pending' then paid:=public.parking_collect_hotel_batch((r->>'id')::uuid,p_payment_method,false,null);end if;
 return r||jsonb_build_object('payment_status',case when p_payment_method='pending' then 'pending' else 'paid' end,'payment_method',p_payment_method);
end $$;
revoke all on function public.parking_buy_hotel_batch(text,integer,text) from public,anon;
grant execute on function public.parking_buy_hotel_batch(text,integer,text) to authenticated;
