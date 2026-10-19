/* Rotation uses the same named inventory as stays. A = Salón Alto (no keys). */
let rotationAvailableSpots=[],rotationSpotsLoaded=false,rotationSpotsRequest=0,rotationEntryBusy=false;
function rotationSpotType(code){return {COCHERA:'XL',CAMION:'XXL'}[code]||code}
function normalizeRotationSpot(value){return String(value||'').toUpperCase().replace(/[^A-Z0-9]/g,'')}
function rotationSpotCandidates(){const category=rotationSpotType(opsEl('rotTariff').value),all=[...rotationAvailableSpots];if(currentRotationSession?.spot_id&&!all.some(s=>s.id===currentRotationSession.spot_id)){const s=spots.find(s=>s.id===currentRotationSession.spot_id);if(s)all.push({...s,vehicle_type:vehicleTypes.find(t=>t.id===s.vehicle_type_id)?.code,leaves_keys:!['A','M'].includes(s.zone)})}return all.filter(s=>parkingSizeFits(s.polyvalent?'POLIVALENTE':s.vehicle_type,category))}
function selectedRotationSpot(){const text=normalizeRotationSpot(opsEl('rotKeyNumber').value),group=opsEl('rotSpotGroup').value;if(!text)return null;const matches=rotationSpotCandidates().filter(s=>(!group||s.zone===group)&&(normalizeRotationSpot(s.code)===text||(/^\d+$/.test(text)&&group&&Number(s.code.match(/\d+$/)?.[0])===Number(text))));return matches.length===1?matches[0]:null}
function applyRotationSpotKeys(){const s=selectedRotationSpot();opsEl('rotLeavesKeys').checked=s?!['A','M'].includes(s.zone):true;opsEl('rotLeavesKeys').disabled=true;opsEl('rotKeyNumber').disabled=!!currentRotationSession?.billing_only;return s}
toggleRotationKey=applyRotationSpotKeys;
function renderRotationSpotOptions(){const field=opsEl('rotSpotGroup'),selected=field.value,candidates=rotationSpotCandidates(),groups=[...new Set(candidates.map(s=>s.zone).filter(Boolean))];field.innerHTML='<option value="">Todos los grupos</option>'+groups.map(g=>`<option value="${esc(g)}">${esc(g==='A'?'A · Salón Alto':g)} · ${candidates.filter(s=>s.zone===g).length} libres</option>`).join('');field.value=groups.includes(selected)?selected:'';opsEl('rotSpotOptions').innerHTML=candidates.filter(s=>!field.value||s.zone===field.value).map(s=>`<option value="${esc(s.code)}">${esc(s.spot_class||'')}</option>`).join('');applyRotationSpotKeys();if(opsEl('rotationSpotMatches')?.style.display==='block')showRotationSpotMatches()}
async function loadRotationSpotOptions(){const warning=opsEl('rotLegacyWarning'),unassigned=typeof rotationUnassignedCount==='number'?rotationUnassignedCount:0;if(warning){warning.textContent=unassigned+' tickets anteriores sin plaza asignada: localízalos en Ocupación y asigna su plaza desde Actualizar datos.';warning.classList.toggle('hidden',!unassigned)}const serial=++rotationSpotsRequest;const r=await db.rpc('parking_available_rotation_spots',{p_tariff_code:null});if(serial!==rotationSpotsRequest)return false;if(r.error){rotationSpotsLoaded=false;rotationAvailableSpots=[];renderRotationSpotOptions();opsEl('rotSpotStatus').textContent='No se pudieron consultar las plazas: '+r.error.message;return false}rotationAvailableSpots=r.data||[];rotationSpotsLoaded=true;renderRotationSpotOptions();opsEl('rotSpotStatus').textContent=rotationSpotCandidates().length+' plazas disponibles para este tamaño. Escribe el código completo o selecciona grupo y número.';return true}
let rotationSpotMatchRows=[],rotationSpotMatchIndex=-1;
function hideRotationSpotMatches(){const list=opsEl('rotationSpotMatches');if(list)list.style.display='none';opsEl('rotKeyNumber').setAttribute('aria-expanded','false');opsEl('rotKeyNumber').removeAttribute('aria-activedescendant');rotationSpotMatchIndex=-1}
function rotationSpotInputMatches(s,text,group){return (!group||s.zone===group)&&(!text||normalizeRotationSpot(s.code).startsWith(text)||(/^\d+$/.test(text)&&String(s.code.match(/\d+$/)?.[0]||'').startsWith(text)))}
function showRotationSpotMatches(){
 const list=opsEl('rotationSpotMatches'),input=opsEl('rotKeyNumber');if(!list||input.disabled)return;
 const text=normalizeRotationSpot(input.value),group=opsEl('rotSpotGroup').value;
 rotationSpotMatchRows=rotationSpotCandidates().filter(s=>rotationSpotInputMatches(s,text,group));rotationSpotMatchIndex=-1;
 list.innerHTML=rotationSpotMatchRows.length?rotationSpotMatchRows.map((s,i)=>'<button type="button" role="option" id="rotationSpotMatch-'+i+'" data-spot-index="'+i+'" aria-selected="false" style="display:block;width:100%;padding:10px 12px;background:white;border:0;border-bottom:1px solid #dce4ec;text-align:left;color:#142b40;font-size:16px;cursor:pointer"><b>'+esc(s.code)+'</b> · '+esc(['A','M'].includes(s.zone)?s.spot_class+' · Sin llaves':s.spot_class||s.vehicle_type||'Disponible')+'</button>').join(''):'<div style="padding:12px;color:#a51d32">No hay plazas disponibles que coincidan.</div>';
 list.style.display='block';input.setAttribute('aria-expanded','true')
}
function chooseRotationSpotMatch(index){const s=rotationSpotMatchRows[index];if(!s)return;opsEl('rotKeyNumber').value=s.code;rotationSpotChanged();hideRotationSpotMatches();opsEl('rotKeyNumber').focus()}
function rotationSpotChanged(){
 const spot=applyRotationSpotKeys(),input=opsEl('rotKeyNumber'),status=opsEl('rotSpotStatus'),text=normalizeRotationSpot(input.value),group=opsEl('rotSpotGroup').value;
 const known=(spots||[]).some(s=>(!group||s.zone===group)&&(normalizeRotationSpot(s.code)===text||(/^\d+$/.test(text)&&group&&Number(s.code.match(/\d+$/)?.[0])===Number(text))));
 const unavailable=!!text&&!spot&&known;
 input.setCustomValidity(unavailable?'Plaza no disponible':'');input.setAttribute('aria-invalid',String(unavailable));
 input.style.borderColor=unavailable?'#c5283d':'';input.style.backgroundColor=unavailable?'#fff0f2':'';status.style.color=unavailable?'#b51e32':'';
 status.textContent=spot?'Plaza '+spot.code+(['A','M'].includes(spot.zone)?' · No deja llaves':' · Deja llaves'):unavailable?'Plaza no disponible':'Selecciona una plaza disponible del grupo y tamaño indicados.';
 return spot
}

