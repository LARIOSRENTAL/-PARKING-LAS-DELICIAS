/* Month-limited historical rotation documents, printed directly for employees. */
function rotationCurrentMonth(){
 const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Europe/Madrid',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date());
 const value=type=>parts.find(p=>p.type===type).value,y=value('year'),m=value('month');
 return {first:y+'-'+m+'-01',last:y+'-'+m+'-'+new Date(Number(y),Number(m),0).getDate(),today:y+'-'+m+'-'+value('day')};
}
function rotationCurrentMonthContains(stamp){if(!stamp)return false;const day=new Intl.DateTimeFormat('en-CA',{timeZone:'Europe/Madrid',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(stamp));const range=rotationCurrentMonth();return day>=range.first&&day<=range.last;}
loadRotationReport=async function(){
 const privileged=['admin','manager'].includes(currentProfile?.role),range=rotationCurrentMonth();
 const fromField=opsEl('rotationDateFrom'),toField=opsEl('rotationDateTo');
 for(const field of [fromField,toField])if(field){field.min=privileged?'':range.first;field.max=privileged?'':range.last;}
 const from=fromField?.value||range.today,to=toField?.value||range.today;
 if(from>to)return alert('Fechas no válidas');
 if(!privileged&&(from<range.first||to>range.last))return alert('Puedes consultar tickets únicamente del mes vigente.');
 const result=await db.rpc('parking_rotation_ticket_search',{p_from:from,p_to:to});if(result.error)return alert(result.error.message);
 const payment=opsEl('rotationPayFilter')?.value,min=opsEl('rotationMinAmount')?.value,max=opsEl('rotationMaxAmount')?.value,weekday=opsEl('rotationWeekday')?.value||'',plate=String(opsEl('rotationPlateSearch')?.value||'').trim().toUpperCase();
 rotationReportRows=(result.data||[]).filter(x=>(!payment||x.payment_method===payment)&&(!min||Number(x.amount_eur||0)>=Number(min))&&(!max||Number(x.amount_eur||0)<=Number(max))&&(weekday===''||new Date(x.entry_at).getDay()===Number(weekday))&&(!plate||String(x.plate||'').toUpperCase().includes(plate)));
 const rows=rotationReportRows,el=opsEl('rotationReportResults');if(!el)return;
 el.innerHTML='<p>'+rows.length+' tickets · Total cobrado '+money(rows.filter(x=>x.exit_at).reduce((a,x)=>a+Number(x.amount_eur||0),0))+(privileged?'':' · Consulta e impresión del mes vigente')+'</p><div class="tableWrap"><table class="tbl"><thead><tr><th>Ticket</th><th>Matrícula</th><th>Tarifa</th><th>Entrada</th><th>Salida</th><th>Importe</th><th>Pago</th><th>Documentos</th></tr></thead><tbody>'+rows.map(x=>'<tr><td>#'+x.ticket_number+'</td><td>'+esc(x.plate)+'</td><td>'+esc(x.rotation_tariffs?.name||'')+'</td><td>'+fmt(x.entry_at)+'</td><td>'+(x.exit_at?fmt(x.exit_at):'DENTRO')+'</td><td>'+(x.exit_at?money(x.amount_eur||0):'—')+'</td><td>'+esc(Number(x.amount_eur)===0?'':paymentMethodLabel(x.payment_method))+'</td><td>'+rotationReportActions(x,privileged)+'</td></tr>').join('')+'</tbody></table></div>';
};
rotationReportActions=function(row,privileged){
 if(row.status==='cancelled')return 'Convertido / cancelado';
 const allowed=privileged||rotationCurrentMonthContains(row.exit_at||row.entry_at);
 if(!allowed)return 'Fuera del mes vigente';
 let html='<button class="mini" onclick="reprintRotationEntryById(\''+row.id+'\')">Entrada</button>';
 if(row.status==='departed')html+=' <button class="mini" onclick="reprintSimplified(\'rotation\',\''+row.id+'\')">Ticket de cobro</button> <button class="mini" onclick="issueParkingInvoice(\'rotation\',\''+row.id+'\',null)">Factura</button>';
 return html;
};
(function(){
 const originalInvoice=issueParkingInvoice,originalEntry=reprintRotationEntryById;let invoiceBusy=false;
 reprintRotationEntryById=async function(id){const row=rotationReportRows.find(x=>x.id===id);if(!['admin','manager'].includes(currentProfile?.role)&&(!row||!rotationCurrentMonthContains(row.exit_at||row.entry_at)))return alert('Solo puedes imprimir tickets del mes vigente.');return originalEntry(id);};
 issueParkingInvoice=async function(type,id,month){
  if(type!=='rotation')return originalInvoice(type,id,month);if(invoiceBusy)return;invoiceBusy=true;
  try{
   const row=rotationReportRows.find(x=>x.id===id);let result=await db.rpc('parking_rotation_invoice_document',{p_session_id:id,p_customer:null});if(result.error)throw result.error;
   if(result.data.needs_customer){const customer=await openInvoiceCustomerForm({name:row?.client_text||'',search:row?.plate||''});if(!customer)return;result=await db.rpc('parking_rotation_invoice_document',{p_session_id:id,p_customer:customer});if(result.error)throw result.error;}
   if(result.data.doc_kind==='simplified')await printParkingThermal(buildSimplifiedTicket(result.data));
   else await sendParkingPrint('invoice',buildParkingInvoiceHtml(result.data));
  }catch(e){alert('No se pudo imprimir la factura: '+e.message+'. Si ya se emitió, vuelve a pulsar Factura para reimprimirla sin repetir el cobro.');}
  finally{invoiceBusy=false;}
 };
})();
