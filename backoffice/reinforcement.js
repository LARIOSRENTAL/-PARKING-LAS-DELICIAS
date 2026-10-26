/* Acceso limitado de Refuerzo. La clave fija se valida en servidor y crea una sesión temporal. */
const reinforcementDb = window.supabase.createClient(
  'https://vcwbfljcqpqkmuzcpboi.supabase.co',
  'sb_publishable_is9ITJdQMbieunMWrv6g8A_2OdrO3xe',
  {auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}}
);
let reinforcementCode = '';
let reinforcementData = null;
let lastReinforcementTicket = null;
async function reloadReinforcementSpots(){if(!reinforcementCode)return;const options=await reCall('parking_reinforcement_options',{p_code:reinforcementCode});reinforcementData=options;const tariff=reEl('tariff').value;const previous=reEl('spot').value;const free=(options.spots||[]).filter(s=>(s.tariffs||[]).includes(tariff));reEl('spot').innerHTML='<option value="">Selecciona plaza libre</option>'+free.map(s=>'<option value="'+reEscape(s.code)+'">'+reEscape(s.code)+'</option>').join('');if(free.some(s=>s.code===previous))reEl('spot').value=previous;}
const reEl = id => document.getElementById(id);
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
    const now = new Date();
    now.setMinutes(now.getMinutes() - now.getTimezoneOffset());
    reEl('start').value = now.toISOString().slice(0,16);
    reEl('login').classList.add('hidden');
    reEl('work').classList.remove('hidden');
    reShowMessage('Acceso temporal activo. Las operaciones quedan registradas sin cobro.', false);
  } catch (error) {
    reEl('loginError').textContent = error.message || 'Código no válido o caducado.';
  } finally {
    button.disabled = false;
  }
}
function tab(name) {
  reEl('rotation').classList.toggle('hidden', name !== 'rotation');
  reEl('stay').classList.toggle('hidden', name !== 'stay');
}
async function printReinforcementTicket(ticket) {
 lastReinforcementTicket=ticket;
 const html=buildRotationEntryTicket({...ticket,spot_code:ticket.spot,key_number:ticket.spot,leaves_keys:!['A','M'].includes(String(ticket.spot||'').split('-')[0]),client_text:ticket.client_text||'',entry_shift_code:'REFUERZO'});
 await sendParkingPrint('ticket',html,true);
 reShowMessage('Entrada registrada para '+ticket.plate+' · plaza '+ticket.spot+'. Ticket enviado a la impresora de oficina.',false);
}
async function rotationEntry() {
  const button = reEl('enterButton');
  if (button.disabled) return;
  const plate = reEl('plate').value.trim().toUpperCase();
  const spot = reEl('spot').value.trim().toUpperCase();
  if (plate.length < 3 || !spot) { reShowMessage('Indica una matrícula y una plaza.', true); return; }
  button.disabled = true;
  try {
    const result = await reCall('parking_reinforcement_enter', {
      p_code: reinforcementCode,
      p_tariff: reEl('tariff').value,
      p_plate: plate,
      p_spot: spot,
      p_client: reEl('client').value.trim()
    });
    reShowMessage('Entrada registrada para ' + result.plate + ' · plaza ' + result.spot + '. Preparando ticket…', false);
    reEl('plate').value = '';
    result.client_text=reEl('client').value.trim();
    reEl('client').value = '';
    try{await printReinforcementTicket(result)}catch(e){reShowMessage('Entrada registrada para '+result.plate+'. No se imprimió: '+e.message+'. Usa Reimprimir ticket; no repitas la entrada.',true)}
    try{await reloadReinforcementSpots()}catch(e){reShowMessage('Entrada registrada. No se pudo actualizar la lista de plazas: '+e.message,true)}
  } catch (error) {
    reShowMessage(error.message || 'No se pudo registrar la entrada.', true);
  } finally {
    button.disabled = false;
  }
}
async function createStay() {
  const button = reEl('stayButton');
  if (button.disabled) return;
  const entry = new Date(reEl('start').value);
  if (!reEl('stayPlate').value.trim() || !reEl('model').value.trim() || Number.isNaN(entry.getTime())) {
    reShowMessage('Completa matrícula, marca/modelo y fecha de entrada.', true);
    return;
  }
  button.disabled = true;
  try {
    const result = await reCall('parking_reinforcement_create_stay', {
      p_code: reinforcementCode,
      p_type: reEl('type').value,
      p_plate: reEl('stayPlate').value.trim().toUpperCase(),
      p_model: reEl('model').value.trim().toUpperCase(),
      p_entry: entry.toISOString(),
      p_days: Number(reEl('days').value),
      p_name: reEl('name').value.trim() || null
    });
    reShowMessage('Estancia creada sin cobro. Reserva ' + result.reference + ' · ' + result.plate + ' · pendiente de cobro.', false);
    reEl('stayPlate').value = '';
    reEl('model').value = '';
    reEl('name').value = '';
  } catch (error) {
    reShowMessage(error.message || 'No se pudo crear la estancia.', true);
  } finally {
    button.disabled = false;
  }
}
async function reprintTicket(){if(!lastReinforcementTicket)return;try{await printReinforcementTicket(lastReinforcementTicket)}catch(e){reShowMessage('No se pudo reimprimir: '+e.message,true)}}
const esc=reEscape;
function normalizeRotationPlate(value){return String(value||'').toUpperCase().replace(/[^A-Z0-9]/g,'')}

