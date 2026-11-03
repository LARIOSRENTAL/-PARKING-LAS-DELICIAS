(function(){
const original=buildVoucherHtml;
buildVoucherHtml=function(r,spot,entry,audit){
 let html=original(r,spot,entry,audit);
 if(!['hotel_voucher','hotel_voucher_old'].includes(r?.payment_method))return html;
 const name=parkingHotels.find(h=>h.id===r.hotel_id)?.name||r.parking_hotels?.name||String(r.notes||'').trim()||'HOTEL NO INDICADO';
 const safe=esc(name.toUpperCase());
 html=html.replace(/<tr><th>Tipo vehículo<\/th><td>[^<]*<\/td><\/tr>/,'<tr><th>Hotel</th><td>'+safe+'</td></tr>');
 html=html.replace(/<tr><th>Precio<\/th><td>[^<]*<\/td><\/tr>/,'');
 html=html.replace(/<div class="type">[^<]*<\/div>/,'<div class="type">'+safe+'</div>');
 return html;
};
})();