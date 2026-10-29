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
 const config=parkingCashbookPrintConfig(parkingCashbookTrayName(printer),kind);if(kind==='withdrawal'){config.copies=2;config.jobName='RETIRADA DE EFECTIVO · 2 COPIAS · BANDEJA 1'}if(kind==='cashvale'){config.jobName='VALE DE EFECTIVO · 1 COPIA · BANDEJA 1'}if(kind==='cashexpense'){config.jobName='RECIBO DE GASTO · 1 COPIA · BANDEJA 1'}return config
}
// Only entry tickets use the compact format; payment receipts keep their profile.
function parkingRotationEntryPageHeight(html){if(!html.includes('data-parking-ticket="rotation-entry"'))return null;const height=Number(html.match(/@page\s*\{\s*size\s*:\s*80mm\s+([\d.]+)mm/i)?.[1]);if(!Number.isFinite(height)||height<140)throw new Error('El ticket de entrada no declara un tamaño válido.');return height}
function parkingThermalPrintConfig(html){return {copies:1,color:false,size:{width:80,height:parkingRotationEntryPageHeight(html)||200},units:'mm',orientation:'portrait',margins:0}}
function parkingHtmlPrintData(kind,html){
 const data={type:'pixel',format:'html',flavor:'plain',data:html};
 if(kind==='ticket'&&parkingRotationEntryPageHeight(html))data.options={pageWidth:80,pageHeight:parkingRotationEntryPageHeight(html)};
 if(kind==='stay')data.options={pageWidth:100,pageHeight:210};
 if(kind==='cashbook')data.options={pageWidth:285,pageHeight:198};
 if(kind==='withdrawal'||kind==='cashvale'||kind==='cashexpense')data.options={pageWidth:285,pageHeight:198};
 return data;
}
