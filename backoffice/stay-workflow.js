/* Atomic, paid-at-creation stays and a single edit form with separate amendment payments. */
let manualStayRequestId=null,stayEditState=null,stayEditPriceSerial=0;
const manualPaymentWithVoucherFields=updateManualPaymentUI;
updateManualPaymentUI=function(){const voucher=opsEl('mPayment').value==='hotel_voucher';if(voucher){const tourism=vehicleTypes.find(v=>v.code==='TURISMO');if(tourism)opsEl('mType').value=tourism.id}opsEl('mType').disabled=voucher;manualPaymentWithVoucherFields()};
async function maybeCreateManualFromVouchers(){if(manualStayCreateBusy||opsEl('mPayment').value!=='hotel_voucher'||opsEl('mPlate').value.trim().length<3||opsEl('mModel').value.trim().length<2)return;try{if(parseHotelVoucherCodes(opsEl('mVoucherCodes').value).length===Number(opsEl('mDays').value))await createManualReservation()}catch(e){opsEl('mVoucherStatus').textContent=e.message}}
createManualReservation=async function(){
 if(manualStayCreateBusy)return;const button=document.querySelector('#manual button[onclick="createManualReservation()"]'),msg=opsEl('manualMsg');
 const plate=opsEl('mPlate').value.trim(),model=opsEl('mModel').value.trim(),method=opsEl('mPayment').value;
 if(plate.length<3||model.length<2||!opsEl('mEntry').value){msg.textContent='Completa matrícula, marca/modelo y entrada.';return}
 manualStayCreateBusy=true;if(button)button.disabled=true;let saved=false;
 try{
  const days=Number(opsEl('mDays').value),codes=method==='hotel_voucher'?parseHotelVoucherCodes(opsEl('mVoucherCodes').value):[];
  if(method==='hotel_voucher'&&codes.length!==days)throw Error('Necesitas '+days+' bono(s), uno por día.');
  manualStayRequestId=manualStayRequestId||crypto.randomUUID();
  const result=await db.rpc('parking_create_paid_stay',{p_request_id:manualStayRequestId,p_data:{plate,model,vehicle_type_id:opsEl('mType').value,entry_at:new Date(opsEl('mEntry').value).toISOString(),days,payment_method:method,amount_eur:Number(opsEl('mPrice').value),codes,name:opsEl('mName').value,phone:opsEl('mPhone').value,email:opsEl('mEmail').value,notes:opsEl('mNotes').value,print_ticket:opsEl('mReceiptPrint').checked}});
  if(result.error)throw result.error;saved=true;manualStayRequestId=null;const r=result.data.reservation;
  msg.innerHTML='<div class="msg">'+esc(r.reference)+' · Pagada · Fin '+fmt(r.exit_at)+'</div>';
  for(const id of ['mName','mPhone','mEmail','mPlate','mModel','mNotes','mVoucherCodes'])opsEl(id).value='';
  opsEl('mPayment').value='cash';opsEl('mEntry').value=localInput(new Date());updateManualPaymentUI();
  if(result.data.receipt){try{await printParkingThermal(buildSimplifiedTicket(result.data.receipt))}catch(e){alert('Estancia creada y cobrada. No se imprimió el ticket: '+e.message+'. Puedes reimprimirlo desde Reservas.')}}
  await refreshAll();await loadParkingHotels();currentStayTab='reservations';
  document.querySelectorAll('#staysNav button').forEach(x=>x.classList.toggle('active',x.dataset.tab==='reservations'));
  document.querySelectorAll('.section').forEach(x=>x.classList.toggle('active',x.id==='reservations'));await loadReservations();
 }catch(e){msg.innerHTML='<div class="msg error">'+(saved?'La estancia ya está creada y pagada. Actualiza el listado; no repitas el cobro. ': '')+esc(e.message)+'</div>'}
 finally{manualStayCreateBusy=false;if(button)button.disabled=false}
};
const paidStayCollection=openStayCollection;
openStayCollection=async function(id){const r=reservations.find(x=>x.id===id);if(!r)return;if(r.payment_status!=='paid')return alert('El pago inicial de esta reserva antigua no consta registrado. Verifica el cobro antes de emitir su ticket; no se ha realizado ningún nuevo cargo.');return paidStayCollection(id)};
function stayAttentionClass(end){return ({overdue:'lateRow',due_soon:'soonRow'})[insideAttention({planned_exit_at:end})]||''}
const renderOutsideWithFinish=renderOutside;
renderOutside=function(){renderOutsideWithFinish();const rows=opsEl('outsideBody')?.querySelectorAll('tbody tr')||[];outsideSessions.forEach((r,i)=>{if(rows[i])rows[i].className=stayAttentionClass(r.exit_at)})};
renderTotalStays=function(){
 const el=opsEl('totalStaysBody');if(!el)return;const query=normalizeRotationPlate(opsEl('totalStaySearch')?.value||'');const rows=totalStayDisplayRows().filter(x=>!query||normalizeRotationPlate(x.plate).includes(query));
 let h='<div class="panel"><b>'+rows.length+' estancias activas</b><div class="tableWrap"><table class="tbl"><thead><tr><th>Plaza</th><th>Referencia</th><th>Cliente</th><th>Vehículo / matrícula</th><th>Inicio</th><th>Fin previsto</th><th>Situación</th><th>Acciones</th></tr></thead><tbody>';
 for(const x of rows){const r=reservations.find(r=>r.reference===x.reference),attention=insideAttention({planned_exit_at:x.end});let actions='';if(r)actions='<button class="mini blue" onclick="moveActiveStay(\''+r.id+'\')">Cambiar plaza</button><button class="mini blue" onclick="reprintActiveStay(\''+r.id+'\')">Reimprimir bono</button><button class="mini" onclick="modifyReservation(\''+r.id+'\')">Modificar estancia</button>';if(r)actions+='<button class="mini '+(x.presence==='DENTRO'?'green':'blue')+'" onclick="toggleTotalStayPresence(this,\''+r.id+'\')">'+(x.presence==='DENTRO'?'Dar salida':'Dar entrada')+'</button>';
  h+='<tr class="'+stayAttentionClass(x.end)+'"><td><b>'+esc(x.spot)+'</b></td><td>'+esc(x.reference)+'</td><td>'+esc(x.customer)+'</td><td><b>'+esc(x.plate)+'</b><br>'+esc(x.vehicle)+'</td><td>'+fmt(x.start)+'</td><td>'+fmt(x.end)+'</td><td><span class="tag '+(x.presence==='DENTRO'?'amber':'red')+'">'+esc(x.presence)+'</span>'+(attention==='overdue'?'<br><b>TIEMPO EXCEDIDO</b>':attention==='due_soon'?'<br>Finaliza en menos de 3 h':'')+'</td><td><div class="actions">'+actions+'</div></td></tr>';
 }el.innerHTML=h+'</tbody></table></div></div>';
};
async function reprintActiveStay(id){const r=reservations.find(x=>x.id===id);if(!r)return;try{const changes=await db.from('parking_stay_changes').select('*').eq('reservation_id',id).order('created_at',{ascending:false}).limit(1);if(changes.error)throw changes.error;await printStayEditVoucher(r,changes.data?.[0]||null)}catch(e){alert('No se pudo reimprimir el bono: '+e.message)}}
async function moveActiveStay(id){const r=reservations.find(x=>x.id===id);if(!r)return;const available=freeSpotsFor(r.vehicle_type_id);opsModal('Cambiar plaza · '+r.plate,'<div class="field"><label>Plaza disponible</label><select id="stayMoveSpot">'+available.map(s=>'<option value="'+s.id+'">'+esc(s.code)+'</option>').join('')+'</select></div>','<button class="btn green" id="stayMoveConfirm" onclick="confirmMoveActiveStay(\''+id+'\')">Guardar plaza</button>')}
async function confirmMoveActiveStay(id){const b=opsEl('stayMoveConfirm');if(b.disabled)return;b.disabled=true;try{const r=await db.rpc('parking_move_active_stay',{p_reservation_id:id,p_spot_id:opsEl('stayMoveSpot').value});if(r.error)throw r.error;closeParkingOpsModal();await refreshAll();renderTotalStays()}catch(e){opsEl('parkingOpsMessage').textContent=e.message}finally{b.disabled=false}}
function stayEditInput(id,label,value,type='text',extra=''){return '<div class="field"><label for="'+id+'">'+label+'</label><input id="'+id+'" type="'+type+'" value="'+esc(value??'')+'" '+extra+'></div>'}
modifyReservation=async function(id){
 const r=reservations.find(x=>x.id===id);if(!r)return;stayEditState={reservation:r,requestId:crypto.randomUUID(),busy:false,invoiceCustomer:null,quoteReady:false};
 const started=!!r.last_movement_at;
 opsModal('Modificar estancia · '+r.reference,'<div class="stayEditFields"><div class="grid3"><div class="field"><label>Tipo vehículo</label><select id="stayEditType" onchange="quoteStayEdit()">'+vehicleTypes.map(t=>'<option value="'+t.id+'" '+(t.id===r.vehicle_type_id?'selected':'')+'>'+esc(t.name)+'</option>').join('')+'</select></div>'+stayEditInput('stayEditEntry','Entrada inicial',localInput(new Date(r.entry_at)),'datetime-local',(started?'disabled ':'')+'onchange="quoteStayEdit()"')+stayEditInput('stayEditDays','Días totales',r.duration_days,'number','min="1" max="24" onchange="quoteStayEdit()"')+'</div><div class="grid2">'+stayEditInput('stayEditPlate','Matrícula',r.plate)+stayEditInput('stayEditModel','Marca / modelo',r.vehicle_make_model)+'</div><div class="grid3">'+stayEditInput('stayEditName','Nombre',r.customer_name)+stayEditInput('stayEditPhone','Teléfono',r.customer_phone)+stayEditInput('stayEditEmail','Email',r.customer_email,'email')+'</div>'+stayEditInput('stayEditNotes','Notas',r.notes)+'<div class="grid3">'+stayEditInput('stayEditAmount','Precio total de la estancia',r.amount_eur,'number','min="0" step="0.01" oninput="updateStayEditSummary()"')+'<div class="field"><label>Forma de pago adicional</label><select id="stayEditPayment" onchange="stayEditPaymentChanged()"><option value="cash">Efectivo</option><option value="card">Tarjeta</option><option value="hotel_voucher">Bonos hotel</option></select></div>'+stayEditInput('stayEditExit','Fin previsto',fmt(r.exit_at),'text','readonly')+'</div><div id="stayEditSummary" class="stayEditSummary" role="status"></div><div id="stayEditVouchers" class="hidden">'+hotelVoucherFields('editStay')+'</div><div id="stayEditDocuments"><label><input type="checkbox" id="stayEditPrint" style="width:auto"> Imprimir ticket del pago adicional</label> <button type="button" class="mini" id="stayEditInvoice" onclick="prepareStayEditInvoice()">Generar factura del pago adicional</button><div id="stayEditInvoiceStatus"></div></div></div>','<button class="btn light" type="button" onclick="reprintCurrentStayEdit()">Reimprimir bono</button><button class="btn green" id="stayEditSave" onclick="saveStayEdit()">Guardar cambios</button>');
 opsEl('stayEditPayment').value=r.payment_method==='hotel_voucher'?'hotel_voucher':'cash';
 opsEl('stayEditInvoice').classList.toggle('hidden',!['admin','manager'].includes(currentProfile?.role));
 stayEditPaymentChanged();
};
async function quoteStayEdit(){
 const state=stayEditState;if(!state)return;const serial=++stayEditPriceSerial;state.quoteReady=false;opsEl('stayEditSave').disabled=true;
 const r=state.reservation,days=Number(opsEl('stayEditDays').value),type=opsEl('stayEditType').value;
 try{
  if(!Number.isInteger(days)||days<1||days>24)throw Error('Introduce entre 1 y 24 días.');
  const entry=r.last_movement_at?r.entry_at:new Date(opsEl('stayEditEntry').value).toISOString();
  const result=await db.rpc('parking_stay_price',{p_vehicle_type_id:type,p_days:days,p_entry_at:entry});if(serial!==stayEditPriceSerial||state!==stayEditState)return;if(result.error)throw result.error;if(result.data===null)throw Error('No existe tarifa para estos datos.');
  const voucher=opsEl('stayEditPayment').value==='hotel_voucher',extraDays=days-Number(r.duration_days);let additional=0;if(extraDays>0&&!voucher){const extraQuote=await db.rpc('parking_stay_price',{p_vehicle_type_id:type,p_days:extraDays,p_entry_at:r.exit_at});if(serial!==stayEditPriceSerial||state!==stayEditState)return;if(extraQuote.error)throw extraQuote.error;additional=Number(extraQuote.data);if(!Number.isFinite(additional))throw Error('No existe tarifa para los días de ampliación')}opsEl('stayEditAmount').value=Number(voucher?r.amount_eur:extraDays>0?Number(r.amount_eur)+additional:Math.max(Number(r.amount_eur),Number(result.data))).toFixed(2);opsEl('stayEditExit').value=fmt(new Date(new Date(entry).getTime()+days*86400000).toISOString());
  state.quoteReady=true;opsEl('stayEditSave').disabled=false;updateStayEditSummary();
 }catch(e){if(serial===stayEditPriceSerial){opsEl('stayEditSummary').textContent=e.message;state.quoteReady=false}}
}
function stayEditPaymentChanged(){const voucher=opsEl('stayEditPayment').value==='hotel_voucher',r=stayEditState.reservation;if(voucher){const tourism=vehicleTypes.find(t=>t.code==='TURISMO');if(tourism)opsEl('stayEditType').value=tourism.id}opsEl('stayEditType').disabled=voucher;opsEl('stayEditAmount').readOnly=voucher;opsEl('stayEditVouchers').classList.toggle('hidden',!voucher);opsEl('stayEditDocuments').classList.toggle('hidden',voucher);opsEl('stayEditPrint').checked=false;quoteStayEdit()}
function updateStayEditSummary(){if(!stayEditState)return;const r=stayEditState.reservation,diff=Math.round((Number(opsEl('stayEditAmount').value)-Number(r.amount_eur))*100)/100,voucher=opsEl('stayEditPayment').value==='hotel_voucher',added=Number(opsEl('stayEditDays').value)-Number(r.duration_days);opsEl('stayEditSummary').textContent=voucher?Math.max(0,added)+' bono(s) para los días adicionales. Sin nuevo cobro en caja.':'Pagado anteriormente: '+money(r.amount_eur)+' · Diferencia a cobrar: '+money(Math.max(0,diff));const extension=added>0;opsEl('stayEditPrint').disabled=extension;if(extension){opsEl('stayEditPrint').checked=false;opsEl('stayEditSummary').textContent+=' · Se imprimirá un único bono de ampliación.'}opsEl('stayEditSave').textContent=!voucher&&diff>0?'Cobrar '+money(diff)+' y guardar':'Guardar cambios'}
async function prepareStayEditInvoice(){const state=stayEditState;if(!state)return;const values=readStayEditValues(),customer=await openInvoiceCustomerForm(state.invoiceCustomer||{name:values.name});if(stayEditState!==state)return;state.invoiceCustomer=customer;await modifyStayEditRestore(state,values)}
function readStayEditValues(){const r=stayEditState.reservation;return{plate:opsEl('stayEditPlate').value,model:opsEl('stayEditModel').value,vehicle_type_id:opsEl('stayEditType').value,entry_at:r.last_movement_at?r.entry_at:new Date(opsEl('stayEditEntry').value).toISOString(),days:Number(opsEl('stayEditDays').value),amount_eur:Number(opsEl('stayEditAmount').value),payment_method:opsEl('stayEditPayment').value,name:opsEl('stayEditName').value,phone:opsEl('stayEditPhone').value,email:opsEl('stayEditEmail').value,notes:opsEl('stayEditNotes').value,print_ticket:opsEl('stayEditPrint').checked,codes:opsEl('editStayVoucherCodes').value}}
async function modifyStayEditRestore(state,values){await modifyReservation(state.reservation.id);stayEditState.requestId=state.requestId;stayEditState.invoiceCustomer=state.invoiceCustomer;for(const [key,id] of Object.entries({plate:'stayEditPlate',model:'stayEditModel',vehicle_type_id:'stayEditType',days:'stayEditDays',amount_eur:'stayEditAmount',payment_method:'stayEditPayment',name:'stayEditName',phone:'stayEditPhone',email:'stayEditEmail',notes:'stayEditNotes'}))opsEl(id).value=values[key];opsEl('stayEditEntry').value=localInput(new Date(values.entry_at));opsEl('stayEditVouchers').classList.toggle('hidden',values.payment_method!=='hotel_voucher');opsEl('stayEditDocuments').classList.toggle('hidden',values.payment_method==='hotel_voucher');opsEl('stayEditAmount').readOnly=values.payment_method==='hotel_voucher';opsEl('stayEditPrint').checked=values.print_ticket;opsEl('stayEditInvoiceStatus').textContent=state.invoiceCustomer?'Factura preparada: '+state.invoiceCustomer.name:'';await quoteStayEdit();opsEl('stayEditAmount').value=values.amount_eur;updateStayEditSummary()}
async function printStayEditVoucher(reservation,change=null){
 const spot=spots.find(x=>x.id===reservation.assigned_spot_id)?.code||reservation.parking_space_label||'';
 const session=insideSessions.find(x=>x.reservation_id===reservation.id);
 let html=buildVoucherHtml(reservation,spot,session?.actual_entry_at||reservation.entry_at,null);
 if(change){
  const changes=await db.from('parking_stay_changes').select('id,created_at').eq('reservation_id',reservation.id).order('created_at',{ascending:true});
  const position=changes.error?1:Math.max(1,(changes.data||[]).findIndex(x=>x.id===change.id)+1);
  const added=Number(reservation.duration_days||0)-Number(change.before_data?.duration_days||0);
  const due=Number(change.amount_eur||0);
  html=html.replace(/<tr><th>Precio<\/th><td>[\s\S]*?<\/td><\/tr>/,'');
  const rows='<tr><th>Ampliación</th><td>Nº '+position+(added>0?' · '+added+' día(s)':'')+'</td></tr><tr><th>Precio ampliación</th><td>'+money(due)+'</td></tr>';
  html=html.replace('</table><div class="signature">',''+rows+'</table><div class="signature">');
 }
 await sendParkingPrint('stay',html);
}
async function reprintCurrentStayEdit(){
 const id=stayEditState?.reservation?.id;if(!id)return;
 try{
  const r=await db.from('parking_stay_changes').select('*').eq('reservation_id',id).order('created_at',{ascending:false}).limit(1);
  if(r.error)throw r.error;
  await printStayEditVoucher(stayEditState.reservation,r.data?.[0]||null);
 }catch(e){alert('No se pudo reimprimir el bono: '+e.message)}
}
async function saveStayEdit(){
 const state=stayEditState;if(!state||state.busy||!state.quoteReady)return;const b=opsEl('stayEditSave');state.busy=true;b.disabled=true;let saved=false;
 try{const data=readStayEditValues();if(data.days>Number(state.reservation.duration_days))data.print_ticket=false;data.codes=data.payment_method==='hotel_voucher'&&data.days>Number(state.reservation.duration_days)?parseHotelVoucherCodes(data.codes):[];data.expected_updated_at=state.reservation.updated_at;data.invoice_customer=state.invoiceCustomer;const r=await db.rpc('parking_save_stay_changes',{p_request_id:state.requestId,p_reservation_id:state.reservation.id,p_data:data});if(r.error)throw r.error;saved=true;closeParkingOpsModal();if(r.data.invoice)showParkingInvoicePreview(r.data.invoice);if(r.data.receipt){try{await printParkingThermal(buildSimplifiedTicket(r.data.receipt))}catch(e){alert('El pago adicional ya está registrado. No se imprimió el ticket: '+e.message)}}await refreshAll();try{await printStayEditVoucher(r.data.reservation,r.data.change)}catch(e){alert('Reserva guardada. No se pudo imprimir el bono actualizado: '+e.message)}renderTotalStays();await loadParkingHotels()}
 catch(e){if(saved)alert('Cambios y pago guardados. Actualiza el listado; no repitas la operación. '+e.message);else opsEl('parkingOpsMessage').textContent=e.message}
 finally{state.busy=false;b.disabled=false}
}

