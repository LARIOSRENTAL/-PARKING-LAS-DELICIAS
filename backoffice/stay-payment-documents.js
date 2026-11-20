/* Historical payment documents: issuing/printing never charges or edits a stay. */
(function(){
 const openEdit=modifyReservation;
 modifyReservation=async function(id){
  await openEdit(id);
  const state=stayEditState;if(state?.reservation.id!==id)return;
  const anchor=opsEl('stayEditDocuments');if(!anchor)return;
  const section=document.createElement('section');section.id='stayPaymentDocuments';section.className='profileSection';
  section.innerHTML='<h4>Documentos de los pagos registrados</h4><p class="muted">El pago inicial y cada ampliación tienen sus propios documentos. Imprimir o generar una factura no realiza otro cobro ni guarda los cambios de esta ficha.</p><div id="stayPaymentDocumentRows" role="status">Consultando pagos…</div><details id="stayPaymentCustomer"><summary>Datos del cliente para la factura</summary><div class="field"><label for="stayDocumentName">Nombre / razón social</label><input id="stayDocumentName" maxlength="200"></div><div class="field"><label for="stayDocumentTax">NIF / CIF</label><input id="stayDocumentTax" maxlength="40"></div><div class="field"><label for="stayDocumentAddress">Domicilio completo</label><textarea id="stayDocumentAddress" maxlength="500"></textarea></div></details><p id="stayPaymentDocumentStatus" role="status"></p>';
  anchor.insertAdjacentElement('afterend',section);
  opsEl('stayDocumentName').value=state.reservation.customer_name||'';
  state.paymentDocumentBusy=false;await loadStayPaymentDocuments(state);
 };
 window.loadStayPaymentDocuments=async function(state=stayEditState){
  const target=opsEl('stayPaymentDocumentRows');if(!target||!state)return;
  try{
   const result=await db.rpc('parking_stay_payment_documents',{p_reservation_id:state.reservation.id});
   if(stayEditState!==state||opsEl('stayPaymentDocumentRows')!==target)return;
   if(result.error)throw result.error;state.paymentDocuments=result.data||[];
   target.replaceChildren();
   if(!state.paymentDocuments.length){target.textContent='No hay cobros en caja para emitir documentos. Los bonos hotel ya se pagaron al comprarlos.';return;}
   let extension=0;
   for(const row of state.paymentDocuments){
    const line=document.createElement('div');line.className='eventRow';
    const label=document.createElement('div');label.textContent=(row.entity_type==='reservation'?'Estancia inicial':'Ampliación '+(++extension))+' · '+money(row.amount_eur)+' · '+fmt(row.paid_at);line.append(label);
    const actions=document.createElement('div');actions.className='actions';
    for(const [kind,text]of [['ticket','Ticket de cobro'],['invoice',row.invoice?'Ver / imprimir factura':'Generar factura']]){
     const button=document.createElement('button');button.type='button';button.className='mini blue';button.textContent=text;
     button.onclick=()=>emitStayPaymentDocument(row,kind,state);actions.append(button);
    }
    line.append(actions);target.append(line);
   }
  }catch(e){if(stayEditState===state&&opsEl('stayPaymentDocumentRows')===target)target.textContent='No se pudieron consultar los documentos: '+e.message;}
 };
 window.emitStayPaymentDocument=async function(row,kind,state=stayEditState){
  if(!state||stayEditState!==state||state.paymentDocumentBusy||state.busy)return;
  const status=opsEl('stayPaymentDocumentStatus');let customer=null;
  if(kind==='invoice'&&!row.invoice){
   customer={name:opsEl('stayDocumentName').value.trim(),tax_id:opsEl('stayDocumentTax').value.trim(),address:opsEl('stayDocumentAddress').value.trim()};
   if(!customer.name||!customer.tax_id||!customer.address){opsEl('stayPaymentCustomer').open=true;status.textContent='Completa los datos del cliente y vuelve a pulsar «Generar factura» en el pago correspondiente.';opsEl(!customer.name?'stayDocumentName':!customer.tax_id?'stayDocumentTax':'stayDocumentAddress').focus();return;}
  }
  state.paymentDocumentBusy=true;const buttons=[...opsEl('stayPaymentDocuments').querySelectorAll('button')];buttons.forEach(b=>b.disabled=true);
  const save=opsEl('stayEditSave'),saveDisabled=save.disabled;save.disabled=true;status.textContent='Preparando documento…';let issued=false;
  try{
   const result=await db.rpc('parking_stay_payment_document',{p_reservation_id:state.reservation.id,p_entity_type:row.entity_type,p_entity_id:row.entity_id,p_kind:kind,p_customer:customer});
   if(result.error)throw result.error;issued=true;
   if(kind==='ticket'||result.data.doc_kind==='simplified')await printParkingThermal(buildSimplifiedTicket(result.data));
   else showParkingInvoicePreview(result.data);
   status.textContent='Documento preparado. No se ha realizado ningún nuevo cobro.';
  }catch(e){status.textContent=(issued?'Documento guardado. Puedes volver a imprimirlo sin repetir el cobro. ':'No se pudo generar el documento. ')+e.message;}
  finally{state.paymentDocumentBusy=false;if(stayEditState===state){save.disabled=saveDisabled;buttons.forEach(b=>b.disabled=false);await loadStayPaymentDocuments(state);}}
 };
})();

