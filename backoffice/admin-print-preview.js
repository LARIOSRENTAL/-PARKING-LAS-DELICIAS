/* Administrator-only, browser-local document preview. Never changes QZ/Windows defaults. */
let adminPrintJobs=[],adminPrintJobId=0,adminPreviewLibrary=null;
function adminPrintAllowed(){return currentProfile?.role==='admin'}
function adminPrintModeKey(){return 'pld_admin_print_mode:'+currentSession?.user?.id}
function adminPrintMode(){if(!adminPrintAllowed())return 'office';try{return localStorage.getItem(adminPrintModeKey())==='office'?'office':'preview'}catch(e){return 'preview'}}
function shouldPreviewParkingPrint(){return adminPrintAllowed()&&adminPrintMode()==='preview'}
function syncAdminPrintTools(){let box=document.getElementById('adminPrintTools');if(!box){box=document.createElement('div');box.id='adminPrintTools';box.className='hidden';box.style.cssText='display:flex;gap:6px;flex-wrap:wrap;align-items:center;font-size:12px';box.innerHTML='<label>Impresión <select id="adminPrintMode" onchange="setAdminPrintMode(this.value)"><option value="preview">Previsualizar / PDF / otra impresora</option><option value="office">Impresoras de la oficina · QZ</option></select></label><button class="mini" onclick="showAdminPrintPreview()">Documentos preparados</button>';document.querySelector('.topUser')?.appendChild(box)}box.classList.toggle('hidden',!adminPrintAllowed());const select=document.getElementById('adminPrintMode');if(select)select.value=adminPrintMode();document.getElementById('adminCashbookPreview')?.classList.toggle('hidden',!adminPrintAllowed());if(!adminPrintAllowed())clearAdminPrintJobs()}
function setAdminPrintMode(value){if(!adminPrintAllowed())return;try{localStorage.setItem(adminPrintModeKey(),value==='office'?'office':'preview')}catch(e){}syncAdminPrintTools()}
function adminPrintNotice(normal){return shouldPreviewParkingPrint()?'Documento preparado. Puedes previsualizarlo, guardar el PDF o imprimir en este equipo.':normal}
function adminPrintPageSpec(kind,html){let width=210,height=297,margin=7;if(kind==='stay'){width=100;height=210;margin=0}else if(kind==='ticket'){width=80;height=200;margin=0}else if(['cashbook','withdrawal','cashvale'].includes(kind)){width=297;height=210;margin=6}const page=html.match(/@page\s*\{([^}]*)\}/i)?.[1]||'',size=page.match(/size\s*:\s*([^;!}]+)/i)?.[1]||'',custom=size.match(/([\d.]+)mm\s+([\d.]+)mm/i);if(custom){width=Number(custom[1]);height=Number(custom[2])}else if(/a4/i.test(size)){width=/landscape/i.test(size)?297:210;height=/landscape/i.test(size)?210:297}const m=page.match(/margin\s*:\s*([\d.]+)(mm)?\s*(?:;|$)/i);if(m)margin=Number(m[1]);return{width,height,margin,contentWidth:width-2*margin,contentHeight:height-2*margin}}
function adminCleanPrintHtml(html){const doc=new DOMParser().parseFromString(html,'text/html');doc.querySelectorAll('script,iframe,object,embed,base').forEach(e=>e.remove());doc.querySelectorAll('*').forEach(e=>{for(const a of Array.from(e.attributes)){if(/^on/i.test(a.name)||(/^(href|src|action)$/i.test(a.name)&&/^javascript:/i.test(a.value)))e.removeAttribute(a.name)}});const base=doc.createElement('base');base.href=location.href;doc.head.prepend(base);return '<!doctype html>'+doc.documentElement.outerHTML}
async function prepareAdminPrintPreview(kind,html){if(!adminPrintAllowed())throw Error('Solo el administrador puede previsualizar documentos.');const job={id:++adminPrintJobId,owner:currentSession?.user?.id,kind,html:adminCleanPrintHtml(html),spec:adminPrintPageSpec(kind,html),copies:kind==='withdrawal'?2:1,pdfUrl:null,pdfPromise:null};adminPrintJobs.push(job);if(adminPrintJobs.length>12){const old=adminPrintJobs.shift();if(old.pdfUrl)URL.revokeObjectURL(old.pdfUrl)}showAdminPrintPreview(job.id);return true}
function activeAdminPrintJob(){if(!adminPrintAllowed())return null;const id=Number(document.getElementById('adminPrintJobSelect')?.value);return adminPrintJobs.find(j=>j.id===id&&j.owner===currentSession?.user?.id)||null}
function showAdminPrintPreview(id){if(!adminPrintAllowed())return;if(!adminPrintJobs.length){alert('No hay documentos preparados. Selecciona Previsualizar / PDF y pulsa el botón de impresión del documento.');return}let modal=document.getElementById('adminPrintPreview');if(!modal){modal=document.createElement('div');modal.id='adminPrintPreview';modal.style.cssText='position:fixed;inset:0;z-index:20000;background:#10283ce8;padding:12px;display:flex;flex-direction:column;gap:8px';modal.innerHTML='<div style="background:white;padding:10px;border-radius:10px;display:flex;gap:8px;flex-wrap:wrap;align-items:center"><strong>Previsualización · administrador</strong><select id="adminPrintJobSelect" onchange="selectAdminPrintJob()" aria-label="Documento preparado"></select><button class="btn green" onclick="printAdminDocumentHere()">Imprimir en este equipo / Guardar como PDF</button><button class="btn light" onclick="openAdminDocumentPdf()">Ver PDF</button><button class="btn light" onclick="downloadAdminDocumentPdf()">Descargar PDF</button><button class="btn light" onclick="printAdminDocumentOffice()">Enviar a impresora de oficina</button><button class="btn light" onclick="closeAdminPrintPreview()">Cerrar</button><p id="adminPrintPreviewMessage" role="status" style="margin:0;width:100%"></p></div><iframe id="adminPrintPreviewFrame" title="Previsualización del documento" sandbox="allow-same-origin allow-modals" style="flex:1;min-height:0;width:100%;border:0;background:white"></iframe>';document.body.appendChild(modal)}const select=document.getElementById('adminPrintJobSelect');select.innerHTML=adminPrintJobs.filter(j=>j.owner===currentSession?.user?.id).map(j=>'<option value="'+j.id+'">'+esc(({stay:'Bono de estancia / hotel',invoice:'Factura / listado',ticket:'Ticket',cashbook:'Resumen de caja',withdrawal:'Retirada',cashvale:'Vale'}[j.kind]||'Documento')+' · '+j.id)+'</option>').join('');select.value=String(id||adminPrintJobs.at(-1).id);modal.style.display='flex';selectAdminPrintJob()}
function selectAdminPrintJob(){const job=activeAdminPrintJob();if(!job)return;const frame=document.getElementById('adminPrintPreviewFrame');frame.onload=()=>{if(activeAdminPrintJob()?.id===job.id)prepareAdminPreviewDocument(frame,job)};frame.srcdoc=job.html;document.getElementById('adminPrintPreviewMessage').textContent='Documento preparado · '+job.spec.width+' × '+job.spec.height+' mm · '+job.copies+' copia(s). Puedes elegir una impresora de este equipo o guardar como PDF.'}
function prepareAdminPreviewDocument(frame,job){const doc=frame.contentDocument;if(!doc)return;let printCss='';const visit=rules=>{for(const rule of Array.from(rules||[])){if(rule.media&&/print/.test(rule.media.mediaText))printCss+=Array.from(rule.cssRules||[]).map(r=>r.cssText).join('\n')}};for(const sheet of Array.from(doc.styleSheets)){try{visit(sheet.cssRules)}catch(e){}}const style=doc.createElement('style');style.textContent=printCss+'\nhtml,body{box-sizing:border-box!important;width:'+job.spec.contentWidth+'mm!important;min-height:'+job.spec.contentHeight+'mm;margin:0!important;padding:0!important;background:white!important;overflow:visible!important}';doc.head.appendChild(style);job.frame=frame}
function closeAdminPrintPreview(){const modal=document.getElementById('adminPrintPreview');if(modal)modal.style.display='none'}
function clearAdminPrintJobs(){for(const job of adminPrintJobs)if(job.pdfUrl)URL.revokeObjectURL(job.pdfUrl);adminPrintJobs=[];closeAdminPrintPreview();const frame=document.getElementById('adminPrintPreviewFrame');if(frame)frame.srcdoc=''}
function printAdminDocumentHere(){const job=activeAdminPrintJob(),frame=document.getElementById('adminPrintPreviewFrame');if(!job||job.frame!==frame)return;const copies=frame.contentDocument.querySelectorAll('.adminExtraPrintCopy');copies.forEach(e=>e.remove());if(job.copies===2){const sheet=frame.contentDocument.querySelector('.sheet');if(sheet){const copy=sheet.cloneNode(true);copy.classList.add('adminExtraPrintCopy');copy.style.breakBefore='page';frame.contentDocument.body.appendChild(copy);const remove=()=>copy.remove();frame.contentWindow.addEventListener('afterprint',remove,{once:true});setTimeout(remove,60000)}}frame.contentWindow.focus();frame.contentWindow.print()}
async function printAdminDocumentOffice(){const job=activeAdminPrintJob();if(!job)return;const msg=document.getElementById('adminPrintPreviewMessage');msg.textContent='Enviando a la impresora de oficina…';try{await sendParkingPrint(job.kind,job.html,true);msg.textContent='Documento enviado a la impresora de oficina · '+job.copies+' copia(s).'}catch(e){msg.textContent=e.message}}
function loadAdminPreviewLibrary(){if(adminPreviewLibrary)return adminPreviewLibrary;adminPreviewLibrary=loadParkingPdfLibraries().then(()=>new Promise((resolve,reject)=>{if(window.html2canvas)return resolve();const script=document.createElement('script');script.src='assets/vendor/html2canvas.min.js?v=1.4.1';script.onload=resolve;script.onerror=()=>reject(Error('No se pudo cargar el generador de PDF.'));document.head.appendChild(script)})).catch(e=>{adminPreviewLibrary=null;throw e});return adminPreviewLibrary}
function adminPdfStep(text){const el=document.getElementById('adminPrintPreviewMessage');if(el)el.textContent=text}
function adminPdfDeadline(promise,ms,stage){return Promise.race([Promise.resolve(promise),new Promise((_,reject)=>setTimeout(()=>reject(Error('Tiempo de espera agotado en '+stage+'. Usa Imprimir en este equipo / Guardar como PDF.')),ms))])}
async function adminDocumentPdf(job){
 if(!adminPrintAllowed()||job.owner!==currentSession?.user?.id)throw Error('No autorizado');
 if(job.pdfUrl)return job.pdfUrl;
 if(job.pdfPromise)return job.pdfPromise;
 job.pdfPromise=(async()=>{
  adminPdfStep('PDF: cargando generador…');
  await adminPdfDeadline(loadParkingPdfLibraries(),12000,'bibliotecas');
  if(!window.jspdf?.jsPDF)throw Error('Generador PDF no disponible.');
  const parsed=new DOMParser().parseFromString(job.html,'text/html');
  parsed.querySelectorAll('script,style,head,noscript,iframe').forEach(el=>el.remove());
  const pdf=new window.jspdf.jsPDF({compress:true,unit:'mm',format:[job.spec.width,job.spec.height],orientation:job.spec.width>job.spec.height?'landscape':'portrait'});
  const margin=Math.max(7,job.spec.margin||0),width=job.spec.width-2*margin;
  const rows=[];
  const seen=new Set();
  function add(text,bold=false){
   text=String(text||'').replace(/\\s+/g,' ').trim();
   if(text)rows.push({text,bold});
  }
  // Extract semantic blocks directly from HTML; does not use Safari layout,
  // canvases, ranges, or hidden frames.
  const root=parsed.body;
  function walk(el){
   if(!el||el.nodeType!==1)return;
   const tag=el.tagName.toLowerCase();
   if(['script','style','svg','img','button','input'].includes(tag))return;
   if(tag==='tr'){
    const cells=Array.from(el.children).filter(c=>/^(TD|TH)$/.test(c.tagName));
    const values=cells.map(c=>c.textContent.replace(/\\s+/g,' ').trim()).filter(Boolean);
    if(values.length)add(values.join('     '),cells.some(c=>c.tagName==='TH'));
    return;
   }
   if(['h1','h2','h3','h4','p','li','dt','dd'].includes(tag)){
    add(el.textContent,/^h[1-4]$/.test(tag));return;
   }
   const kids=Array.from(el.children).filter(c=>!['STYLE','SCRIPT','NOSCRIPT'].includes(c.tagName));
   if(!kids.length){if(!el.closest('table'))add(el.textContent);return}
   for(const child of kids)walk(child);
  }
  walk(root);
  if(!rows.length){
   const fallback=root.textContent.replace(/\\s+/g,' ').trim();
   if(fallback)add(fallback);
  }
  if(!rows.length)throw Error('El HTML de origen no contiene texto para el PDF.');
  adminPdfStep('PDF: componiendo documento…');
  const lineHeight=5.4,top=Math.max(11,margin),bottom=job.spec.height-margin;
  const startCopy=()=>{let y=top;return function(row){
   pdf.setFont('helvetica',row.bold?'bold':'normal');
   pdf.setFontSize(row.bold?11:9);
   const wrapped=pdf.splitTextToSize(row.text,width);
   for(const line of wrapped){
    if(y+lineHeight>bottom){pdf.addPage([job.spec.width,job.spec.height],job.spec.width>job.spec.height?'landscape':'portrait');y=top}
    pdf.text(line,margin,y);y+=lineHeight;
   }
   y+=row.bold?2:0;
  }};
  for(let copy=0;copy<job.copies;copy++){
   if(copy)pdf.addPage([job.spec.width,job.spec.height],job.spec.width>job.spec.height?'landscape':'portrait');
   const write=startCopy();
   for(const row of rows)write(row);
  }
  if(!adminPrintAllowed()||job.owner!==currentSession?.user?.id)throw Error('Sesión finalizada');
  job.pdfUrl=URL.createObjectURL(pdf.output('blob'));
  return job.pdfUrl;
 })().catch(e=>{job.pdfPromise=null;throw e});
 return job.pdfPromise;
}
async function openAdminDocumentPdf(){const job=activeAdminPrintJob();if(!job)return;const msg=document.getElementById('adminPrintPreviewMessage');msg.textContent='Preparando PDF…';try{const url=await adminDocumentPdf(job);const a=document.createElement('a');a.href=url;a.target='_blank';a.rel='noopener';a.textContent='Abrir PDF preparado';msg.replaceChildren(a);a.click()}catch(e){msg.textContent='No se pudo generar el PDF: '+e.message}}
async function downloadAdminDocumentPdf(){const job=activeAdminPrintJob();if(!job)return;const msg=document.getElementById('adminPrintPreviewMessage');msg.textContent='Preparando PDF…';try{const a=document.createElement('a');a.href=await adminDocumentPdf(job);a.download='parking-'+job.kind+'-'+job.id+'.pdf';document.body.appendChild(a);a.click();a.remove();msg.textContent='PDF preparado'+(job.copies===2?' con las 2 copias de la retirada.':'.')}catch(e){msg.textContent='No se pudo generar el PDF: '+e.message}}
async function previewAdminCashbook(){if(!adminPrintAllowed())return;try{const id=opsEl('cashbookEmployee').value||parkingCashbookData?.shift_id;if(!id)throw Error('Selecciona el turno y el empleado.');const r=await db.rpc('parking_export_cashbook',{p_shift_id:id});if(r.error)throw r.error;await prepareAdminPrintPreview('cashbook',buildCashbookHtml(r.data))}catch(e){alert('No se pudo preparar la hoja de caja: '+e.message)}}

if(typeof document!=='undefined')syncAdminPrintTools();
