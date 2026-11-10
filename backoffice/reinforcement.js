/* Acceso limitado de Refuerzo. La clave fija se valida en servidor y crea una sesión temporal. */
const reinforcementDb = window.supabase.createClient(
  'https://vcwbfljcqpqkmuzcpboi.supabase.co',
  'sb_publishable_is9ITJdQMbieunMWrv6g8A_2OdrO3xe',
  {auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}}
);
let reinforcementCode = '';
let reinforcementData = null;
let lastReinforcementTicket = null;
const reEl = id => document.getElementById(id);
function reinforcementFreeSpots(){return (reinforcementData?.spots||[]).filter(s=>(s.tariffs||[]).includes(reEl('tariff').value));}
function reinforcementSpotCode(value){return String(value||'').toUpperCase().replace(/[\s-]/g,'');}
function selectedReinforcementSpot(){
  const code=reinforcementSpotCode(reEl('spot').value),free=reinforcementFreeSpots();
  if(['A','M'].includes(code))return free.filter(s=>String(s.code).toUpperCase().split('-')[0]===code).sort((a,b)=>a.code.localeCompare(b.code,'es',{numeric:true}))[0];
  return free.find(s=>reinforcementSpotCode(s.code)===code);
}
function completeReinforcementZone(){
  const input=reEl('spot'),zone=reinforcementSpotCode(input.value);
  if(!['A','M'].includes(zone))return;
  const spot=selectedReinforcementSpot();
  if(!spot){reEl('spotHelp').textContent='No hay plazas '+zone+' disponibles para esta tarifa.';return;}
  input.value=spot.code;
  input.removeAttribute('list');
  input.setSelectionRange(input.value.length,input.value.length);
  reEl('spotHelp').textContent='Primera plaza libre: '+spot.code+' · No deja llaves.';
}
let reinforcementZoneTimer;
reEl('spot').addEventListener('input',event=>{
  clearTimeout(reinforcementZoneTimer);
  reEl('spot').setAttribute('list','spotOptions');
  reEl('spotHelp').textContent='Escribe una plaza; A o M selecciona automáticamente la primera libre.';
  if(!event.isComposing&&!String(event.inputType||'').startsWith('delete'))reinforcementZoneTimer=setTimeout(completeReinforcementZone,0);
});
reEl('spot').addEventListener('compositionend',()=>{clearTimeout(reinforcementZoneTimer);reinforcementZoneTimer=setTimeout(completeReinforcementZone,0);});
reEl('spot').addEventListener('change',()=>completeReinforcementZone());
reEl('spot').addEventListener('blur',()=>completeReinforcementZone());
reEl('spot').addEventListener('keydown',event=>{
  if(event.key==='Enter'){event.preventDefault();completeReinforcementZone();rotationEntry();}
});
let reinforcementSpotSerial=0;
async function reloadReinforcementSpots(){
  if(!reinforcementCode)return;
  const serial=++reinforcementSpotSerial;
  let options;try{options=await reCall('parking_reinforcement_options',{p_code:reinforcementCode});}catch(e){if(serial===reinforcementSpotSerial){reinforcementData={...reinforcementData,spots:[]};reEl('spotOptions').innerHTML='';}throw e;}
  if(serial!==reinforcementSpotSerial)return;
  const field=reEl('spot'),current=field.value,editing=document.activeElement===field;
  const previouslyListed=(reinforcementData?.spots||[]).some(s=>reinforcementSpotCode(s.code)===reinforcementSpotCode(current));
  reinforcementData=options;
  const free=reinforcementFreeSpots();
  const list=reEl('spotOptions'),markup=free.map(s=>'<option value="'+reEscape(s.code)+'"></option>').join('');
  if(list.innerHTML!==markup)list.innerHTML=markup;
  if(!editing)field.setAttribute('list','spotOptions');
  const selected=free.find(s=>reinforcementSpotCode(s.code)===reinforcementSpotCode(current));
  if(selected){if(!editing&&field.value!==selected.code)field.value=selected.code;}
  else if(previouslyListed){if(!editing)field.value='';reEl('spotHelp').textContent='La plaza '+current+' ya no está disponible. Selecciona otra plaza libre.';}

}
function reEscape(value) {
  return String(value == null ? '' : value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function reDate(value) {
  return value ? new Date(value).toLocaleString('es-ES', {dateStyle:'short',timeStyle:'short'}) : '';
}
function reShowMessage(text, error) {
  reEl('result').textContent = text || '';
  reEl('result').className = 'panel' + (error ? ' error' : '');
}
async function reCall(name, args) {
  const result = await reinforcementDb.rpc(name, args);
  if (result.error) throw new Error(result.error.message || 'No se pudo completar la operación.');
  return result.data;
}
async function enter() {
  const button = document.querySelector('#login button');
  const pin = reEl('code').value.trim();
  reEl('loginError').textContent = '';
  if (!pin) { reEl('loginError').textContent = 'Introduce la clave de acceso.'; return; }
  button.disabled = true;
  try {
    const session = await reCall('parking_reinforcement_login', {p_pin:pin});
    if (!session || !session.code) throw new Error('No se pudo iniciar la sesión de Refuerzo.');
    const data = await reCall('parking_reinforcement_options', {p_code:session.code});
    if (!data || !Array.isArray(data.tariffs) || !Array.isArray(data.types)) throw new Error('No se pudieron cargar las opciones de trabajo.');
    reinforcementCode = session.code;
    reinforcementData = data;
    reEl('tariff').addEventListener('change',()=>reloadReinforcementSpots().catch(e=>reShowMessage(e.message,true)));
    reEl('tariff').innerHTML = data.tariffs.map(t => '<option value="' + reEscape(t.code) + '">' + reEscape(t.name) + '</option>').join('');
    await reloadReinforcementSpots();
    reEl('type').innerHTML = data.types.map(t => '<option value="' + reEscape(t.id) + '">' + reEscape(t.name) + '</option>').join('');
    const xlType = data.types.find(t => String(t.code || t.name || '').trim().toUpperCase() === 'XL');
    if (xlType) reEl('type').value = String(xlType.id);
    reEl('days').innerHTML = Array.from({length:24}, (_,i) => '<option value="' + (i+1) + '">' + (i+1) + (i ? ' días' : ' día') + '</option>').join('');
    refreshReinforcementStayDates();
    reEl('login').classList.add('hidden');
    reEl('work').classList.remove('hidden');
    tab('rotation');
    reShowMessage('Acceso temporal activo. Las operaciones quedan registradas sin cobro.', false);
  } catch (error) {
    reEl('loginError').textContent = error.message || 'Código no válido o caducado.';
  } finally {
    button.disabled = false;
  }
}
function tab(name) {
  if(name==='stay'){refreshReinforcementStayDates();reloadReinforcementStaySpots().catch(e=>reShowMessage(e.message,true));}
  reEl('rotation').classList.toggle('hidden', name !== 'rotation');
  reEl('stay').classList.toggle('hidden', name !== 'stay');
  const plate=reEl(name==='stay'?'stayPlate':'plate');plate.focus();plate.select();
}
async function printReinforcementTicket(ticket) {
 lastReinforcementTicket=ticket;
 const html=buildRotationEntryTicket({...ticket,spot_code:ticket.spot,key_number:ticket.spot,leaves_keys:!!String(ticket.client_text||'').trim()||!['A','M'].includes(String(ticket.spot||'').split('-')[0]),client_text:ticket.client_text||'',entry_shift_code:'REFUERZO'});
 await sendParkingPrint('ticket',html,true);
 reShowMessage('Entrada registrada para '+ticket.plate+' · plaza '+ticket.spot+'. Ticket enviado a la impresora de oficina.',false);
}
async function rotationEntry() {
  const button = reEl('enterButton');
  if (button.disabled) return;
  const plate = reEl('plate').value.trim().toUpperCase();
  const selectedSpot = selectedReinforcementSpot();
  if (plate.length < 3) { reShowMessage('Indica una matrícula válida.', true); reEl('plate').focus(); return; }
  if (!selectedSpot) { reShowMessage('Selecciona una plaza disponible de las sugerencias.', true); reEl('spot').focus(); return; }
  const spot = selectedSpot.code;
  reEl('spot').value = spot;
  button.disabled = true;
  try {
    const result = await reCall('parking_reinforcement_enter', {
      p_code: reinforcementCode,
      p_tariff: reEl('tariff').value,
      p_plate: plate,
      p_spot: spot,
      p_client: reEl('client').value.trim().toUpperCase()
    });
    reShowMessage('Entrada registrada para ' + result.plate + ' · plaza ' + result.spot + '. Preparando ticket…', false);
    reEl('plate').value = '';
    result.client_text=reEl('client').value.trim();
    reEl('client').value = '';
    try{await printReinforcementTicket(result)}catch(e){reShowMessage('Entrada registrada para '+result.plate+'. No se imprimió: '+e.message+'. No repitas la entrada.',true)}
    reEl('plate').focus();
    try{await reloadReinforcementSpots()}catch(e){reShowMessage(reEl('result').textContent+'\nNo se pudo actualizar la lista de plazas: '+e.message,true)}
  } catch (error) {
    reShowMessage(error.message || 'No se pudo registrar la entrada.', true);
  } finally {
    button.disabled = false;
  }
}
function reinforcementLocalDateTime(date){
  const parts=new Intl.DateTimeFormat('sv-SE',{timeZone:'Europe/Madrid',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(date);
  return parts.replace(' ','T');
}
function refreshReinforcementStayDates(){
  const entry=new Date(),days=Number(reEl('days').value)||1;
  const departure=new Date(entry.getTime()+days*86400000);
  reEl('start').value=reinforcementLocalDateTime(entry);
  reEl('stayEnd').value=reinforcementLocalDateTime(departure);
  reEl('stayEndDay').textContent=new Intl.DateTimeFormat('es-ES',{timeZone:'Europe/Madrid',weekday:'long',day:'numeric',month:'long',year:'numeric'}).format(departure);
  return entry;
}
reEl('days').addEventListener('change',()=>refreshReinforcementStayDates());
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&!reEl('stayButton').disabled)refreshReinforcementStayDates();});
setInterval(()=>{if(!document.hidden&&!reEl('stay').classList.contains('hidden')&&!reEl('stayButton').disabled)refreshReinforcementStayDates();},1000);
async function createStay() {
  const button = reEl('stayButton');
  if (button.disabled) return;
  const entry = refreshReinforcementStayDates();
  const staySpot=selectedReinforcementStaySpot();
  if(reEl('staySpot').value.trim()&&!staySpot){reShowMessage('Selecciona una plaza disponible compatible o deja el campo vacío.',true);reEl('staySpot').focus();return;}
  if (!reEl('stayPlate').value.trim() || !reEl('model').value.trim() || Number.isNaN(entry.getTime())) {
    reShowMessage('Completa matrícula, marca/modelo y fecha de entrada.', true);
    return;
  }
  button.disabled = true;
  try {
    const result = await reCall('parking_reinforcement_create_stay_with_spot', {
      p_code: reinforcementCode,
      p_spot_id: staySpot?.id || null,
      p_type: reEl('type').value,
      p_plate: reEl('stayPlate').value.trim().toUpperCase(),
      p_model: reEl('model').value.trim().toUpperCase(),
      p_entry: entry.toISOString(),
      p_days: Number(reEl('days').value),
      p_name: reEl('name').value.trim().toUpperCase() || null
    });
    reShowMessage('Estancia creada sin cobro. Reserva ' + result.reference + ' · ' + result.plate + ' · pendiente de cobro.', false);
    reEl('stayPlate').value = '';
    reEl('model').value = '';
    reEl('name').value = '';
    reEl('staySpot').value='';
    await reloadReinforcementStaySpots().catch(()=>{});
    reEl('stayPlate').focus();
  } catch (error) {
    reShowMessage(error.message || 'No se pudo crear la estancia.', true);
  } finally {
    button.disabled = false;
  }
}
async function reprintTicket(){if(!lastReinforcementTicket)return;try{await printReinforcementTicket(lastReinforcementTicket)}catch(e){reShowMessage('No se pudo reimprimir: '+e.message,true)}}
const esc=reEscape;
function normalizeRotationPlate(value){return String(value||'').toUpperCase().replace(/[^A-Z0-9]/g,'')}


function normalizeReinforcementText(event){const el=event.target;if(!el.matches('input:not([type="password"]):not([type="datetime-local"]):not([type="number"]),textarea'))return;const start=el.selectionStart,end=el.selectionEnd,value=el.value.toLocaleUpperCase('es-ES');if(el.value!==value){el.value=value;try{el.setSelectionRange(start,end)}catch(e){}}}
document.addEventListener('input',normalizeReinforcementText,true);document.addEventListener('change',normalizeReinforcementText,true);

/* Mobile Refuerzo prints through the office PC; desktop Refuerzo remains local. */
window.parkingQzRemoteHost=/Android|iPhone|iPad/i.test(navigator.userAgent)?'192.168.1.50':null;
(function mountReinforcementPrinting(){const panel=document.createElement('details');panel.className='panel';panel.id='reinforcementPrinting';panel.innerHTML='<summary style="font-weight:bold;cursor:pointer">Configurar impresión en oficina</summary><p id="reinforcementPrinterTarget"></p><p>Después de guardar la autorización, pulsa Comprobar conexión. Mantén la tablet en la Wi-Fi del parking y QZ Tray abierto en el ordenador. La petición Allow puede aparecer en la pantalla del ordenador.</p><button type="button" onclick="showParkingQzSetup()">Autorizar este dispositivo</button><button type="button" id="reinforcementPrinterCheck" onclick="checkReinforcementPrinter()">Comprobar conexión</button><button type="button" onclick="testReinforcementPrinter()">Imprimir ticket de prueba</button><p><a id="reinforcementQzAddress" target="_blank" rel="noopener">Abrir conexión del ordenador</a></p><p id="reinforcementPrinterStatus" role="status"></p>';document.querySelector('#work .tabs').after(panel);reEl('reinforcementPrinterTarget').textContent='Impresora: '+PARKING_PRINTERS.ticket+' · QZ: '+(window.parkingQzRemoteHost||'este ordenador');const address=reEl('reinforcementQzAddress');address.href='https://'+(window.parkingQzRemoteHost||'localhost')+':8181/';address.hidden=!window.parkingQzRemoteHost})();
let reinforcementPrinterCheckBusy=false;
async function checkReinforcementPrinter(){
 if(reinforcementPrinterCheckBusy)return;reinforcementPrinterCheckBusy=true;
 const status=reEl('reinforcementPrinterStatus'),button=reEl('reinforcementPrinterCheck');button.disabled=true;status.textContent='Comprobando conexión e impresora…';
 try{await connectParkingQz();const found=await parkingQzWithTimeout(qz.printers.find(PARKING_PRINTERS.ticket),'QZ conecta, pero no responde la consulta de impresora. Comprueba los avisos del ordenador.');if(!found||!(Array.isArray(found)?found.includes(PARKING_PRINTERS.ticket):String(found)===PARKING_PRINTERS.ticket))throw Error('No se encuentra '+PARKING_PRINTERS.ticket+' en el ordenador del parking.');status.textContent='Conexión correcta. Impresora '+PARKING_PRINTERS.ticket+' disponible.'}
 catch(e){status.textContent='No se pudo conectar: '+e.message}
 finally{reinforcementPrinterCheckBusy=false;button.disabled=false}
}

let reinforcementPrintTestBusy=false;
async function testReinforcementPrinter(){if(reinforcementPrintTestBusy)return;reinforcementPrintTestBusy=true;const status=reEl('reinforcementPrinterStatus');try{await sendParkingPrint('ticket',parkingTicketShell('Prueba de impresión Refuerzo','<h2 class="center">PRUEBA DE IMPRESIÓN</h2><p class="center"><b>REFUERZO · LAS DELICIAS</b></p><p class="center">'+reEscape(new Date().toLocaleString('es-ES'))+'</p><p class="center">No registra entradas ni cobros.</p>',100),true);status.textContent='Ticket de prueba enviado a la BIXOLON. Comprueba la salida en papel.'}catch(e){status.textContent='No se imprimió la prueba: '+e.message}finally{reinforcementPrintTestBusy=false}}

let reinforcementStaySpots=[],reinforcementStaySpotSerial=0;
function reinforcementFreeStaySpots(){return reinforcementStaySpots.filter(s=>(s.types||[]).includes(reEl('type').value));}
function selectedReinforcementStaySpot(){
 const code=reinforcementSpotCode(reEl('staySpot').value),free=reinforcementFreeStaySpots();
 if(['A','M'].includes(code))return free.filter(s=>String(s.code).toUpperCase().split('-')[0]===code).sort((a,b)=>a.code.localeCompare(b.code,'es',{numeric:true}))[0];
 return free.find(s=>reinforcementSpotCode(s.code)===code);
}
function renderReinforcementStaySpots(previousSpots=reinforcementStaySpots){
 const field=reEl('staySpot'),current=field.value,free=reinforcementFreeStaySpots(),editing=document.activeElement===field;
 const list=reEl('staySpotOptions'),markup=free.map(s=>'<option value="'+reEscape(s.code)+'"></option>').join('');
 if(list.innerHTML!==markup)list.innerHTML=markup;
 if(!editing)field.setAttribute('list','staySpotOptions');
 const selected=free.find(s=>reinforcementSpotCode(s.code)===reinforcementSpotCode(current));
 const previouslyListed=previousSpots.some(s=>reinforcementSpotCode(s.code)===reinforcementSpotCode(current));
 if(selected){if(!editing&&field.value!==selected.code)field.value=selected.code;}
 else if(previouslyListed){if(!editing)field.value='';reEl('staySpotHelp').textContent='La plaza '+current+' ya no está disponible. Selecciona otra plaza libre.';return;}
 if(selected||!current)reEl('staySpotHelp').textContent='Opcional. Escribe para filtrar; A o M selecciona la primera libre. Se puede cambiar después en Reservas.';
}
function completeReinforcementStayZone(){
 const field=reEl('staySpot'),zone=reinforcementSpotCode(field.value);if(!['A','M'].includes(zone))return;
 const spot=selectedReinforcementStaySpot();if(!spot){reEl('staySpotHelp').textContent='No hay plazas '+zone+' disponibles para este vehículo. Puedes dejar el campo vacío.';return;}
 field.value=spot.code;field.removeAttribute('list');field.setSelectionRange(field.value.length,field.value.length);
 reEl('staySpotHelp').textContent='Primera plaza libre: '+spot.code+'. Se puede cambiar después en Reservas.';
}
let reinforcementStayZoneTimer;
reEl('staySpot').addEventListener('input',event=>{clearTimeout(reinforcementStayZoneTimer);reEl('staySpot').setAttribute('list','staySpotOptions');reEl('staySpotHelp').textContent='Opcional. Escribe para filtrar; A o M selecciona la primera libre. Se puede cambiar después en Reservas.';if(!event.isComposing&&!String(event.inputType||'').startsWith('delete'))reinforcementStayZoneTimer=setTimeout(completeReinforcementStayZone,0);});
reEl('staySpot').addEventListener('compositionend',()=>{clearTimeout(reinforcementStayZoneTimer);reinforcementStayZoneTimer=setTimeout(completeReinforcementStayZone,0);});
reEl('staySpot').addEventListener('change',completeReinforcementStayZone);
reEl('staySpot').addEventListener('blur',completeReinforcementStayZone);
reEl('staySpot').addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();completeReinforcementStayZone();reEl('days').focus();}});

