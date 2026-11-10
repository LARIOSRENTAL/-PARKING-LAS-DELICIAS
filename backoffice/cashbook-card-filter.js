/* Screen-only card view. Original cashbook data and printed totals are unchanged. */
let cashbookCardsOnly=false,cashbookCardFilterShift=null;
function setCashbookCardsOnly(enabled){
 if(!['manager','admin'].includes(currentProfile?.role)||!parkingCashbookData)return;
 cashbookCardsOnly=!!enabled;cashbookCardFilterShift=parkingCashbookData.shift_id;
 document.getElementById('cashbookBody').innerHTML=renderCashbook(parkingCashbookData);
}
(function(){
 const previous=renderCashbook;
 renderCashbook=function(data){
  const original=previous(data);
  if(!['manager','admin'].includes(currentProfile?.role))return original;
  if(cashbookCardFilterShift!==data.shift_id){cashbookCardsOnly=false;cashbookCardFilterShift=data.shift_id;}
  const template=document.createElement('template');template.innerHTML=original;
  const summary=template.content.querySelector('.grid4');if(!summary)return original;
  const card=[...summary.children].find(panel=>panel.querySelector('b')?.textContent.trim()==='Tarjeta');
  if(card){const button=document.createElement('button');button.type='button';button.setAttribute('onclick','setCashbookCardsOnly('+!cashbookCardsOnly+')');button.setAttribute('aria-pressed',String(cashbookCardsOnly));button.title=cashbookCardsOnly?'Ver todos los ingresos':'Ver solo pagos con tarjeta';button.style.cssText='background:transparent;border:0;color:inherit;font:inherit;text-align:left;padding:0;width:100%;cursor:pointer';button.innerHTML=card.innerHTML;card.replaceChildren(button);}
  if(!cashbookCardsOnly)return template.innerHTML;
  const rows=(data.rows||[]).filter(r=>r.payment_method==='card').slice().sort((a,b)=>new Date(a.paid_at)-new Date(b.paid_at)||String(a.id).localeCompare(String(b.id)));
  const categories={rotation:'Rotación',stay:'Estancias',subscriber:'Abonados'};
  return summary.outerHTML+'<div class="toolbar"><h3>Pagos con tarjeta · '+rows.length+' cobros</h3><button type="button" class="btn light" onclick="setCashbookCardsOnly(false)">Ver todos los ingresos</button></div>'+(rows.length?'<div class="tableWrap"><table class="tbl"><thead><tr><th>Fecha y hora de cobro</th><th>Apartado</th><th>Ticket / matrícula</th><th>Concepto</th><th>Empleado</th><th>Importe</th></tr></thead><tbody>'+rows.map(r=>'<tr><td>'+esc(fmt(r.paid_at))+'</td><td>'+esc(categories[r.category]||r.category||'')+'</td><td>'+esc(r.reference||'')+'<br>'+esc(r.plate||'')+'</td><td>'+esc(r.description||'')+'</td><td>'+esc(r.employee_name||'')+'</td><td>'+money(r.amount_eur)+'</td></tr>').join('')+'</tbody></table></div>':'<p class="muted">No hay cobros con tarjeta en el turno seleccionado.</p>');
 };
})();
