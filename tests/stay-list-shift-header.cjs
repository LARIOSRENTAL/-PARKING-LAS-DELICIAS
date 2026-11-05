const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const htmlSource=fs.readFileSync(__dirname+'/../backoffice/index.html','utf8'),start=htmlSource.indexOf('async function printTotalStays('),end=htmlSource.indexOf('\nasync function ',start+10);const source=htmlSource.slice(start,end);let jobs=[];
const rows=Array.from({length:113},(_,i)=>({vehicle:'TURISMO',plate:'TEST'+i,spot:'A-'+i,start:'2026-11-01T10:00:00Z',end:'2099-12-01T10:00:00Z',presence:'DENTRO'}));
const ctx={console,Date,Math,Number,currentShift:{id:'wrong',employee_name:'Otro empleado',shift_code:3,shift_date:'2026-11-05'},currentProfile:{full_name:'Perfil actual'},totalStayOrder:'soon',rotationTariffs:[],loadTotalStays:async()=>{ctx.currentShift={employee_name:'Turno cambiado',shift_code:2};ctx.currentProfile.full_name='Perfil cambiado'},totalStayDisplayRows:()=>rows,esc:v=>String(v??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;'),money:String,alert:message=>{throw Error(message)},sendParkingPrint:async(kind,html,automatic)=>jobs.push({kind,html,automatic}),shouldPreviewParkingPrint:()=>true};
vm.createContext(ctx);vm.runInContext(source,ctx);
(async()=>{
 const report={employee_name:'Empleado <turno>',shift_code:1,date:'2026-11-05',generated_at:'2026-11-05T05:02:00Z'};
 await ctx.printTotalStays(true,report);assert.equal(jobs.length,1);const {html}=jobs[0];
 assert.equal((html.match(/Empleado: Empleado &lt;turno&gt;/g)||[]).length,3);
 assert.equal((html.match(/Turno 1 · 05\/11\/2026/g)||[]).length,3);
 const stamp=new Date(report.generated_at).toLocaleString('es-ES',{timeZone:'Europe/Madrid',dateStyle:'short',timeStyle:'short'});assert.equal(html.split('Fecha y hora: '+stamp).length-1,3);
 assert(!html.includes('Perfil cambiado'));assert(!html.includes('Turno cambiado'));assert(html.includes('Página 3 / 3'));assert(html.includes('Hasta 56 estancias por hoja A4'));assert.equal(jobs[0].kind,'staylist');assert.equal(jobs[0].automatic,true);
 ctx.currentShift={employee_name:'Manual',shift_code:2,shift_date:'2026-11-05'};await ctx.printTotalStays(false);assert(jobs[1].html.includes('Empleado: Manual'));assert(jobs[1].html.includes('Turno 2 · 05/11/2026'));
 ctx.currentShift=null;ctx.currentProfile.full_name='Gerente';await ctx.printTotalStays(false);assert(jobs[2].html.includes('Sin turno operativo'));assert(jobs[2].html.includes('Empleado: Gerente'));
 console.log('Stay list: closing employee/date/time/shift repeated on all pages, captured context survives async refresh, manual/free access headers and print profile retained.');
})().catch(e=>{console.error(e);process.exitCode=1});
