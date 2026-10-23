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
 let h=previousReservationTable(rows,actions);if(!actions)return h;
 for(const r of rows){
  const paid=r.payment_status==='paid',prefix="onclick=\"checkIn('"+r.id+"')\"";
  h=h.replace(prefix+'\u003eMarcar entrada',paid?prefix+'>Dar entrada':"onclick=\"openStayCollection('"+r.id+"')\">Cobrar y dar entrada");
  if(!paid){h=h.replace("onclick=\"openStayCollection('"+r.id+"')\">Cobrar reserva","onclick=\"openStayCollection('"+r.id+"')\" style=\"display:none\">Cobrar reserva");}
  const status=paid?'PAGADO':'PENDIENTE DE PAGO';
  const pos=h.indexOf('>'+esc(r.reference)+'</b>'); // status changes only in matching row via status cell
  const marker='<td>'+statusTag(r.status)+'</td>';
  if(h.includes(marker))h=h.replace(marker,'<td><span class="tag '+(paid?'green':'red')+'">'+status+'</span></td>');
 }
 return h;
};
openStayCollection=function(id){
 const r=reservations.find(x=>x.id===id);if(!r)return;const paid=r.payment_status==='paid';if(paid)return;
 const spot=document.getElementById('spot-'+id)?.value;if(!spot)return alert('Selecciona una plaza antes de cobrar y dar entrada.');
 window.stayPaymentCurrent={id,spot,entry:r.entry_at,type:r.vehicle_type_id};
 opsModal('Cobrar reserva y dar entrada · '+r.reference,
 '<div class="grid2"><div class="field"><label>Días de estancia</label><input id="stayCollectDays" type="number" min="1" max="24" value="'+Number(r.duration_days)+'" onchange="updateCombinedStayPayment()"></div><div class="field"><label>Fin previsto</label><input id="stayCollectEnd" type="datetime-local" onchange="stayEndChanged()"></div></div><div id="stayCollectPrice" style="font-size:22px;font-weight:bold"></div><div class="field"><label>Forma de pago</label><select id="stayCollectMethod" onchange="updateCombinedStayPayment()"><option value="cash">Efectivo</option><option value="card">Tarjeta</option><option value="hotel_voucher">Bonos hotel</option><option value="hotel_voucher_old">Bonos hotel antiguos</option></select></div><div id="stayCollectVouchers"></div><label id="stayCollectPrintWrap"><input type="checkbox" id="stayCollectPrint" style="width:auto"> Imprimir ticket de cobro</label>',
 '<button class="btn green" id="stayCollectConfirm" onclick="confirmCombinedStayPayment()">Cobrar y dar entrada</button>');
 updateCombinedStayPayment();
};
function stayEndChanged(){const ctx=window.stayPaymentCurrent;if(!ctx)return;const entry=new Date(ctx.entry).getTime(),end=new Date(opsEl('stayCollectEnd').value).getTime();if(!Number.isFinite(end)||end<=entry)return;opsEl('stayCollectDays').value=Math.ceil((end-entry)/86400000);updateCombinedStayPayment()}
async function updateCombinedStayPayment(){
 const ctx=window.stayPaymentCurrent;if(!ctx)return;
 const days=Number(opsEl('stayCollectDays').value),method=opsEl('stayCollectMethod').value;
 const voucher=method==='hotel_voucher'||method==='hotel_voucher_old';
 opsEl('stayCollectPrice').classList.toggle('hidden',voucher);
 opsEl('stayCollectPrintWrap').classList.toggle('hidden',voucher);
 const end=new Date(new Date(ctx.entry).getTime()+days*86400000);
 opsEl('stayCollectEnd').value=Number.isFinite(end.getTime())?localInput(end):'';
 const wrapper=opsEl('stayCollectVouchers'),previous=[...wrapper.querySelectorAll('input')].map(x=>x.value);
 wrapper.innerHTML=voucher&&Number.isInteger(days)&&days>0&&days<=24?Array.from({length:days},(_,i)=>'<div class="field"><label>Bono hotel día '+(i+1)+'</label><input class="stayVoucherNumber" placeholder="'+(method==='hotel_voucher'?'Escanear bono':'Número del bono antiguo')+'" value="'+esc(previous[i]||'')+'"></div>').join(''):'';
 if(voucher){opsEl('stayCollectPrice').textContent='';return}
 const quote=await db.rpc('parking_stay_price',{p_vehicle_type_id:ctx.type,p_days:days,p_entry_at:ctx.entry});
 opsEl('stayCollectPrice').textContent=quote.error?'No se pudo calcular precio':money(quote.data);
}
async function confirmCombinedStayPayment(){
 const ctx=window.stayPaymentCurrent;if(!ctx)return;
 const button=opsEl('stayCollectConfirm');button.disabled=true;
 try{
 const days=Number(opsEl('stayCollectDays').value),method=opsEl('stayCollectMethod').value,codes=[...document.querySelectorAll('.stayVoucherNumber')].map(x=>x.value.trim().toUpperCase());
 if(!Number.isInteger(days)||days<1||days>24)throw Error('Introduce una duración válida.');
 if(method.startsWith('hotel_voucher')&&(codes.length!==days||codes.some(x=>!x)||new Set(codes).size!==days))throw Error('Se necesita un número de bono distinto para cada día.');
 const result=await db.rpc('parking_pay_and_enter_stay',{p_reservation_id:ctx.id,p_spot_id:ctx.spot,p_days:days,p_method:method,p_codes:codes,p_print_ticket:opsEl('stayCollectPrint').checked});
 if(result.error)throw result.error;
 closeParkingOpsModal();await refreshAll();
 if(result.data.receipt)try{await printParkingThermal(buildSimplifiedTicket(result.data.receipt))}catch(e){alert('Entrada guardada; error al imprimir el ticket de cobro: '+e.message)}
 const res=reservations.find(x=>x.id===ctx.id);
 if(res)try{const ps=insideSessions.find(x=>x.reservation_id===ctx.id),sp=spots.find(x=>x.id===ctx.spot);await sendParkingPrint('stay',buildVoucherHtml(res,sp?.code||'',ps?.actual_entry_at||new Date().toISOString(),null))}catch(e){alert('Entrada y cobro guardados; error al imprimir el bono: '+e.message)}
 }catch(e){opsEl('parkingOpsMessage').textContent=e.message}finally{button.disabled=false}
}
