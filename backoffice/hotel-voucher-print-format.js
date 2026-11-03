/* Hotel voucher printing: query voucher ownership before printing. */
(function(){
 const originalBuild=buildVoucherHtml,originalPrint=printEntryVoucher;
 async function details(r){
  const out={name:'',numbers:[]};let hotelId=r.hotel_id||null;
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
  const name=String(r._hotelPrintName||parkingHotels.find(h=>h.id===r.hotel_id)?.name||r.parking_hotels?.name||'HOTEL NO INDICADO').toUpperCase();
  const safe=esc(name),codes=r._hotelPrintCodes||[];
  if(codes.length){
   const control=esc(codes.join(', '));
   html=html.replace(/(<tr><th>Nº Control<\/th><td>)[^<]*(<\/td><\/tr>)/,'$1'+control+'$2');
   html=html.replace(/(<div class="control-number">)[^<]*(<\/div>)/,'$1'+control+'$2');
  }
  html=html.replace(/<tr><th>Tipo vehículo<\/th><td>[^<]*<\/td><\/tr>/,'<tr><th>Hotel</th><td>'+safe+'</td></tr>');
  html=html.replace(/<tr><th>Precio<\/th><td>[^<]*<\/td><\/tr>/,'');
  html=html.replace(/<div class="type">[^<]*<\/div>/,'<div class="type">'+safe+'</div>');
  return html;
 };
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