// Tickets emitidos para estancias finalizadas. Los documentos usan pagos registrados y nunca vuelven a cobrar.
let stayTicketReportRows=[];
function stayTickets(){
 const privileged=['admin','manager'].includes(currentProfile?.role),range=rotationCurrentMonth(),today=range.today;
 historyTitle.textContent='Tickets emitidos · Estancias';
 historyBody.innerHTML='<div class="panel"><div class="grid2"><div class="field"><label for="stayTicketDateFrom">Desde</label><input type="date" id="stayTicketDateFrom" value="'+today+'" '+(privileged?'':'min="'+range.first+'" max="'+range.last+'"')+'></div><div class="field"><label for="stayTicketDateTo">Hasta</label><input type="date" id="stayTicketDateTo" value="'+today+'" '+(privileged?'':'min="'+range.first+'" max="'+range.last+'"')+'></div></div><button class="mini blue" type="button" onclick="loadStayTicketReport()">Buscar tickets</button><div id="stayTicketReportResults"></div></div>';
 historyModal.classList.remove('hidden');
 loadStayTicketReport();
}
function stayTicketLocalDate(stamp){
 if(!stamp)return '';
 const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Europe/Madrid',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(stamp));
 const value=type=>parts.find(p=>p.type===type)?.value||'';
 return value('year')+'-'+value('month')+'-'+value('day');
}
async function loadStayTicketReport(){
 const privileged=['admin','manager'].includes(currentProfile?.role),range=rotationCurrentMonth();
 const fromField=opsEl('stayTicketDateFrom'),toField=opsEl('stayTicketDateTo'),el=opsEl('stayTicketReportResults');
 if(!fromField||!toField||!el)return;
 const from=fromField.value||range.today,to=toField.value||range.today;
 if(from>to)return alert('Fechas no válidas');
 if(!privileged&&(from<range.first||to>range.last))return alert('Puedes consultar tickets únicamente del mes vigente.');
 el.textContent='Consultando estancias finalizadas…';
 try{
  const result=await db.from('reservations').select('id,reference,control_reference,plate,customer_name,customer_phone,vehicle_make_model,amount_eur,finished_at,updated_at,status').eq('status','completed').order('finished_at',{ascending:false,nullsFirst:false}).limit(5000);
  if(result.error)throw result.error;
  stayTicketReportRows=(result.data||[]).filter(x=>{const date=stayTicketLocalDate(x.finished_at||x.updated_at);return date&&date>=from&&date<=to&&(privileged||rotationCurrentMonthContains(x.finished_at||x.updated_at))});
  if(!stayTicketReportRows.length){el.innerHTML='<div class="muted">No hay estancias finalizadas en esas fechas.</div>';return}
  el.innerHTML='<p>'+stayTicketReportRows.length+' estancia(s) finalizada(s). Puedes emitir documentos de pagos registrados sin repetir el cobro.</p><div class="tableWrap"><table class="tbl"><thead><tr><th>Estancia</th><th>Matrícula</th><th>Cliente</th><th>Finalizada</th><th>Importe estancia</th><th>Documentos</th></tr></thead><tbody>'+stayTicketReportRows.map(x=>'<tr><td>'+esc(x.control_reference||x.reference||'—')+'</td><td><b>'+esc(x.plate||'—')+'</b><br>'+esc(x.vehicle_make_model||'')+'</td><td>'+esc(x.customer_name||'—')+'</td><td>'+fmt(x.finished_at||x.updated_at)+'</td><td>'+money(x.amount_eur||0)+'</td><td><button class="mini blue" type="button" onclick="loadStayTicketPayments(\''+esc(x.id)+'\')">Tickets / facturas</button><div id="stayTicketPayments_'+esc(x.id)+'" class="stayTicketPayments hidden"></div></td></tr>').join('')+'</tbody></table></div>';
 }catch(e){el.textContent='No se pudieron cargar las estancias finalizadas: '+e.message}
}
async function loadStayTicketPayments(id){
 const stay=stayTicketReportRows.find(x=>x.id===id),target=opsEl('stayTicketPayments_'+id);
 if(!stay||!target)return;
 target.classList.remove('hidden');target.textContent='Consultando pagos registrados…';
 try{
  const result=await db.rpc('parking_stay_payment_documents',{p_reservation_id:id});
  if(result.error)throw result.error;
  const payments=result.data||[];
  if(!payments.length){target.textContent='No hay pagos registrados en caja para esta estancia. Los bonos hotel se facturan desde su compra.';return}
  target.replaceChildren();
  let extension=0;
  for(const payment of payments){
   const line=document.createElement('div');line.className='eventRow';
   const info=document.createElement('div');info.innerHTML='<b>'+esc(payment.entity_type==='reservation'?'Estancia inicial':'Ampliación '+(++extension))+'</b><br><small>'+money(payment.amount_eur||0)+' · '+fmt(payment.paid_at)+'</small>';
   const actions=document.createElement('div');actions.className='actions';
   for(const kind of ['ticket','invoice']){
    const button=document.createElement('button');button.type='button';button.className='mini blue';
    button.textContent=kind==='ticket'?'Ticket de cobro':payment.invoice?'Ver / imprimir factura':'Generar factura';
    button.onclick=()=>emitStayListDocument(stay,payment,kind,target);
    actions.append(button);
   }
   line.append(info,actions);target.append(line);
  }
  const status=document.createElement('p');status.className='muted stayTicketDocumentStatus';status.setAttribute('role','status');target.append(status);
 }catch(e){target.textContent='No se pudieron consultar los pagos: '+e.message}
}
async function emitStayListDocument(stay,payment,kind,target){
 if(!stay||!payment||!target||target.dataset.busy==='true')return;
 let customer=null;
 if(kind==='invoice'&&!payment.invoice){
  customer=await openInvoiceCustomerForm({name:stay.customer_name||'',search:stay.plate||''});
  if(!customer)return;
 }
 target.dataset.busy='true';
 const buttons=[...target.querySelectorAll('button')];buttons.forEach(b=>b.disabled=true);
 const status=target.querySelector('.stayTicketDocumentStatus');if(status)status.textContent='Preparando documento…';
 let saved=false;
 try{
  const result=await db.rpc('parking_stay_payment_document',{p_reservation_id:stay.id,p_entity_type:payment.entity_type,p_entity_id:payment.entity_id,p_kind:kind,p_customer:customer});
  if(result.error)throw result.error;saved=true;
  if(kind==='ticket'||result.data.doc_kind==='simplified')await printParkingThermal(buildSimplifiedTicket(result.data));
  else await showParkingInvoicePreview(result.data);
  if(status)status.textContent='Documento preparado. No se ha realizado ningún nuevo cobro.';
 }catch(e){if(status)status.textContent=(saved?'Documento guardado; vuelve a pulsar para reimprimirlo. ':'No se pudo preparar el documento. ')+e.message}
 finally{target.dataset.busy='false';buttons.forEach(b=>b.disabled=false);if(stayTicketReportRows.some(x=>x.id===stay.id))await loadStayTicketPayments(stay.id)}
}
