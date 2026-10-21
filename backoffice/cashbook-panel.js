/* Shift-local cash reconciliation. All money writes are authenticated server RPCs. */
let cashbookActiveTab='income',cashCountDirty=false,cashCountShiftId=null,cashCountBusy=false;
const CASHBOOK_TABS=['income','count','withdrawals','expenses','vouchers'];
const CASH_COUNT_FIELDS=['opening_balance','loose_coins','wrapped_coins','banknotes','vouchers'];
let cashDenominationDraft={},cashCountRevision=0,cashCountSavePromise=null,cashCountAutoTimer=null;
let activeCashVouchers=null,cashValeCancelBusy=false;
let cashEntryBusy={expense:false,voucher:false},cashEntryPending={};
function showCashbookTab(tab){cashbookActiveTab=CASHBOOK_TABS.includes(tab)?tab:'income';document.querySelectorAll('#cashbookTabs button').forEach(b=>b.classList.toggle('active',b.dataset.cashTab===cashbookActiveTab));document.querySelectorAll('.cashbookPane').forEach(e=>e.classList.toggle('hidden',e.dataset.cashPane!==cashbookActiveTab));if(cashbookActiveTab==='withdrawals')loadCashWithdrawals();saveParkingNavigation('cashbook')}
function ownCashbookShift(){return !!currentShift?.id&&currentAccessMode!=='free'&&parkingCashbookData?.shift_id===currentShift.id&&!parkingCashbookData.closed_at}
function cashCountDraftKey(id){return 'pld_cash_count_v1:'+currentSession?.user?.id+':'+id}
function cashCountValues(){return {...Object.fromEntries(CASH_COUNT_FIELDS.map(k=>[k,opsEl('cashCount_'+k).value])),denomination_breakdown:cashDenominationDraft}}
function renderCashDenominationInputs(state,own){
 cashDenominationDraft={};
 for(const [group,title]of [['loose_coins','MONEDAS SUELTAS'],['wrapped_coins','MONEDAS EMPAQUETADAS'],['banknotes','BILLETES SUELTOS'],['packed_banknotes','BILLETES EMPAQUETADOS']]){
  const defs=cashDenominations(group),values=cashBreakdownGroup(state,group);cashDenominationDraft[group]=values;
  opsEl('cashDenominations_'+group).innerHTML='<fieldset class="cashDenominationBlock"><legend>'+title+'</legend><table><thead><tr>'+defs.map(([,label])=>'<th>'+esc(label)+'</th>').join('')+'</tr></thead><tbody><tr>'+defs.map(([key,label])=>'<td><input id="cashDenom_'+group+'_'+key+'" aria-label="'+title+' '+esc(label)+' (importe en euros)" inputmode="decimal" draggable="false" oninput="cashDenominationChanged(\''+group+'\')"></td>').join('')+'</tr></tbody></table><p id="cashInheritedHint_'+group+'" class="muted" '+(values.unallocated?'':'hidden')+'>Recuento anterior pendiente de desglosar. Al rellenar estas casillas se sustituye por su suma.</p></fieldset>';
  for(const [key]of defs){const input=opsEl('cashDenom_'+group+'_'+key);input.value=Number(values[key]).toFixed(2);input.disabled=!own}
 }
}
function cashDenominationTotal(group){const values=cashDenominationDraft[group]||{};return (Math.round((normalCashAmount(values.unallocated)??0)*100)+cashDenominations(group).reduce((n,[key])=>n+Math.round((normalCashAmount(values[key])??0)*100),0))/100}
function cashDenominationChanged(changedGroup){
 for(const group of ['loose_coins','wrapped_coins','banknotes','packed_banknotes']){
  const remainder=group===changedGroup?0:(normalCashAmount(cashDenominationDraft[group]?.unallocated)??0),values={unallocated:remainder};let cents=Math.round(remainder*100);
  for(const [key]of cashDenominations(group)){const raw=opsEl('cashDenom_'+group+'_'+key).value.trim()||'0',n=normalCashAmount(raw);values[key]=raw;if(n!==null)cents+=Math.round(n*100)}
  cashDenominationDraft[group]=values;if(group==='banknotes'||group==='packed_banknotes'){const loose=group==='banknotes'?cents/100:cashDenominationTotal('banknotes');const packed=group==='packed_banknotes'?cents/100:cashDenominationTotal('packed_banknotes');opsEl('cashCount_banknotes').value=(loose+packed).toFixed(2)}else opsEl('cashCount_'+group).value=(cents/100).toFixed(2);
  if(group===changedGroup)opsEl('cashInheritedHint_'+group).hidden=true;
 }
 markCashCountDirty();
}
function normalCashAmount(value){const s=String(value??'').trim().replace(',','.');return /^\d+(\.\d{1,2})?$/.test(s)&&Number(s)<10000000000?Number(s):null}
function markCashCountDirty(){cashCountDirty=true;cashCountRevision++;try{sessionStorage.setItem(cashCountDraftKey(cashCountShiftId),JSON.stringify(cashCountValues()))}catch(e){}updateCashCountTotals();scheduleCashCountSave()}
function updateCashCountTotals(){const v=cashCountValues(),number=k=>normalCashAmount(v[k])??0,cash=number('loose_coins')+number('wrapped_coins')+number('banknotes'),counted=cash+number('vouchers'),t=cashbookTotals(parkingCashbookData?.rows||[]),expected=number('opening_balance')+t.cash-Number(parkingCashbookData?.cash_state?.expense_total||0)-Number(parkingCashbookData?.withdrawal_total_eur||0),difference=Math.round((counted-expected)*100)/100;opsEl('cashCountTotal').textContent=money(cash);opsEl('cashCountBalance').textContent=money(counted);opsEl('cashCountExpected').textContent=money(expected);opsEl('cashCountDifference').textContent=money(difference);opsEl('cashCountDifference').style.color=difference?'#c62828':'#16804a';opsEl('cashCountMessage').textContent=cashCountDirty?'Cambios pendientes de guardar.':(parkingCashbookData?.cash_state?.saved?'Arqueo guardado.':'Comprueba el saldo de entrada y rellena el dinero contado.');}
function renderCashbookPanel(data){
 if(!data){for(const key of CASH_COUNT_FIELDS){if(!cashCountDirty)opsEl('cashCount_'+key).value='';opsEl('cashCount_'+key).disabled=true}for(const id of ['cashCountTotal','cashCountBalance','cashCountExpected','cashCountDifference'])opsEl(id).textContent='—';opsEl('cashCountSave').disabled=true;opsEl('cashCountMessage').textContent='Resumen no disponible. Pulsa Actualizar caja para cargar tu turno; estos campos no representan un saldo de cero.';return}
 const own=ownCashbookShift();if(cashCountShiftId!==data?.shift_id||!cashCountDirty){cashCountShiftId=data?.shift_id||null;cashCountDirty=false;let draft=null;try{if(own)draft=JSON.parse(sessionStorage.getItem(cashCountDraftKey(cashCountShiftId))||'null')}catch(e){}for(const k of CASH_COUNT_FIELDS)opsEl('cashCount_'+k).value=(k==='opening_balance'||k==='vouchers')?String(data?.cash_state?.[k]??0):(draft?.[k]??String(data?.cash_state?.[k]??0));cashCountDirty=!!draft;renderCashDenominationInputs({...data?.cash_state,...draft},own);}
 for(const group of ['loose_coins','wrapped_coins','banknotes','packed_banknotes'])for(const [key]of cashDenominations(group))opsEl('cashDenom_'+group+'_'+key).disabled=!own;
 for(const k of CASH_COUNT_FIELDS){opsEl('cashCount_'+k).disabled=!own;opsEl('cashCount_'+k).readOnly=true;}opsEl('cashCount_vouchers').readOnly=true;opsEl('cashCount_vouchers').value=String(data?.cash_state?.vouchers??0);opsEl('cashCountSave').disabled=!own||cashCountBusy;updateCashCountTotals();
 const entries=data?.cash_state?.entries||[];
 for(const kind of ['expense','voucher']){restoreCashEntryPending(kind);const prefix=kind==='expense'?'cashExpense':'cashVale',pending=cashEntryPending[kind];opsEl(prefix+'Amount').disabled=!own||!!pending||cashEntryBusy[kind];if(kind==='expense')opsEl(prefix+'Description').disabled=!own||!!pending||cashEntryBusy[kind];opsEl(prefix+'Submit').disabled=cashEntryBusy[kind]||(!own&&!pending);opsEl(prefix+'Submit').textContent=pending?'Reintentar registro':'Registrar e imprimir 1 copia';const rows=kind==='voucher'?(activeCashVouchers?.rows??data?.cash_state?.active_vouchers??entries.filter(e=>e.kind===kind)):entries.filter(e=>e.kind===kind);opsEl(prefix+'List').innerHTML=rows.length?`<div class="tableWrap"><table class="tbl"><thead><tr><th>Nº</th><th>Fecha</th><th>Empleado / descripción</th><th>Importe</th><th>Justificante</th></tr></thead><tbody>${rows.map(e=>`<tr><td>${kind==='expense'?'G':'V'}-${esc(e.entry_number)}</td><td>${esc(fmt(e.created_at))}</td><td>${esc(kind==='expense'?e.description:e.employee_name)}</td><td>${money(e.amount_eur)}</td><td><button class="mini" onclick="${kind==='expense'?'reprintCashExpense':'reprintCashVale'}('${esc(e.id)}')">Reimprimir 1 copia</button>${kind==='voucher'?` <button class="mini" ${!own||cashValeCancelBusy?'disabled':''} onclick="cancelCashVale('${esc(e.id)}')">Cancelar vale</button>`:''}</td></tr>`).join('')}</tbody></table></div>`:'<p class="muted">No hay '+(kind==='expense'?'gastos':'vales')+(kind==='voucher'?' pendientes.':' registrados en este turno.')+'</p>';}
 const legacy=Number(activeCashVouchers?.legacy_vouchers??data?.cash_state?.legacy_vouchers??0);restoreCashEntryPending('legacyVoucherReturn');const pendingLegacy=cashEntryPending.legacyVoucherReturn;if(legacy||pendingLegacy)opsEl('cashValeList').innerHTML+='<div class="panel"><b>Vales anteriores sin desglose individual: '+money(legacy)+'</b><p class="muted">Pendientes de turnos anteriores. Incluidos en el resumen de caja.</p><button class="mini" '+(!own||cashValeCancelBusy?'disabled':'')+' onclick="cancelLegacyCashVale()">'+(pendingLegacy?'Reintentar confirmación de devolución':'Cancelar vale anterior')+'</button></div>';
 showCashbookTab(cashbookActiveTab);
 if(own&&!cashCountBusy){if(!data.cash_state?.saved&&!cashCountDirty)markCashCountDirty();else if(cashCountDirty)scheduleCashCountSave()}
}
function scheduleCashCountSave(delay=600){
 clearTimeout(cashCountAutoTimer);
 if(cashCountDirty&&ownCashbookShift())cashCountAutoTimer=setTimeout(()=>{cashCountAutoTimer=null;saveCashCount(true)},delay);
}
function flushCashCountOnBlur(event){if(event.target?.tagName==='INPUT'&&cashCountDirty)scheduleCashCountSave(0)}
async function saveCashCount(silent=false){
 clearTimeout(cashCountAutoTimer);cashCountAutoTimer=null;
 if(cashCountSavePromise){const ok=await cashCountSavePromise;if(!ok)return false;return cashCountDirty?saveCashCount(silent):true}
 if(!ownCashbookShift())return false;
 cashCountSavePromise=persistCashCount(silent);
 let ok;try{ok=await cashCountSavePromise}finally{cashCountSavePromise=null}
 if(ok&&cashCountDirty&&ownCashbookShift())return saveCashCount(silent);
 return ok;
}
async function persistCashCount(silent){
 const values=cashCountValues(),normalized={};
 for(const key of CASH_COUNT_FIELDS){const n=normalCashAmount(values[key]);if(n===null){opsEl('cashCountMessage').textContent='Introduce importes válidos con hasta dos decimales. Los cambios siguen pendientes de guardar.';if(!silent)opsEl('cashCount_'+key).focus();return false}normalized[key]=n.toFixed(2)}
 normalized.denomination_breakdown={};
 for(const group of ['loose_coins','wrapped_coins','banknotes','packed_banknotes']){normalized.denomination_breakdown[group]={};for(const [key,raw]of Object.entries(cashDenominationDraft[group]||{})){const n=normalCashAmount(raw);if(n===null){opsEl('cashCountMessage').textContent='Revisa los importes del desglose: usa como máximo dos decimales. Los cambios siguen pendientes de guardar.';return false}normalized.denomination_breakdown[group][key]=n.toFixed(2)}}
 const shiftId=cashCountShiftId,revision=cashCountRevision;cashCountBusy=true;opsEl('cashCountSave').disabled=true;opsEl('cashCountMessage').textContent='Guardando automáticamente…';
 try{
  const r=await db.rpc('parking_save_cash_count',{p_shift_id:shiftId,p_values:normalized});if(r.error)throw r.error;
  if(cashCountShiftId===shiftId){
   if(parkingCashbookData?.shift_id===shiftId)parkingCashbookData.cash_state=r.data;
   if(cashCountRevision===revision){cashCountDirty=false;try{sessionStorage.removeItem(cashCountDraftKey(shiftId))}catch(e){}}
   updateCashCountTotals();if(!cashCountDirty)opsEl('cashCountMessage').textContent='Arqueo guardado automáticamente.';
  }
  return true;
 }catch(e){if(cashCountShiftId===shiftId)opsEl('cashCountMessage').textContent='No se pudo guardar: '+e.message+'. Los cambios se conservan pendientes; vuelve a intentarlo.';return false}
 finally{cashCountBusy=false;opsEl('cashCountSave').disabled=!ownCashbookShift()}
}