async function reloadReinforcementStaySpots(){
 if(!reinforcementCode)return;const serial=++reinforcementStaySpotSerial;
 try{const data=await reCall('parking_reinforcement_stay_spots',{p_code:reinforcementCode});if(serial!==reinforcementStaySpotSerial)return;const previousSpots=reinforcementStaySpots;reinforcementStaySpots=data||[];renderReinforcementStaySpots(previousSpots);}
 catch(e){if(serial===reinforcementStaySpotSerial){reinforcementStaySpots=[];renderReinforcementStaySpots();}throw e;}
}
reEl('type').addEventListener('change',()=>renderReinforcementStaySpots());

/* Refresh only while Refuerzo is visible; preflight remains mandatory before writes. */
let reinforcementAvailabilityBusy=false;
function reinforcementAvailabilityStatus(message){let status=reEl('reinforcementAvailabilityStatus');if(!status){status=document.createElement('p');status.id='reinforcementAvailabilityStatus';status.setAttribute('role','status');document.querySelector('#work .tabs').after(status)}status.textContent=message;}
async function refreshReinforcementAvailability(){
 if(!reinforcementCode||document.hidden||reinforcementAvailabilityBusy||reEl('enterButton').disabled||reEl('stayButton').disabled)return;
 reinforcementAvailabilityBusy=true;
 try{await Promise.all([reloadReinforcementSpots(),reloadReinforcementStaySpots()]);
  reinforcementAvailabilityStatus('Plazas actualizadas · '+new Date().toLocaleTimeString('es-ES'));
 }catch(e){reinforcementAvailabilityStatus('No se pudieron actualizar las plazas. Se comprobarán antes de registrar: '+e.message)}finally{reinforcementAvailabilityBusy=false}
}
setInterval(refreshReinforcementAvailability,3000);
window.addEventListener('focus',refreshReinforcementAvailability);
window.addEventListener('online',refreshReinforcementAvailability);
document.addEventListener('visibilitychange',()=>{if(!document.hidden)refreshReinforcementAvailability()});
const rotationEntryBeforeAvailabilityCheck=rotationEntry;
rotationEntry=async function(){
 const button=reEl('enterButton');if(button.disabled)return;button.disabled=true;
 const wanted=reEl('spot').value;
 try{await reloadReinforcementSpots();
  if(!wanted||!selectedReinforcementSpot()){reShowMessage('La plaza seleccionada ya no está disponible. Elige otra plaza libre antes de dar entrada.',true);return;}
  button.disabled=false;await rotationEntryBeforeAvailabilityCheck();
 }catch(e){reShowMessage('No se pudo comprobar la plaza. No se ha registrado la entrada: '+e.message,true)}finally{button.disabled=false}
};
const createStayBeforeAvailabilityCheck=createStay;
createStay=async function(){
 const button=reEl('stayButton');if(button.disabled)return;button.disabled=true;const wanted=reEl('staySpot').value.trim();
 try{await reloadReinforcementStaySpots();
  if(wanted&&!selectedReinforcementStaySpot()){reShowMessage('La plaza seleccionada ya no está disponible. Selecciona otra o deja el campo vacío.',true);return;}
  button.disabled=false;await createStayBeforeAvailabilityCheck();
 }catch(e){reShowMessage('No se pudo comprobar la disponibilidad. No se ha creado la estancia: '+e.message,true)}finally{button.disabled=false}
};


