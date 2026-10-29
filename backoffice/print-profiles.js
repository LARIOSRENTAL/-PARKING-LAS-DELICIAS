/* Document-local print contract. Never writes printer/Windows/QZ global defaults. */
const PARKING_STAY_PRINT_PROFILE=Object.freeze({
 copies:1,color:false,units:'mm',orientation:'portrait',rotation:0,
 // Raster snapshots contain printer-resolution pixels; fit them to the physical sheet.
 margins:0,scaleContent:true,rasterize:true,
 size:Object.freeze({width:100,height:210,custom:true})
});
function parkingStayPrintConfig(){return {...PARKING_STAY_PRINT_PROFILE,size:{...PARKING_STAY_PRINT_PROFILE.size}}}
// All cash documents use the HOJA DE CAJA queue: A4 landscape, tray 1.
function parkingCashbookPrintConfig(tray,kind='cashbook'){if(typeof tray!=='string'||!tray.trim())throw new Error('No se ha identificado la bandeja 1 de la Ricoh.');return {
 copies:1,color:false,units:'mm',orientation:'landscape',rotation:0,
 size:{width:210,height:297},printerTray:tray,jobName:'HOJA DE CAJA · A4 HORIZONTAL · BANDEJA 1',margins:6,
 scaleContent:true,rasterize:true
}}
function parkingCashbookTrayName(printer){
 const trays=printer?.trays;if(!Array.isArray(trays))throw new Error('QZ no comunica las bandejas de la Ricoh. No se enviará la caja a una bandeja por defecto.');
 const matches=trays.filter(name=>typeof name==='string'&&/^(?:(?:paper[ _-]*)?(?:tray|bandeja|cassette|cassete|bandeja de papel|gaveta))[ _-]*0?1(?:[ _-]*\([^)]*\))?$/i.test(name.trim()));
 // Ricoh MP 2003 Windows/Java names observed on this workstation:
 // DMBIN_UPPER (1) = MediaTray.TOP; DMBIN_MIDDLE (3) = MIDDLE.
 // Only this queue and the observed top/middle driver family use this alias.
 if(matches.length===0&&['RICOH MP 2003','HOJA DE CAJA'].includes(printer?.name)){
  const top=trays.filter(name=>typeof name==='string'&&name.trim().toLowerCase()==='top');
  const middle=trays.some(name=>typeof name==='string'&&name.trim().toLowerCase()==='middle');
  if(top.length===1&&middle)return top[0]
 }
 if(matches.length!==1)throw new Error('No se identifica una única bandeja 1 en la Ricoh. Bandejas comunicadas: '+trays.join(', ')+'. No se ha impreso el resumen.');
 return matches[0]
}
async function parkingCashbookPrintConfigForPrinter(target,kind='cashbook'){
 const details=await qz.printers.details(),printers=Array.isArray(details)?details:[details],printer=printers.find(p=>p?.name===target);
 if(!printer)throw new Error('No se pudieron consultar las bandejas de '+target+'.');
 const config=parkingCashbookPrintConfig(parkingCashbookTrayName(printer),kind);if(kind==='withdrawal'){config.copies=2;config.jobName='RETIRADA DE EFECTIVO · 2 COPIAS · BANDEJA 1'}if(kind==='cashvale'){config.jobName='VALE DE EFECTIVO · 1 COPIA · BANDEJA 1'}if(kind==='cashexpense'){config.jobName='RECIBO DE GASTO · 1 COPIA · BANDEJA 1'}if(kind==='monthly_receipt')config.jobName='RECIBO DE ABONADO · 2 COPIAS · HOJA DE CAJA · BANDEJA 1';return config
}
// Only entry tickets use the compact format; payment receipts keep their profile.
function parkingRotationEntryPageHeight(html){if(!html.includes('data-parking-ticket="rotation-entry"'))return null;const height=Number(html.match(/@page\s*\{\s*size\s*:\s*80mm\s+([\d.]+)mm/i)?.[1]);if(!Number.isFinite(height)||height<140)throw new Error('El ticket de entrada no declara un tamaño válido.');return height}
function parkingThermalPrintConfig(html){return {copies:1,color:false,size:{width:80,height:parkingRotationEntryPageHeight(html)||200},units:'mm',orientation:'portrait',margins:0}}
function parkingHtmlPrintData(kind,html){
 const data={type:'pixel',format:'html',flavor:'plain',data:html};
 if(kind==='ticket'&&parkingRotationEntryPageHeight(html))data.options={pageWidth:80,pageHeight:parkingRotationEntryPageHeight(html)};
 if(kind==='stay')data.options={pageWidth:100,pageHeight:210};
 if(kind==='cashbook'||kind==='monthly_receipt')data.options={pageWidth:285,pageHeight:198};
 if(kind==='withdrawal'||kind==='cashvale'||kind==='cashexpense')data.options={pageWidth:285,pageHeight:198};
 return data;
}

function parkingMonthlyReceiptCashbookHtml(html){
 const doc=new DOMParser().parseFromString(html,'text/html');
 if(!doc.querySelector('.monthly-receipt-copies'))throw Error('El documento no es un recibo de abonado.');
 // Match the physical feed of HOJA DE CAJA without changing any printer defaults.
 for(const style of doc.querySelectorAll('style'))style.textContent=style.textContent.replace(/@page\s*\{[^}]*\}/gi,'@page{size:A4 landscape;margin:6mm}');
 const style=doc.createElement('style');style.textContent='@page{size:A4 landscape;margin:6mm}html,body{width:285mm!important;height:auto!important;margin:0!important;padding:0!important;background:#fff!important;overflow:visible!important}.subscriberInvoiceDocument{width:285mm!important;height:198mm!important;max-height:198mm!important}.monthly-receipt-copies{width:285mm!important;height:198mm!important;display:grid!important;grid-template-columns:minmax(0,1fr) 0 minmax(0,1fr)!important;gap:5mm!important;padding:4mm!important;align-items:stretch!important;box-sizing:border-box!important}.monthly-receipt-copies>.receipt{width:100%!important;min-height:0!important;height:100%!important;padding:4mm!important;font-size:12px!important;box-sizing:border-box!important}.monthly-receipt-copies .header h2{font-size:16px!important}.monthly-receipt-copies .box{padding:3mm!important}.monthly-receipt-copies .meta{gap:3mm!important;margin:5mm 0!important}.monthly-receipt-copies .details{flex-direction:column!important;gap:5mm!important;margin-top:5mm!important}.monthly-receipt-copies .customer{min-width:0!important}.monthly-receipt-copies .receiptTotals{width:100%!important}.monthly-receipt-copies .receiptTotal{font-size:18px!important}.monthly-receipt-copies .monthly-receipt-cut{width:0!important;height:100%!important;margin:0!important;border:0!important;border-left:1px dashed #555!important}';
 doc.head.appendChild(style);return '<!doctype html>'+doc.documentElement.outerHTML;
}
