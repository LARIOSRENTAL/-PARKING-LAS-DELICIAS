/* Early exits remain temporary; an overdue departure ends the stay and opens excess collection. */
function compareParkingStayEnd(endA,endB,tieA='',tieB=''){const timestamp=value=>{const n=value?new Date(value).getTime():NaN;return Number.isFinite(n)?n:Infinity},a=timestamp(endA),b=timestamp(endB);return (a<b?-1:a>b?1:0)||String(tieA).localeCompare(String(tieB),'es',{numeric:true})}
function isOpenParkingStay(r){return !!r&&!!r.last_movement_at&&!!r.assigned_spot_id&&!r.rotation_pending&&!r.finished_at&&['confirmed','checked_in'].includes(r.status)}
reservedOutsideSpotIds=function(){return new Set(reservations.filter(r=>isOpenParkingStay(r)&&r.vehicle_presence==='FUERA').map(r=>r.assigned_spot_id))};
loadOutside=async function(){outsideSessions=reservations.filter(r=>isOpenParkingStay(r)&&r.vehicle_presence==='FUERA').sort((a,b)=>compareParkingStayEnd(a.exit_at,b.exit_at,a.reference,b.reference));renderOutside()};
activeTotalStayRows=function(){const rows=new Map();for(const r of reservations){if(!isOpenParkingStay(r)||!['DENTRO','FUERA'].includes(r.vehicle_presence))continue;const spot=spots.find(s=>s.id===r.assigned_spot_id);rows.set(r.id,{reference:r.reference,spot:spot?.code||'—',plate:r.plate||'—',vehicle:r.vehicle_make_model||r.vehicle_types?.name||'',customer:r.customer_name||'—',phone:r.customer_phone||'',start:r.entry_at,end:r.exit_at,presence:r.vehicle_presence})}for(const s of insideSessions){if(s.billing_mode!=='reservation'||rows.has(s.reservation_id))continue;const r=reservations.find(r=>r.id===s.reservation_id);if(r&&(r.rotation_pending||r.finished_at||['completed','expired','cancelled'].includes(r.status)))continue;rows.set(s.reservation_id||s.id,{reference:r?.reference||'—',spot:s.parking_spots?.code||spots.find(x=>x.id===s.spot_id)?.code||'—',plate:s.plate||'—',vehicle:s.vehicle_make_model||'',customer:s.customer_name||'—',phone:s.customer_phone||'',start:s.actual_entry_at||s.planned_entry_at,end:s.planned_exit_at,presence:'DENTRO'})}return [...rows.values()].sort((a,b)=>compareParkingStayEnd(a.end,b.end,a.spot,b.spot))};
function addFinishStayButton(container,id){if(!container||!id)return;const button=document.createElement('button');button.type='button';button.className='mini red';button.textContent='Finalizar estancia';button.dataset.finishStay=id;button.onclick=()=>finishParkingStay(id);container.appendChild(button)}
const renderInsideBeforeManualFinish=renderInside;
renderInside=function(){insideSessions.sort((a,b)=>compareParkingStayEnd(a.planned_exit_at,b.planned_exit_at,a.parking_spots?.code,b.parking_spots?.code));renderInsideBeforeManualFinish();for(const s of insideSessions){const r=reservations.find(r=>r.id===s.reservation_id);if(!r||r.rotation_pending||!['confirmed','checked_in'].includes(r.status))continue;const out=opsEl('out-'+s.id);if(out)out.title=new Date(r.exit_at)<new Date()?'Finalizar estancia y cobrar el tiempo excedido en Rotación':'Salida temporal: conserva la estancia y su plaza hasta finalizarla';addFinishStayButton(out?.parentElement,s.reservation_id)}};
const renderOutsideBeforeManualFinish=renderOutside;
renderOutside=function(){outsideSessions.sort((a,b)=>compareParkingStayEnd(a.exit_at,b.exit_at,a.reference,b.reference));renderOutsideBeforeManualFinish();const rows=opsEl('outsideBody')?.querySelectorAll('tbody tr')||[];outsideSessions.forEach((r,i)=>addFinishStayButton(rows[i]?.querySelector('.actions'),r.id))};
checkOut=async function(sessionId,reservationId){
 const button=opsEl('out-'+sessionId);if(button?.disabled)return;if(button)button.disabled=true;
 try{
  const stay=reservations.find(r=>r.id===reservationId);
  if(stay&&new Date(stay.exit_at)<new Date()){await finishParkingStay(reservationId,false);return}
  const r=reservationId?await db.rpc('record_parking_movement',{p_reservation_id:reservationId,p_direction:'OUT'}):await db.rpc('backoffice_check_out',{p_session_id:sessionId,p_actual_exit_at:new Date().toISOString()});
  if(r.error)throw r.error;await refreshAll();
 }catch(e){alert('No se pudo marcar la salida: '+e.message)}finally{if(button)button.disabled=false}
};
async function openStayExcessCollection(rotation){
 currentStayRotationPlate=rotation.plate;
 opsEl('stayRotationInfo').textContent=(rotation.plate||'')+' · Rotación desde '+fmt(rotation.entry_at)+' · Ticket nº '+rotation.ticket_number;
 try{
  showArea('rotation');opsEl('rotPlate').value=rotation.plate;
  const found=await rotationLookupPlate(false);if(!found)throw Error('No se pudo recuperar el ticket pendiente');
  await rotationCheckOut();
 }catch(e){opsEl('stayRotationModal').classList.remove('hidden');alert('La salida está registrada y el exceso queda pendiente en Rotación. No se pudo abrir el cobro: '+e.message)}
}

const finishingParkingStays=new Set();
async function finishParkingStay(id,askConfirmation=true){if(finishingParkingStays.has(id))return;const r=reservations.find(x=>x.id===id);if(!r)return;const overdueInside=r.vehicle_presence==='DENTRO'&&new Date(r.exit_at)<new Date();if(askConfirmation&&!confirm('¿Finalizar la estancia de '+(r.plate||r.reference)+' y liberar su plaza?'+(overdueInside?' El tiempo excedido se gestionará en Rotación.':'')))return;finishingParkingStays.add(id);const buttons=[...document.querySelectorAll('[data-finish-stay]')].filter(b=>b.dataset.finishStay===id);buttons.forEach(b=>b.disabled=true);try{const result=await db.rpc('parking_finish_stay',{p_reservation_id:id});if(result.error)throw result.error;await refreshAll();const rotation=result.data.rotation;if(rotation)await openStayExcessCollection(rotation)}catch(e){alert('No se pudo finalizar la estancia: '+e.message)}finally{finishingParkingStays.delete(id);buttons.forEach(b=>b.disabled=false)}}