/* Check only the typed plate through the temporary reinforcement access. */
const reinforcementPlateTimers=new Map();
function reinforcementNormalizedPlate(value){return String(value||'').toUpperCase().replace(/[^A-Z0-9]/g,'');}
async function checkReinforcementPlate(id,notify=false){
 const input=reEl(id),plate=reinforcementNormalizedPlate(input.value);
 let warning=reEl(id+'Warning');
 if(!warning){warning=document.createElement('div');warning.id=id+'Warning';warning.setAttribute('role','alert');warning.style.cssText='color:#b51d28;font-weight:900;white-space:pre-wrap;margin:8px 0';input.after(warning);}
 warning.textContent='';
 if(!reinforcementCode||plate.length<3)return false;
 try{
  const data=await reCall('parking_reinforcement_check_plate',{p_code:reinforcementCode,p_plate:plate});
  if(reinforcementNormalizedPlate(input.value)!==plate)return true;
  const text=data.blocked?'ENTRADA BLOQUEADA · '+plate+'\n'+(data.blocked.observation||'')+'\nNo emitir ticket ni dar entrada al vehículo.':data.authorized?'VEHÍCULO AUTORIZADO · '+plate+'\n'+(data.authorized.observation||''):'';
  warning.textContent=text;
  if(data.blocked&&notify)alert(text);
  return !!data.blocked;
 }catch(error){warning.textContent='No se pudo comprobar la matrícula: '+error.message;if(notify)throw error;return true;}
}
for(const id of ['plate','stayPlate']){
 reEl(id).addEventListener('input',()=>{if(reEl(id+'Warning'))reEl(id+'Warning').textContent='';clearTimeout(reinforcementPlateTimers.get(id));reinforcementPlateTimers.set(id,setTimeout(()=>checkReinforcementPlate(id),300));});
 reEl(id).addEventListener('change',()=>checkReinforcementPlate(id));
}
function withReinforcementPlateCheck(previous,id,buttonId){
 return async function(...args){
  const button=reEl(buttonId);if(button.disabled)return;button.disabled=true;
  try{if(await checkReinforcementPlate(id,true))return;button.disabled=false;return await previous.apply(this,args);}
  catch(error){reShowMessage(error.message,true);}
  finally{button.disabled=false;}
 };
}
rotationEntry=withReinforcementPlateCheck(rotationEntry,'plate','enterButton');
createStay=withReinforcementPlateCheck(createStay,'stayPlate','stayButton');
