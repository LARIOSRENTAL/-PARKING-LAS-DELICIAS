/* Voucher preparation and collection are separate, idempotent operations. */
let hotelPaymentBatches=[];
function hotelAvailableCodeLabel(codes){const numbers=(codes||[]).map(c=>Number(String(c).replace(/^H-/,''))).sort((a,b)=>a-b);let groups=[];for(let i=0;i<numbers.length;i++){const start=numbers[i];let end=start;while(i+1<numbers.length&&numbers[i+1]===end+1)end=numbers[++i];groups.push('H-'+start+(end!==start?' — H-'+end:''))}return groups.join(', ')}
function renderHotelPayments(){
 const body=opsEl('hotelBalances');if(!body)return;
 const pending=h=>hotelPaymentBatches.filter(b=>b.hotel_id===h.id&&b.payment_status==='pending'&&!b.is_test),available=hotelPaymentBatches.filter(b=>Number(b.available_days)>0);
 const paymentButton=b=>b.is_test?'':'<button class="mini '+(b.payment_status==='pending'?'red':'blue')+'" onclick="openHotelBatchPayment(\''+b.id+'\')">'+(b.payment_status==='pending'?'Generar pago':'Ticket / factura')+'</button>';
 body.innerHTML='<table class="tbl"><thead><tr><th>Hotel / apartamento</th><th>Bonos disponibles</th><th>Pendientes de pago</th></tr></thead><tbody>'+parkingHotels.filter(h=>Number(h.available_days)>0).map(h=>{const p=pending(h);return '<tr><td>'+esc(h.name)+'</td><td><b>'+h.available_days+'</b></td><td>'+(p.length?'<span class="tag red">PENDIENTE DE PAGO · '+money(p.reduce((a,b)=>a+Number(b.days)*Number(b.unit_price_eur),0))+'</span>':'—')+'</td></tr>'}).join('')+'</tbody></table><h3>Bonos disponibles por compra</h3><p class="muted">Solo se muestran los registros que quedan sin utilizar. Los usados se descuentan automáticamente. Los pagos pendientes mantienen el importe de la compra original.</p>'+(available.length?'<div class="tableWrap"><table class="tbl"><thead><tr><th>Hotel / apartamento</th><th>Registros disponibles</th><th>Bonos disponibles</th><th>Estado de pago</th><th>Acciones</th></tr></thead><tbody>'+available.map(b=>{const due=b.payment_status==='pending';return '<tr><td>'+esc(parkingHotels.find(h=>h.id===b.hotel_id)?.name||'')+(b.is_test?' · PRUEBA':'')+'</td><td>'+esc(hotelAvailableCodeLabel(b.available_codes))+'</td><td><b>'+b.available_days+'</b> disponibles</td><td>'+(due?'<span class="tag red">PENDIENTE DE PAGO · '+money(Number(b.days)*Number(b.unit_price_eur))+'</span>':'<span class="tag green">'+(b.is_test?'PRUEBA SIN COBRO':'PAGADO')+'</span>')+'</td><td><div class="actions"><button class="mini blue" onclick="printHotelVoucherBatch(\''+b.id+'\')">Reimprimir disponibles</button>'+paymentButton(b)+'</div></td></tr>'}).join('')+'</tbody></table></div>':'<p class="muted">No quedan bonos disponibles.</p>');
 const unpaidEmpty=hotelPaymentBatches.filter(b=>b.payment_status==='pending'&&Number(b.available_days)===0&&!b.is_test);if(unpaidEmpty.length)body.innerHTML+='<h3>Pagos pendientes de compras ya agotadas</h3><p class="muted">Estos bonos ya se han utilizado, pero el hotel todavía debe abonar su compra.</p>'+unpaidEmpty.map(b=>'<div class="panel"><b>'+esc(parkingHotels.find(h=>h.id===b.hotel_id)?.name||'')+'</b> · <span class="tag red">PENDIENTE DE PAGO · '+money(Number(b.days)*Number(b.unit_price_eur))+'</span> '+paymentButton(b)+'</div>').join('');
}
let hotelInventoryLoadSerial=0;
loadParkingHotels=async function(){
 const serial=++hotelInventoryLoadSerial;
 const [hotels,batches]=await Promise.all([db.from('parking_hotel_balances').select('*').order('name'),db.rpc('parking_hotel_available_batches')]);if(serial!==hotelInventoryLoadSerial)return;
 if(hotels.error||batches.error){opsEl('hotelBalances').textContent='No se pudo cargar la disponibilidad: '+(hotels.error||batches.error).message;return}
 parkingHotels=hotels.data||[];hotelPaymentBatches=batches.data||[];
 if(opsEl('hotelBatchChoices')?.style.display==='block')filterHotelBatchOptions(true);
 if(opsEl('hotelNameList'))opsEl('hotelNameList').innerHTML=parkingHotels.map(h=>'<option value="'+esc(h.name)+'"></option>').join('');
 renderHotelPayments();
};
function hotelBatchPaymentChanged(){const invoice=!!opsEl('hotelPayInvoice')?.checked,ticket=opsEl('hotelPayTicket');ticket.checked=!invoice&&opsEl('hotelPayMethod').value==='card';ticket.disabled=invoice;opsEl('hotelInvoiceFields')?.classList.toggle('hidden',!invoice)}
let hotelInvoiceOpenSerial=0;
async function openHotelBatchPayment(id){
 const request=++hotelInvoiceOpenSerial;
 const b=hotelPaymentBatches.find(x=>x.id===id);if(!b)return;
 const due=b.payment_status==='pending',hotel=parkingHotels.find(h=>h.id===b.hotel_id),canInvoice=['admin','manager'].includes(currentProfile?.role),requiresInvoice=Number(b.days)*Number(b.unit_price_eur)>3000;
 if(requiresInvoice&&!canInvoice)return alert('Este importe requiere factura completa. Debe gestionarlo un administrador o gerente.');
 let fiscal=null,fiscalError='';
 if(canInvoice){try{const r=await db.rpc('parking_hotel_invoice_customer',{p_hotel_id:b.hotel_id});if(r.error)throw r.error;fiscal=r.data;}catch(e){fiscalError='No se pudieron cargar los datos fiscales guardados: '+e.message;}}
 if(request!==hotelInvoiceOpenSerial)return;

 opsModal(due?'Generar pago · Bonos hotel':'Documentos del cobro · Bonos hotel','<p><b>'+esc(hotel?.name||'')+'</b><br>'+b.days+' bonos · '+esc(b.registration_first||b.first_control)+' — '+esc(b.registration_last||b.first_control)+'<br><b>'+money(Number(b.days)*Number(b.unit_price_eur))+'</b></p>'+(due?'<p class="msg">Se contabilizará en tu turno actual al confirmar el pago.</p>':'<p class="muted">El cobro ya está registrado. Generar o reimprimir documentos no vuelve a sumar caja.</p>')+'<div class="field"><label>Forma de pago</label><select id="hotelPayMethod" '+(due?'':'disabled')+' onchange="hotelBatchPaymentChanged()"><option value="cash">Efectivo</option><option value="card">Tarjeta</option><option value="bank">Banco</option></select></div><div class="field"><label><input type="checkbox" id="hotelPayTicket" style="width:auto"> Imprimir ticket · factura simplificada</label></div>'+(canInvoice?'<div class="field"><label><input type="checkbox" id="hotelPayInvoice" style="width:auto" onchange="hotelBatchPaymentChanged()" '+(requiresInvoice?'checked disabled':'')+'> Generar e imprimir factura completa</label></div><div id="hotelInvoiceFields" class="hidden"><div class="field"><label>Nombre / razón social</label><input id="hotelInvoiceName" maxlength="200" value="'+esc(fiscal?.name||hotel?.name||'')+'"></div><div class="field"><label>NIF / CIF</label><input id="hotelInvoiceTax" maxlength="40" value="'+esc(fiscal?.tax_id||'')+'"></div><div class="field"><label>Domicilio completo (calle, número, CP y localidad)</label><textarea id="hotelInvoiceAddress" maxlength="500">'+esc(fiscal?.address||'')+'</textarea></div></div>':'')+'<div id="hotelPayStatus" role="status"></div>','<button id="hotelPayConfirm" class="btn green" onclick="confirmHotelBatchPayment(\''+id+'\')">'+(due?'Confirmar pago':'Generar documento')+'</button>');
 opsEl('hotelPayMethod').value=due?'cash':b.payment_method;hotelBatchPaymentChanged();if(fiscalError)opsEl('hotelPayStatus').textContent=fiscalError;
}
async function confirmHotelBatchPayment(id){
 const button=opsEl('hotelPayConfirm');if(button.disabled)return;const status=opsEl('hotelPayStatus');let customer=null;
 if(opsEl('hotelPayInvoice')?.checked){customer={name:opsEl('hotelInvoiceName').value.trim(),tax_id:opsEl('hotelInvoiceTax').value.trim(),address:opsEl('hotelInvoiceAddress').value.trim()};if(!customer.name||!customer.tax_id||!customer.address){status.textContent='Completa nombre, NIF/CIF y domicilio para emitir la factura.';return}}
 if(!customer&&!opsEl('hotelPayTicket').checked&&hotelPaymentBatches.find(b=>b.id===id)?.payment_status==='paid'){status.textContent='Selecciona ticket o factura.';return}
 button.disabled=true;status.textContent='Registrando…';let paymentRecorded=false;
 try{
  const r=await db.rpc('parking_collect_hotel_batch',{p_batch_id:id,p_payment_method:opsEl('hotelPayMethod').value,p_print_ticket:!customer&&opsEl('hotelPayTicket').checked,p_invoice_customer:customer});if(r.error)throw r.error;
  paymentRecorded=true;status.textContent='Cobro registrado.';button.textContent='Cobro registrado';
  const data=r.data;let printError=null;
  try{if(data.invoice)await sendParkingPrint('invoice',buildParkingInvoiceHtml(data.invoice,{includeInternalReceipt:true}));else if(data.receipt)await printParkingThermal(buildSimplifiedTicket(data.receipt))}catch(e){printError=e}
  closeParkingOpsModal();await loadParkingHotels();if(currentProfile?.role==='admin'||currentProfile?.role==='manager')await loadIssuedParkingInvoices();
  if(opsEl('cashbook')?.classList.contains('active'))await loadCashbook();
  if(printError){if(data.invoice)showParkingInvoicePreview(data.invoice);alert('El pago quedó registrado. No se pudo imprimir: '+printError.message+'. Usa Ticket / factura para reimprimir sin volver a cobrar.')}
 }catch(e){status.textContent=(paymentRecorded?'El pago está registrado, pero no se pudo actualizar la vista. Recarga antes de reimprimir: ':'No se pudo registrar el pago: ')+e.message;button.disabled=paymentRecorded}
}
