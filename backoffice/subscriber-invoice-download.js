/* Selected documents use the existing invoice preview; viewing never records payments. */
let subscriberInvoiceDownloadBusy=false,selectedSubscriberPreviewDocuments=null;
function selectBankSubscriberInvoices(){if(!['admin','manager'].includes(currentProfile?.role))return;selectedSubscribers.clear();for(const check of document.querySelectorAll('#subscribersBody .subscriberCheck')){const s=monthlySubscribers.find(x=>x.id===check.value);check.checked=!!s&&subscriberIsBank(s);if(check.checked)selectedSubscribers.add(check.value);}opsEl('subscriberDownloadStatus').textContent=selectedSubscribers.size+' abonado(s) por banco seleccionados.';}
function buildSelectedSubscriberInvoiceHtml(documents,includeInternalReceipt=false){
 const parser=new DOMParser(),styles=[],pages=[];
 documents.forEach((invoice,i)=>{
  const doc=parser.parseFromString(buildParkingInvoiceHtml(invoice,{includeInternalReceipt}),'text/html'),id='selected-invoice-'+i;
  // Scope each original template so receipts and invoices keep their own layout.
  for(const style of doc.querySelectorAll('style')){
   const sheet=new CSSStyleSheet();sheet.replaceSync(style.textContent);
   const scoped=rules=>Array.from(rules).map(rule=>{
    if(rule.type===CSSRule.STYLE_RULE){const selectors=rule.selectorText.split(',').map(s=>{s=s.trim();return /^(html|body)$/.test(s)?'#'+id:'#'+id+' '+s.replace(/^(html\s+body|html|body)\s+/,'');});return selectors.join(',')+'{'+rule.style.cssText+'}';}
    if(rule.cssRules)return rule.cssText.slice(0,rule.cssText.indexOf('{')+1)+scoped(rule.cssRules)+'}';
    return rule.cssText;
   }).join('');styles.push(scoped(sheet.cssRules));
  }
  doc.querySelectorAll('script,style').forEach(el=>el.remove());pages.push('<section class="subscriberInvoiceDocument" id="'+id+'">'+doc.body.innerHTML+'</section>');
 });
 return '<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Facturas seleccionadas</title><style>'+styles.join('\n')+'\n*{box-sizing:border-box}body{margin:0;background:#ddd}.subscriberInvoiceDocument{font:12px "Times New Roman",serif;color:#111}@media print{@page{size:A4 portrait;margin:7mm}html,body{width:196mm;height:auto!important;overflow:visible!important;background:#fff}.subscriberInvoiceDocument{width:196mm;height:278mm;max-height:278mm;overflow:hidden;break-inside:avoid;break-after:page;page-break-after:always}.subscriberInvoiceDocument:last-child{break-after:auto;page-break-after:auto}.subscriberInvoiceDocument .page{margin:0!important}}</style></head><body>'+pages.join('')+'</body></html>';
}
const subscriberSingleInvoicePreview=showParkingInvoicePreview,subscriberSingleInvoicePrint=printParkingInvoicePreview,subscriberSingleInvoiceSave=saveParkingInvoiceForEmail,subscriberSingleInvoiceClose=closeParkingInvoicePreview;
showParkingInvoicePreview=function(invoice){selectedSubscriberPreviewDocuments=null;subscriberSingleInvoicePreview(invoice);};
closeParkingInvoicePreview=function(){selectedSubscriberPreviewDocuments=null;subscriberSingleInvoiceClose();};
printParkingInvoicePreview=async function(){if(!selectedSubscriberPreviewDocuments)return subscriberSingleInvoicePrint();const html=buildSelectedSubscriberInvoiceHtml(selectedSubscriberPreviewDocuments,true);try{await sendParkingPrint('invoice',html);}catch(e){if(confirm('No se pudo enviar a FACTURAS: '+e.message+'\n\n¿Abrir la impresión convencional?'))await printParkingInvoiceInBrowser(html);}};
saveParkingInvoiceForEmail=async function(){if(!selectedSubscriberPreviewDocuments)return subscriberSingleInvoiceSave();await printParkingInvoiceInBrowser(buildSelectedSubscriberInvoiceHtml(selectedSubscriberPreviewDocuments));};
async function viewSelectedSubscriberInvoices(){
 if(subscriberInvoiceDownloadBusy||!['admin','manager'].includes(currentProfile?.role))return;
 const ids=[...selectedSubscribers],status=opsEl('subscriberDownloadStatus');if(!ids.length){status.textContent='Selecciona los clientes del listado.';return;}
 subscriberInvoiceDownloadBusy=true;opsEl('downloadSubscriberInvoices').disabled=true;
 try{status.textContent='Consultando documentos emitidos…';const r=await db.rpc('parking_selected_subscriber_documents',{p_ids:ids,p_month:billingMonth()+'-01'});if(r.error)throw r.error;const docs=r.data.documents||[],missing=r.data.missing||[];if(!docs.length)throw Error('No hay documentos emitidos para los clientes y el mes seleccionados.');
  showParkingInvoicePreview(docs[0]);selectedSubscriberPreviewDocuments=docs;
  opsEl('parkingInvoicePreviewTitle').textContent='Facturas seleccionadas · '+docs.length+' documento(s)';opsEl('parkingInvoiceFrame').srcdoc=buildSelectedSubscriberInvoiceHtml(docs);
  status.textContent=docs.length+' documento(s) abiertos.'+(missing.length?' Sin documento emitido: '+missing.map(s=>s.name+' ('+s.plate+')').join(', ')+'.':'');
 }catch(e){status.textContent='No se pudieron abrir las facturas: '+e.message;}finally{subscriberInvoiceDownloadBusy=false;opsEl('downloadSubscriberInvoices').disabled=false;}
}
// Keep older inline links compatible without downloading automatically.
async function downloadSelectedSubscriberInvoices(){return viewSelectedSubscriberInvoices();}
(function mountSubscriberInvoiceDownloads(){
 const actions=opsEl('subscriberListActions'),button=document.createElement('button');button.id='downloadSubscriberInvoices';button.className='btn green hidden';button.textContent='Ver facturas seleccionadas';button.onclick=viewSelectedSubscriberInvoices;actions.prepend(button);
 const panel=document.createElement('div');panel.id='subscriberInvoiceDownloadPanel';panel.className='hidden';panel.innerHTML='<button class="mini" onclick="selectBankSubscriberInvoices()">Seleccionar abonados por banco</button><span id="subscriberDownloadStatus" role="status" class="muted" style="margin-left:10px">Selecciona clientes para ver sus facturas del mes.</span>';const body=opsEl('subscribersBody');body.before(panel);panel.style.marginBottom='12px';
})();
const renderBeforeInvoiceDownloads=renderMonthlySubscribers;
renderMonthlySubscribers=function(){renderBeforeInvoiceDownloads();const canManage=['admin','manager'].includes(currentProfile?.role);for(const id of ['subscriberInvoiceDownloadPanel','downloadSubscriberInvoices','subscriberScheduledEnds','subscriberScheduledStarts','subscriberFullList'])opsEl(id).classList.toggle('hidden',!canManage);for(const [id,mode]of [['subscriberFullList','active'],['subscriberScheduledEnds','ends'],['subscriberScheduledStarts','starts']]){const b=opsEl(id),active=subscriberListMode===mode;b.classList.toggle('dark',active);b.classList.toggle('light',!active);b.setAttribute('aria-pressed',String(active));}};
