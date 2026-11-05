const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const src=n=>fs.readFileSync(path.join(__dirname,'../backoffice',n),'utf8');
(async()=>{
 const dom=new JSDOM('<style>.hidden{display:none}</style><main id="modal"></main>',{runScripts:'outside-only'}),w=dom.window,d=w.document,el=id=>d.getElementById(id);const calls=[];
 Object.assign(w,{opsEl:el,money:n=>n+' €',fmt:x=>x,docs:[{entity_type:'reservation',entity_id:'initial',amount_eur:120,paid_at:'2026-11-01'},{entity_type:'stay_change',entity_id:'extension',amount_eur:30,paid_at:'2026-11-05'}],
 modifyReservation:async id=>{w.stayEditState={reservation:{id,customer_name:'Cliente'},busy:false};el('modal').innerHTML='<div class="stayEditFields"><div id="stayEditDocuments"></div><button id="stayEditSave">Guardar</button></div>'},
 db:{rpc:async(name,args)=>{calls.push({name,args});if(name==='parking_stay_payment_documents')return{data:w.docs};await new Promise(r=>setTimeout(r,10));const row=w.docs.find(r=>r.entity_id===args.p_entity_id);if(args.p_kind==='invoice')row.invoice={number:'OF-1'};return{data:{...row,number:'OF-1'}}}},
 printParkingThermal:async()=>{},buildSimplifiedTicket:x=>x,showParkingInvoicePreview:x=>w.preview=x});
 w.eval(src('stay-payment-documents.js'));await w.modifyReservation('stay-1');
 assert.equal(el('stayPaymentDocumentRows').querySelectorAll('.eventRow').length,2);assert.match(el('stayPaymentDocumentRows').textContent,/Estancia inicial · 120/);assert.match(el('stayPaymentDocumentRows').textContent,/Ampliación 1 · 30/);
 await w.emitStayPaymentDocument(w.stayEditState.paymentDocuments[0],'invoice');assert(el('stayPaymentCustomer').open);assert.equal(calls.filter(c=>c.name==='parking_stay_payment_document').length,0);
 el('stayDocumentTax').value='B12345678';el('stayDocumentAddress').value='Calle 1';await w.emitStayPaymentDocument(w.stayEditState.paymentDocuments[0],'invoice');assert.equal(w.preview.entity_id,'initial');
 await Promise.all([w.emitStayPaymentDocument(w.stayEditState.paymentDocuments[1],'ticket'),w.emitStayPaymentDocument(w.stayEditState.paymentDocuments[1],'ticket')]);
 assert.deepEqual(calls.filter(x=>x.name==='parking_stay_payment_document').map(x=>[x.args.p_entity_type,x.args.p_entity_id,x.args.p_kind]),[['reservation','initial','invoice'],['stay_change','extension','ticket']]);assert.equal(el('stayEditSave').disabled,false);
 // Real reservation collection fields, switches and request payload.
 const commerce=src('commerce-sales-and-unpaid-stays.js'),open=commerce.slice(commerce.indexOf('openStayCollection=function(id){'),commerce.indexOf('function combinedStayDateError')),update=commerce.slice(commerce.indexOf('function combinedStayDateError'),commerce.indexOf('/* Focus only'));
 Object.assign(w,{reservations:[{id:'stay-2',reference:'E-302',duration_days:1,entry_at:'2026-11-05T10:00:00Z',exit_at:'2026-11-06T10:00:00Z',vehicle_type_id:'type',payment_status:'unpaid'}],currentProfile:{role:'employee'},esc:x=>String(x??''),localInput:x=>x.toISOString().slice(0,16),parkingProductionDateReached:()=>true,parseHotelVoucherCodes:x=>[x],refreshAll:async()=>{},closeParkingOpsModal:()=>{},alert:m=>{throw Error(m)},insideSessions:[],spots:[],printEntryVoucher:async()=>{}});
 el('modal').innerHTML='<select id="spot-stay-2"><option value="spot">A-1</option></select><div id="collection"></div>';
 w.opsModal=(title,body,actions)=>el('collection').innerHTML=body+actions+'<p id="parkingOpsMessage"></p>';
 w.db={rpc:async(name,args)=>{calls.push({name,args});return{data:name==='parking_stay_price'?20:{}}}};
 w.eval(open+update);w.openStayCollection('stay-2');await w.updateCombinedStayPayment();el('stayCollectMethod').value='hotel_voucher_old';await w.updateCombinedStayPayment();
 assert(!el('stayCollectHotelWrap').classList.contains('hidden'));d.querySelector('.stayVoucherNumber').value='ANT-1';await w.confirmCombinedStayPayment();assert.match(el('parkingOpsMessage').textContent,/nombre del hotel/);
 el('stayCollectHotelName').value='Hotel Pinar';el('stayCollectMethod').value='cash';await w.updateCombinedStayPayment();assert(el('stayCollectHotelWrap').classList.contains('hidden'));el('stayCollectMethod').value='hotel_voucher_old';await w.updateCombinedStayPayment();assert.equal(el('stayCollectHotelName').value,'Hotel Pinar');d.querySelector('.stayVoucherNumber').value='ANT-1';await w.confirmCombinedStayPayment();
 const paid=calls.find(x=>x.name==='parking_pay_enter_stay_named_hotel');assert.equal(paid.args.p_hotel_name,'Hotel Pinar');assert.equal(paid.args.p_codes[0],'ANT-1');assert.equal(paid.args.p_method,'hotel_voucher_old');
 // Hotel vouchers keep the E-N stay control and list redeemed codes separately.
 w.parkingHotels=[];w.buildVoucherHtml=()=>'<table><tr><th>Nº Control</th><td>E-299</td></tr><tr><th>Tipo vehículo</th><td>TURISMO</td></tr></table><div class="control-number">E-299</div>';w.printEntryVoucher=()=>{};
 w.eval(src('hotel-voucher-print-format.js').split('/* Backoffice visual')[0]);const voucher=w.buildVoucherHtml({payment_method:'hotel_voucher_old',_hotelPrintName:'Hotel Pinar',_hotelPrintCodes:['ANT-1','ANT-2']},'',null,null);assert.equal((voucher.match(/E-299/g)||[]).length,2);assert.match(voucher,/<th>Bonos hotel<\/th><td>ANT-1, ANT-2/);assert.match(voucher,/HOTEL PINAR/);
 console.log('PASS: initial/extension document buttons, invoice details and double-click guard; hotel-name field preserved and sent; E-control retained alongside voucher numbers.');dom.window.close();
})().catch(e=>{console.error(e);process.exitCode=1});
