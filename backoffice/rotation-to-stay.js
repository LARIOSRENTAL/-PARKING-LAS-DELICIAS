/* Conversion and both collections commit together in one database transaction. */
let rotationConversionBusy=false,rotationConversionQuote=null,rotationConversionSource=null;
function conversionCodes(){const method=opsEl('convertPayment').value;if(!method.startsWith('hotel_voucher'))return [];return method==='hotel_voucher'?parseHotelVoucherCodes(opsEl('convertVoucherCodes').value):opsEl('convertOldCodes').value.split(/[\n,;]+/).map(s=>s.trim().toUpperCase()).filter(Boolean)}
function conversionPaymentChanged(){const method=opsEl('convertPayment').value,hotel=method.startsWith('hotel_voucher');opsEl('convertCurrentWrap').hidden=method!=='hotel_voucher';opsEl('convertOldWrap').hidden=method!=='hotel_voucher_old';const type=opsEl('convertType');type.disabled=false;updateConvertSpots();opsEl('convertPrint').checked=method==='card';opsEl('convertPrint').disabled=method==='card';updateConversionReturn();}
let conversionPriceSerial=0;
updateConversionReturn=function(){
 if(!opsEl('convertDays')||!rotationConversionSource)return;
 const hotel=opsEl('convertPayment').value.startsWith('hotel_voucher'),field=opsEl('convertDays');
 field.readOnly=hotel;
 if(hotel){let count=0;try{count=conversionCodes().length;}catch(e){}field.value=count;}
 else if(Number(field.value)<1)field.value=1;
 const days=Number(field.value);
 opsEl('convertExit').value=days>0?fmt(new Date(new Date(rotationConversionSource.entry_at).getTime()+days*86400000).toISOString()):'';
 rotationConversionQuote=null;updateConversionLivePrice();return days;
};
async function updateConversionLivePrice(){
 const serial=++conversionPriceSerial,price=opsEl('convertLivePrice');if(!price)return;
 const hotel=opsEl('convertPayment').value.startsWith('hotel_voucher');price.hidden=hotel;if(hotel){price.textContent='';return;}
 const days=Number(opsEl('convertDays').value);if(!Number.isInteger(days)||days<1||days>24){price.textContent='Selecciona entre 1 y 24 días';return;}
 price.textContent='Calculando precio…';try{const r=await db.rpc('parking_stay_price',{p_vehicle_type_id:opsEl('convertType').value,p_days:days,p_entry_at:rotationConversionSource.entry_at});if(serial!==conversionPriceSerial||!opsEl('convertLivePrice'))return;if(r.error)throw r.error;if(r.data===null)throw Error('Tarifa no disponible');price.textContent='Precio estancia: '+money(r.data);}catch(e){if(serial===conversionPriceSerial&&opsEl('convertLivePrice'))price.textContent=e.message;}
}
showRotationToStay=async function(){if(!currentRotationSession)return;rotationConversionSource={...currentRotationSession};rotationConversionQuote=null;rotationConversionBusy=false;
const body='<style>#parkingOpsModal:has(.conversionForm){padding:8px}#parkingOpsModal:has(.conversionForm) .modalCard{width:min(1050px,100%);max-width:1050px!important}#parkingOpsModal:has(.conversionForm) .modalHead{padding:10px 16px}#parkingOpsModal:has(.conversionForm) h3{margin:0;font-size:20px}#parkingOpsModal:has(.conversionForm) .modalBody{padding:10px 16px}#parkingOpsModal:has(.conversionForm) .field{margin:0 0 8px}#parkingOpsModal:has(.conversionForm) label{font-size:13px;margin-bottom:3px}#parkingOpsModal:has(.conversionForm) input,#parkingOpsModal:has(.conversionForm) select,#parkingOpsModal:has(.conversionForm) textarea{padding:7px;font-size:15px;width:100%;box-sizing:border-box}#parkingOpsModal:has(.conversionForm) textarea{height:62px;min-height:0}#parkingOpsModal:has(.conversionForm) small{font-size:12px}#parkingOpsModal:has(.conversionForm) p{margin:4px 0 8px}#parkingOpsModal:has(.conversionForm) .grid2{gap:8px 16px}#parkingOpsModal:has(.conversionForm) [hidden]{display:none!important}#parkingOpsModal:has(.conversionForm) .actions{margin-top:8px!important}#parkingOpsModal:has(.conversionForm) .btn{padding:8px 12px}#parkingOpsModal:has(.conversionForm) #convertPrint{width:auto}</style><div class="conversionForm"><p>Entrada original: <b>'+fmt(rotationConversionSource.entry_at)+'</b></p><div id="convertStep1"><div class="grid2"><div class="field"><label>Forma de pago</label><select id="convertPayment" onchange="conversionPaymentChanged()"><option value="hotel_voucher">Bonos hotel</option><option value="hotel_voucher_old">Bonos hotel antiguos</option><option value="cash">Efectivo</option><option value="card">Tarjeta</option></select></div><div class="field"><label>Días desde la entrada original</label><input id="convertDays" type="number" min="1" max="24" value="1" oninput="updateConversionReturn()"></div><div class="field"><label>Categoría</label><select id="convertType" onchange="updateConvertSpots();updateConversionReturn()">'+vehicleTypes.map(t=>'<option value="'+t.id+'" '+(t.code==='TURISMO'?'selected':'')+'>'+esc(t.name)+'</option>').join('')+'</select></div><div class="field"><label>Plaza</label><select id="convertSpot"></select></div><div class="field"><label>Marca / modelo</label><input id="convertModel" required></div><div class="field"><label>Fecha fin de estancia</label><input id="convertExit" readonly></div></div><p id="convertLivePrice" role="status" style="font-size:20px;font-weight:bold" hidden></p><div id="convertCurrentWrap">'+hotelVoucherFields('convert')+'</div><div id="convertOldWrap" hidden><label>Bonos antiguos · un número por bono</label><textarea id="convertOldCodes" rows="2" oninput="updateConversionReturn()" placeholder="Separa los números con comas o saltos de línea"></textarea></div><small>El tiempo que no cubran los bonos se cobra por Rotación, hasta la devolución seleccionada o la hora actual si ya ha pasado.</small></div><div id="convertStep2" hidden><h3 id="convertChargeTitle"></h3><p id="convertQuoteSummary"></p><div id="convertDifferenceWrap"><label>Pago de la diferencia de Rotación</label><select id="convertDifferenceMethod" onchange="conversionDifferenceChanged()"><option value="cash">Efectivo</option><option value="card">Tarjeta</option></select></div></div><label><input type="checkbox" id="convertPrint"> Imprimir ticket de cobro</label></div>';
opsModal('Mandar a estancia · '+rotationConversionSource.plate,body,'<button class="btn light" id="convertBack" hidden onclick="conversionBack()">Volver</button><button id="convertConfirm" class="btn green" onclick="confirmRotationToStay()">Continuar</button>');conversionPaymentChanged();opsEl('convertVoucherCodes').focus();};
function conversionDifferenceChanged(){const card=opsEl('convertDifferenceMethod').value==='card'||opsEl('convertPayment').value==='card';opsEl('convertPrint').checked=card;opsEl('convertPrint').disabled=card;}
function conversionBack(){rotationConversionQuote=null;opsEl('convertStep1').hidden=false;opsEl('convertStep2').hidden=true;opsEl('convertBack').hidden=true;opsEl('convertConfirm').textContent='Continuar';conversionPaymentChanged();}
function conversionArgs(commit){return {p_session_id:rotationConversionSource.id,p_vehicle_type_id:opsEl('convertType').value,p_spot_id:opsEl('convertSpot').value,p_days:Number(opsEl('convertDays').value),p_model:opsEl('convertModel').value.trim(),p_method:opsEl('convertPayment').value,p_codes:conversionCodes(),p_difference_method:opsEl('convertDifferenceMethod').value,p_print_ticket:opsEl('convertPrint').checked,p_commit:commit,p_expected_amount:commit?Number(rotationConversionQuote.total):null};}
confirmRotationToStay=async function(){if(rotationConversionBusy)return;const button=opsEl('convertConfirm');rotationConversionBusy=true;button.disabled=true;let created=null;try{
if(!rotationConversionQuote){const r=await db.rpc('parking_convert_rotation_stay',conversionArgs(false));if(r.error)throw r.error;if(r.data.already_converted)throw Error('Este ticket ya está convertido. Actualiza los listados.');rotationConversionQuote=r.data;opsEl('convertStep1').hidden=true;opsEl('convertStep2').hidden=false;opsEl('convertBack').hidden=false;opsEl('convertDifferenceWrap').hidden=Number(r.data.difference_amount)<=0;opsEl('convertChargeTitle').textContent=Number(r.data.difference_amount)>0?'Cobrar diferencia por Rotación':'Confirmar estancia';opsEl('convertQuoteSummary').textContent=opsEl('convertPayment').value.startsWith('hotel_voucher')?(Number(r.data.difference_amount)>0?'Diferencia de Rotación: '+money(r.data.difference_amount):'Estancia cubierta por los bonos indicados.'):'Precio estancia: '+money(r.data.stay_amount);button.textContent='Confirmar y crear estancia';conversionDifferenceChanged();return;}
const source=rotationConversionSource,spotCode=spots.find(s=>s.id===opsEl('convertSpot').value)?.code||'',r=await db.rpc('parking_convert_rotation_stay',conversionArgs(true));if(r.error){rotationConversionQuote=null;throw r.error;}created=r.data.id;closeParkingOpsModal();closeRotationCheckout();clearRotationDisplay();try{await printConvertedStayVoucher(created,spotCode,source.entry_at);for(const doc of [r.data.receipt,r.data.rotation_receipt])if(doc)await printParkingThermal(buildSimplifiedTicket(doc));}catch(e){alert('Estancia guardada. Error al imprimir: '+e.message+'. No repitas la conversión.');}await refreshAll();await loadParkingHotels();showArea('stays');currentStayTab='inside';document.querySelectorAll('#staysNav button').forEach(b=>b.classList.toggle('active',b.dataset.tab==='inside'));document.querySelectorAll('.section').forEach(e=>e.classList.toggle('active',e.id==='inside'));await loadInside();
}catch(e){if(created)alert('Estancia creada. Actualiza el listado; no repitas la conversión. '+e.message);else {opsEl('parkingOpsMessage').textContent=e.message;if(!rotationConversionQuote){opsEl('convertStep1').hidden=false;opsEl('convertStep2').hidden=true;opsEl('convertBack').hidden=true;button.textContent='Continuar';}}}finally{rotationConversionBusy=false;button.disabled=false;}};

