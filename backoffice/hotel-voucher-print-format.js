/* Hotel voucher printing: query voucher ownership before printing. */
(function(){
 const originalBuild=buildVoucherHtml,originalPrint=printEntryVoucher;
 async function details(r){
  const out={name:'',numbers:[]};let hotelId=r.hotel_id||null;
  if(!hotelId&&r.id){const current=await db.from('reservations').select('hotel_id').eq('id',r.id).maybeSingle();if(current.error)throw current.error;hotelId=current.data?.hotel_id||null;}
  if(r.payment_method==='hotel_voucher'){
   const v=await db.from('parking_hotel_vouchers').select('number,code,batch_id').eq('redeemed_reservation_id',r.id).order('number',{ascending:true});
   if(v.error)throw v.error;
   out.numbers=(v.data||[]).map(x=>String(x.number??x.code??'')).filter(Boolean);
   const batchIds=[...new Set((v.data||[]).map(x=>x.batch_id).filter(Boolean))];
   if(batchIds.length){
    const b=await db.from('parking_hotel_batches').select('hotel_id').in('id',batchIds);
    if(b.error)throw b.error;
    const hotels=[...new Set((b.data||[]).map(x=>x.hotel_id).filter(Boolean))];
    if(hotels.length>1)throw Error('La estancia contiene bonos de hoteles distintos.');
    hotelId=hotels[0]||hotelId;
   }
  }else{
   const v=await db.from('parking_legacy_hotel_vouchers').select('hotel_voucher_number,day_number').eq('reservation_id',r.id).order('day_number',{ascending:true});
   if(v.error)throw v.error;
   out.numbers=(v.data||[]).map(x=>String(x.hotel_voucher_number||'')).filter(Boolean);
  }
  if(hotelId){
   const h=await db.from('parking_hotels').select('name').eq('id',hotelId).maybeSingle();
   if(h.error)throw h.error;
   out.name=h.data?.name||'';
  }
  return out;
 }
 buildVoucherHtml=function(r,spot,entry,audit){
  let html=originalBuild(r,spot,entry,audit);
  if(!['hotel_voucher','hotel_voucher_old'].includes(r?.payment_method))return html;
  const name=String(r._hotelPrintName||r.hotel_name||parkingHotels.find(h=>h.id===r.hotel_id)?.name||r.parking_hotels?.name||'').toUpperCase();
  if(!name.trim())throw Error('Completa el nombre del hotel en Modificar estancia antes de imprimir el bono.');
  const safe=esc(name),codes=r._hotelPrintCodes||[];
  if(!codes.length)throw Error('No constan los números de los bonos utilizados. Revisa el pago antes de imprimir.');
  const control=esc(codes.join(', '));
  html=html.replace(/(<tr><th>Nº Control<\/th><td>)[^<]*(<\/td><\/tr>)/,(_,before,after)=>before+control+after);
  html=html.replace(/(<div class="control-number">)[^<]*(<\/div>)/,(_,before,after)=>before+control+after);
  html=html.replace(/<title>[\s\S]*?<\/title>/,()=>'<title>Bono '+control+'</title>');
  html=html.replace(/<tr><th>Tipo vehículo<\/th><td>[^<]*<\/td><\/tr>/,'<tr><th>Hotel</th><td>'+safe+'</td></tr>');
  html=html.replace(/<tr><th>Precio<\/th><td>[^<]*<\/td><\/tr>/,'');
  html=html.replace(/<div class="type">[^<]*<\/div>/,'<div class="type">'+safe+'</div>');
  return html;
 };
 window.hydrateParkingHotelVoucher=async function(r){if(!['hotel_voucher','hotel_voucher_old'].includes(r?.payment_method))return r;const d=await details(r);return {...r,_hotelPrintName:d.name,_hotelPrintCodes:d.numbers};};
 printEntryVoucher=async function(win,r,spot,entry,audit){
  if(!['hotel_voucher','hotel_voucher_old'].includes(r?.payment_method))return originalPrint(win,r,spot,entry,audit);
  try{
   const d=await details(r);
   return originalPrint(win,{...r,_hotelPrintName:d.name,_hotelPrintCodes:d.numbers},spot,entry,audit);
  }catch(e){
   console.error('Hotel voucher lookup failed',e);
   if(win)win.close();
   alert('Entrada registrada; impresión detenida porque no se pudo consultar el hotel y sus bonos: '+e.message);
  }
 };
})();

