const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),{PGlite}=require('@electric-sql/pglite');
(async()=>{const db=new PGlite();await db.exec(`create schema auth;create schema private;create role anon;create role authenticated;
create function auth.uid() returns uuid language sql as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
create table staff_profiles(user_id uuid,active boolean,role text);create function private.is_staff()returns boolean language sql set search_path=public as $$select exists(select 1 from staff_profiles where user_id=auth.uid() and active)$$;
create table rotation_tariffs(id uuid primary key,name text,code text);
create table rotation_sessions(id uuid primary key,ticket_number int,plate text,client_text text,leaves_keys boolean,key_number text,tariff_id uuid,entry_at timestamptz,exit_at timestamptz,status text,amount_eur numeric,payment_method text,entry_shift_id uuid,exit_shift_id uuid,entry_user_id uuid,exit_user_id uuid);
create table parking_cash_movements(id uuid primary key,entity_type text,entity_id uuid,amount_eur numeric,paid_at timestamptz,user_id uuid,shift_id uuid);
create table parking_invoices(id uuid primary key default gen_random_uuid(),entity_type text,entity_id uuid,billing_month date,is_production boolean default true,issued_at timestamptz default now(),display_number text default 'OF-TEST',number text,customer_name text,customer_tax_id text,customer_address text,vehicle text,plate text,amount_before_vat numeric,discount_eur numeric,vat_eur numeric,total_eur numeric);
create table parking_simplified_invoices(id uuid primary key default gen_random_uuid(),movement_id uuid,series text,customer_name text,customer_tax_id text,customer_address text,full_invoice_id uuid,issued_at timestamptz default now(),total_eur numeric);
create table parking_commerce_bonus_sales(id uuid,user_id uuid,shift_id uuid);
create function public.rotation_operator_context()returns jsonb language sql as $$select '{}'::jsonb$$;
create function private.parking_is_production(text,uuid,date)returns boolean language sql as $$select true$$;
create function private.parking_receipt_json(uuid)returns jsonb language sql set search_path=public as $$select to_jsonb(s)||jsonb_build_object('doc_kind','simplified')from parking_simplified_invoices s where id=$1$$;
create function private.parking_entity_movement(text,uuid,date)returns parking_cash_movements language sql set search_path=public as $$select m.*from parking_cash_movements m where entity_type=$1 and entity_id=$2 limit 1$$;
create function private.parking_create_production_receipt(uuid,boolean)returns jsonb language plpgsql set search_path=public as $$declare s parking_simplified_invoices;begin insert into parking_simplified_invoices(movement_id,series,total_eur)select id,'OTH',amount_eur from parking_cash_movements where id=$1 returning *into s;return private.parking_receipt_json(s.id);end$$;
`);await db.exec(fs.readFileSync(path.join(__dirname,'../database/rotation_current_month_documents.sql'),'utf8'));
const user='10000000-0000-0000-0000-000000000001',other='10000000-0000-0000-0000-000000000002',id='20000000-0000-0000-0000-000000000001',old='20000000-0000-0000-0000-000000000002',card='20000000-0000-0000-0000-000000000003';
await db.exec(`insert into staff_profiles values('${user}',true,'employee'),('${other}',true,'employee');select set_config('test.uid','${user}',false);
insert into rotation_sessions(id,ticket_number,entry_at,exit_at,status,amount_eur,plate,exit_user_id) values
('${id}',1,clock_timestamp()-interval '1 hour',clock_timestamp(),'departed',10,'TEST','${other}'),
('${old}',2,date_trunc('month',clock_timestamp())-interval '3 days',date_trunc('month',clock_timestamp())-interval '2 days','departed',20,'OLD','${user}'),
('${card}',3,clock_timestamp()-interval '1 hour',clock_timestamp(),'departed',30,'CARD','${other}');
insert into parking_cash_movements select gen_random_uuid(),'rotation',id,amount_eur,exit_at,exit_user_id,null from rotation_sessions;
insert into parking_simplified_invoices(movement_id,series,total_eur)select id,'OTH',amount_eur from parking_cash_movements where entity_id='${card}';`);
const scalar=async(sql,args=[])=>(await db.query(sql,args)).rows[0].v;
const dates=await scalar("select jsonb_build_object('first',date_trunc('month',clock_timestamp() at time zone 'Europe/Madrid')::date,'last',(date_trunc('month',clock_timestamp() at time zone 'Europe/Madrid')+interval '1 month'-interval '1 day')::date,'old',(date_trunc('month',clock_timestamp() at time zone 'Europe/Madrid')-interval '3 days')::date)v");
const rows=await scalar('select parking_rotation_ticket_search($1,$2)v',[dates.first,dates.last]);assert(rows.some(x=>x.id===id));assert(!rows.some(x=>x.id===old));
await assert.rejects(scalar('select parking_rotation_ticket_search($1,$2)v',[dates.old,dates.last]),/mes vigente/);
await assert.rejects(scalar("select parking_issue_simplified('rotation',$1)v",[old]),/mes vigente/);
const customer={name:'Cliente',tax_id:'B12345678',address:'Calle 1'};
const issue=(sid,c=null)=>scalar('select parking_rotation_invoice_document($1,$2)v',[sid,c]);
assert.equal((await issue(id)).needs_customer,true);const invoice=await issue(id,customer);assert.equal(invoice.total_eur,10);assert.equal((await issue(id)).id,invoice.id);
const receipt=await issue(card,customer);assert.equal(receipt.total_eur,30);assert.equal(receipt.doc_kind,'simplified');assert.equal((await issue(card)).id,receipt.id);
await assert.rejects(issue(old,customer),/mes vigente/);await assert.rejects(scalar("select parking_issue_full_invoice('rotation',$1,null,'Cliente','NIF','Calle')v",[old]),/mes vigente/);
assert.equal(await scalar('select count(*)::int v from parking_cash_movements'),3);assert.equal(await scalar('select count(*)::int v from parking_invoices'),1);
await db.exec("update staff_profiles set role='admin' where user_id=auth.uid()");assert.equal((await issue(old,customer)).total_eur,20);assert((await scalar('select parking_rotation_ticket_search($1,$2)v',[dates.old,dates.last])).some(x=>x.id===old));
await db.exec("select set_config('test.uid','',false)");await assert.rejects(issue(id),/No autorizado/);assert.equal(await scalar("select has_function_privilege('anon','parking_rotation_ticket_search(date,date)','execute')v"),false);
console.log('PASS: employees search all shifts only in current Madrid month; full/card invoices reused; old-month invoice and ticket RPCs denied; admin history preserved; no new payments.');await db.close();})().catch(e=>{console.error(e);process.exitCode=1});
