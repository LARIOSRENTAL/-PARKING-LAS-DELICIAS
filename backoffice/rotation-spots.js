function orderedRotationTariffs(){const order=['TURISMO','COCHERA','CAMION','MOTO'];return [...rotationTariffs].sort((a,b)=>(order.includes(a.code)?order.indexOf(a.code):99)-(order.includes(b.code)?order.indexOf(b.code):99))}
function prepareRotationEntryTariff(){const field=opsEl('rotTariff');field.disabled=false;opsEl('rotKeyNumber').value='';hideRotationSpotMatches();opsEl('rotSpotStatus').textContent='Elige tarifa y pulsa Intro para seleccionar plaza.';field.focus()}
/* Rotation uses the same named inventory as stays. A = Salón Alto (no keys). */
let rotationAvailableSpots=[],rotationSpotsLoaded=false,rotationSpotsRequest=0,rotationEntryBusy=false;
function rotationSpotType(code){return {COCHERA:'XL',CAMION:'XXL'}[code]||code}
function normalizeRotationSpot(value){return String(value||'').toUpperCase().replace(/[^A-Z0-9]/g,'')}
function rotationSpotCandidates(){const category=rotationSpotType(opsEl('rotTariff').value),all=[...rotationAvailableSpots];if(currentRotationSession?.spot_id&&!all.some(s=>s.id===currentRotationSession.spot_id)){const s=spots.find(s=>s.id===currentRotationSession.spot_id);if(s)all.push({...s,vehicle_type:vehicleTypes.find(t=>t.id===s.vehicle_type_id)?.code,leaves_keys:!['A','M'].includes(s.zone)})}return all.filter(s=>parkingSizeFits(s.polyvalent?'POLIVALENTE':s.vehicle_type,category))}
function selectedRotationSpot(){const text=normalizeRotationSpot(opsEl('rotKeyNumber').value);if(!text)return null;const matches=rotationSpotCandidates().filter(s=>(normalizeRotationSpot(s.code)===text||(/^\d+$/.test(text)&&Number(s.code.match(/\d+$/)?.[0])===Number(text))));return matches.length===1?matches[0]:null}
function rotationClientLeavesKeys(spot){return !!opsEl('rotClient').value.trim()||!spot||!['A','M'].includes(spot.zone);}
function applyRotationSpotKeys(){const s=selectedRotationSpot();opsEl('rotLeavesKeys').checked=rotationClientLeavesKeys(s);opsEl('rotLeavesKeys').disabled=true;opsEl('rotKeyNumber').disabled=!!currentRotationSession?.billing_only;return s}
toggleRotationKey=applyRotationSpotKeys;
function renderRotationSpotOptions(){const candidates=rotationSpotCandidates();opsEl('rotSpotOptions').innerHTML=candidates.map(s=>`<option value="${esc(s.code)}">${esc(s.spot_class||'')}</option>`).join('');applyRotationSpotKeys();if(opsEl('rotationSpotMatches')?.style.display==='block')showRotationSpotMatches()}
async function loadRotationSpotOptions(){const warning=opsEl('rotLegacyWarning'),unassigned=typeof rotationUnassignedCount==='number'?rotationUnassignedCount:0;if(warning){warning.textContent=unassigned+' tickets anteriores sin plaza asignada: localízalos en Ocupación y asigna su plaza desde Actualizar datos.';warning.classList.toggle('hidden',!unassigned)}const serial=++rotationSpotsRequest;const r=await db.rpc('parking_available_rotation_spots',{p_tariff_code:null});if(serial!==rotationSpotsRequest)return false;if(r.error){rotationSpotsLoaded=false;rotationAvailableSpots=[];renderRotationSpotOptions();opsEl('rotSpotStatus').textContent='No se pudieron consultar las plazas: '+r.error.message;return false}rotationAvailableSpots=r.data||[];rotationSpotsLoaded=true;renderRotationSpotOptions();opsEl('rotSpotStatus').textContent=rotationSpotCandidates().length+' plazas disponibles para este tamaño. Escribe el código o elige entre todas las plazas libres.';return true}
let rotationSpotMatchRows=[],rotationSpotMatchIndex=-1;
function hideRotationSpotMatches(){const list=opsEl('rotationSpotMatches');if(list)list.style.display='none';opsEl('rotKeyNumber').setAttribute('aria-expanded','false');opsEl('rotKeyNumber').removeAttribute('aria-activedescendant');rotationSpotMatchIndex=-1}
function rotationSpotInputMatches(s,text){return (!text||normalizeRotationSpot(s.code).startsWith(text)||(/^\d+$/.test(text)&&String(s.code.match(/\d+$/)?.[0]||'').startsWith(text)))}
function showRotationSpotMatches(){
 const list=opsEl('rotationSpotMatches'),input=opsEl('rotKeyNumber');if(!list||input.disabled)return;
 const text=normalizeRotationSpot(input.value);
 rotationSpotMatchRows=rotationSpotCandidates().filter(s=>['A','M'].includes(text)?s.zone===text:rotationSpotInputMatches(s,text));if(['A','M'].includes(text))rotationSpotMatchRows.sort((a,b)=>a.code.localeCompare(b.code,'es',{numeric:true}));rotationSpotMatchIndex=['A','M'].includes(text)&&rotationSpotMatchRows.length?0:-1;
 list.innerHTML=rotationSpotMatchRows.length?rotationSpotMatchRows.map((s,i)=>'<button type="button" role="option" id="rotationSpotMatch-'+i+'" data-spot-index="'+i+'" aria-selected="'+(i===rotationSpotMatchIndex?'true':'false')+'" style="display:block;width:100%;padding:10px 12px;background:white;border:0;border-bottom:1px solid #dce4ec;text-align:left;color:#142b40;font-size:16px;cursor:pointer"><b>'+esc(s.code)+'</b> · '+esc(['A','M'].includes(s.zone)?s.spot_class+(rotationClientLeavesKeys(s)?' · Deja llaves':' · Sin llaves'):s.spot_class||s.vehicle_type||'Disponible')+'</button>').join(''):'<div style="padding:12px;color:#a51d32">No hay plazas disponibles que coincidan.</div>';
 list.style.display='block';input.setAttribute('aria-expanded','true');if(rotationSpotMatchIndex===0){const first=rotationSpotMatchRows[0];input.setAttribute('aria-activedescendant','rotationSpotMatch-0');const option=list.querySelector?.('[data-spot-index]');if(option)option.style.backgroundColor='#e2f4ed';opsEl('rotSpotStatus').textContent='Plaza '+first.code+' seleccionada · Intro para dar entrada.'}
}
function chooseRotationSpotMatch(index){const s=rotationSpotMatchRows[index];if(!s)return;opsEl('rotKeyNumber').value=s.code;rotationSpotChanged();hideRotationSpotMatches();opsEl('rotKeyNumber').focus()}
function rotationSpotChanged(){
 const spot=applyRotationSpotKeys(),input=opsEl('rotKeyNumber'),status=opsEl('rotSpotStatus'),text=normalizeRotationSpot(input.value);
 const known=(spots||[]).some(s=>(normalizeRotationSpot(s.code)===text||(/^\d+$/.test(text)&&Number(s.code.match(/\d+$/)?.[0])===Number(text))));
 const unavailable=!!text&&!spot&&known;
 input.setCustomValidity(unavailable?'Plaza no disponible':'');input.setAttribute('aria-invalid',String(unavailable));
 input.style.borderColor=unavailable?'#c5283d':'';input.style.backgroundColor=unavailable?'#fff0f2':'';status.style.color=unavailable?'#b51e32':'';
 status.textContent=spot?'Plaza '+spot.code+(rotationClientLeavesKeys(spot)?' · Deja llaves':' · No deja llaves'):unavailable?'Plaza no disponible':'Escribe el código de cualquier plaza libre compatible.';
 return spot
}