/* Backoffice visual and report fixes 2026-11-03. */
(function(){
 const style=document.createElement('style');
 style.textContent='#totalStaySearch{border:3px solid #cf2828!important;background:#fff2f2!important;font-weight:850!important;font-size:17px!important}label[for="totalStaySearch"]{color:#bc1717!important;font-weight:900!important;font-size:16px!important}#spots .spot strong{font-size:23px!important;font-weight:950!important}#spots .spot.free{background:#d5f4de!important;border:2px solid #31925d!important}#spots .spot.busy{background:#ffdddd!important;border:2px solid #c83c3c!important}#spots .spot.reservedOut{background:#ffe09a!important;border:2px solid #ac7000!important}';
 document.head.appendChild(style);
 const priorRows=totalStayDisplayRows;
 totalStayDisplayRows=function(mode){
  const q=String(document.getElementById('totalStaySearch')?.value||'').trim().toLocaleUpperCase('es');
  const rows=priorRows(mode);
  return q?rows.filter(r=>[r.plate,r.reference,r.spot,r.vehicle,r.customer].some(v=>String(v||'').toLocaleUpperCase('es').includes(q))):rows;
 };
 const priorSend=sendParkingPrint;
 sendParkingPrint=async function(kind,html,...args){
  if(kind==='staylist'&&typeof html==='string'){
   html=html.replace(/\.inside td\{background:#fff2d3\}/g,'.inside td{background:#fff}');
  }
  return priorSend(kind,html,...args);
 };
 const priorTickets=rotationTickets;
 rotationTickets=async function(...args){
  await priorTickets(...args);
  const container=document.getElementById('rotationMinAmount')?.closest('.grid3');
  if(container&&!document.getElementById('rotationPlateSearch')){
   const field=document.createElement('div');field.className='field';
   field.innerHTML='<label for="rotationPlateSearch">Buscar por matrícula</label><input id="rotationPlateSearch" type="search" placeholder="Matrícula completa o parcial">';
   container.prepend(field);
  }
 };
 const priorLoad=loadRotationReport;
 loadRotationReport=async function(...args){
  await priorLoad(...args);
  const q=String(document.getElementById('rotationPlateSearch')?.value||'').trim().toUpperCase();
  if(!q)return;
  rotationReportRows=rotationReportRows.filter(r=>String(r.plate||'').toUpperCase().includes(q));
  const el=document.getElementById('rotationReportResults');if(!el)return;
  const privileged=['admin','manager'].includes(currentProfile?.role),rows=rotationReportRows;
  el.innerHTML='<p>'+rows.length+' tickets · Total cobrado '+money(rows.filter(x=>x.exit_at).reduce((a,x)=>a+Number(x.amount_eur||0),0))+'</p><div class="tableWrap"><table class="tbl"><thead><tr><th>Ticket</th><th>Matrícula</th><th>Tarifa</th><th>Entrada</th><th>Salida</th><th>Importe</th><th>Pago</th><th>Documentos</th></tr></thead><tbody>'+rows.map(x=>'<tr><td>#'+x.ticket_number+'</td><td>'+esc(x.plate)+'</td><td>'+esc(x.rotation_tariffs?.name||'')+'</td><td>'+fmt(x.entry_at)+'</td><td>'+(x.exit_at?fmt(x.exit_at):'DENTRO')+'</td><td>'+(x.exit_at?money(x.amount_eur||0):'—')+'</td><td>'+esc(Number(x.amount_eur)===0?'':paymentMethodLabel(x.payment_method))+'</td><td>'+rotationReportActions(x,privileged)+'</td></tr>').join('')+'</tbody></table></div>';
 };
})();