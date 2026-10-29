/* Issued-invoice customers: read-only directory, shared by active staff roles. */
let invoiceClientsOffset=0,invoiceClientsTotal=0,invoiceClientsRequest=0,invoiceClientsTimer=null,invoiceClientsFocus=null,invoiceClientRows=new Map(),invoiceCustomerEditBusy=false;
function openInvoiceCustomers(){
 if(!currentProfile)return;
 invoiceClientsFocus=document.activeElement;
 let modal=document.getElementById('invoiceCustomersModal');
 if(!modal){modal=document.createElement('div');modal.id='invoiceCustomersModal';modal.className='modalBack hidden';modal.style.zIndex='12000';modal.innerHTML='<div class="modalCard" role="dialog" aria-modal="true" aria-labelledby="invoiceCustomersTitle" style="max-width:1120px;width:96vw"><div class="modalHead"><h3 id="invoiceCustomersTitle">Clientes factura · todos los registrados</h3><button class="btn light" onclick="closeInvoiceCustomers()">Cerrar</button></div><div class="modalBody"><div class="field"><label for="invoiceCustomersSearch">Buscar por nombre de cliente o matrícula</label><input id="invoiceCustomersSearch" maxlength="200" autocomplete="off" placeholder="Nombre del cliente o matrícula"></div><p id="invoiceCustomersStatus" class="muted" role="status"></p><div id="invoiceCustomersRows"></div><div class="actions" style="justify-content:flex-end;margin-top:12px"><button id="invoiceCustomersPrevious" class="btn light" onclick="changeInvoiceCustomersPage(-1)">Anterior</button><button id="invoiceCustomersNext" class="btn light" onclick="changeInvoiceCustomersPage(1)">Siguiente</button></div></div></div>';document.body.appendChild(modal);modal.addEventListener('click',e=>{if(e.target===modal)closeInvoiceCustomers();});document.getElementById('invoiceCustomersSearch').addEventListener('input',()=>{clearTimeout(invoiceClientsTimer);invoiceClientsOffset=0;invoiceClientsTimer=setTimeout(loadInvoiceCustomers,250);});}
 modal.classList.remove('hidden');document.getElementById('invoiceCustomersSearch').value='';invoiceClientsOffset=0;loadInvoiceCustomers();document.getElementById('invoiceCustomersSearch').focus();
}
function closeInvoiceCustomers(){clearTimeout(invoiceClientsTimer);invoiceClientsRequest++;document.getElementById('invoiceCustomersModal')?.classList.add('hidden');invoiceClientsFocus?.focus?.();}
function changeInvoiceCustomersPage(direction){clearTimeout(invoiceClientsTimer);invoiceClientsOffset=Math.max(0,invoiceClientsOffset+direction*100);loadInvoiceCustomers();}
async function loadInvoiceCustomers(){
 const request=++invoiceClientsRequest,status=document.getElementById('invoiceCustomersStatus'),rows=document.getElementById('invoiceCustomersRows'),previous=document.getElementById('invoiceCustomersPrevious'),next=document.getElementById('invoiceCustomersNext');
 if(!status)return;status.textContent='Consultando clientes…';previous.disabled=next.disabled=true;
 try{const r=await db.rpc('parking_invoice_customer_list',{p_query:document.getElementById('invoiceCustomersSearch').value.trim(),p_offset:invoiceClientsOffset,p_limit:100});if(request!==invoiceClientsRequest)return;if(r.error)throw r.error;
 const data=r.data,list=data.customers||[];invoiceClientsTotal=Number(data.total||0);invoiceClientRows=new Map(list.map(c=>[c.client_key,c]));
 status.textContent=invoiceClientsTotal+' cliente(s)'+(invoiceClientsTotal?' · '+(invoiceClientsOffset+1)+'–'+(invoiceClientsOffset+list.length):'');
 rows.onclick=e=>{const button=e.target.closest('[data-customer-key]');if(button)openInvoiceCustomerProfile(button.dataset.customerKey);};
 rows.innerHTML=list.length?'<div class="tableWrap"><table class="tbl" style="min-width:720px"><thead><tr><th>Cliente / razón social</th><th>NIF / CIF</th><th>Domicilio</th><th>Matrículas</th></tr></thead><tbody>'+list.map(c=>'<tr><td><button class="subscriberNameLink" data-customer-key="'+esc(c.client_key)+'">'+esc(c.name)+'</button><small>'+(c.subscriber_id?'Abonado · '+(c.can_manage_subscriber?'Edición por gerente / administrador':'Solo consulta'):'Cliente registrado · Editar ficha')+'</small></td><td>'+esc(c.tax_id||'—')+'</td><td>'+esc(c.address||'—')+'</td><td>'+(c.plates?.length?c.plates.map(p=>'<span class="tag gray" style="margin:2px">'+esc(p)+'</span>').join(' '):'—')+'</td></tr>').join('')+'</tbody></table></div>':'<div class="msg">No hay clientes registrados que coincidan con la búsqueda.</div>';
 previous.disabled=invoiceClientsOffset===0;next.disabled=!data.has_more;
 }catch(e){if(request!==invoiceClientsRequest)return;status.textContent='No se pudieron cargar los clientes: '+e.message;rows.replaceChildren();}
}

