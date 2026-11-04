/* Read-only daily report. Shift RPCs keep the existing manager/admin authorization. */
let dailyCashbookData=null,dailyCashbookVersion=0,dailyCashbookPrintBusy=false;
function canViewDailyCashbook(){return ['admin','manager'].includes(currentProfile?.role)}
const dailyCashRound=n=>Math.round((Number(n||0)+Number.EPSILON)*100)/100;
function dailyCashUniqueRows(reports){const rows=new Map();for(const report of reports)for(const row of report.rows||[]){if(!row.id)throw Error('Hay un movimiento sin identificador. No se puede consolidar la caja.');rows.set(row.id,row)}return [...rows.values()]}
function dailyCashMeasures(reports){
 if(!reports.length)return null;
 const sorted=[...reports].sort((a,b)=>Number(a.shift_code)-Number(b.shift_code)||String(a.opened_at||'').localeCompare(String(b.opened_at||''))),first=sorted[0],last=sorted.at(-1),t=cashbookTotals(dailyCashUniqueRows(sorted));
 const expenses=dailyCashRound(sorted.reduce((n,r)=>n+Number(r.cash_state?.expense_total||0),0)),withdrawals=dailyCashRound(sorted.reduce((n,r)=>n+Number(r.withdrawal_total_eur||0),0)),opening=Number(first.cash_state?.opening_balance||0),expected=dailyCashRound(opening+t.cash-expenses-withdrawals),saved=sorted.every(r=>r.cash_state?.saved),s=last.cash_state||{};
 return {...t,subscriber_invoice:dailyCashRound(t.subscriber-t.receipt_p),expenses,withdrawals,opening,expected,counted:s.saved?Number(s.counted_total):null,loose:s.saved?Number(s.loose_coins||0):null,wrapped:s.saved?Number(s.wrapped_coins||0):null,banknotes:s.saved?Number(s.banknotes||0):null,vouchers:s.saved?Number(s.vouchers||0):null,difference:saved?dailyCashRound(Number(s.counted_total)-expected):null};
}
function consolidateDailyCashbook(date,reports){
 const ids=new Set();for(const r of reports){if(!r.shift_id||ids.has(r.shift_id)||r.date!==date||![1,2,3].includes(Number(r.shift_code)))throw Error('La selección contiene un turno duplicado o de otra fecha.');ids.add(r.shift_id)}
 const groups=[1,2,3].map(code=>reports.filter(r=>Number(r.shift_code)===code)),warnings=[];
 groups.forEach((group,i)=>{if(!group.length)warnings.push('T'+(i+1)+': sin turno registrado.');else{if(group.some(r=>!r.closed_at))warnings.push('T'+(i+1)+': turno abierto, datos provisionales.');if(group.some(r=>!r.cash_state?.saved))warnings.push('T'+(i+1)+': arqueo pendiente.');if(group.length>1)warnings.push('T'+(i+1)+': incluye '+group.length+' hojas; revisar los relevos.')}});
 const measures=dailyCashMeasures(reports);if(measures&&groups.some(g=>!g.length))measures.difference=null;
 return {date,reports,groups,warnings,measures,generated_at:new Date().toISOString()};
}
async function fetchDailyCashbook(date){
 if(!canViewDailyCashbook())throw Error('Solo gerente y administrador pueden consultar la caja diaria.');
 if(!/^\d{4}-\d{2}-\d{2}$/.test(date))throw Error('Selecciona una fecha válida.');
 const lists=await Promise.all([1,2,3].map(async code=>{const r=await db.rpc('parking_cashbook_shifts',{p_date:date,p_shift_code:code});if(r.error)throw r.error;return (r.data||[]).map(s=>({...s,code}))}));
 const reports=await Promise.all(lists.flat().map(async s=>{const r=await db.rpc('parking_cashbook',{p_date:date,p_shift_code:s.code,p_shift_id:s.id});if(r.error)throw r.error;if(r.data?.shift_id!==s.id)throw Error('No se pudo identificar una de las hojas de caja.');return r.data}));
 return consolidateDailyCashbook(date,reports);
}
const DAILY_CASH_LINES=[['Saldo de entrada','opening'],['TOTAL COBRADO POR HORAS','rotation'],['TOTAL COBRADO POR ESTANCIAS','stay'],['TOTAL COBRADO POR ABONADOS','subscriber_invoice'],['TOTAL COBRADO POR RECIBOS P','receipt_p'],['TOTAL INGRESOS','total'],['TOTAL COBRADO POR TARJETAS','card'],['TOTAL COBRADO POR BANCO','bank'],['TOTAL COBRADO ONLINE','online'],['Ingresos en efectivo','cash'],['TOTAL PAGOS REALIZADOS','expenses'],['RETIRADO POR LA EMPRESA','withdrawals'],['Saldo calculado a la salida','expected'],['Monedas sueltas','loose'],['Monedas empaquetadas','wrapped'],['Billetes','banknotes'],['Vales pendientes','vouchers'],['Saldo contado a la salida','counted'],['Diferencia de arqueo','difference']];
function renderDailyCashbook(data,forPrint=false){
 const columns=forPrint?[data.measures]:[...data.groups.map(dailyCashMeasures),data.measures];
 const lines=forPrint?DAILY_CASH_LINES.slice(1,DAILY_CASH_LINES.findIndex(([,key])=>key==='expected')+1):DAILY_CASH_LINES;
 let html='<h2>Caja diaria · '+esc(data.date.split('-').reverse().join('/'))+'</h2><p>'+(forPrint?'Periodo diario: desde las 22:00 del día anterior hasta las 22:00 del día indicado.':'T1: 22:00 del día anterior–06:00 · T2: 06:00–14:00 · T3: 14:00–22:00.')+'</p>';
 if(data.warnings.length)html+='<p class="dailyWarning"><b>Resumen provisional.</b> '+data.warnings.map(esc).join(' ')+'</p>';
 html+='<div class="tableWrap"><table class="dailyCashTable"><thead><tr><th>Concepto</th>'+(forPrint?'':[1,2,3].map((code,i)=>'<th>T'+code+'<br><small>'+data.groups[i].map(r=>esc(r.employee_name||'')+' · hoja '+esc(r.cashbook_number??'—')).join('<br>')+'</small></th>').join(''))+'<th>DÍA COMPLETO</th></tr></thead><tbody>';
 for(const [label,key]of lines)html+='<tr'+(['total','expected','counted','difference'].includes(key)?' class="dailyTotal"':'')+'><th>'+label+'</th>'+columns.map(m=>'<td>'+(m&&m[key]!==null?money(m[key]):'—')+'</td>').join('')+'</tr>';
 return html+'</tbody></table></div>'+(forPrint?'':'<p class="dailyNote">En la columna diaria, el saldo de entrada es el del primer turno y el recuento de salida es el del último. El dinero y los vales trasladados entre turnos no se suman de nuevo. Los cobros, gastos y retiradas sí se suman.</p>')+'<p>Generado: '+esc(fmt(data.generated_at))+'</p>';
}
async function openDailyCashbook(){
 if(!canViewDailyCashbook())return;
 let dialog=document.getElementById('dailyCashbookDialog');if(!dialog){dialog=document.createElement('dialog');dialog.id='dailyCashbookDialog';dialog.className='dailyCashDialog';dialog.innerHTML='<div class="toolbar"><h2>Caja diaria · 3 turnos</h2><button class="mini" onclick="document.getElementById(\'dailyCashbookDialog\').close()">Cerrar</button></div><div class="toolbar"><label>Fecha <input type="date" id="dailyCashbookDate" onchange="loadDailyCashbook()"></label><button class="btn light" onclick="loadDailyCashbook()">Actualizar día</button><button id="dailyCashbookPrint" class="btn dark" onclick="printDailyCashbook()">Imprimir caja diaria</button></div><p id="dailyCashbookMessage" role="status"></p><div id="dailyCashbookBody"></div>';document.body.append(dialog)}
 opsEl('dailyCashbookDate').value=opsEl('cashbookDate').value||initialCashbookShift().date;dialog.showModal();await loadDailyCashbook();
}
async function loadDailyCashbook(){
 const version=++dailyCashbookVersion;dailyCashbookData=null;opsEl('dailyCashbookPrint').disabled=true;opsEl('dailyCashbookMessage').textContent='Consultando los tres turnos…';opsEl('dailyCashbookBody').innerHTML='';
 try{const data=await fetchDailyCashbook(opsEl('dailyCashbookDate').value);if(version!==dailyCashbookVersion)return;dailyCashbookData=data;opsEl('dailyCashbookBody').innerHTML=renderDailyCashbook(data);opsEl('dailyCashbookMessage').textContent=data.reports.length?'':'No hay turnos registrados para esta fecha.';opsEl('dailyCashbookPrint').disabled=!data.reports.length||dailyCashbookPrintBusy}catch(e){if(version===dailyCashbookVersion)opsEl('dailyCashbookMessage').textContent='No se pudo obtener la caja diaria: '+e.message}
}
function buildDailyCashbookHtml(data){return '<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Caja diaria '+esc(data.date)+'</title><style>@page{size:A4 landscape;margin:6mm}*{box-sizing:border-box}body{margin:0;width:285mm;font:11px Arial;color:#111}h2{font-size:18px;margin:0 0 5px}p{margin:5px 0}.dailyCashTable{width:100%;border-collapse:collapse;table-layout:fixed}.dailyCashTable th,.dailyCashTable td{border:1px solid #999;padding:4px 6px;text-align:right}.dailyCashTable th:first-child{width:75%;text-align:left}.dailyCashTable thead th{background:#eee;font-size:12px}.dailyTotal{font-weight:bold;background:#eee}.dailyNote,.dailyWarning{font-size:10px}tr{break-inside:avoid}</style></head><body>'+renderDailyCashbook(data,true)+'</body></html>'}
async function printDailyCashbook(){
 if(!canViewDailyCashbook()||dailyCashbookPrintBusy)return;dailyCashbookPrintBusy=true;opsEl('dailyCashbookPrint').disabled=true;const version=++dailyCashbookVersion;
 try{if(cashCountDirty&&!await saveCashCount(true))throw Error('No se pudieron guardar los cambios del arqueo actual.');const data=await fetchDailyCashbook(opsEl('dailyCashbookDate').value);if(version!==dailyCashbookVersion)throw Error('La fecha ha cambiado. Vuelve a imprimir.');if(!data.reports.length)throw Error('No hay turnos para imprimir.');dailyCashbookData=data;opsEl('dailyCashbookBody').innerHTML=renderDailyCashbook(data);await sendParkingPrint('cashbook',buildDailyCashbookHtml(data));opsEl('dailyCashbookMessage').textContent='Caja diaria preparada para impresión.'}catch(e){opsEl('dailyCashbookMessage').textContent='No se pudo imprimir: '+e.message}finally{dailyCashbookPrintBusy=false;opsEl('dailyCashbookPrint').disabled=!dailyCashbookData?.reports.length}
}
