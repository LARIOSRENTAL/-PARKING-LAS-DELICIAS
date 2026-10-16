const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.join(__dirname,'..'),html=fs.readFileSync(path.join(root,'backoffice/index.html'),'utf8');
const source=html.slice(html.indexOf('async function sendParkingPrint('),html.indexOf('function voucherVehicleType('));
const jobs=[],configs=[],ctx={console,connectParkingQz:async()=>{},PARKING_PRINTERS:{stay:'RICOH MP 2003',cashbook:'RICOH MP 2003',invoice:'FACTURAS',ticket:'BIXOLON SRP-350III'},hotelCouponPrintPages:h=>[h.replace('COUPONS','FIRST'),h.replace('COUPONS','SECOND')],qz:{printers:{find:async name=>name},configs:{create:(name,opts)=>{const config={name,options:JSON.parse(JSON.stringify(opts))};configs.push(config);return config}},print:async(config,data)=>jobs.push({config,data})}};
vm.createContext(ctx);vm.runInContext(fs.readFileSync(path.join(root,'backoffice/print-profiles.js'),'utf8')+'\n'+source,ctx);
(async()=>{
 const voucher='<html><head></head><body>ABONO POR DÍAS</body></html>';
 for(const kind of ['invoice','stay','ticket','stay'])await ctx.sendParkingPrint(kind,voucher);
 assert.equal(jobs[0].config.name,'FACTURAS');assert.deepEqual(jobs[0].config.options,{copies:1,color:false});assert.equal(jobs[0].data[0].options,undefined);
 assert.equal(jobs[2].config.name,'BIXOLON SRP-350III');assert.deepEqual(jobs[2].config.options,{copies:1,color:false,size:{width:80,height:200},units:'mm',orientation:'portrait',margins:0});assert.equal(jobs[2].data[0].options,undefined);
 for(const index of [1,3]){const j=jobs[index];assert.equal(j.config.name,'RICOH MP 2003');assert.equal(j.config.options.orientation,'portrait');assert.equal(j.config.options.rotation,0);assert.equal(j.config.options.scaleContent,false);assert.equal(j.config.options.rasterize,true);assert.deepEqual(j.config.options.size,{width:100,height:210,custom:true});assert.equal(j.data[0].options.pageWidth,100);assert.equal(j.data[0].options.pageHeight,210);assert.equal('printerTray'in j.config.options,false);assert.equal('paperThickness'in j.config.options,false)}
 const first=ctx.parkingStayPrintConfig();first.orientation='landscape';first.size.width=210;const next=ctx.parkingStayPrintConfig();assert.equal(next.orientation,'portrait');assert.equal(next.size.width,100);
 await ctx.sendParkingPrint('stay','<html><head><title>Bonos hotel H-1</title></head><body>COUPONS</body></html>');assert.equal(jobs.length,6);for(const j of jobs.slice(4)){assert.equal(j.config.options.orientation,'portrait');assert.equal(j.data[0].options.pageHeight,210)}
 await ctx.sendParkingPrint('cashbook','<html><head></head><body>Hoja de caja</body></html>');
 const cash=jobs[6];assert.equal(cash.config.name,'RICOH MP 2003');assert.equal(cash.config.options.printerTray,1);assert.equal(cash.config.options.orientation,'landscape');assert.deepEqual(cash.config.options.size,{width:148,height:210});assert.equal(cash.data[0].options.pageWidth,198);assert.equal(cash.data[0].options.pageHeight,undefined);
 await ctx.sendParkingPrint('stay',voucher);assert.equal(jobs[7].config.options.orientation,'portrait');assert.equal('printerTray' in jobs[7].config.options,false);
 assert.notEqual(configs[4],configs[5]);ctx.qz.print=async()=>{throw Error('fallo cola')};await assert.rejects(()=>ctx.sendParkingPrint('stay',voucher),/falla el envío/);
 assert.doesNotMatch(source,/setDefaults|setDefaultPrinter|\.reconfigure\(/);console.log('Impresión: estancias/hotel verticales 100×210, sin giro ni escalado, raster y página explícitos; secuencia factura/bono/ticket/bono aislada; un bono por envío; perfiles Windows y otras colas sin cambios.');
})().catch(e=>{console.error(e);process.exitCode=1});