async function toggleTotalStayPresence(button,id){
 if(button.disabled)return;button.disabled=true;
 try{const r=reservations.find(x=>x.id===id);if(!r)throw Error('Estancia no encontrada.');
 if(r.vehicle_presence==='DENTRO'){const session=insideSessions.find(x=>x.reservation_id===id);await checkOut(session?.id||'',id)}
 else {if(!r.assigned_spot_id){await openTotalStayEntrySpot(id);return;}const result=await db.rpc('record_parking_movement',{p_reservation_id:id,p_direction:'IN'});if(result.error)throw result.error;await refreshAll()}
 renderTotalStays();
 }catch(e){alert('No se pudo cambiar la situación: '+e.message)}finally{button.disabled=false}
}

async function openTotalStayEntrySpot(id){
 await refreshSharedStayAvailability();const r=reservations.find(x=>x.id===id),available=freeSpotsFor(r.vehicle_type_id);
 if(!available.length)throw Error('No hay plazas libres compatibles para volver a dar entrada.');
 opsModal('Dar entrada · '+r.plate,'<div class="field"><label>Plaza libre</label><select id="totalStayEntrySpot">'+available.map(s=>'<option value="'+s.id+'">'+esc(s.code)+'</option>').join('')+'</select></div>','<button class="btn green" id="totalStayEntryConfirm" onclick="confirmTotalStayEntry(\''+id+'\')">Dar entrada</button>');
}
async function confirmTotalStayEntry(id){const b=opsEl('totalStayEntryConfirm');if(b.disabled)return;b.disabled=true;try{const r=await db.rpc('backoffice_check_in',{p_reservation_id:id,p_spot_id:opsEl('totalStayEntrySpot').value,p_actual_entry_at:new Date().toISOString()});if(r.error)throw r.error;closeParkingOpsModal();await refreshAll();renderTotalStays()}catch(e){opsEl('parkingOpsMessage').textContent=e.message}finally{b.disabled=false}}
