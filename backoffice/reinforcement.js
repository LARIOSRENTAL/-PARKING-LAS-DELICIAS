/* Acceso limitado de Refuerzo. Las operaciones se validan en RPC con código temporal. */
const reinforcementDb = window.supabase.createClient(
  'https://vcwbfljcqpqkmuzcpboi.supabase.co',
  'sb_publishable_is9ITJdQMbieunMWrv6g8A_2OdrO3xe',
  {auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}}
);
let reinforcementCode = '';
let reinforcementData = null;
let lastReinforcementTicket = null;
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
  const code = reEl('code').value.trim();
  reEl('loginError').textContent = '';
  if (!code) { reEl('loginError').textContent = 'Introduce el código temporal.'; return; }
  button.disabled = true;
  try {
    const data = await reCall('parking_reinforcement_options', {p_code:code});
    if (!data || !Array.isArray(data.tariffs) || !Array.isArray(data.types)) throw new Error('No se pudieron cargar las opciones de trabajo.');
    reinforcementCode = code;
    reinforcementData = data;
    reEl('tariff').innerHTML = data.tariffs.map(t => '<option value="' + reEscape(t.code) + '">' + reEscape(t.name) + '</option>').join('');
    reEl('type').innerHTML = data.types.map(t => '<option value="' + reEscape(t.id) + '">' + reEscape(t.name) + '</option>').join('');
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
function printReinforcementTicket(ticket) {
  lastReinforcementTicket = ticket;
  const time = reDate(ticket.entry_at);
  reEl('ticket').innerHTML =
    '<div style="text-align:center;font-weight:bold;font-size:17px">PARKING LAS DELICIAS</div>' +
    '<div style="text-align:center;margin:3px 0 10px">C/ Don Rodrigo nº 3 · Málaga</div>' +
    '<hr><div style="text-align:center;font-size:16px;font-weight:bold">TICKET DE ENTRADA</div>' +
    '<p><b>Nº:</b> ' + reEscape(ticket.ticket_number) + '</p>' +
    '<p><b>Matrícula:</b> ' + reEscape(ticket.plate) + '</p>' +
    '<p><b>Tarifa:</b> ' + reEscape(ticket.tariff) + '</p>' +
    '<p><b>Plaza:</b> ' + reEscape(ticket.spot) + '</p>' +
    '<p><b>Entrada:</b> ' + reEscape(time) + '</p>' +
    '<hr><div style="text-align:center">Conserve este ticket hasta la salida.</div>';
  reEl('ticketWrap').classList.remove('hidden');
  window.setTimeout(() => window.print(), 250);
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
    reEl('spot').value = '';
    reEl('client').value = '';
    printReinforcementTicket(result);
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
function reprintTicket() {
  if (lastReinforcementTicket) window.print();
}
