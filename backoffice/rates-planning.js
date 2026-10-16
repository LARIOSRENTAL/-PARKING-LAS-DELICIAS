// Manager tariff configuration and the single inventory planning view.
let ratePeriods=[],rotationSpotSessions=[],rotationUnassignedCount=0;
function canManageRates(){return ['admin','manager'].includes(currentProfile?.role)}
function configureRatesAccess(){document.querySelector('[data-area="rates"]')?.classList.toggle('hidden',!canManageRates())}
async function loadRateConfiguration(){
 if(!canManageRates())return;
 const results=await Promise.all([db.from('tariffs').select('vehicle_type_id,days,price_eur').order('days'),db.from('rotation_tariffs').select('id,code,name,daily_cap_eur,rounding_step_eur,calculation_ready,capacity,sort_order').eq('active',true).order('sort_order'),db.from('rotation_tariff_segments').select('tariff_id,segment_order,from_minute,to_minute,price_per_minute_eur').order('segment_order'),db.from('parking_rate_periods').select('*').order('starts_on')]);
 const failed=results.find(r=>r.error);if(failed)return alert('No se pudieron cargar las tarifas: '+failed.error.message);
 [tariffs,rotationTariffs,rotationSegments,ratePeriods]=results.map(r=>r.data||[]);
 renderDailyRates();renderHourlyRates();renderRateEditor();
}
function renderRateEditor(){
 if(!canManageRates())return;
 let box=document.getElementById('rateEditor');if(!box){box=document.createElement('div');box.id='rateEditor';document.getElementById('rates').append(box)}
 box.innerHTML=`<div class="panel"><h3>Modificar tarifas</h3><p>Tarifa base: se aplica sin fecha final. Tarifa por fechas: se aplica desde el primer día hasta el último, ambos incluidos, según la hora de Málaga.</p><p class="muted">En estancias se usa la fecha de entrada y el precio total de la duración elegida. En Rotación se aplica a cada bloque de 24 horas desde la entrada. Las reservas ya creadas conservan su precio.</p><div class="grid3"><div class="field"><label>Servicio</label><select id="rateService" onchange="renderRateFields()"><option value="days">Estancias · días</option><option value="hourly">Rotación · horas</option></select></div><div class="field"><label>Aplicación</label><select id="rateMode" onchange="renderRateFields()"><option value="base">Tarifa base</option><option value="period">Fechas concretas</option></select></div></div><div id="rateFields"></div><div id="rateEditorMessage" role="status"></div><button id="rateSave" class="btn green" onclick="saveParkingRate()">Guardar tarifa</button><h3>Tarifas por fechas</h3><div class="tableWrap"><table class="tbl"><thead><tr><th>Servicio / categoría</th><th>Fechas</th><th>Precio</th><th></th></tr></thead><tbody>${ratePeriods.map(r=>`<tr><td>${r.service==='days'?esc(vehicleTypes.find(v=>v.id===r.vehicle_type_id)?.name||'')+' · '+r.days+' días':esc(rotationTariffs.find(v=>v.id===r.rotation_tariff_id)?.name||'')}</td><td>${esc(r.starts_on)} — ${esc(r.ends_on)}</td><td>${r.service==='days'?money(r.price_eur):'Tramos × '+Number(r.multiplier)+' · máximo '+money(r.daily_cap_eur)+'/día'}</td><td><button class="mini red" onclick="deleteRatePeriod('${r.id}')">Eliminar</button></td></tr>`).join('')||'<tr><td colspan="4">Sin tarifas por fechas.</td></tr>'}</tbody></table></div></div>`;
 renderRateFields();
}
function renderRateFields(){
 const hourly=document.getElementById('rateService').value==='hourly',period=document.getElementById('rateMode').value==='period';
 document.getElementById('rateFields').innerHTML=`<div class="grid3"><div class="field"><label>Categoría</label><select id="rateCategory" onchange="fillRateValues()">${(hourly?rotationTariffs:vehicleTypes).map(v=>`<option value="${v.id}">${esc(v.name)}</option>`).join('')}</select></div>${hourly?'':`<div class="field"><label>Duración</label><select id="rateDays" onchange="fillRateValues()">${Array.from({length:24},(_,i)=>`<option>${i+1}</option>`).join('')}</select></div>`}<div class="field"><label>${hourly?'Máximo por 24 horas (€)':'Precio total (€)'}</label><input id="ratePrice" type="number" min="0" step="0.01"></div></div>${period?'<div class="grid2"><div class="field"><label>Desde</label><input id="rateStart" type="date"></div><div class="field"><label>Hasta (incluido)</label><input id="rateEnd" type="date"></div></div>':''}${hourly?(period?'<div class="field"><label>Incremento sobre los tramos base (%)</label><input id="rateIncrease" type="number" min="-99.99" step="0.01" value="0"></div>':'<div id="rateSegmentFields"></div>'):''}`;
 fillRateValues();
}
function fillRateValues(){
 const hourly=document.getElementById('rateService').value==='hourly',id=document.getElementById('rateCategory').value;
 document.getElementById('ratePrice').value=hourly?(rotationTariffs.find(v=>v.id===id)?.daily_cap_eur??0):(tariffs.find(v=>v.vehicle_type_id===id&&Number(v.days)===Number(document.getElementById('rateDays').value))?.price_eur??0);
 const segBox=document.getElementById('rateSegmentFields');if(segBox)segBox.innerHTML='<h4>Precio por minuto de cada tramo</h4>'+rotationSegments.filter(v=>v.tariff_id===id).map(v=>`<div class="field"><label>${v.from_minute}–${v.to_minute} minutos · €/minuto</label><input class="rateSegmentInput" data-order="${v.segment_order}" type="number" min="0" step="0.00001" value="${v.price_per_minute_eur}"></div>`).join('');
}
async function saveParkingRate(){
 if(!canManageRates())return;
 const b=document.getElementById('rateSave');if(b.disabled)return;
 const hourly=rateService.value==='hourly',period=rateMode.value==='period',id=rateCategory.value,price=Number(ratePrice.value);
 if(!ratePrice.value||!Number.isFinite(price)||price<0)return alert('Introduce un precio válido.');
 b.disabled=true;try{
 let r;
 if(period){const start=document.getElementById('rateStart').value,end=document.getElementById('rateEnd').value;if(!start||!end||end<start)throw Error('Selecciona un intervalo de fechas válido.');const factor=hourly?1+Number(document.getElementById('rateIncrease').value)/100:1;if(!Number.isFinite(factor)||factor<=0)throw Error('Incremento no válido.');r=await db.from('parking_rate_periods').insert({service:hourly?'hourly':'days',vehicle_type_id:hourly?null:id,rotation_tariff_id:hourly?id:null,days:hourly?0:Number(rateDays.value),starts_on:start,ends_on:end,price_eur:hourly?null:price,multiplier:factor,daily_cap_eur:hourly?price:null});}
 else if(!hourly)r=await db.from('tariffs').upsert({vehicle_type_id:id,days:Number(rateDays.value),price_eur:price},{onConflict:'vehicle_type_id,days'});
 else {const segments=[...document.querySelectorAll('.rateSegmentInput')].map(el=>{const v=Number(el.value);if(!el.value||!Number.isFinite(v)||v<0)throw Error('Precio por minuto no válido.');return {...rotationSegments.find(s=>s.tariff_id===id&&s.segment_order===Number(el.dataset.order)),price_per_minute_eur:v}});r=await db.rpc('parking_save_rotation_rate',{p_tariff_id:id,p_daily_cap_eur:price,p_segments:segments});}
 if(r.error)throw r.error;await loadRateConfiguration();document.getElementById('rateEditorMessage').textContent='Tarifa guardada.';updateManualPrice();
 }catch(e){document.getElementById('rateEditorMessage').textContent='No se guardó la tarifa: '+e.message}finally{b.disabled=false}
}
async function deleteRatePeriod(id){if(!canManageRates()||!confirm('¿Eliminar esta tarifa por fechas? Se volverá a usar la tarifa base.'))return;const r=await db.from('parking_rate_periods').delete().eq('id',id);if(r.error)return alert(r.error.message);await loadRateConfiguration()}
let manualPriceRequest=0;
async function updateManualPrice(){
 const field=document.getElementById('mPrice');if(!field||!mType?.value||!mDays?.value||!mEntry?.value)return;
 const serial=++manualPriceRequest;
 const r=await db.rpc('parking_stay_price',{p_vehicle_type_id:mType.value,p_days:Number(mDays.value),p_entry_at:new Date(mEntry.value).toISOString()});
 if(serial!==manualPriceRequest)return;
 if(r.error){field.value='';document.getElementById('manualMsg').textContent='No se pudo calcular la tarifa: '+r.error.message;return}
 if(r.data!==null)field.value=Number(r.data).toFixed(2);
}
function availableInventorySpot(s){return !s.inventory_state||s.inventory_state==='available'}
function freeSpotsFor(typeId){const used=new Set([...insideSessions,...rotationSpotSessions].map(s=>s.spot_id).filter(Boolean)),reserved=reservedOutsideSpotIds();return spots.filter(s=>availableInventorySpot(s)&&(s.polyvalent||s.vehicle_type_id===typeId||(s.code==='P-11'&&vehicleTypes.find(v=>v.id===typeId)?.code==='XL'))&&!used.has(s.id)&&!reserved.has(s.id)&&!activeBlockForSpot(s.id))}
async function loadSpots(){
 const rotationRows=await db.from('rotation_sessions').select('id,spot_id,plate,entry_at').eq('status','inside').eq('billing_only',false);
 if(rotationRows.error){document.getElementById('spotsBody').textContent='No se pudo consultar la ocupación de Rotación: '+rotationRows.error.message;return}
 rotationUnassignedCount=(rotationRows.data||[]).filter(s=>!s.spot_id).length;
 rotationSpotSessions=(rotationRows.data||[]).filter(s=>s.spot_id).map(s=>({...s,actual_entry_at:s.entry_at}));
 await loadCapacityBlocks();
 const date=document.getElementById('spotPlanDate')?.value||localInput(new Date()).slice(0,10),start=new Date(date+'T00:00:00'),end=new Date(date+'T00:00:00');end.setDate(end.getDate()+1);
 const overlap=(a,b)=>new Date(a)<end&&new Date(b)>start;
 const stateFilter=document.getElementById('spotStateFilter')?.value||'',classFilter=document.getElementById('spotClassFilter')?.value||'';
 const live=reservations.filter(r=>!r.rotation_pending&&['confirmed','checked_in','pending_payment'].includes(r.status)&&(overlap(r.entry_at,r.exit_at)||(r.last_movement_at&&['confirmed','checked_in'].includes(r.status)&&new Date(r.entry_at)<end)));
 const used=new Map([...insideSessions,...rotationSpotSessions].filter(s=>s.spot_id).map(s=>[s.spot_id,s]));
 const zones=[...new Set(spots.map(s=>s.inventory_state==='legacy'?'PENDIENTES DE UBICAR':s.zone||'OTRAS'))];
 let html=(rotationUnassignedCount?'<div class="msg error">'+rotationUnassignedCount+' tickets anteriores de Rotación sin plaza asignada. Revisa Ocupación de Rotación y asigna su plaza desde Actualizar datos.</div>':'')+'<div class="msg">218 plazas del listado + 30 plazas de reserva polivalentes. FIJO: abonados · OCUPADO: bloqueada · PEQUEÑO-XL: categoría mixta.</div>';
 for(const zone of zones){let cards=[];for(const s of spots.filter(s=>(s.inventory_state==='legacy'?'PENDIENTES DE UBICAR':s.zone||'OTRAS')===zone)){
 const assigned=live.filter(r=>r.assigned_spot_id===s.id),u=used.get(s.id),b=capacityBlocks.find(b=>b.spot_id===s.id&&overlap(b.starts_at,b.ends_at));
 let state=s.inventory_state==='fixed'?'FIJO':s.inventory_state==='blocked'?'OCUPADO':b?'BLOQUEADA':assigned.length?'RESERVADA':s.inventory_state==='legacy'?'PENDIENTE DE UBICAR':'LIBRE';
 if(assigned.some(r=>r.last_movement_at))state=assigned.some(r=>r.vehicle_presence==='DENTRO')?'DENTRO':'FUERA';
 if(u&&new Date(u.actual_entry_at||u.planned_entry_at)<end)state='DENTRO';
 if(stateFilter&&stateFilter!==state)continue;if(classFilter&&s.spot_class!==classFilter)continue;
 const cls=state==='LIBRE'?'free':['FIJO','OCUPADO','BLOQUEADA'].includes(state)?'blocked':state==='DENTRO'?'busy':'reservedOut';
 const detail=assigned.map(r=>'<div><b>'+esc(r.plate||r.reference)+'</b><br><small>'+fmt(r.entry_at)+' → '+fmt(r.exit_at)+'</small></div>').join('')|| (u?'<div>'+esc(u.plate)+'</div>':'');
 cards.push(`<div class="spot ${cls}"><strong>${esc(s.code)}</strong><small>${esc(s.spot_class||'')} · ${state}</small>${detail}${canManageRates()&&s.inventory_state!=='legacy'?`<button class="mini" onclick="editInventoryState('${s.id}')">Estado</button>${state==='LIBRE'||state==='BLOQUEADA'?`<button class="mini" onclick="toggleSpotBlock('${s.id}')">${b?'Desbloquear':'Bloquear por fechas'}</button>`:''}`:''}</div>`)
 }if(cards.length)html+='<div class="panel"><h3>'+esc(zone)+'</h3><div class="spotGrid">'+cards.join('')+'</div></div>'}
 document.getElementById('spotsBody').innerHTML=html;renderQuickBlocks();
}
async function editInventoryState(id){
 if(!canManageRates())return;const spot=spots.find(s=>s.id===id);if(!spot)return;
 const answer=prompt('Estado de '+spot.code+': LIBRE, FIJO u OCUPADO',({available:'LIBRE',fixed:'FIJO',blocked:'OCUPADO'})[spot.inventory_state]);if(answer===null)return;
 const state=({LIBRE:'available',FIJO:'fixed',OCUPADO:'blocked'})[answer.trim().toUpperCase()];if(!state)return alert('Estado no válido.');
 if(state!=='available'&&([...insideSessions,...rotationSpotSessions].some(s=>s.spot_id===id)||reservations.some(r=>r.assigned_spot_id===id&&['confirmed','checked_in','pending_payment'].includes(r.status)&&(r.last_movement_at||new Date(r.exit_at)>new Date()))))return alert('Esta plaza tiene una estancia o reserva asignada. Cámbiala de plaza antes.');
 const r=await db.from('parking_spots').update({inventory_state:state}).eq('id',id);if(r.error)return alert(r.error.message);spot.inventory_state=state;await loadSpots();await loadReservations();
}