async function prepareRotationEntrySpot(){if(!await loadRotationSpotOptions())return;opsEl('rotKeyNumber').disabled=false;opsEl('rotKeyNumber').value='';applyRotationSpotKeys();opsEl('rotSpotStatus').textContent='Escribe una plaza disponible y pulsa Enter para dar entrada.';opsEl('rotKeyNumber').focus()}
const previousRotationLookupWithSpots=rotationLookupPlate;
rotationLookupPlate=async function(showNotFound=false){const r=await previousRotationLookupWithSpots(showNotFound);if(r){const s=spots.find(s=>s.id===r.spot_id);opsEl('rotKeyNumber').value=r.spot_code||r.key_number||'';opsEl('rotTariff').disabled=true;if(!r.spot_id){opsEl('rotLeavesKeys').checked=!!r.leaves_keys;opsEl('rotKeyNumber').disabled=!!r.billing_only}else{renderRotationSpotOptions();applyRotationSpotKeys()}}else opsEl('rotTariff').disabled=false;return r};
const previousRotationClearWithSpots=clearRotationDisplay;
clearRotationDisplay=function(keepPlate=false){const category=opsEl('rotTariff').value;rotationLookupSerial++;previousRotationClearWithSpots(keepPlate);opsEl('rotTariff').disabled=false;if(category)opsEl('rotTariff').value=category;opsEl('rotKeyNumber').value='';opsEl('rotKeyNumber').disabled=false;opsEl('rotKeyNumber').setCustomValidity('');opsEl('rotLeavesKeys').checked=true;hideRotationMatches();hideRotationSpotMatches();rotationSpotChanged()};
rotationTariffLabel=function(t){return t.name+' · máx. '+money(t.daily_cap_eur)+'/día'+(t.calculation_ready?'':' · TRAMOS PENDIENTES')};
const previousRotationInitWithSpots=initRotation;
initRotation=function(){previousRotationInitWithSpots();loadRotationSpotOptions()};
rotationCheckIn=async function(){if(rotationEntryBusy)return;const button=document.querySelector('button[onclick="rotationCheckIn()"]');if(button?.disabled)return;const plate=normalizeRotationPlate(opsEl('rotPlate').value);if(plate.length<3)return alert('Introduce una matrícula válida.');if(currentRotationSession)return alert('Ese vehículo ya consta dentro de Rotación.');if(!rotationSpotsLoaded){if(!await loadRotationSpotOptions())return}const spot=selectedRotationSpot();if(!spot){rotationSpotChanged();opsEl('rotKeyNumber').setCustomValidity('Plaza no disponible. Selecciona una plaza real disponible compatible con el tamaño del vehículo.');opsEl('rotKeyNumber').setAttribute('aria-invalid','true');opsEl('rotKeyNumber').style.borderColor='#c5283d';opsEl('rotKeyNumber').style.backgroundColor='#fff0f2';opsEl('rotSpotStatus').style.color='#b51e32';opsEl('rotSpotStatus').textContent='Plaza no disponible';opsEl('rotKeyNumber').reportValidity();opsEl('rotKeyNumber').focus();return}rotationEntryBusy=true;let registered=false;if(button)button.disabled=true;try{if(await checkParkingPlateInput(opsEl('rotPlate'),true))return;const r=await db.rpc('rotation_check_in',{p_tariff_code:opsEl('rotTariff').value,p_plate:plate,p_client_text:opsEl('rotClient').value,p_authorized_text:opsEl('rotAuthorized').value,p_leaves_keys:rotationClientLeavesKeys(spot),p_key_number:spot.code});if(r.error)throw r.error;registered=true;const session=r.data;clearTimeout(rotationPlateTimer);clearRotationDisplay();opsEl('rotPlate').focus();rotationAvailableSpots=rotationAvailableSpots.filter(s=>s.id!==spot.id);renderRotationSpotOptions();opsEl('rotSpotStatus').textContent='Entrada registrada · '+plate+' · Plaza '+spot.code;try{await printParkingThermal(buildRotationEntryTicket(session))}catch(e){alert('Entrada registrada para '+plate+'. No se imprimió el ticket: '+e.message+'. Usa Tickets emitidos para reimprimir; no vuelvas a dar entrada.')}await Promise.all([loadRotationSpotOptions(),refreshAll()])}catch(e){if(registered){opsEl('rotSpotStatus').textContent='Entrada registrada. No se pudo actualizar la vista: '+e.message;return}opsEl('rotSpotStatus').textContent='No se pudo dar entrada: '+e.message;await loadRotationSpotOptions();rotationSpotChanged();alert('No se pudo dar entrada: '+e.message)}finally{rotationEntryBusy=false;if(button)button.disabled=false}};
const spotField=opsEl('rotKeyNumber');
spotField.addEventListener('input',()=>{rotationSpotChanged();showRotationSpotMatches()});
spotField.addEventListener('focus',showRotationSpotMatches);
spotField.addEventListener('blur',()=>{rotationSpotChanged();hideRotationSpotMatches()});
const spotMatches=opsEl('rotationSpotMatches');
spotMatches.addEventListener('mousedown',e=>e.preventDefault());
spotMatches.addEventListener('click',e=>{const option=e.target.closest('[data-spot-index]');if(option)chooseRotationSpotMatch(Number(option.dataset.spotIndex))});spotField.addEventListener('change',()=>{const s=selectedRotationSpot();if(s)spotField.value=s.code;rotationSpotChanged()});
spotField.addEventListener('keydown',async event=>{
 if(event.key==='Escape'){hideRotationSpotMatches();return}
 if(event.key==='ArrowDown'||event.key==='ArrowUp'){
  event.preventDefault();if(opsEl('rotationSpotMatches').style.display!=='block')showRotationSpotMatches();
  if(!rotationSpotMatchRows.length)return;
  rotationSpotMatchIndex=(rotationSpotMatchIndex+(event.key==='ArrowDown'?1:-1)+rotationSpotMatchRows.length)%rotationSpotMatchRows.length;
  const options=opsEl('rotationSpotMatches').querySelectorAll('[data-spot-index]');
  options.forEach((el,i)=>{el.style.backgroundColor=i===rotationSpotMatchIndex?'#e2f4ed':'white';el.setAttribute('aria-selected',String(i===rotationSpotMatchIndex))});
  const active=options[rotationSpotMatchIndex];if(active){spotField.setAttribute('aria-activedescendant',active.id);active.scrollIntoView({block:'nearest'})}return
 }
 if(event.key==='Enter'){event.preventDefault();event.stopImmediatePropagation();if(['A','M'].includes(normalizeRotationSpot(spotField.value))){const zone=normalizeRotationSpot(spotField.value),available=rotationSpotCandidates().filter(s=>s.zone===zone).sort((a,b)=>a.code.localeCompare(b.code,'es',{numeric:true})),first=available[Math.max(0,rotationSpotMatchIndex)]||available[0];if(first){spotField.value=first.code;rotationSpotChanged();hideRotationSpotMatches();await rotationCheckIn()}else{rotationSpotChanged();opsEl('rotSpotStatus').textContent='No hay plazas '+zone+' disponibles para este tamaño.'}return}if(rotationSpotMatchIndex>=0){chooseRotationSpotMatch(rotationSpotMatchIndex);return}hideRotationSpotMatches();await rotationCheckIn()}
});
opsEl('rotTariff').addEventListener('change',()=>{spotField.value='';renderRotationSpotOptions();rotationSpotChanged()});

opsEl('rotTariff').addEventListener('keydown',async event=>{if(event.key!=='Enter'||event.repeat||event.isComposing)return;event.preventDefault();event.stopImmediatePropagation();if(currentRotationSession)return;await prepareRotationEntrySpot()});

opsEl('rotClient').addEventListener('input',rotationSpotChanged);
opsEl('rotClient').addEventListener('change',rotationSpotChanged);
