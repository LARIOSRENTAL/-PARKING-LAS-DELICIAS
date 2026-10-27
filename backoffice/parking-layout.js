/* The paid tariff stays unchanged when a larger physical space is assigned. */
function parkingSizeFits(space,vehicle){const rank={MOTO:0,TURISMO:1,XL:2,XXL:3,POLIVALENTE:3};return space in rank&&vehicle in rank&&rank[space]>=rank[vehicle]}
function spotFitsVehicle(s,typeId){const space=s.polyvalent?'POLIVALENTE':vehicleTypes.find(v=>v.id===s.vehicle_type_id)?.code;return parkingSizeFits(space,vehicleTypes.find(v=>v.id===typeId)?.code)}
const parkingZoneOrder=['J','C','B','M','LL','P','A','MOTO','RESERVA'];
let fixedSpotAssignments=[],parkingPlanZone='J',parkingPlanDetails=new Map();
function parkingMapPosition(zone,code){
 const n=Number(code.match(/\d+$/)?.[0]);let x,y,w=12,h=3.5;
 if(zone==='J'){
  if(n<=4){x=(4-n)*20;y=0;w=19;h=5.4}
  else if(n<=28){x=0;y=6+(n-5)*5.8;w=19;h=5.4}
  else if(n<=38){x=80;y=48+(38-n)*5.8;w=19;h=5.4}
  else if(n<=42){x=80;y=4+(42-n)*5.8;w=19;h=5.4}
  else if(n<=46){x=32+(46-n)*10;y=30;w=9;h=8}
  else if(n<=54){x=32;y=39+(n-47)*5.8;w=19;h=5.4}
  else{x=52;y=39+(62-n)*5.8;w=19;h=5.4}
  y/=1.5;h/=1.5;
 }else if(zone==='C'){
  w=15;h=7;
  if(n<=6){x=0;y=(n-2)*8}
  else if(n===7){x=0;y=46}
  else if(n<=13){x=0;y=54+(n-8)*7.5}
  else if(n===14){x=24;y=91;w=45}
  else if(n===15){x=75;y=91;w=24}
  else if(n<=19){x=84;y=83-(n-16)*8}
  else if(n===20){x=67;y=47;w=15;h=7}
  else if(n===21){x=53;y=39;w=15;h=7}
  else if(n===28){x=65;y=0}else{x=84;y=(27-n)*8}
 }else if(zone==='B'){
  w=14;h=7;
  if(n===3){x=0;y=91;h=8}
  else if(n===4){x=85;y=91;h=8}
  else if(n<=13){x=59;y=89-(n-5)*5.5;h=5.2}
  else if(n<=22){x=44;y=89-(n-14)*5.5;h=5.2}
  else if(n<=33){x=0;y=83-(n-23)*7.5;h=7}
  else if(n<=36){x=26;y=29-(n-34)*8;w=13}
  else if(n<=41){x=41+(n-37)*10;y=21;w=9;h=12}
  else if(n===42){x=26;y=0;w=27;h=8}
  else if(n===43){x=57;y=5;w=27;h=8}
  else{x=85;y=5;w=14;h=14}
 }else return '';
 if(zone==='C')x=100-x-w;
 return `left:${x}%;top:${y}%;width:${w}%;height:${h}%`;
}
function switchParkingPlanZone(zone){parkingPlanZone=zone;document.querySelectorAll('[data-plan-zone]').forEach(e=>{const on=e.dataset.planZone===zone;if(e.tagName==='BUTTON'){e.classList.toggle('active',on);e.setAttribute('aria-selected',String(on))}else e.hidden=!on});sizeParkingMap()}
function openParkingSpotDetail(id){
 const data=parkingPlanDetails.get(id);if(!data)return;
 let dialog=document.getElementById('parkingSpotDialog');if(!dialog){dialog=document.createElement('dialog');dialog.id='parkingSpotDialog';document.body.append(dialog)}
 dialog.innerHTML=`<div class="toolbar"><h3>${esc(data.spot.code)} · ${esc(data.state)}</h3><button class="mini" onclick="document.getElementById('parkingSpotDialog').close()">Cerrar</button></div><p>${esc(data.spot.spot_class)}${['A','M'].includes(data.spot.zone)?' · No deja llaves':''}</p>${data.detail||'<p>Sin vehículo asignado.</p>'}${data.actions}`;
 dialog.showModal();
}

function sizeParkingMap(){const map=document.querySelector('.planGroup:not([hidden]) .parkingMap');if(map)map.style.height=Math.max(parkingPlanZone==='J'?960:360,window.innerHeight-map.getBoundingClientRect().top-24)+'px'}
window.addEventListener('resize',sizeParkingMap);

function parkingSpotOperationDetails(spot,holders,assigned,session){
 let detail=holders.map(x=>'<div class="spotOperation"><b>Abonado</b><br>'+esc(x.customer_name)+'<br>Matrícula: <strong>'+esc(x.plate||'Sin matrícula')+'</strong></div>').join('');
 if(spot.inventory_state==='fixed'&&!holders.length)detail+='<p><b>Abonado</b> · Titular pendiente de identificar.</p>';
 detail+=assigned.map(r=>'<div class="spotOperation"><b>Estancia</b><br>Matrícula: <strong>'+esc(r.plate||'Sin matrícula')+'</strong><br>Fin previsto: <strong>'+fmt(r.exit_at)+'</strong><br><small>Entrada: '+fmt(r.entry_at)+'</small></div>').join('');
 if(session&&!assigned.some(r=>r.id===session.reservation_id)){
  const stay=!!session.reservation_id||!!session.planned_exit_at;
  detail+='<div class="spotOperation"><b>'+(stay?'Estancia':'Rotación')+'</b><br>Matrícula: <strong>'+esc(session.plate||'Sin matrícula')+'</strong>'+(stay?'<br>Fin previsto: <strong>'+fmt(session.planned_exit_at)+'</strong>':'')+'<br><small>Entrada: '+fmt(session.actual_entry_at||session.entry_at)+'</small></div>';
 }
 if(!detail&&spot.inventory_state==='blocked')detail='<p>Plaza ocupada / bloqueada. No hay una operación identificada.</p>';
 return detail;
}
