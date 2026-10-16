/* Document-local print contract. Never writes printer/Windows/QZ global defaults. */
const PARKING_STAY_PRINT_PROFILE=Object.freeze({
 copies:1,color:false,units:'mm',orientation:'portrait',rotation:0,
 margins:0,scaleContent:false,rasterize:true,
 size:Object.freeze({width:100,height:210,custom:true})
});
function parkingStayPrintConfig(){return {...PARKING_STAY_PRINT_PROFILE,size:{...PARKING_STAY_PRINT_PROFILE.size}}}
// HOJA DE CAJA: A5 horizontal, bandeja 1. Options apply only to this job.
function parkingCashbookPrintConfig(){return {
 copies:1,color:false,units:'mm',orientation:'landscape',rotation:0,
 size:{width:148,height:210},printerTray:1,margins:6,
 scaleContent:false,rasterize:true
}}
function parkingHtmlPrintData(kind,html){
 const data={type:'pixel',format:'html',flavor:'plain',data:html};
 if(kind==='stay')data.options={pageWidth:100,pageHeight:210};
 if(kind==='cashbook')data.options={pageWidth:198};
 return data;
}
