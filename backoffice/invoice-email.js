/* Manual customer invoice email, attached as the standard A4 invoice PDF. */
(function(){
 let invoiceForEmail=null,invoiceEmailBusy=false;
 function ensureInvoiceEmailModal(){
  let modal=document.getElementById('parkingInvoiceEmailModal');if(modal)return modal;
  modal=document.createElement('div');modal.id='parkingInvoiceEmailModal';modal.className='modalBack hidden';modal.style.zIndex='14000';
  modal.innerHTML='<div class="modalCard" role="dialog" aria-modal="true" aria-labelledby="parkingInvoiceEmailTitle" style="max-width:560px;width:94vw"><div class="modalHead"><h3 id="parkingInvoiceEmailTitle">Enviar factura por correo</h3><button class="btn light" onclick="closeParkingInvoiceEmail()">Cerrar</button></div><div class="modalBody"><p id="parkingInvoiceEmailInfo"></p><div class="field"><label for="parkingInvoiceRecipient">Correo electrónico del cliente</label><input id="parkingInvoiceRecipient" type="email" maxlength="254" autocomplete="email" placeholder="cliente@ejemplo.com"></div><p id="parkingInvoiceEmailStatus" role="status"></p><div class="actions" style="justify-content:flex-end"><button class="btn light" onclick="closeParkingInvoiceEmail()">Cancelar</button><button id="parkingInvoiceEmailSend" class="btn green" onclick="sendParkingInvoiceToCustomer()">Enviar factura</button></div></div></div>';
  document.body.appendChild(modal);return modal;
 }
 window.closeParkingInvoiceEmail=function(){if(invoiceEmailBusy)return;document.getElementById('parkingInvoiceEmailModal')?.classList.add('hidden')};
 async function lookupEmail(invoice){
  if(invoice.customer_email||invoice.email)return invoice.customer_email||invoice.email;
  if(!invoice.customer_tax_id)return '';
  const r=await db.rpc('parking_invoice_customer_email',{p_tax_id:invoice.customer_tax_id});if(r.error)throw r.error;return r.data||'';
 }
 async function sendUsingEmail(invoice,email,status,button){
  if(invoiceEmailBusy)return;
  invoiceEmailBusy=true;button.disabled=true;status.textContent='Generando el PDF A4 y enviando el correo desde oficina@parkinglasdelicias.com…';
  try{
   const saved=await db.rpc('parking_save_invoice_customer_email',{p_tax_id:invoice.customer_tax_id,p_email:email});if(saved.error)throw saved.error;
   const result=await db.functions.invoke('bank-invoice-mail',{body:{action:'send_customer',invoice_id:invoice.id,recipient:email,pending_payment:invoice.pending_payment===true||invoice.payment_status==='pending'}});
   if(result.error)throw result.error;
   if(!result.data?.emailSent)throw new Error(result.data?.error||'El servicio de correo no confirmó el envío.');
   status.textContent='Factura '+(result.data.invoiceNumber||invoice.number||'')+' enviada a '+email+'.';
  }catch(e){status.textContent='No se pudo enviar la factura: '+e.message}
  finally{invoiceEmailBusy=false;button.disabled=false}
 }
 window.sendParkingInvoiceToCustomer=async function(){
  const invoice=invoiceForEmail,modal=document.getElementById('parkingInvoiceEmailModal');if(!invoice||!modal)return;
  const input=document.getElementById('parkingInvoiceRecipient'),status=document.getElementById('parkingInvoiceEmailStatus'),button=document.getElementById('parkingInvoiceEmailSend'),email=input.value.trim().toLowerCase();
  if(!email||!/^\S+@\S+\.\S+$/.test(email)){status.textContent='Introduce un correo electrónico válido.';input.focus();return}
  await sendUsingEmail(invoice,email,status,button);
 };
 window.openParkingInvoiceEmail=async function(invoice){
  invoiceForEmail=invoice;const modal=ensureInvoiceEmailModal(),input=document.getElementById('parkingInvoiceRecipient'),status=document.getElementById('parkingInvoiceEmailStatus'),button=document.getElementById('parkingInvoiceEmailSend');
  document.getElementById('parkingInvoiceEmailInfo').textContent='Factura '+(invoice.display_number||invoice.number||'')+(invoice.pending_payment||invoice.payment_status==='pending'?' · pendiente de pago':'');
  input.value='';status.textContent='';modal.classList.remove('hidden');button.disabled=true;status.textContent='Buscando el correo guardado en la ficha del cliente…';
  try{input.value=await lookupEmail(invoice);status.textContent=input.value?'Correo encontrado en la ficha. Al continuar, la factura se enviará directamente.':'La ficha no tiene correo electrónico. Escribe el correo y confirma el envío.'}
  catch(e){status.textContent='No se pudo consultar la ficha: '+e.message+' Puedes indicar el correo manualmente.'}
  button.disabled=false;input.focus();
  if(input.value)await sendUsingEmail(invoice,input.value,status,button);
 }
 const originalPreview=window.showParkingInvoicePreview;
 if(typeof originalPreview==='function'){
  window.showParkingInvoicePreview=function(invoice){
   originalPreview(invoice);
   const modal=document.getElementById('parkingInvoicePreview'),toolbar=modal?.firstElementChild;
   if(!toolbar)return;
   let button=toolbar.querySelector('#parkingInvoiceEmailOpen');
   if(!button){button=document.createElement('button');button.id='parkingInvoiceEmailOpen';button.className='btn light';button.textContent='Enviar por correo';}
   button.onclick=()=>window.openParkingInvoiceEmail(parkingInvoicePreviewData||invoice);
   const close=toolbar.querySelector('button[onclick*="closeParkingInvoicePreview"]');(close?.parentElement||toolbar).insertBefore(button,close||null);
  };
 }
})();
