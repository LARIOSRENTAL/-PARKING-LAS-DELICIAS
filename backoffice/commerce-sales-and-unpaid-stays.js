/* Ventas de bonos comercio y reservas con cobro separado. */
let pendingStayCreateId=null,commerceSaleBusy=false;
function openCommerceSale(){
 opsModal('Venta bonos comercio','<div class="grid2"><div class="field"><label>Cantidad de bonos</label><input id="commerceSaleQty" type="number" min="1" step="1" value="1"></div><div class="field"><label>Precio total (€)</label><input id="commerceSalePrice" type="number" min="0.01" step="0.01"></div></div><div class="field"><label>Forma de pago</label><select id="commerceSaleMethod" onchange="commerceSalePaymentChanged()"><option value="cash">Efectivo</option><option value="card">Tarjeta</option></select></div><label id="commerceSaleTicketWrap" class="hidden"><input id="commerceSaleTicket" type="checkbox" style="width:auto"> Imprimir ticket</label>','<button class="btn green" id="commerceSaleConfirm" onclick="sellCommerceBonuses()">Confirmar venta</button>');
}
function commerceSalePaymentChanged(){opsEl('commerceSaleTicketWrap').classList.toggle('hidden',opsEl('commerceSaleMethod').value!=='card');if(opsEl('commerceSaleMethod').value!=='card')opsEl('commerceSaleTicket').checked=false}
async function sellCommerceBonuses(){
 if(commerceSaleBusy)return;
 const qty=Number(opsEl('commerceSaleQty').value),price=Number(opsEl('commerceSalePrice').value),method=opsEl('commerceSaleMethod').value,print=opsEl('commerceSaleTicket').checked;
 if(!Number.isInteger(qty)||qty<1||!Number.isFinite(price)||price<=0)return opsEl('parkingOpsMessage').textContent='Revisa cantidad y precio.';
 commerceSaleBusy=true;opsEl('commerceSaleConfirm').disabled=true;
 try{
 const r=await db.rpc('parking_sell_commerce_bonuses',{p_quantity:qty,p_amount_eur:price,p_payment_method:method});
 if(r.error)throw r.error;closeParkingOpsModal();
 if(print){const html='<html><body style="font:16px Arial;width:75mm;text-align:center"><h2>LAS DELICIAS</h2><h3>VENTA BONOS COMERCIO</h3><p>CANTIDAD: '+qty+'</p><p>TOTAL: '+money(price)+'</p><p>TARJETA</p><p>'+new Date().toLocaleString('es-ES')+'</p></body></html>';try{await printParkingThermal(html)}catch(e){alert('Venta guardada. Error de impresión: '+e.message)}}
 }catch(e){opsEl('parkingOpsMessage').textContent=e.message}finally{commerceSaleBusy=false;const b=opsEl('commerceSaleConfirm');if(b)b.disabled=false}
}
createManualReservation=async function(){
 if(manualStayCreateBusy)return;
 const b=document.querySelector('#manual button[onclick="createManualReservation()"]'),msg=opsEl('manualMsg');
 const plate=opsEl('mPlate').value.trim(),model=opsEl('mModel').value.trim();
 if(plate.length<3||model.length<2)return msg.textContent='Completa matrícula y marca/modelo.';
 manualStayCreateBusy=true;if(b)b.disabled=true;
 try{
 pendingStayCreateId=pendingStayCreateId||crypto.randomUUID();
 const r=await db.rpc('parking_create_unpaid_stay',{p_request_id:pendingStayCreateId,p_data:{plate,model,vehicle_type_id:opsEl('mType').value,entry_at:new Date(opsEl('mEntry').value).toISOString(),days:Number(opsEl('mDays').value),name:opsEl('mName').value,phone:opsEl('mPhone').value,email:opsEl('mEmail').value,notes:opsEl('mNotes').value}});
 if(r.error)throw r.error;pendingStayCreateId=null;
 msg.textContent='Reserva '+r.data.reference+' creada, pendiente de cobro.';
 for(const id of ['mName','mPhone','mEmail','mPlate','mModel','mNotes'])opsEl(id).value='';
 await loadReservations();currentStayTab='reservations';document.querySelectorAll('#staysNav button').forEach(x=>x.classList.toggle('active',x.dataset.tab==='reservations'));document.querySelectorAll('.section').forEach(x=>x.classList.toggle('active',x.id==='reservations'));
 }catch(e){msg.textContent=e.message}finally{manualStayCreateBusy=false;if(b)b.disabled=false}
};
const previousReservationTable=reservationTable;
reservationTable=function(rows,actions=false){
 let html=previousReservationTable(rows,actions);
 if(actions)for(const r of rows){if(r.payment_status!=='paid'&&r.payment_method!=='hotel_voucher')html=html.replace('onclick="openStayCollection(\''+r.id+'\')">Ticket de cobro','onclick="openStayCollection(\''+r.id+'\')">Cobrar reserva')}
 return html;
};
openStayCollection=function(id){
 const r=reservations.find(x=>x.id===id);if(!r)return;
 const paid=r.payment_status==='paid';
 opsModal(paid?'Reimprimir ticket':'Cobrar reserva · '+r.reference,'<p><b>'+esc(r.plate)+' · '+money(r.amount_eur)+'</b></p><div class="field"><label>Forma de pago</label><select id="stayCollectMethod" '+(paid?'disabled':'')+' onchange="stayCollectionMethodChanged()"><option value="cash">Efectivo</option><option value="card">Tarjeta</option><option value="hotel_voucher">Bonos hotel</option></select></div><div class="field hidden" id="stayCollectVouchers"><label>Códigos de bonos hotel (uno por línea o escanear)</label><textarea id="stayCollectCodes" rows="4"></textarea></div><label><input type="checkbox" style="width:auto" id="stayCollectPrint"> Imprimir ticket</label>','<button class="btn green" id="stayCollectConfirm" onclick="confirmStayPaymentNew(\''+id+'\')">'+(paid?'Reimprimir':'Confirmar cobro')+'</button>');
 opsEl('stayCollectMethod').value=paid?r.payment_method||'cash':'cash';opsEl('stayCollectPrint').checked=paid;stayCollectionMethodChanged();
};
function stayCollectionMethodChanged(){const hotel=opsEl('stayCollectMethod').value==='hotel_voucher';opsEl('stayCollectVouchers').classList.toggle('hidden',!hotel);opsEl('stayCollectPrint').closest('label').classList.toggle('hidden',hotel)}
async function confirmStayPaymentNew(id){
 const b=opsEl('stayCollectConfirm');if(b.disabled)return;b.disabled=true;
 try{
 const method=opsEl('stayCollectMethod').value;let result;
 if(method==='hotel_voucher'){
 const raw=opsEl('stayCollectCodes').value;const codes=raw.split(/[\s,;]+/).map(x=>x.trim()).filter(Boolean);
 const q=await db.rpc('parking_pay_stay_hotel_vouchers',{p_reservation_id:id,p_codes:codes});if(q.error)throw q.error;result=q.data;
 }else{
 const q=await db.rpc('parking_collect_stay',{p_reservation_id:id,p_payment_method:method,p_print_ticket:opsEl('stayCollectPrint').checked});if(q.error)throw q.error;result=q.data;
 }
 closeParkingOpsModal();await loadReservations();if(result?.receipt)await printParkingThermal(buildSimplifiedTicket(result.receipt));
 }catch(e){opsEl('parkingOpsMessage').textContent=e.message}finally{b.disabled=false}
}
