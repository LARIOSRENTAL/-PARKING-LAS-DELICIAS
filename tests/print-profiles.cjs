const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.join(__dirname,'..'),html=fs.readFileSync(path.join(root,'backoffice/index.html'),'utf8');
const source=html.slice(html.indexOf('async function sendParkingPrint('),html.indexOf('function voucherVehicleType('));
const jobs=[],configs=[],ctx={console,connectParkingQz:async()=>{},PARKING_PRINTERS:{stay:'RICOH MP 2003',cashbook:'HOJA DE CAJA',withdrawal:'HOJA DE CAJA',cashvale:'HOJA DE CAJA',cashexpense:'HOJA DE CAJA',invoice:'FACTURAS',ticket:'BIXOLON SRP-350III'},hotelCouponPrintPages:h=>[h.replace('COUPONS','FIRST'),h.replace('COUPONS','SECOND')],qz:{printers:{find:async name=>name,details:async()=>[{name:'HOJA DE CAJA',trays:['Bandeja 2','Bandeja 1','Bandeja bypass']}]},configs:{create:(name,opts)=>{const config={name,options:JSON.parse(JSON.stringify(opts))};configs.push(config);return config}},print:async(config,data)=>jobs.push({config,data})}};
vm.createContext(ctx);vm.runInContext(fs.readFileSync(path.join(root,'backoffice/print-profiles.js'),'utf8')+'\n'+source,ctx);
(async()=>{
 const voucher='<html><head></head><body>ABONO POR DÍAS</body></html>';
 for(const kind of ['invoice','stay','ticket','stay'])await ctx.sendParkingPrint(kind,voucher);
 assert.equal(jobs[0].config.name,'FACTURAS');assert.deepEqual(jobs[0].config.options,{copies:1,color:false});assert.equal(jobs[0].data[0].options,undefined);
 assert.equal(jobs[2].config.name,'BIXOLON SRP-350III');assert.deepEqual(jobs[2].config.options,{copies:1,color:false,size:{width:80,height:200},units:'mm',orientation:'portrait',margins:0});assert.equal(jobs[2].data[0].options,undefined);
 for(const index of [1,3]){const j=jobs[index];assert.equal(j.config.name,'RICOH MP 2003');assert.equal(j.config.options.orientation,'portrait');assert.equal(j.config.options.rotation,0);assert.equal(j.config.options.scaleContent,true);assert.equal(j.config.options.rasterize,true);assert.deepEqual(j.config.options.size,{width:100,height:210,custom:true});assert.equal(j.data[0].options.pageWidth,100);assert.equal(j.data[0].options.pageHeight,210);assert.equal('printerTray'in j.config.options,false);assert.equal('paperThickness'in j.config.options,false)}
 const first=ctx.parkingStayPrintConfig();first.orientation='landscape';first.size.width=210;const next=ctx.parkingStayPrintConfig();assert.equal(next.orientation,'portrait');assert.equal(next.size.width,100);
 await ctx.sendParkingPrint('stay','<html><head><title>Bonos hotel H-1</title></head><body>COUPONS</body></html>');assert.equal(jobs.length,6);for(const j of jobs.slice(4)){assert.equal(j.config.options.orientation,'portrait');assert.equal(j.data[0].options.pageHeight,210)}
 await ctx.sendParkingPrint('cashbook','<html><head></head><body>Hoja de caja</body></html>');
 const cash=jobs[6];assert.equal(cash.config.name,'HOJA DE CAJA');assert.equal(cash.config.options.printerTray,'Bandeja 1');assert.equal(cash.config.options.orientation,'landscape');assert.match(cash.config.options.jobName,/A4 HORIZONTAL/);assert.equal(cash.config.options.rasterize,true);assert.equal(cash.config.options.scaleContent,true);assert.deepEqual(cash.config.options.size,{width:210,height:297});assert.equal(cash.data[0].options.pageWidth,285);assert.equal(cash.data[0].options.pageHeight,198);
 await ctx.sendParkingPrint('stay',voucher);assert.equal(jobs[7].config.options.orientation,'portrait');assert.equal('printerTray' in jobs[7].config.options,false);
 // Regression: QZ PrintHTML rasterizes at printer DPI; PrintImage's unscaled
 // path starts with dpiScale=1. At 600dpi a 100mm snapshot would span 833mm.
 // Exercise the actual submitted options against both QZ drawing branches.
 function physicalRasterSize(config,dpi){const w=config.size.width/25.4*72,h=config.size.height/25.4*72;const imageW=w*dpi/72,imageH=h*dpi/72;if(!config.scaleContent)return{width:imageW*25.4/72,height:imageH*25.4/72};const factor=Math.min(w/imageW,h/imageH);return{width:imageW*factor*25.4/72,height:imageH*factor*25.4/72}}
 for(const dpi of [203,300,600,1200])for(const j of [jobs[1],jobs[3],jobs[4],jobs[5],jobs[7]]){const physical=physicalRasterSize(j.config.options,dpi);assert(Math.abs(physical.width-100)<0.001);assert(Math.abs(physical.height-210)<0.001)}
 assert(physicalRasterSize({...jobs[1].config.options,scaleContent:false},600).width>800);
 assert.equal(ctx.parkingCashbookTrayName({trays:['Tray 2','Tray 1']}),'Tray 1');
 assert.equal(ctx.parkingCashbookTrayName({trays:['Bandeja 2','Bandeja 1']}),'Bandeja 1');
 assert.throws(()=>ctx.parkingCashbookTrayName({trays:['Bandeja 2','Bypass']}),/No se identifica/);
 assert.throws(()=>ctx.parkingCashbookTrayName({trays:['Tray 1','Bandeja 1']}),/única/);
 const observed={name:'HOJA DE CAJA',trays:['Automatic-Feeder','top','middle','manual']};
 assert.equal(ctx.parkingCashbookTrayName(observed),'top');
 assert.throws(()=>ctx.parkingCashbookTrayName({name:'OTHER',trays:observed.trays}),/No se identifica/);
 assert.throws(()=>ctx.parkingCashbookTrayName({name:'RICOH MP 2003',trays:['Automatic-Feeder','middle','manual']}),/No se identifica/);
 assert.throws(()=>ctx.parkingCashbookTrayName({name:'RICOH MP 2003',trays:['top','manual']}),/No se identifica/);
 assert.throws(()=>ctx.parkingCashbookTrayName({name:'RICOH MP 2003',trays:['top','top','middle']}),/No se identifica/);
 ctx.qz.printers.details=async()=>[observed];await ctx.sendParkingPrint('cashbook',voucher);
 const observedJob=jobs.at(-1);assert.equal(observedJob.config.options.printerTray,'top');assert.equal(observedJob.config.options.orientation,'landscape');assert.deepEqual(observedJob.config.options.size,{width:210,height:297});
 await ctx.sendParkingPrint('stay',voucher);assert.equal('printerTray' in jobs.at(-1).config.options,false);assert.equal(jobs.at(-1).config.options.orientation,'portrait');
 await ctx.sendParkingPrint('withdrawal',voucher);const withdrawal=jobs.at(-1);assert.equal(withdrawal.config.name,'HOJA DE CAJA');assert.equal(withdrawal.config.options.copies,2);assert.equal(withdrawal.config.options.printerTray,'top');assert.deepEqual(withdrawal.config.options.size,{width:210,height:297});assert.equal(withdrawal.config.options.orientation,'landscape');
 await ctx.sendParkingPrint('cashbook',voucher);assert.equal(jobs.at(-1).config.options.copies,1);
 await ctx.sendParkingPrint('cashvale',voucher);assert.equal(jobs.at(-1).config.name,'HOJA DE CAJA');assert.equal(jobs.at(-1).config.options.copies,1);assert.equal(jobs.at(-1).config.options.printerTray,'top');assert.equal(jobs.at(-1).data[0].options.pageWidth,285);assert.match(jobs.at(-1).config.options.jobName,/VALE DE EFECTIVO/);
 await ctx.sendParkingPrint('cashexpense',voucher);assert.equal(jobs.at(-1).config.name,'HOJA DE CAJA');assert.equal(jobs.at(-1).config.options.copies,1);assert.equal(jobs.at(-1).config.options.printerTray,'top');assert.equal(jobs.at(-1).data[0].options.pageWidth,285);assert.match(jobs.at(-1).config.options.jobName,/RECIBO DE GASTO/);
 const before=jobs.length;ctx.qz.printers.details=async()=>[{name:'HOJA DE CAJA',trays:['Bandeja 2']}];
 await assert.rejects(()=>ctx.sendParkingPrint('cashbook',voucher),/No se identifica/);assert.equal(jobs.length,before);
 const sentBeforeMissing=jobs.length;ctx.qz.printers.find=async()=>null;await assert.rejects(()=>ctx.sendParkingPrint('cashbook',voucher),/Falta la cola/);assert.equal(jobs.length,sentBeforeMissing);ctx.qz.printers.find=async name=>name; assert.notEqual(configs[4],configs[5]);ctx.qz.print=async()=>{throw Error('fallo cola')};await assert.rejects(()=>ctx.sendParkingPrint('stay',voucher),/falla el envío/);
 assert.doesNotMatch(source,/setDefaults|setDefaultPrinter|\.reconfigure\(/);console.log('Impresión: estancias/hotel verticales 100×210, sin giro, raster ajustado a la hoja física (203–1200 dpi), página explícita y resumen A4 horizontal raster con bandeja exacta; bandeja ausente/ambigua bloquea el envío; secuencia factura/bono/ticket/bono aislada; un bono por envío; perfiles Windows y otras colas sin cambios.');
})().catch(e=>{console.error(e);process.exitCode=1});
