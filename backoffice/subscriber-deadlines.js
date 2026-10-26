/* Monthly payment deadlines use server-side Madrid dates and frozen collection prices. */
function subscriberMonthAlerts(rows){return rows.filter(s=>s.active&&!subscriberHasZeroCharge(s)&&s.monthly_charge?.overdue_alert)}
function subscriberMonthAlertHtml(rows){const late=subscriberMonthAlerts(rows);return late.length?'<div class="msg error" role="alert"><b>'+late.length+' abonado(s) sin pagar antes del día 15.</b> Revisa los marcados como IMPAGO. Las cuotas pendientes desde el día 10 se cobran sin descuento.</div>':''}
let subscriberDeadlineRequest=0;
async function refreshSubscriberDeadlineAlerts(){
 const box=document.getElementById('subscriberDueAlert');if(!box||!currentProfile)return;
 const request=++subscriberDeadlineRequest,parts=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:'Europe/Madrid',year:'numeric',month:'2-digit'}).formatToParts(new Date()).map(p=>[p.type,p.value])),month=parts.year+'-'+parts.month+'-01';
 const r=await db.rpc('parking_monthly_subscribers',{p_month:month});if(request!==subscriberDeadlineRequest)return;
 if(r.error){box.classList.remove('hidden');box.innerHTML='<div class="msg error">No se pudieron consultar las alertas de abonados. Actualiza la página.</div>';return}
 const late=subscriberMonthAlerts(r.data||[]);box.classList.toggle('hidden',!late.length);
 box.innerHTML=late.length?'<div class="msg error" role="alert"><b>'+late.length+' abonado(s) con impago desde el día 15.</b> <button class="mini red" onclick="showArea(\'subscribers\')">Revisar abonados</button></div>':'';
}

setInterval(()=>{if(currentProfile){if(typeof syncSubscriberBillingPeriod==='function'&&syncSubscriberBillingPeriod()&&document.getElementById('subscribers')?.classList.contains('active'))loadMonthlyPayments().catch(()=>{});refreshSubscriberDeadlineAlerts().catch(()=>{})}},60000);

function subscriberTrainingWindow(month,now=new Date()){return month==='2026-10'&&now>=new Date('2026-10-19T22:00:00Z')&&now<new Date('2026-10-24T22:00:00Z')}
function subscriberTrainingNotice(rows){return rows.some(s=>s.training?.active)||(typeof billingMonth==='function'&&subscriberTrainingWindow(billingMonth()))?'<div class="msg" role="status"><b>PRUEBAS · OCTUBRE</b><br>Las prácticas no generan ingresos ni facturas reales. El 25 de octubre se abrirán los recibos reales de noviembre.</div>':''}
