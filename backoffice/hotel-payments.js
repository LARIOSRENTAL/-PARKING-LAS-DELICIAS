/* Voucher preparation and collection are separate, idempotent operations. */
let hotelPaymentBatches=[];
function renderHotelPayments(){
 const body=opsEl('hotelBalances');if(!body)return;
 const pending=h=>hotelPaymentBatches.filter(b=>b.hotel_id===h.id&&b.payment_status==='pending'&&!b.is_test);
 body.innerHTML='<table class="tbl"><thead><tr><th>Hotel</th><th>Comprados</th><th>Utilizados</th><th>Disponibles</th><th>Pendientes de pago</th></tr></thead><tbody>'+parkingHotels.map(h=>{const p=pending(h);return '<tr><td>'+esc(h.name)+'</td><td>'+h.purchased_days+'</td><td>'+h.used_days+'</td><td><b>'+h.available_days+'</b></td><td>'+(p.length?'<span class="tag red">'+p.reduce((a,b)=>a+Number(b.days),0)+' bonos · '+money(p.reduce((a,b)=>a+Number(b.days)*Number(b.unit_price_eur),0))+'</span>':'—')+'</td></tr>'}).join('')+'</tbody></table><h3>Bonos preparados y últimas compras</h3><p class="muted">Los pendientes no suman en caja hasta registrar su pago. Reimprimir no genera otro cobro.</p><div class="tableWrap"><table class="tbl"><thead><tr><th>Hotel</th><th>Registros</th><th>Bonos / importe</th><th>Estado de pago</th><th>Acciones</th></tr></thead><tbody>'+hotelPaymentBatches.map(b=>{const due=b.payment_status==='pending';return '<tr><td>'+esc(parkingHotels.find(h=>h.id===b.hotel_id)?.name||'')+(b.is_test?' · PRUEBA':'')+'</td><td>'+esc(b.registration_first||b.first_control)+' — '+esc(b.registration_last||b.first_control)+'</td><td>'+b.days+' · '+money(Number(b.days)*Number(b.unit_price_eur))+'</td><td>'+(due?'<span class="tag red">PENDIENTE DE PAGO</span>':'<span class="tag green">'+(b.is_test?'PRUEBA SIN COBRO':'PAGADO')+'</span>'+(!b.is_test?'<br><small>'+esc(({cash:'Efectivo',card:'Tarjeta',bank:'Banco'}[b.payment_method])||'')+(b.paid_at?' · '+fmt(b.paid_at):'')+'</small>':''))+'</td><td><div class="actions"><button class="mini blue" onclick="printHotelVoucherBatch(\''+b.id+'\')">Reimprimir disponibles</button>'+(!b.is_test?'<button class="mini '+(due?'red':'blue')+'" onclick="openHotelBatchPayment(\''+b.id+'\')">'+(due?'Generar pago':'Ticket / factura')+'</button>':'')+'</div></td></tr>'}).join('')+'</tbody></table></div>';
}
loadParkingHotels=async function(){
 const hotels=await db.from('parking_hotel_balances').select('*').order('name');if(hotels.error){console.error(hotels.error);return}
 parkingHotels=hotels.data||[];if(opsEl('hotelBatchChoices')?.style.display==='block')filterHotelBatchOptions(true);
 if(opsEl('hotelNameList'))opsEl('hotelNameList').innerHTML=parkingHotels.map(h=>'<option value="'+esc(h.name)+'"></option>').join('');
 const fields='id,first_control,days,hotel_id,created_at,unit_price_eur,registration_first,registration_last,is_test,payment_status,payment_method,paid_at';
 const recent=await db.from('parking_hotel_batches').select(fields).eq('is_void',false).order('created_at',{ascending:false}).limit(100);
 if(recent.error){opsEl('hotelBalances').textContent='No se pudo cargar el estado de pago: '+recent.error.message;return}
 const batches=new Map((recent.data||[]).map(b=>[b.id,b]));
 // Include every unpaid batch, even if it is older than the latest 100 purchases.
 for(let offset=0;;offset+=500){const due=await db.from('parking_hotel_batches').select(fields).eq('is_void',false).eq('payment_status','pending').order('id').range(offset,offset+499);if(due.error){opsEl('hotelBalances').textContent='No se pudieron cargar los pagos pendientes: '+due.error.message;return}for(const b of due.data||[])batches.set(b.id,b);if((due.data||[]).length<500)break}
 hotelPaymentBatches=[...batches.values()].sort((a,b)=>(a.payment_status==='pending'?0:1)-(b.payment_status==='pending'?0:1)||String(b.created_at).localeCompare(String(a.created_at)));renderHotelPayments();
};
function hotelBatchPaymentChanged(){const invoice=!!opsEl('hotelPayInvoice')?.checked,ticket=opsEl('hotelPayTicket');ticket.checked=!invoice&&opsEl('hotelPayMethod').value==='card';ticket.disabled=invoice;opsEl('hotelInvoiceFields')?.classList.toggle('hidden',!invoice)}
function openHotelBatchPayment(id){
 const b=hotelPaymentBatches.find(x=>x.id===id);if(!b)return;
 const due=b.payment_status==='pending',hotel=parkingHotels.find(h=>h.id===b.hotel_id),canInvoice=['admin','manager'].includes(currentProfile?.role),requiresInvoice=Number(b.days)*Number(b.unit_price_eur)>3000;
 if(requiresInvoice&&!canInvoice)return alert('Este importe requiere factura completa. Debe gestionarlo un administrador o gerente.');
 opsModal(due?'Generar pago · Bonos hotel':'Documentos del cobro · Bonos hotel','<p><b>'+esc(hotel?.name||'')+'</b><br>'+b.days+' bonos · '+esc(b.registration_first||b.first_control)+' — '+esc(b.registration_last||b.first_control)+'<br><b>'+money(Number(b.days)*Number(b.unit_price_eur))+'</b></p>'+(due?'<p class="msg">Se contabilizará en tu turno actual al confirmar el pago.</p>':'<p class="muted">El cobro ya está registrado. Generar o reimprimir documentos no vuelve a sumar caja.</p>')+'<div class="field"><label>Forma de pago</label><select id="hotelPayMethod" '+(due?'':'disabled')+' onchange="hotelBatchPaymentChanged()"><option value="cash">Efectivo</option><option value="card">Tarjeta</option><option value="bank">Banco</option></select></div><div class="field"><label><input type="checkbox" id="hotelPayTicket" style="width:auto"> Imprimir ticket · factura simplificada</label></div>'+(canInvoice?'<div class="field"><label><input type="checkbox" id="hotelPayInvoice" style="width:auto" onchange="hotelBatchPaymentChanged()" '+(requiresInvoice?'checked disabled':'')+'> Generar e imprimir factura completa</label></div><div id="hotelInvoiceFields" class="hidden"><div class="field"><label>Nombre / razón social</label><input id="hotelInvoiceName" maxlength="200" value="'+esc(hotel?.name||'')+'"></div><div class="field"><label>NIF / CIF</label><input id="hotelInvoiceTax" maxlength="40"></div><div class="field"><label>Domicilio completo (calle, número, CP y localidad)</label><textarea id="hotelInvoiceAddress" maxlength="500"></textarea></div></div>':'')+'<div id="hotelPayStatus" role="status"></div>','<button id="hotelPayConfirm" class="btn green" onclick="confirmHotelBatchPayment(\''+id+'\')">'+(due?'Confirmar pago':'Generar documento')+'</button>');
 opsEl('hotelPayMethod').value=due?'cash':b.payment_method;hotelBatchPaymentChanged();
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