/* Keyboard-wedge readers end a rapid barcode with Enter or Tab. Capture at
   window level so an unrelated focused input cannot consume that scan. */
let conversionScan=null;
window.addEventListener('keydown',event=>{
 const method=opsEl('convertPayment')?.value,step=opsEl('convertStep1'),modal=opsEl('parkingOpsModal');
 if(!step||step.hidden||modal?.classList.contains('hidden')||!method?.startsWith('hotel_voucher')){conversionScan=null;return;}
 if(event.key==='Shift')return;
 if(event.ctrlKey||event.metaKey||event.altKey||event.isComposing){conversionScan=null;return;}
 const now=performance.now();
 if(event.key==='Enter'||event.key==='Tab'){
  const scan=conversionScan;conversionScan=null;
  const valid=scan&&scan.text.length>=3&&now-scan.last<100&&scan.last-scan.started<=Math.max(120,scan.text.length*45)&&(method==='hotel_voucher'?/^H-?[1-9][0-9]*$/i.test(scan.text):/^[A-Z0-9][A-Z0-9-]*$/i.test(scan.text));
  if(!valid)return;
  event.preventDefault();event.stopImmediatePropagation();
  const field=opsEl(method==='hotel_voucher'?'convertVoucherCodes':'convertOldCodes');
  const target=scan.target;
  if(target&&typeof target.value==='string'&&scan.start!==null){const expected=scan.before.slice(0,scan.start)+scan.text+scan.before.slice(scan.end);if(target.value.toUpperCase()===expected.toUpperCase())target.value=scan.before;}
  let code=scan.text.toUpperCase();if(method==='hotel_voucher')code=parseHotelVoucherCodes(code)[0];
  let existing=[];try{existing=conversionCodes();}catch(e){}
  if(!existing.includes(code))field.value=field.value.trim()+(field.value.trim()?'\n':'')+code;
  field.focus();field.setSelectionRange(field.value.length,field.value.length);
  if(method==='hotel_voucher')scheduleHotelVoucherResolve('convert');else updateConversionReturn();
  return;
 }
 if(event.key.length!==1){conversionScan=null;return;}
 const target=event.target;
 if(!conversionScan||now-conversionScan.last>80||conversionScan.target!==target){conversionScan={text:'',target,before:typeof target.value==='string'?target.value:'',start:target.selectionStart??null,end:target.selectionEnd??null,started:now,last:now};}
 conversionScan.text+=event.key;conversionScan.last=now;
},true);
