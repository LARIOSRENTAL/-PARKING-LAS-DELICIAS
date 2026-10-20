const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{PGlite}=require('@electric-sql/pglite');
(async()=>{const db=new PGlite();await db.exec(`create schema auth;create schema private;create role anon;create role authenticated;
create function auth.uid()returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create table staff_profiles(user_id uuid primary key,full_name text,role text,active boolean default true);
create table staff_shifts(id uuid primary key default gen_random_uuid(),user_id uuid,shift_code integer,shift_date date,opened_at timestamptz default clock_timestamp(),closed_at timestamptz);
create table staff_activity_log(shift_id uuid,user_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
create table parking_cash_movements(id uuid default gen_random_uuid(),shift_id uuid,paid_at timestamptz default clock_timestamp(),amount_eur numeric,category text,payment_method text);
create function private.is_staff()returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.staff_profiles where user_id=auth.uid() and active)$$;
create function public.close_staff_shift()returns jsonb language plpgsql security definer set search_path='' as $$declare s uuid;begin select id into s from public.staff_shifts where user_id=auth.uid() and closed_at is null order by opened_at desc limit 1 for update;update public.staff_shifts set closed_at=clock_timestamp() where id=s;return jsonb_build_object('id',s);end$$;
grant usage on schema public,auth,private to authenticated;grant select on staff_profiles to authenticated;`);
for(const name of ['_cash_withdrawals.sql','_cashbook_reconciliation.sql']){const p=fs.readdirSync(path.join(__dirname,'../supabase/migrations')).find(f=>f.endsWith(name));await db.exec(fs.readFileSync(path.join(__dirname,'../supabase/migrations',p),'utf8'))}
const carry=fs.readdirSync(path.join(__dirname,'../supabase/migrations')).find(f=>f.endsWith('_cash_count_carry_forward.sql'));await db.exec(fs.readFileSync(path.join(__dirname,'../supabase/migrations',carry),'utf8'));
const q=(sql,args=[])=>db.query(sql,args),one=async(sql,args=[])=>Object.values((await q(sql,args)).rows[0])[0];
const user='11111111-1111-4111-8111-111111111111',other='22222222-2222-4222-8222-222222222222',manager='33333333-3333-4333-8333-333333333333',req='44444444-4444-4444-8444-444444444444';
await q("insert into staff_profiles values($1,'Empleado uno','employee',true),($2,'Empleado dos','employee',true),($3,'Gerente','manager',true)",[user,other,manager]);
const shift=await one('insert into staff_shifts(user_id,shift_code,shift_date)values($1,1,current_date)returning id',[user]);const second=await one('insert into staff_shifts(user_id,shift_code,shift_date)values($1,1,current_date)returning id',[other]);
await q("select set_config('request.jwt.claim.sub',$1,false)",[user]);
await q("insert into parking_cash_movements(shift_id,amount_eur,payment_method,category)values($1,100,'cash','rotation'),($1,50,'card','stay'),($1,80,'bank','subscriber'),($1,20,'online','stay')",[shift]);
const book=()=>one('select parking_cashbook(current_date,1,$1)',[shift]);const entry=(kind,amount,description='',id=req)=>one('select parking_register_cash_entry($1,$2,$3,$4,$5)',[shift,id,kind,amount,description]);
await assert.rejects(()=>entry('expense',10,''),/descripción/);await assert.rejects(()=>entry('voucher',0),/positivo/);await assert.rejects(()=>entry('voucher',1.001),/decimales/);await assert.rejects(()=>entry('voucher','NaN'),/no válido/);
await q('set role authenticated');const expense=await entry('expense',30,'Limpieza');assert.equal((await entry('expense',30,'Limpieza')).id,expense.id);await assert.rejects(()=>entry('expense',31,'Limpieza'),/otro movimiento/);const vale=await entry('voucher',20,'','55555555-5555-4555-8555-555555555555');assert.equal(vale.employee_name,'Empleado uno');
await one('select parking_register_cash_withdrawal(100,gen_random_uuid(),$1)',[shift]);
const counts={opening_balance:'1000.00',loose_coins:'50.00',wrapped_coins:'200.00',banknotes:'700.00',vouchers:'20.00'};
const save=v=>one('select parking_save_cash_count($1,$2)',[shift,JSON.stringify(v)]);
await assert.rejects(()=>save({...counts,banknotes:'-1'}),/no válido/);await assert.rejects(()=>one('select parking_save_cash_count($1,$2)',[second,JSON.stringify(counts)]),/turno abierto/);
let state=await save(counts);assert.equal(Number(state.expected_balance),970);assert.equal(Number(state.counted_total),970);assert.equal(Number(state.difference),0);assert.equal(Number(state.expense_total),30);assert.equal(Number(state.voucher_total),20);
let report=await book();assert.equal(report.employee_name,'Empleado uno');assert.equal(report.cash_state.entries.length,2);assert.equal(report.rows.length,4);assert.equal(report.shift_id,shift);
assert.equal((await one('select parking_cashbook_shifts(current_date,1)')).length,1);
await assert.rejects(()=>q('delete from parking_cash_counts'),/permission denied/);await assert.rejects(()=>q('update parking_cash_entries set amount_eur=1'),/permission denied/);
await save({...counts,banknotes:'690'});await assert.rejects(()=>one('select close_staff_shift()'),/no coincide/);await save(counts);
// Stale print cannot close a modified drawer; the retry must print refreshed figures.
await assert.rejects(()=>one('select parking_close_cash_shift($1,$2)',[shift,JSON.stringify(report)]),/ha cambiado/);report=await book();
await one('select parking_close_cash_shift($1,$2)',[shift,JSON.stringify(report)]);let archived=await book();assert(archived.closed_at);assert.equal(Number(archived.cash_state.difference),0);
await assert.rejects(()=>save(counts),/turno abierto/);assert.equal((await entry('expense',30,'Limpieza')).id,expense.id);await assert.rejects(()=>entry('voucher',1,'','66666666-6666-4666-8666-666666666666'),/turno abierto/);
await q('reset role');await assert.rejects(()=>q("insert into parking_cash_movements(shift_id,amount_eur,payment_method)values($1,1,'cash')",[shift]),/cerrado/);
const next=await one('insert into staff_shifts(user_id,shift_code,shift_date)values($1,2,current_date)returning id',[user]);const nextBook=await one('select parking_cashbook(current_date,2,$1)',[next]);assert.equal(Number(nextBook.cash_state.opening_balance),970);assert.equal(Number(nextBook.cash_state.vouchers),20);assert.equal(nextBook.cash_state.saved,false);assert.equal(Number(nextBook.cash_state.loose_coins),50);assert.equal(Number(nextBook.cash_state.wrapped_coins),200);assert.equal(Number(nextBook.cash_state.banknotes),700);assert.equal(Number(nextBook.cash_state.counted_total),970);assert.equal(nextBook.cash_state.inherited_from_shift,shift);

// Introduce the feature over existing persisted/closed records, not an empty schema.
await db.exec(fs.readFileSync(path.join(__dirname,'../supabase/migrations/20261016234206_persistent_cash_vouchers.sql'),'utf8'));
await db.exec(fs.readFileSync(path.join(__dirname,'../supabase/migrations/20261019131259_cash_count_denominations.sql'),'utf8'));


await q('update private.parking_legacy_vouchers set amount_eur=500');
const dir=path.join(__dirname,'../supabase/migrations'),f=fs.readdirSync(dir).find(x=>x.endsWith('_cancellable_legacy_vouchers.sql'));
await db.exec(fs.readFileSync(f?path.join(dir,f):path.join(__dirname,'../supabase/patches/cancellable_legacy_vouchers.sql'),'utf8'));
const archivedBefore=await book(),beforeTime=await one('select clock_timestamp()');
assert.equal(Number((await one('select parking_active_cash_vouchers()')).legacy_vouchers),500);
await q("select set_config('request.jwt.claim.sub',$1,false)",[other]);await q('set role authenticated');
const before=await one('select parking_cashbook(current_date,1,$1)',[second]);
const returnOld=(amount,id=req,shiftId=second)=>one('select parking_cancel_legacy_cash_vouchers($1,$2,$3)',[shiftId,id,amount]);
await assert.rejects(()=>returnOld(0),/positivo/);await assert.rejects(()=>returnOld(501),/supera/);await assert.rejects(()=>returnOld(10,req,next),/turno abierto/);
const result=await returnOld(200);assert.equal(Number(result.amount_eur),200);assert.equal((await returnOld(200)).request_id,result.request_id);await assert.rejects(()=>returnOld(201),/otra devolución/);
let afterOld=await one('select parking_cashbook(current_date,1,$1)',[second]);assert.equal(Number(afterOld.cash_state.counted_total),Number(before.cash_state.counted_total));assert.equal(Number(afterOld.cash_state.banknotes),Number(before.cash_state.banknotes)+200);assert.equal(Number(afterOld.cash_state.legacy_vouchers),300);assert.equal(afterOld.cash_state.voucher_returns.filter(r=>r.legacy).length,1);
assert.equal(Number((await one('select parking_active_cash_vouchers()')).legacy_vouchers),300);await assert.rejects(()=>returnOld(301,'77777777-7777-4777-8777-777777777777'),/supera/);
await q('reset role');await q("select set_config('request.jwt.claim.sub',$1,false)",[user]);await q('set role authenticated');
await returnOld(300,'88888888-8888-4888-8888-888888888888',next);const active=await one('select parking_active_cash_vouchers()');assert.equal(Number(active.legacy_vouchers),0);assert.equal(active.rows[0].id,vale.id);
await q('reset role');assert.equal(Number(await one('select private.parking_legacy_voucher_balance($1)',[beforeTime])),500);assert.deepEqual(await book(),archivedBefore);assert.equal(await one('select count(*)::int from parking_cash_movements'),4);assert.equal(await one('select count(*)::int from private.parking_legacy_voucher_returns'),2);
await q("select set_config('request.jwt.claim.sub','',false)");await assert.rejects(()=>returnOld(1),/No autorizado/);assert.equal(await one("select has_table_privilege('authenticated','private.parking_legacy_voucher_returns','select')"),false);
await db.close();console.log('Vales anteriores: visibles globalmente, devolución parcial/completa desde empleados distintos, idempotencia, exceso rechazado, caja total conservada, histórico y cobros intactos verificados.');})().catch(e=>{console.error(e);process.exitCode=1});
