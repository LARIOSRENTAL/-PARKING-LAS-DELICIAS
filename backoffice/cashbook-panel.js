/* Shift-local cash reconciliation. All money writes are authenticated server RPCs. */
let cashbookActiveTab='income',cashCountDirty=false,cashCountShiftId=null,cashCountBusy=false;
const CASHBOOK_TABS=['income','count','withdrawals','expenses','vouchers'];
const CASH_COUNT_FIELDS=['opening_balance','loose_coins','wrapped_coins','banknotes','vouchers'];
let cashDenominationDraft={};
let activeCashVouchers=null,cashValeCancelBusy=false;
let cashEntryBusy={expense:false,voucher:false},cashEntryPending={};
function showCashbookTab(tab){cashbookActiveTab=CASHBOOK_TABS.includes(tab)?tab:'income';document.querySelectorAll('#cashbookTabs button').forEach(b=>b.classList.toggle('active',b.dataset.cashTab===cashbookActiveTab));document.querySelectorAll('.cashbookPane').forEach(e=>e.classList.toggle('hidden',e.dataset.cashPane!==cashbookActiveTab));if(cashbookActiveTab==='withdrawals')loadCashWithdrawals();saveParkingNavigation('cashbook')}
function ownCashbookShift(){return !!currentShift?.id&&currentAccessMode!=='free'&&parkingCashbookData?.shift_id===currentShift.id&&!parkingCashbookData.closed_at}
function cashCountDraftKey(id){return 'pld_cash_count_v1:'+currentSession?.user?.id+':'+id}
function cashCountValues(){return {...Object.fromEntries(CASH_COUNT_FIELDS.map(k=>[k,opsEl('cashCount_'+k).value])),denomination_breakdown:cashDenominationDraft}}
function renderCashDenominationInputs(state,own){
 cashDenominationDraft={};
 for(const [group,title]of [['loose_coins','MONEDAS SUELTAS'],['wrapped_coins','MONEDAS EMPAQUETADAS'],['banknotes','BILLETES']]){
  const defs=cashDenominations(group),values=cashBreakdownGroup(state,group);cashDenominationDraft[group]=values;
  opsEl('cashDenominations_'+group).innerHTML='<fieldset class="cashDenominationBlock"><legend>'+title+'</legend><table><thead><tr>'+defs.map(([,label])=>'<th>'+esc(label)+'</th>').join('')+'</tr></thead><tbody><tr>'+defs.map(([key,label])=>'<td><input id="cashDenom_'+group+'_'+key+'" aria-label="'+title+' '+esc(label)+' (importe en euros)" inputmode="decimal" oninput="cashDenominationChanged()"></td>').join('')+'</tr></tbody></table><div class="legacyCash"><label>Importe anterior sin desglosar (€)<input id="cashDenom_'+group+'_unallocated" inputmode="decimal" oninput="cashDenominationChanged()"></label></div></fieldset>';
  for(const key of [...defs.map(([key])=>key),'unallocated']){const input=opsEl('cashDenom_'+group+'_'+key);input.value=Number(values[key]).toFixed(2);input.disabled=!own}
  opsEl('cashCount_'+group).readOnly=true;
 }
}
function cashDenominationChanged(){
 for(const group of ['loose_coins','wrapped_coins','banknotes']){let cents=0;cashDenominationDraft[group]={};for(const key of [...cashDenominations(group).map(([key])=>key),'unallocated']){const raw=opsEl('cashDenom_'+group+'_'+key).value.trim()||'0',n=normalCashAmount(raw);cashDenominationDraft[group][key]=raw;if(n!==null)cents+=Math.round(n*100)}opsEl('cashCount_'+group).value=(cents/100).toFixed(2)}
 markCashCountDirty();
}
function normalCashAmount(value){const s=String(value||'').trim().replace(',','.');return /^\d+(\.\d{1,2})?$/.test(s)&&Number(s)<10000000000?Number(s):null}
function markCashCountDirty(){cashCountDirty=true;try{sessionStorage.setItem(cashCountDraftKey(cashCountShiftId),JSON.stringify(cashCountValues()))}catch(e){}updateCashCountTotals()}
function updateCashCountTotals(){const v=cashCountValues(),number=k=>normalCashAmount(v[k])??0,cash=number('loose_coins')+number('wrapped_coins')+number('banknotes'),counted=cash+number('vouchers'),t=cashbookTotals(parkingCashbookData?.rows||[]),expected=number('opening_balance')+t.cash-Number(parkingCashbookData?.cash_state?.expense_total||0)-Number(parkingCashbookData?.withdrawal_total_eur||0),difference=Math.round((counted-expected)*100)/100;opsEl('cashCountTotal').textContent=money(cash);opsEl('cashCountBalance').textContent=money(counted);opsEl('cashCountExpected').textContent=money(expected);opsEl('cashCountDifference').textContent=money(difference);opsEl('cashCountDifference').style.color=difference?'#c62828':'#16804a';opsEl('cashCountMessage').textContent=cashCountDirty?'Cambios pendientes de guardar.':(parkingCashbookData?.cash_state?.saved?'Arqueo guardado.':'Comprueba el saldo de entrada y rellena el dinero contado.');}
function renderCashbookPanel(data){
 if(!data){for(const key of CASH_COUNT_FIELDS){if(!cashCountDirty)opsEl('cashCount_'+key).value='';opsEl('cashCount_'+key).disabled=true}for(const id of ['cashCountTotal','cashCountBalance','cashCountExpected','cashCountDifference'])opsEl(id).textContent='—';opsEl('cashCountSave').disabled=true;opsEl('cashCountMessage').textContent='Resumen no disponible. Pulsa Actualizar caja para cargar tu turno; estos campos no representan un saldo de cero.';return}
 const own=ownCashbookShift();if(cashCountShiftId!==data?.shift_id||!cashCountDirty){cashCountShiftId=data?.shift_id||null;cashCountDirty=false;let draft=null;try{if(own)draft=JSON.parse(sessionStorage.getItem(cashCountDraftKey(cashCountShiftId))||'null')}catch(e){}for(const k of CASH_COUNT_FIELDS)opsEl('cashCount_'+k).value=draft?.[k]??String(data?.cash_state?.[k]??0);cashCountDirty=!!draft;renderCashDenominationInputs({...data?.cash_state,...draft},own);}
 for(const group of ['loose_coins','wrapped_coins','banknotes'])for(const key of [...cashDenominations(group).map(([key])=>key),'unallocated'])opsEl('cashDenom_'+group+'_'+key).disabled=!own;
 for(const k of CASH_COUNT_FIELDS)opsEl('cashCount_'+k).disabled=!own;opsEl('cashCount_vouchers').readOnly=true;opsEl('cashCount_vouchers').value=String(data?.cash_state?.vouchers??0);opsEl('cashCountSave').disabled=!own||cashCountBusy;updateCashCountTotals();
 const entries=data?.cash_state?.entries||[];
 for(const kind of ['expense','voucher']){restoreCashEntryPending(kind);const prefix=kind==='expense'?'cashExpense':'cashVale',pending=cashEntryPending[kind];opsEl(prefix+'Amount').disabled=!own||!!pending||cashEntryBusy[kind];if(kind==='expense')opsEl(prefix+'Description').disabled=!own||!!pending||cashEntryBusy[kind];opsEl(prefix+'Submit').disabled=cashEntryBusy[kind]||(!own&&!pending);opsEl(prefix+'Submit').textContent=pending?'Reintentar registro':kind==='expense'?'Registrar gasto':'Registrar e imprimir 1 copia';const rows=kind==='voucher'?(activeCashVouchers?.rows??data?.cash_state?.active_vouchers??entries.filter(e=>e.kind===kind)):entries.filter(e=>e.kind===kind);opsEl(prefix+'List').innerHTML=rows.length?'<div class="tableWrap"><table class="tbl"><thead><tr>'+(kind==='voucher'?'<th>Nº</th>':'')+'<th>Fecha</th><th>Empleado / descripción</th><th>Importe</th>'+(kind==='voucher'?'<th>Justificante</th>':'')+'</tr></thead><tbody>'+rows.map(e=>'<tr>'+(kind==='voucher'?'<td>V-'+esc(e.entry_number)+'</td>':'')+'<td>'+esc(fmt(e.created_at))+'</td><td>'+esc(kind==='expense'?e.description:e.employee_name)+'</td><td>'+money(e.amount_eur)+'</td>'+(kind==='voucher'?'<td><button class="mini" onclick="reprintCashVale(\''+e.id+'\')">Reimprimir 1 copia</button> <button class="mini" '+(!own||cashValeCancelBusy?'disabled':'')+' onclick="cancelCashVale(\''+e.id+'\')">Cancelar vale</button></td>':'')+'</tr>').join('')+'</tbody></table></div>':'<p class="muted">No hay '+(kind==='expense'?'gastos':'vales')+(kind==='voucher'?' pendientes.':' registrados en este turno.')+'</p>';}
 const legacy=Number(activeCashVouchers?.legacy_vouchers??data?.cash_state?.legacy_vouchers??0);if(legacy)opsEl('cashValeList').innerHTML+='<p class="muted">Vales anteriores sin desglose individual: '+money(legacy)+'. Incluidos en el resumen de caja.</p>';
 showCashbookTab(cashbookActiveTab);
}
async function saveCashCount(silent=false){if(cashCountBusy||!ownCashbookShift())return false;const values=cashCountValues(),normalized={};for(const key of CASH_COUNT_FIELDS){const n=normalCashAmount(values[key]);if(n===null){opsEl('cashCountMessage').textContent='Introduce importes válidos con hasta dos decimales.';if(!silent)opsEl('cashCount_'+key).focus();return false}normalized[key]=n.toFixed(2)}normalized.denomination_breakdown={};for(const group of ['loose_coins','wrapped_coins','banknotes']){normalized.denomination_breakdown[group]={};for(const [key,raw]of Object.entries(cashDenominationDraft[group]||{})){const n=normalCashAmount(raw);if(n===null){opsEl('cashCountMessage').textContent='Revisa los importes del desglose: usa como máximo dos decimales.';return false}normalized.denomination_breakdown[group][key]=n.toFixed(2)}}const shiftId=cashCountShiftId;cashCountBusy=true;opsEl('cashCountSave').disabled=true;try{const r=await db.rpc('parking_save_cash_count',{p_shift_id:shiftId,p_values:normalized});if(r.error)throw r.error;cashCountDirty=false;try{sessionStorage.removeItem(cashCountDraftKey(shiftId))}catch(e){}if(parkingCashbookData?.shift_id===shiftId){parkingCashbookData.cash_state=r.data;renderCashbookPanel(parkingCashbookData)}opsEl('cashCountMessage').textContent='Arqueo guardado.';return true}catch(e){opsEl('cashCountMessage').textContent='No se pudo guardar: '+e.message;return false}finally{cashCountBusy=false;opsEl('cashCountSave').disabled=!ownCashbookShift()}}
function cashEntryPendingKey(kind){return 'pld_cash_entry_pending:'+currentSession?.user?.id+':'+kind}
function restoreCashEntryPending(kind){try{cashEntryPending[kind]=JSON.parse(sessionStorage.getItem(cashEntryPendingKey(kind))||'null')}catch(e){cashEntryPending[kind]=null}}
function saveCashEntryPending(kind){try{if(cashEntryPending[kind])sessionStorage.setItem(cashEntryPendingKey(kind),JSON.stringify(cashEntryPending[kind]));else sessionStorage.removeItem(cashEntryPendingKey(kind))}catch(e){}}
function buildCashValeHtml(row){return buildCashWithdrawalHtml({...row,withdrawal_number:row.entry_number}).replaceAll('R-'+esc(row.entry_number),'V-'+esc(row.entry_number)).replace('ENTREGA DE EFECTIVO','VALE DE EFECTIVO').replace('HE RECIBIDO DE &nbsp;','Vale de &nbsp;').replace('LA CANTIDAD DE &nbsp;','por la cantidad de &nbsp;').replace('RECIBÍ<div>','DEBE<div>')}
async function printCashVale(row){await sendParkingPrint('cashvale',buildCashValeHtml(row))}
async function reprintCashVale(id){const row=(activeCashVouchers?.rows??parkingCashbookData?.cash_state?.entries??[]).find(e=>e.id===id&&e.kind==='voucher');if(!row)return;try{await printCashVale(row);opsEl('cashValeMessage').textContent=(typeof adminPrintNotice==='function'?adminPrintNotice('Vale V-'+row.entry_number+' · 1 copia enviada.'):'Vale V-'+row.entry_number+' · 1 copia enviada.')}catch(e){opsEl('cashValeMessage').textContent='No se pudo imprimir: '+e.message+'. Usa Reimprimir; no registres otro vale.'}}
async function submitCashEntry(kind){
 if(cashEntryBusy[kind])return;restoreCashEntryPending(kind);const prefix=kind==='expense'?'cashExpense':'cashVale',message=opsEl(prefix+'Message');
 if(!cashEntryPending[kind]){if(!ownCashbookShift()){message.textContent='Selecciona tu turno abierto para registrar el movimiento.';return}const amount=normalCashAmount(opsEl(prefix+'Amount').value),description=kind==='expense'?opsEl(prefix+'Description').value.trim():'';if(amount===null||amount<=0){message.textContent='Introduce un importe positivo con hasta dos decimales.';return}if(kind==='expense'&&!description){message.textContent='Escribe la descripción del gasto.';return}if(cashCountDirty&&!await saveCashCount(true)){message.textContent='Guarda primero los cambios del Resumen de caja.';return}cashEntryPending[kind]={shiftId:currentShift.id,requestId:crypto.randomUUID(),amount,description};saveCashEntryPending(kind)}
 cashEntryBusy[kind]=true;renderCashbookPanel(parkingCashbookData);message.textContent='Guardando…';
 try{const p=cashEntryPending[kind],r=await db.rpc('parking_register_cash_entry',{p_shift_id:p.shiftId,p_request_id:p.requestId,p_kind:kind,p_amount_eur:p.amount,p_description:p.description});if(r.error){if(r.error.code&&r.error.code!=='PGRST000'){cashEntryPending[kind]=null;saveCashEntryPending(kind)}throw r.error}if(!r.data?.id)throw Error('No se recibió la confirmación. Reintenta para recuperar el mismo movimiento.');const row=r.data;cashEntryPending[kind]=null;saveCashEntryPending(kind);opsEl(prefix+'Amount').value='';if(kind==='expense')opsEl(prefix+'Description').value='';message.textContent=kind==='expense'?'Gasto registrado.':'Vale V-'+row.entry_number+' registrado.';await loadCashbook();if(kind==='voucher'){try{await printCashVale(row);message.textContent=(typeof adminPrintNotice==='function'?adminPrintNotice('Vale V-'+row.entry_number+' registrado · 1 copia enviada.'):'Vale V-'+row.entry_number+' registrado · 1 copia enviada.')}catch(e){message.textContent='Vale guardado. No se pudo imprimir: '+e.message+'. Usa Reimprimir 1 copia; no registres otro vale.'}}}
 catch(e){message.textContent='No se pudo completar: '+e.message+'. '+(cashEntryPending[kind]?'Reintenta para recuperar el mismo movimiento.':'')}
 finally{cashEntryBusy[kind]=false;renderCashbookPanel(parkingCashbookData)}
}

