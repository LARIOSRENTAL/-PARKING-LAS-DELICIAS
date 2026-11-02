/* Payment-method correction: only payments in the logged-in employee's open shift. */
(function(){
 const previous=window.renderCashbook;
 if(typeof previous!=='function')return;
 window.renderCashbook=function(data){
   let html=previous(data);
   const own=!!currentShift?.id&&currentAccessMode!=='free'&&data?.shift_id===currentShift.id&&!data?.closed_at;
   if(!own)return html;
   // Add a compact editing table after the original income breakdown. No changes to printed reports.
   const rows=(data.rows||[]).filter(r=>r.shift_id===currentShift.id&&r.user_id===currentSession?.user?.id&&Number(r.amount_eur)>0&&['cash','card'].includes(r.payment_method)&&['rotation','reservation','stay_change','hotel_batch','subscriber_payment'].includes(r.entity_type));
   if(!rows.length)return html;
   html+='<div class="panel" style="margin-top:16px"><h3>Corregir forma de pago · turno abierto</h3><p class="muted">Solo modifica efectivo o tarjeta. El importe no cambia. Si corresponde, la factura simplificada recibe una nueva serie y numeración; se conserva un historial de la corrección.</p><div class="tableWrap"><table class="tbl"><thead><tr><th>Hora</th><th>Referencia</th><th>Importe</th><th>Forma actual</th><th>Corrección</th></tr></thead><tbody>'+rows.map(r=>'<tr><td>'+esc(fmt(r.paid_at))+'</td><td>'+esc(r.reference||r.plate||'')+'</td><td>'+money(r.amount_eur)+'</td><td>'+esc(paymentMethodLabel(r.payment_method))+'</td><td><button class="mini blue" onclick="correctCashbookPayment(\''+esc(r.id)+'\',\''+(r.payment_method==='cash'?'card':'cash')+'\')">Cambiar a '+(r.payment_method==='cash'?'tarjeta':'efectivo')+'</button></td></tr>').join('')+'</tbody></table></div><p id="paymentCorrectionFeedback" role="status"></p></div>';
   return html;
 };
 window.correctCashbookPayment=async function(movementId,newMethod){
   const shift=currentShift?.id;
   if(!shift||currentAccessMode==='free'||parkingCashbookData?.shift_id!==shift||parkingCashbookData?.closed_at){alert('Solo puedes corregir tu turno abierto.');return;}
   const row=(parkingCashbookData.rows||[]).find(r=>r.id===movementId&&r.shift_id===shift&&r.user_id===currentSession?.user?.id);
   if(!row||!['cash','card'].includes(row.payment_method)||newMethod==row.payment_method)return;
   if(!confirm('¿Cambiar '+money(row.amount_eur)+' de '+paymentMethodLabel(row.payment_method)+' a '+paymentMethodLabel(newMethod)+'? El importe no cambiará y se actualizará la numeración fiscal cuando corresponda.'))return;
   const node=document.getElementById('paymentCorrectionFeedback');if(node)node.textContent='Registrando corrección...';
   try{
      const result=await db.rpc('parking_correct_payment_method',{p_movement_id:movementId,p_new_method:newMethod});
      if(result.error)throw result.error;
      await loadCashbook();
      const notice=document.getElementById('paymentCorrectionFeedback');
      if(notice)notice.textContent='Cambio registrado. '+(result.data?.new_series?'Documento: '+result.data.new_series+' '+result.data.new_number:'');
   }catch(e){if(node)node.textContent='No se pudo corregir: '+e.message;else alert(e.message);}
 };
})();