function cashEntryPendingKey(kind){return 'pld_cash_entry_pending:'+currentSession?.user?.id+':'+kind}
function restoreCashEntryPending(kind){try{cashEntryPending[kind]=JSON.parse(sessionStorage.getItem(cashEntryPendingKey(kind))||'null')}catch(e){cashEntryPending[kind]=null}}
function saveCashEntryPending(kind){try{if(cashEntryPending[kind])sessionStorage.setItem(cashEntryPendingKey(kind),JSON.stringify(cashEntryPending[kind]));else sessionStorage.removeItem(cashEntryPendingKey(kind))}catch(e){}}
function buildCashValeHtml(row){return buildCashWithdrawalHtml({...row,withdrawal_number:row.entry_number}).replaceAll('R-'+esc(row.entry_number),'V-'+esc(row.entry_number)).replace('ENTREGA DE EFECTIVO','VALE DE EFECTIVO').replace('HE RECIBIDO DE &nbsp;','Vale de &nbsp;').replace('LA CANTIDAD DE &nbsp;','por la cantidad de &nbsp;').replace('RECIBÍ<div>','DEBE<div>')}
async function printCashVale(row){await sendParkingPrint('cashvale',buildCashValeHtml(row))}
async function reprintCashVale(id){const row=(activeCashVouchers?.rows??parkingCashbookData?.cash_state?.entries??[]).find(e=>e.id===id&&e.kind==='voucher');if(!row)return;try{await printCashVale(row);opsEl('cashValeMessage').textContent=(typeof adminPrintNotice==='function'?adminPrintNotice('Vale V-'+row.entry_number+' · 1 copia enviada.'):'Vale V-'+row.entry_number+' · 1 copia enviada.')}catch(e){opsEl('cashValeMessage').textContent='No se pudo imprimir: '+e.message+'. Usa Reimprimir; no registres otro vale.'}}
function buildCashExpenseHtml(row){return buildCashWithdrawalHtml({...row,withdrawal_number:row.entry_number}).replaceAll('R-'+esc(row.entry_number),'G-'+esc(row.entry_number)).replace('Entrega de efectivo','Recibo de gasto').replace('ENTREGA DE EFECTIVO','RECIBO DE GASTO').replace('HE RECIBIDO DE &nbsp;','Registrado por &nbsp;').replace('LA CANTIDAD DE &nbsp;','Importe &nbsp;').replace('.sentence{margin-top:18mm;line-height:1.8;','.sentence{margin-top:10mm;line-height:1.5;').replace('.signature{','.expenseConcept{margin-top:4mm;font-size:12px;line-height:1.4;overflow-wrap:anywhere}.signature{').replace('top:60mm','top:70mm').replace('<div class="signature">','<div class="expenseConcept"><b>CONCEPTO:</b> '+esc(row.description||'')+'</div><div class="signature">')}
async function printCashExpense(row){await sendParkingPrint('cashexpense',buildCashExpenseHtml(row))}
async function reprintCashExpense(id){const row=(parkingCashbookData?.cash_state?.entries||[]).find(e=>e.id===id&&e.kind==='expense');if(!row)return;try{await printCashExpense(row);opsEl('cashExpenseMessage').textContent=(typeof adminPrintNotice==='function'?adminPrintNotice('Gasto G-'+row.entry_number+' · 1 copia enviada.'):'Gasto G-'+row.entry_number+' · 1 copia enviada.')}catch(e){opsEl('cashExpenseMessage').textContent='No se pudo imprimir: '+e.message+'. Usa Reimprimir; no registres otro gasto.'}}
async function submitCashEntry(kind){
 if(cashEntryBusy[kind])return;restoreCashEntryPending(kind);const prefix=kind==='expense'?'cashExpense':'cashVale',message=opsEl(prefix+'Message');
 if(!cashEntryPending[kind]){if(!ownCashbookShift()){message.textContent='Selecciona tu turno abierto para registrar el movimiento.';return}const amount=normalCashAmount(opsEl(prefix+'Amount').value),description=kind==='expense'?opsEl(prefix+'Description').value.trim():'';if(amount===null||amount<=0){message.textContent='Introduce un importe positivo con hasta dos decimales.';return}if(kind==='expense'&&!description){message.textContent='Escribe la descripción del gasto.';return}if(cashCountDirty&&!await saveCashCount(true)){message.textContent='Guarda primero los cambios del Resumen de caja.';return}cashEntryPending[kind]={shiftId:currentShift.id,requestId:crypto.randomUUID(),amount,description};saveCashEntryPending(kind)}
 cashEntryBusy[kind]=true;renderCashbookPanel(parkingCashbookData);message.textContent='Guardando…';
 try{const p=cashEntryPending[kind],r=await db.rpc('parking_register_cash_entry',{p_shift_id:p.shiftId,p_request_id:p.requestId,p_kind:kind,p_amount_eur:p.amount,p_description:p.description});if(r.error){if(r.error.code&&r.error.code!=='PGRST000'){cashEntryPending[kind]=null;saveCashEntryPending(kind)}throw r.error}if(!r.data?.id)throw Error('No se recibió la confirmación. Reintenta para recuperar el mismo movimiento.');const row=r.data;cashEntryPending[kind]=null;saveCashEntryPending(kind);opsEl(prefix+'Amount').value='';if(kind==='expense')opsEl(prefix+'Description').value='';message.textContent=kind==='expense'?'Gasto registrado.':'Vale V-'+row.entry_number+' registrado.';await loadCashbook();const label=kind==='expense'?'Gasto G-':'Vale V-';try{if(kind==='expense')await printCashExpense(row);else await printCashVale(row);const notice=label+row.entry_number+' registrado · 1 copia enviada.';message.textContent=typeof adminPrintNotice==='function'?adminPrintNotice(notice):notice}catch(e){message.textContent=(kind==='expense'?'Gasto':'Vale')+' guardado. No se pudo imprimir: '+e.message+'. Usa Reimprimir 1 copia; no registres otro '+(kind==='expense'?'gasto':'vale')+'.'}}
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

// Opening IOUs remain visible across shifts; retries keep the same redemption reference.
async function cancelLegacyCashVale(){
 if(cashValeCancelBusy||!ownCashbookShift())return;
 restoreCashEntryPending('legacyVoucherReturn');
 if(!cashEntryPending.legacyVoucherReturn){
  const remaining=Number(activeCashVouchers?.legacy_vouchers??parkingCashbookData?.cash_state?.legacy_vouchers??0);
  if(remaining<=0)return;
  const raw=prompt('Importe del vale anterior devuelto a caja (€). Pendiente: '+money(remaining),String(remaining));if(raw===null)return;
  const amount=normalCashAmount(raw);if(amount===null||amount<=0||amount>remaining){opsEl('cashValeMessage').textContent='Introduce un importe positivo que no supere los vales pendientes.';return}
  if(!confirm('¿Confirmar la devolución de '+money(amount)+' a caja y cancelar ese importe de los vales anteriores?'))return;
  if(cashCountDirty&&!await saveCashCount(true))return;
  cashEntryPending.legacyVoucherReturn={shiftId:currentShift.id,requestId:crypto.randomUUID(),amount};saveCashEntryPending('legacyVoucherReturn');
 }
 cashValeCancelBusy=true;renderCashbookPanel(parkingCashbookData);
 try{
  const p=cashEntryPending.legacyVoucherReturn,r=await db.rpc('parking_cancel_legacy_cash_vouchers',{p_shift_id:p.shiftId,p_request_id:p.requestId,p_amount_eur:p.amount});
  if(r.error){if(r.error.code==='P0001'){cashEntryPending.legacyVoucherReturn=null;saveCashEntryPending('legacyVoucherReturn')}throw r.error}if(!r.data?.request_id)throw Error('No se recibió la confirmación');
  cashEntryPending.legacyVoucherReturn=null;saveCashEntryPending('legacyVoucherReturn');await loadCashbook();
  opsEl('cashValeMessage').textContent='Vale anterior cancelado. '+money(r.data.amount_eur)+' devueltos a caja e incluidos en Billetes. Ajusta el desglose si has recibido monedas.';
 }catch(e){if(!cashEntryPending.legacyVoucherReturn){try{await loadCashbook()}catch(refreshError){}}opsEl('cashValeMessage').textContent='No se pudo confirmar la devolución: '+e.message+(cashEntryPending.legacyVoucherReturn?'. Reintenta para confirmar la misma operación sin duplicarla.':'. Revisa los vales pendientes actualizados.')}
 finally{cashValeCancelBusy=false;renderCashbookPanel(parkingCashbookData)}
}

function blockCashCountDrag(event){if(event.target?.closest?.('[id^="cashDenom_"]')){event.preventDefault();if(event.dataTransfer)event.dataTransfer.dropEffect='none'}}
