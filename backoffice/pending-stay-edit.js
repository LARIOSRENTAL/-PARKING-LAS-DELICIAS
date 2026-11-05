/* Reservation edits never collect money; paid stays use the amendment workflow. */
let pendingStayEditState=null;
editVehicleData=async function(id){
 const r=reservations.find(x=>x.id===id);if(!r)return;
 if(r.payment_status==='paid'||r.last_movement_at)return modifyReservation(id);
 const state={reservation:{...r},busy:false,ready:true,serial:0};pendingStayEditState=state;
 const types=[...vehicleTypes];if(!types.some(t=>t.id===r.vehicle_type_id))types.unshift({id:r.vehicle_type_id,name:r.vehicle_types?.name||r.vehicle_type_name||'Tarifa actual'});
 const field=(id,label,value,type='text')=>'<div class="field"><label for="'+id+'">'+label+'</label><input id="'+id+'" type="'+type+'" value="'+esc(value||'')+'"></div>';
 opsModal('Editar estancia · '+stayControlNumber(r),'<p>Entrada: '+fmt(r.entry_at)+' · Fin previsto: '+fmt(r.exit_at)+' · '+Number(r.duration_days)+' día(s)</p><div class="grid2">'+field('pendingStayPlate','Matrícula',r.plate)+field('pendingStayModel','Marca / modelo',r.vehicle_make_model)+'</div><div class="field"><label for="pendingStayType">Tarifa / categoría del vehículo</label><select id="pendingStayType" onchange="quotePendingStayEdit()">'+types.map(t=>'<option value="'+esc(t.id)+'" '+(t.id===r.vehicle_type_id?'selected':'')+'>'+esc(t.name)+'</option>').join('')+'</select><small id="pendingStayTariffPrice">Precio de la estancia: '+money(r.amount_eur)+'</small></div><p class="muted">Se guardan los datos sin cobrar ni imprimir. Si la nueva categoría no cabe en la plaza asignada, se elegirá otra al dar entrada.</p>'+field('pendingStayName','Cliente',r.customer_name)+'<div class="grid2">'+field('pendingStayPhone','Teléfono',r.customer_phone,'tel')+field('pendingStayEmail','Email',r.customer_email,'email')+'</div><div class="field"><label for="pendingStayNotes">Observaciones</label><textarea id="pendingStayNotes">'+esc(r.notes||'')+'</textarea></div>','<button class="btn light" type="button" onclick="closeParkingOpsModal()">Cancelar</button><button class="btn green" type="button" id="pendingStaySave" onclick="savePendingStayEdit()">Guardar estancia</button>');
};
async function quotePendingStayEdit(){
 const state=pendingStayEditState;if(!state)return;const serial=++state.serial,type=opsEl('pendingStayType').value;state.ready=false;opsEl('pendingStaySave').disabled=true;
 try{
  let price=state.reservation.amount_eur;
  if(type!==state.reservation.vehicle_type_id){const result=await db.rpc('parking_stay_price',{p_vehicle_type_id:type,p_days:state.reservation.duration_days,p_entry_at:state.reservation.entry_at});if(result.error)throw result.error;if(result.data===null)throw Error('No hay tarifa para esta categoría y duración.');price=result.data;}
  if(pendingStayEditState!==state||state.serial!==serial||!opsEl('pendingStaySave'))return;
  state.ready=true;opsEl('pendingStayTariffPrice').textContent='Precio de la estancia: '+money(price);opsEl('pendingStaySave').disabled=state.busy;opsEl('parkingOpsMessage').textContent='';
 }catch(e){if(pendingStayEditState===state&&state.serial===serial&&opsEl('parkingOpsMessage'))opsEl('parkingOpsMessage').textContent=e.message;}
}
async function savePendingStayEdit(){
 const state=pendingStayEditState;if(!state||state.busy||!state.ready)return;
 const data={plate:opsEl('pendingStayPlate').value.trim(),model:opsEl('pendingStayModel').value.trim(),vehicle_type_id:opsEl('pendingStayType').value,name:opsEl('pendingStayName').value,phone:opsEl('pendingStayPhone').value,email:opsEl('pendingStayEmail').value,notes:opsEl('pendingStayNotes').value,expected_updated_at:state.reservation.updated_at};
 if(data.plate.length<3||data.model.length<1){opsEl('parkingOpsMessage').textContent='Completa matrícula y marca/modelo.';return;}
 state.busy=true;const button=opsEl('pendingStaySave');button.disabled=true;button.textContent='Guardando…';
 try{const result=await db.rpc('parking_edit_pending_stay',{p_reservation_id:state.reservation.id,p_data:data});if(result.error)throw result.error;closeParkingOpsModal();await refreshAll();}
 catch(e){if(opsEl('parkingOpsMessage'))opsEl('parkingOpsMessage').textContent='No se pudieron guardar los datos: '+e.message;}
 finally{state.busy=false;if(button.isConnected){button.disabled=!state.ready;button.textContent='Guardar estancia';}}
}

function refreshStayCountdowns(){for(const el of document.querySelectorAll('[data-stay-countdown]'))el.textContent=stayRemainingText(el.dataset.stayCountdown);}
setInterval(refreshStayCountdowns,1000);
document.addEventListener('visibilitychange',refreshStayCountdowns);
