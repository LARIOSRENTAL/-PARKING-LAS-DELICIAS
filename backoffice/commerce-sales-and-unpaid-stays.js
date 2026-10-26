/* Ventas de bonos comercio y reservas con cobro separado. */
let pendingStayCreateId=null,commerceSaleBusy=false;
let commerceSaleRequestId=null;
function openCommerceSale(){
 commerceSaleRequestId=crypto.randomUUID();
 opsModal('Venta bonos comercio','<div class="grid2"><div class="field"><label for="commerceSalePackages">Cantidad de paquetes de bonos comercio</label><input id="commerceSalePackages" type="number" min="1" step="1" value="1" oninput="updateCommerceSalePrice()"><small id="commerceSalePackageLabel">1 paquete de bonos comercio · 25 tickets</small></div><div class="field"><label for="commerceSaleCategory">Tipo de vehículo</label><select id="commerceSaleCategory" onchange="updateCommerceSalePrice()"><option value="TURISMO">Turismos · 25 tickets = 20 €</option><option value="XL">Furgoneta / XL · 25 tickets = 25 €</option></select></div></div><div class="grid2"><div class="field"><label>Total de tickets</label><input id="commerceSaleQty" type="number" value="25" readonly></div><div class="field"><label>Precio total (€)</label><input id="commerceSalePrice" type="number" value="20.00" readonly></div></div><div class="field"><label>Forma de pago</label><select id="commerceSaleMethod" onchange="commerceSalePaymentChanged()"><option value="cash">Efectivo</option><option value="card">Tarjeta</option></select></div><label id="commerceSaleTicketWrap"><input id="commerceSaleTicket" type="checkbox" style="width:auto"> Imprimir ticket</label><div style="margin-top:14px"><label><input id="commerceSaleInvoice" type="checkbox" style="width:auto" onchange="commerceSaleInvoiceChanged()"> Generar factura</label></div><div id="commerceSaleInvoiceFields" class="hidden" style="margin-top:14px"><div class="field"><label>Nombre / razón social</label><input id="commerceCustomerName" maxlength="200"></div><div class="grid2"><div class="field"><label>NIF / CIF</label><input id="commerceCustomerTax" maxlength="40"></div><div class="field"><label>Teléfono (opcional)</label><input id="commerceCustomerPhone" type="tel" maxlength="40"></div></div><div class="field"><label>Domicilio (calle y número)</label><input id="commerceCustomerStreet" maxlength="350"></div><div class="grid2"><div class="field"><label>Código postal</label><input id="commerceCustomerPostal" maxlength="20"></div><div class="field"><label>Localidad</label><input id="commerceCustomerCity" maxlength="100"></div></div><div class="field"><label>Email (opcional)</label><input id="commerceCustomerEmail" type="email" maxlength="200"></div></div>','<button class="btn green" id="commerceSaleConfirm" onclick="sellCommerceBonuses()">Confirmar venta</button>');
 updateCommerceSalePrice();commerceSalePaymentChanged();
}
function updateCommerceSalePrice(){const n=Number(opsEl('commerceSalePackages').value),valid=Number.isSafeInteger(n)&&n>0&&n<=1000000;opsEl('commerceSaleQty').value=valid?n*25:'';opsEl('commerceSalePackageLabel').textContent=valid?n+(n===1?' paquete de bonos comercio':' paquetes de bonos comercio')+' · '+(n*25)+' tickets':'Cada paquete de bonos comercio contiene 25 tickets';opsEl('commerceSalePrice').value=valid?(n*(opsEl('commerceSaleCategory').value==='XL'?25:20)).toFixed(2):'';opsEl('commerceSaleConfirm').disabled=!valid||commerceSaleBusy;opsEl('parkingOpsMessage').textContent=valid?'':'Introduce una cantidad entera de paquetes mayor que cero.'}
function commerceSalePaymentChanged(){opsEl('commerceSaleTicket').checked=opsEl('commerceSaleMethod').value==='card'}
function commerceSaleInvoiceChanged(){opsEl('commerceSaleInvoiceFields').classList.toggle('hidden',!opsEl('commerceSaleInvoice').checked)}
function commerceInvoiceCustomer(){if(!opsEl('commerceSaleInvoice').checked)return null;const val=id=>opsEl(id).value.trim(),name=val('commerceCustomerName'),tax_id=val('commerceCustomerTax'),street=val('commerceCustomerStreet'),postal_code=val('commerceCustomerPostal'),city=val('commerceCustomerCity'),email=val('commerceCustomerEmail'),phone=val('commerceCustomerPhone');if(!name||!tax_id||!street||!postal_code||!city)throw Error('Completa nombre, NIF/CIF, domicilio, código postal y localidad para la factura.');if(email&&!opsEl('commerceCustomerEmail').checkValidity())throw Error('Revisa el email del cliente.');return{name,tax_id,address:[street,postal_code,city].join(', '),street,postal_code,city,email,phone}}
async function sellCommerceBonuses(){
 if(commerceSaleBusy)return;const button=opsEl('commerceSaleConfirm');let saved=false;
 try{const packages=Number(opsEl('commerceSalePackages').value);if(!Number.isSafeInteger(packages)||packages<1||packages>1000000)throw Error('Introduce una cantidad entera válida.');const customer=commerceInvoiceCustomer();commerceSaleBusy=true;button.disabled=true;
 const r=await db.rpc('parking_sell_commerce_packages',{p_request_id:commerceSaleRequestId,p_packages:packages,p_category:opsEl('commerceSaleCategory').value,p_payment_method:opsEl('commerceSaleMethod').value,p_print_ticket:opsEl('commerceSaleTicket').checked,p_invoice_customer:customer});if(r.error)throw r.error;saved=true;commerceSaleRequestId=null;closeParkingOpsModal();
 if(r.data.invoice)showParkingInvoicePreview(r.data.invoice);
 if(r.data.receipt){try{await printParkingThermal(buildSimplifiedTicket(r.data.receipt))}catch(e){alert('Venta guardada. No se imprimió el ticket: '+e.message+'. Reimprímelo desde Tickets emitidos; no repitas la venta.')}}
 else if(!r.data.invoice)alert('Venta registrada: '+r.data.sale.quantity+' tickets · '+money(r.data.sale.amount_eur));
 }catch(e){if(saved)alert('La venta ya está guardada. '+e.message);else opsEl('parkingOpsMessage').textContent=e.message}finally{commerceSaleBusy=false;if(button)button.disabled=false}
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
 window.stayPaymentCurrent={id,spot,entry:r.entry_at,end:r.exit_at,type:r.vehicle_type_id,quoteSerial:0};
 opsModal('Cobrar reserva y dar entrada · '+r.reference,
 '<div class="grid2"><div class="field"><label>Días de estancia</label><input id="stayCollectDays" type="number" min="1" max="24" value="'+Number(r.duration_days)+'" onchange="updateCombinedStayPayment(true)"></div><div class="field"><label>Fecha de salida</label><input id="stayCollectEnd" type="datetime-local" onchange="stayEndChanged()"></div></div><div id="stayCollectPrice" style="font-size:22px;font-weight:bold"></div><div class="field"><label>Forma de pago</label><select id="stayCollectMethod" onchange="updateCombinedStayPayment()"><option value="cash">Efectivo</option><option value="card">Tarjeta</option><option value="hotel_voucher">Bonos hotel</option><option value="hotel_voucher_old">Bonos hotel antiguos</option></select></div><div id="stayCollectVouchers"></div><label id="stayCollectPrintWrap"><input type="checkbox" id="stayCollectPrint" style="width:auto"> Imprimir ticket de cobro</label>',
 '<button class="btn green" id="stayCollectConfirm" onclick="confirmCombinedStayPayment()">Cobrar y dar entrada</button>');
 updateCombinedStayPayment();
};
function combinedStayDateError(ctx,days,end){if(!Number.isInteger(days)||days<1||days>24)return 'La duración debe estar entre 1 y 24 días.';if(!Number.isFinite(end.getTime())||end<=new Date(ctx.entry))return 'La salida debe ser posterior a la entrada.';return ''}
function stayEndChanged(){const ctx=window.stayPaymentCurrent;if(!ctx)return;const end=new Date(opsEl('stayCollectEnd').value),days=Math.ceil((end-new Date(ctx.entry))/86400000);const error=combinedStayDateError(ctx,days,end);opsEl('parkingOpsMessage').textContent=error;if(error){++ctx.quoteSerial;ctx.quoteReady=false;opsEl('stayCollectConfirm').disabled=true;return}ctx.end=end.toISOString();opsEl('stayCollectDays').value=days;updateCombinedStayPayment(false)}
async function updateCombinedStayPayment(fromDays=false){
 const ctx=window.stayPaymentCurrent;if(!ctx)return;const serial=++ctx.quoteSerial;ctx.quoteReady=false;opsEl('stayCollectConfirm').disabled=true;
 const days=Number(opsEl('stayCollectDays').value),method=opsEl('stayCollectMethod').value;
 if(!Number.isInteger(days)||days<1||days>24){opsEl('parkingOpsMessage').textContent='La duración debe estar entre 1 y 24 días.';return}
 if(fromDays||!ctx.end)ctx.end=new Date(new Date(ctx.entry).getTime()+days*86400000).toISOString();
 const end=new Date(ctx.end),error=combinedStayDateError(ctx,days,end);opsEl('parkingOpsMessage').textContent=error;if(error)return;
 opsEl('stayCollectEnd').value=localInput(end);
 const voucher=method==='hotel_voucher'||method==='hotel_voucher_old';opsEl('stayCollectPrice').classList.toggle('hidden',voucher);opsEl('stayCollectPrintWrap').classList.toggle('hidden',voucher);
 const wrapper=opsEl('stayCollectVouchers'),previous=[...wrapper.querySelectorAll('input')].map(x=>x.value);
 wrapper.innerHTML=voucher?Array.from({length:days},(_,i)=>'<div class="field"><label>Bono hotel día '+(i+1)+'</label><input class="stayVoucherNumber" placeholder="'+(method==='hotel_voucher'?'Escanear bono':'Número del bono antiguo')+'" value="'+esc(previous[i]||'')+'"></div>').join(''):'';
 if(voucher){opsEl('stayCollectPrice').textContent='';ctx.quoteReady=true;opsEl('stayCollectConfirm').disabled=false;return}
 try{const quote=await db.rpc('parking_stay_price',{p_vehicle_type_id:ctx.type,p_days:days,p_entry_at:ctx.entry});if(ctx!==window.stayPaymentCurrent||serial!==ctx.quoteSerial)return;if(quote.error)throw quote.error;if(quote.data===null)throw Error('No existe tarifa para esa duración.');opsEl('stayCollectPrice').textContent=money(quote.data);ctx.quoteReady=true;opsEl('stayCollectConfirm').disabled=false}catch(e){if(serial===ctx.quoteSerial)opsEl('parkingOpsMessage').textContent='No se pudo calcular el precio: '+e.message}
}
async function confirmCombinedStayPayment(){
 const ctx=window.stayPaymentCurrent;if(!ctx||!ctx.quoteReady)return;
 const button=opsEl('stayCollectConfirm');if(button.disabled)return;button.disabled=true;
 try{
 const days=Number(opsEl('stayCollectDays').value),method=opsEl('stayCollectMethod').value,codes=[...document.querySelectorAll('.stayVoucherNumber')].map(x=>x.value.trim().toUpperCase());
 if(!Number.isInteger(days)||days<1||days>24)throw Error('Introduce una duración válida.');
 if(method.startsWith('hotel_voucher')&&(codes.length!==days||codes.some(x=>!x)||new Set(codes).size!==days))throw Error('Se necesita un número de bono distinto para cada día.');
 const result=await db.rpc('parking_pay_and_enter_stay_with_exit',{p_reservation_id:ctx.id,p_spot_id:ctx.spot,p_exit_at:ctx.end,p_method:method,p_codes:codes,p_print_ticket:opsEl('stayCollectPrint').checked});
 if(result.error)throw result.error;
 closeParkingOpsModal();await refreshAll();
 if(result.data.receipt)try{await printParkingThermal(buildSimplifiedTicket(result.data.receipt))}catch(e){alert('Entrada guardada; error al imprimir el ticket de cobro: '+e.message)}
 const res=reservations.find(x=>x.id===ctx.id);
 if(res)try{const ps=insideSessions.find(x=>x.reservation_id===ctx.id),sp=spots.find(x=>x.id===ctx.spot);await sendParkingPrint('stay',buildVoucherHtml(res,sp?.code||'',ps?.actual_entry_at||new Date().toISOString(),null))}catch(e){alert('Entrada y cobro guardados; error al imprimir el bono: '+e.message)}
 }catch(e){opsEl('parkingOpsMessage').textContent=e.message}finally{button.disabled=false}
}