async function prepareRotationEntrySpot(){if(!await loadRotationSpotOptions())return;opsEl('rotKeyNumber').disabled=false;opsEl('rotKeyNumber').value='';applyRotationSpotKeys();opsEl('rotSpotStatus').textContent='Escribe una plaza disponible y pulsa Enter para dar entrada.';opsEl('rotKeyNumber').focus()}
const previousRotationLookupWithSpots=rotationLookupPlate;
rotationLookupPlate=async function(showNotFound=false){const r=await previousRotationLookupWithSpots(showNotFound);if(r){const s=spots.find(s=>s.id===r.spot_id);opsEl('rotKeyNumber').value=r.spot_code||r.key_number||'';opsEl('rotSpotGroup').value=s?.zone||'';opsEl('rotTariff').disabled=true;if(!r.spot_id){opsEl('rotLeavesKeys').checked=!!r.leaves_keys;opsEl('rotKeyNumber').disabled=!!r.billing_only}else{renderRotationSpotOptions();applyRotationSpotKeys()}}else opsEl('rotTariff').disabled=false;return r};
const previousRotationClearWithSpots=clearRotationDisplay;
clearRotationDisplay=function(keepPlate=false){const category=opsEl('rotTariff').value,group=opsEl('rotSpotGroup').value;rotationLookupSerial++;previousRotationClearWithSpots(keepPlate);opsEl('rotTariff').disabled=false;if(category)opsEl('rotTariff').value=category;opsEl('rotSpotGroup').value=group;opsEl('rotKeyNumber').value='';opsEl('rotKeyNumber').disabled=false;opsEl('rotKeyNumber').setCustomValidity('');opsEl('rotLeavesKeys').checked=true;hideRotationMatches();hideRotationSpotMatches();rotationSpotChanged()};
rotationTariffLabel=function(t){return t.name+' · máx. '+money(t.daily_cap_eur)+'/día'+(t.calculation_ready?'':' · TRAMOS PENDIENTES')};
const previousRotationInitWithSpots=initRotation;
initRotation=function(){previousRotationInitWithSpots();loadRotationSpotOptions()};
rotationCheckIn=async function(){if(rotationEntryBusy)return;const button=document.querySelector('button[onclick="rotationCheckIn()"]');if(button?.disabled)return;const plate=normalizeRotationPlate(opsEl('rotPlate').value);if(plate.length<3)return alert('Introduce una matrícula válida.');if(currentRotationSession)return alert('Ese vehículo ya consta dentro de Rotación.');if(!rotationSpotsLoaded){if(!await loadRotationSpotOptions())return}const spot=selectedRotationSpot();if(!spot){rotationSpotChanged();opsEl('rotKeyNumber').setCustomValidity('Plaza no disponible. Selecciona una plaza real disponible de su grupo y tamaño.');opsEl('rotKeyNumber').setAttribute('aria-invalid','true');opsEl('rotKeyNumber').style.borderColor='#c5283d';opsEl('rotKeyNumber').style.backgroundColor='#fff0f2';opsEl('rotSpotStatus').style.color='#b51e32';opsEl('rotSpotStatus').textContent='Plaza no disponible';opsEl('rotKeyNumber').reportValidity();opsEl('rotKeyNumber').focus();return}rotationEntryBusy=true;let registered=false;if(button)button.disabled=true;try{if(await checkParkingPlateInput(opsEl('rotPlate'),true))return;const r=await db.rpc('rotation_check_in',{p_tariff_code:opsEl('rotTariff').value,p_plate:plate,p_client_text:opsEl('rotClient').value,p_authorized_text:opsEl('rotAuthorized').value,p_leaves_keys:!['A','M'].includes(spot.zone),p_key_number:spot.code});if(r.error)throw r.error;registered=true;const session=r.data;clearTimeout(rotationPlateTimer);clearRotationDisplay();opsEl('rotPlate').focus();rotationAvailableSpots=rotationAvailableSpots.filter(s=>s.id!==spot.id);renderRotationSpotOptions();opsEl('rotSpotStatus').textContent='Entrada registrada · '+plate+' · Plaza '+spot.code;try{await printParkingThermal(buildRotationEntryTicket(session))}catch(e){alert('Entrada registrada para '+plate+'. No se imprimió el ticket: '+e.message+'. Usa Tickets emitidos para reimprimir; no vuelvas a dar entrada.')}await Promise.all([loadRotationSpotOptions(),refreshAll()])}catch(e){if(registered){opsEl('rotSpotStatus').textContent='Entrada registrada. No se pudo actualizar la vista: '+e.message;return}opsEl('rotSpotStatus').textContent='No se pudo dar entrada: '+e.message;await loadRotationSpotOptions();rotationSpotChanged();alert('No se pudo dar entrada: '+e.message)}finally{rotationEntryBusy=false;if(button)button.disabled=false}};
const groupField=opsEl('rotSpotGroup'),spotField=opsEl('rotKeyNumber');
groupField.addEventListener('change',()=>{spotField.value='';renderRotationSpotOptions();rotationSpotChanged();spotField.focus();showRotationSpotMatches()});
spotField.addEventListener('input',()=>{rotationSpotChanged();showRotationSpotMatches()});
spotField.addEventListener('focus',showRotationSpotMatches);
spotField.addEventListener('blur',()=>{rotationSpotChanged();hideRotationSpotMatches()});
const spotMatches=opsEl('rotationSpotMatches');
spotMatches.addEventListener('mousedown',e=>e.preventDefault());
spotMatches.addEventListener('click',e=>{const option=e.target.closest('[data-spot-index]');if(option)chooseRotationSpotMatch(Number(option.dataset.spotIndex))});spotField.addEventListener('change',()=>{const s=selectedRotationSpot();if(s)spotField.value=s.code;rotationSpotChanged()});
spotField.addEventListener('keydown',event=>{
 if(event.key==='Escape'){hideRotationSpotMatches();return}
 if(event.key==='ArrowDown'||event.key==='ArrowUp'){
  event.preventDefault();if(opsEl('rotationSpotMatches').style.display!=='block')showRotationSpotMatches();
  if(!rotationSpotMatchRows.length)return;
  rotationSpotMatchIndex=(rotationSpotMatchIndex+(event.key==='ArrowDown'?1:-1)+rotationSpotMatchRows.length)%rotationSpotMatchRows.length;
  const options=opsEl('rotationSpotMatches').querySelectorAll('[data-spot-index]');
  options.forEach((el,i)=>{el.style.backgroundColor=i===rotationSpotMatchIndex?'#e2f4ed':'white';el.setAttribute('aria-selected',String(i===rotationSpotMatchIndex))});
  const active=options[rotationSpotMatchIndex];if(active){spotField.setAttribute('aria-activedescendant',active.id);active.scrollIntoView({block:'nearest'})}return
 }
 if(event.key==='Enter'){event.preventDefault();event.stopImmediatePropagation();if(rotationSpotMatchIndex>=0){chooseRotationSpotMatch(rotationSpotMatchIndex);return}hideRotationSpotMatches();rotationCheckIn()}
});
opsEl('rotTariff').addEventListener('change',()=>{spotField.value='';renderRotationSpotOptions();rotationSpotChanged()});
