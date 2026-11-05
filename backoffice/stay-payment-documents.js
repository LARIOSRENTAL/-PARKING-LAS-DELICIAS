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