async function cancelCashVale(id){
 if(cashValeCancelBusy||!ownCashbookShift())return;
 const row=activeCashVouchers?.rows?.find(e=>e.id===id);if(!row)return;
 if(cashCountDirty&&!await saveCashCount(true))return;
 cashValeCancelBusy=true;renderCashbookPanel(parkingCashbookData);
 try{const r=await db.rpc('parking_cancel_cash_voucher',{p_voucher_id:id,p_shift_id:currentShift.id});if(r.error)throw r.error;await loadCashbook();opsEl('cashValeMessage').textContent='Vale cancelado. '+money(row.amount_eur)+' devueltos a caja e incluidos en Billetes. Ajusta el desglose si has recibido monedas.'}
 catch(e){opsEl('cashValeMessage').textContent='No se pudo confirmar la cancelación: '+e.message+'. Puedes reintentarlo sin duplicar la devolución.'}
 finally{cashValeCancelBusy=false;renderCashbookPanel(parkingCashbookData)}
}

// Keep count entry fast for both pointer and keyboard users.
function selectCashCountField(event){
 const field=event.target;
 if(field?.tagName==='INPUT'&&!field.disabled)field.select();
}
function advanceCashCountField(event){
 if(event.key!=='Enter'||event.isComposing||event.target?.tagName!=='INPUT')return;
 event.preventDefault();
 if(event.repeat)return;
 const form=event.target.form;
 if(!form)return;
 const fields=[...form.querySelectorAll('input,button')].filter(field=>!field.disabled&&!field.readOnly&&field.type!=='hidden'&&field.getClientRects().length);
 const index=fields.indexOf(event.target),next=fields[index+(event.shiftKey?-1:1)];
 if(next)next.focus();
}