async function openInvoiceCustomerProfile(key){
 const customer=invoiceClientRows.get(key);if(!customer)return;
 if(customer.subscriber_id&&customer.can_manage_subscriber){
  try{document.getElementById('invoiceCustomersStatus').textContent='Abriendo ficha del abonado…';await loadMonthlySubscribers();if(!monthlySubscribers.some(s=>s.id===customer.subscriber_id))throw Error('No se pudo cargar la ficha del abonado.');closeInvoiceCustomers();openSubscriberProfile(customer.subscriber_id);}catch(e){document.getElementById('invoiceCustomersStatus').textContent=e.message;}return;
 }
 let modal=document.getElementById('invoiceCustomerEditModal');
 if(!modal){modal=document.createElement('div');modal.id='invoiceCustomerEditModal';modal.className='modalBack hidden';modal.style.zIndex='13000';modal.innerHTML='<div class="modalCard" role="dialog" aria-modal="true" aria-labelledby="invoiceCustomerEditTitle" style="max-width:720px;width:94vw"><div class="modalHead"><h3 id="invoiceCustomerEditTitle">Ficha de cliente</h3><button class="btn light" onclick="closeInvoiceCustomerProfile()">Cerrar</button></div><div class="modalBody"><p id="invoiceCustomerEditPermission" class="muted"></p><div class="field"><label for="invoiceCustomerEditName">Nombre / razón social</label><input id="invoiceCustomerEditName" maxlength="200"></div><div class="field"><label for="invoiceCustomerEditTax">NIF / CIF</label><input id="invoiceCustomerEditTax" maxlength="40"></div><div class="field"><label for="invoiceCustomerEditAddress">Domicilio completo</label><textarea id="invoiceCustomerEditAddress" rows="3" maxlength="500"></textarea></div><div class="field"><label for="invoiceCustomerEditPlates">Matrículas (una por línea o separadas por comas)</label><textarea id="invoiceCustomerEditPlates" rows="3"></textarea></div><p id="invoiceCustomerEditStatus" role="status"></p><div class="actions" style="justify-content:flex-end"><button class="btn light" onclick="closeInvoiceCustomerProfile()">Cerrar</button><button class="btn green" id="invoiceCustomerEditSave" onclick="saveInvoiceCustomerProfile()">Guardar cambios</button></div></div></div>';document.body.appendChild(modal);}
 modal.dataset.customerKey=key;const readOnly=!!customer.subscriber_id||customer.can_edit===false;
 document.getElementById('invoiceCustomerEditTitle').textContent=readOnly?'Ficha de abonado · solo consulta':'Editar cliente';
 document.getElementById('invoiceCustomerEditPermission').textContent=readOnly?'Los datos de abonados solo pueden modificarlos el gerente y el administrador.':'Los cambios se usarán al seleccionar el cliente para nuevas facturas.';
 for(const [id,value]of [['Name',customer.name],['Tax',customer.tax_id],['Address',customer.address],['Plates',(customer.plates||[]).join('\n')]]){const field=document.getElementById('invoiceCustomerEdit'+id);field.value=value||'';field.readOnly=readOnly;}
 document.getElementById('invoiceCustomerEditStatus').textContent='';document.getElementById('invoiceCustomerEditSave').classList.toggle('hidden',readOnly);document.getElementById('invoiceCustomerEditSave').disabled=false;
 modal.classList.remove('hidden');document.getElementById('invoiceCustomerEditName').focus();
}
function closeInvoiceCustomerProfile(){if(invoiceCustomerEditBusy)return;document.getElementById('invoiceCustomerEditModal')?.classList.add('hidden');document.getElementById('invoiceCustomersSearch')?.focus();}
async function saveInvoiceCustomerProfile(){
 if(invoiceCustomerEditBusy)return;const modal=document.getElementById('invoiceCustomerEditModal'),customer=invoiceClientRows.get(modal.dataset.customerKey),status=document.getElementById('invoiceCustomerEditStatus'),button=document.getElementById('invoiceCustomerEditSave');
 if(!customer||customer.subscriber_id||customer.can_edit===false)return;
 const data={name:document.getElementById('invoiceCustomerEditName').value.trim(),tax_id:document.getElementById('invoiceCustomerEditTax').value.trim(),address:document.getElementById('invoiceCustomerEditAddress').value.trim(),plates:document.getElementById('invoiceCustomerEditPlates').value.split(/[\n,;]+/).map(v=>v.trim()).filter(Boolean)};
 if(data.name.length<2){status.textContent='Introduce el nombre del cliente.';return;}
 invoiceCustomerEditBusy=true;button.disabled=true;status.textContent='Guardando…';
 try{const r=await db.rpc('parking_save_customer_profile',{p_source_kind:customer.source_kind,p_source_id:customer.source_id,p_data:data});if(r.error)throw r.error;modal.classList.add('hidden');await loadInvoiceCustomers();document.getElementById('invoiceCustomersSearch').focus();}catch(e){status.textContent=e.message;}finally{invoiceCustomerEditBusy=false;button.disabled=false;}
}
window.addEventListener('keydown',e=>{
 const editor=document.getElementById('invoiceCustomerEditModal'),modal=document.getElementById('invoiceCustomersModal'),editing=editor&&!editor.classList.contains('hidden')&&editor.contains(e.target);
 if(!editing&&(!modal||modal.classList.contains('hidden')||!modal.contains(e.target)))return;
 e.stopImmediatePropagation();
 if(e.key==='Escape'){e.preventDefault();if(editing)closeInvoiceCustomerProfile();else closeInvoiceCustomers();}
 else if(e.key==='Enter'&&e.target.id==='invoiceCustomersSearch'){e.preventDefault();clearTimeout(invoiceClientsTimer);invoiceClientsOffset=0;loadInvoiceCustomers();}
},true);
