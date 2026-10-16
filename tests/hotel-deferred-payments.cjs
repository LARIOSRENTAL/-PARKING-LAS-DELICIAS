module.exports=async({db,q,scalar,root,assert,user,other})=>{
 const fs=require('fs'),path=require('path');
 await db.exec(fs.readFileSync(path.join(root,'supabase/migrations/20261015220850_hotel_deferred_payments.sql'),'utf8'));
 const count=()=>scalar("select count(*)::int from parking_cash_movements");
 const initial=await count(),pending=await scalar("select parking_buy_hotel_batch('HOTEL PENDIENTE PRUEBA',10,'pending')");
 assert.equal(pending.payment_status,'pending');assert.equal(await count(),initial);
 await q("update parking_hotel_batches set created_at=clock_timestamp()-interval '3 days' where id=$1",[pending.id]);
 const before=await scalar('select to_jsonb(b) from parking_hotel_batches b where id=$1',[pending.id]);assert.equal(before.paid_at,null);assert.equal(before.paid_by,null);
 const print=await scalar('select parking_hotel_batch_vouchers($1)',[pending.id]);assert.equal(print.vouchers.length,10);assert.equal(await count(),initial);
 // Pay in another employee's real shift, not the preparation shift.
 const shift=await scalar('insert into staff_shifts(user_id,shift_code,shift_date)values($1,3,current_date)returning id',[other]);
 await q("select set_config('request.jwt.claim.sub',$1,false)",[other]);
 await assert.rejects(()=>scalar("select parking_collect_hotel_batch($1,'card',false,$2)",[pending.id,{name:'Prueba',tax_id:'B12345678',address:'Calle prueba'}]),/administradores/);
 assert.equal(await scalar('select payment_status from parking_hotel_batches where id=$1',[pending.id]),'pending');assert.equal(await count(),initial);
 const paid=await scalar("select parking_collect_hotel_batch($1,'card',true,null)",[pending.id]);assert.equal(paid.batch.paid_by,other);assert.equal(paid.batch.paid_shift_id,shift);assert.equal(paid.receipt.total_eur,130);assert.equal(await count(),initial+1);
 const movement=await scalar("select to_jsonb(m)from parking_cash_movements m where entity_type='hotel_batch'and entity_id=$1",[pending.id]);assert.equal(movement.shift_id,shift);assert.equal(movement.user_id,other);assert.equal(movement.payment_method,'card');assert.equal(movement.paid_at,paid.batch.paid_at);assert(new Date(movement.paid_at)-new Date(before.created_at)>2*86400000);
 const retry=await scalar("select parking_collect_hotel_batch($1,'cash',true,null)",[pending.id]);assert.equal(retry.already_paid,true);assert.equal(retry.receipt.id,paid.receipt.id);assert.equal(retry.batch.payment_method,'card');assert.equal(await count(),initial+1);
 await assert.rejects(()=>q("update parking_hotel_batches set payment_method='cash'where id=$1",[pending.id]),/no se puede modificar/);
 const book=await scalar('select parking_cashbook(current_date,3,$1)',[shift]);assert(book.rows.some(x=>x.entity_id===pending.id));
 await q("update staff_shifts set closed_at=clock_timestamp()where id=$1",[shift]);await q("select set_config('request.jwt.claim.sub',$1,false)",[user]);
 const invoiceBatch=await scalar("select parking_buy_hotel_batch('HOTEL FACTURA PRUEBA',200,'pending')"),invoice=await scalar("select parking_collect_hotel_batch($1,'bank',true,$2)",[invoiceBatch.id,{name:'Empresa de prueba',tax_id:'B23456789',address:'Calle prueba 1, 29008 Málaga'}]);
 assert.equal(invoice.receipt,null);assert.equal(invoice.invoice.entity_type,'hotel_batch');assert.equal(invoice.invoice.total_eur,2400);assert.equal(invoice.invoice.customer_name,'Empresa de prueba');assert.equal(invoice.batch.payment_method,'bank');
 const again=await scalar("select parking_collect_hotel_batch($1,'bank',true,$2)",[invoiceBatch.id,{name:'Otra empresa',tax_id:'B23456789',address:'Otra calle'}]);assert.equal(again.invoice.id,invoice.invoice.id);assert.equal(again.invoice.customer_name,'Empresa de prueba');assert.equal(await scalar('select count(*)::int from parking_cash_movements where entity_id=$1',[invoiceBatch.id]),1);
 const immediate=await scalar("select parking_buy_hotel_batch('HOTEL PAGO INMEDIATO',10,'cash')");assert.equal(immediate.payment_status,'paid');assert.equal(await scalar('select count(*)::int from parking_cash_movements where entity_id=$1',[immediate.id]),1);
 const large=await scalar("select parking_buy_hotel_batch('HOTEL FACTURA GRANDE',300,'pending')");await assert.rejects(()=>scalar("select parking_collect_hotel_batch($1,'card',true,null)",[large.id]),/factura completa/);assert.equal(await scalar('select payment_status from parking_hotel_batches where id=$1',[large.id]),'pending');assert.equal(await scalar('select count(*)::int from parking_cash_movements where entity_id=$1',[large.id]),0);
 await assert.rejects(()=>scalar("select parking_collect_hotel_batch($1,'pending',false,null)",[large.id]),/efectivo/);
 const codesBefore=await scalar('select count(*)::int from parking_hotel_vouchers where batch_id=$1',[invoiceBatch.id]);await scalar('select parking_hotel_batch_vouchers($1)',[invoiceBatch.id]);assert.equal(await scalar('select count(*)::int from parking_hotel_vouchers where batch_id=$1',[invoiceBatch.id]),codesBefore);
 console.log('Hotel pendiente: preparación sin caja; pago en turno real; reintentos sin duplicados; ticket tarjeta; factura completa sin simplificada; inmutabilidad y permisos verificados.');
};
