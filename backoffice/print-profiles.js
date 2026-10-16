/* Document-local print contract. Never writes printer/Windows/QZ global defaults. */
const PARKING_STAY_PRINT_PROFILE=Object.freeze({
 copies:1,color:false,units:'mm',orientation:'portrait',rotation:0,
 // Raster snapshots contain printer-resolution pixels; fit them to the physical sheet.
 margins:0,scaleContent:true,rasterize:true,
 size:Object.freeze({width:100,height:210,custom:true})
});
function parkingStayPrintConfig(){return {...PARKING_STAY_PRINT_PROFILE,size:{...PARKING_STAY_PRINT_PROFILE.size}}}
// HOJA DE CAJA: A5 horizontal, bandeja 1. Options apply only to this job.
function parkingCashbookPrintConfig(tray){if(typeof tray!=='string'||!tray.trim())throw new Error('No se ha identificado la bandeja 1 de la Ricoh.');return {
 copies:1,color:false,units:'mm',orientation:'landscape',rotation:0,
 size:{width:148,height:210},printerTray:tray,jobName:'HOJA DE CAJA · A5 · BANDEJA 1',margins:6,
 scaleContent:true,rasterize:true
}}
function parkingCashbookTrayName(printer){
 const trays=printer?.trays;if(!Array.isArray(trays))throw new Error('QZ no comunica las bandejas de la Ricoh. No se enviará la caja a una bandeja por defecto.');
 const matches=trays.filter(name=>typeof name==='string'&&/^(?:(?:paper[ _-]*)?(?:tray|bandeja|cassette|cassete|bandeja de papel|gaveta))[ _-]*0?1(?:[ _-]*\([^)]*\))?$/i.test(name.trim()));
 if(matches.length!==1)throw new Error('No se identifica una única bandeja 1 en la Ricoh. Bandejas comunicadas: '+trays.join(', ')+'. No se ha impreso el resumen.');
 return matches[0]
}
async function parkingCashbookPrintConfigForPrinter(target){
 const details=await qz.printers.details(),printers=Array.isArray(details)?details:[details],printer=printers.find(p=>p?.name===target);
 if(!printer)throw new Error('No se pudieron consultar las bandejas de '+target+'.');
 return parkingCashbookPrintConfig(parkingCashbookTrayName(printer))
}
function parkingHtmlPrintData(kind,html){
 const data={type:'pixel',format:'html',flavor:'plain',data:html};
 if(kind==='stay')data.options={pageWidth:100,pageHeight:210};
 if(kind==='cashbook')data.options={pageWidth:198,pageHeight:136};
 return data;
}
