const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const root=path.join(__dirname,'..'),timers=new Map(),nodes=new Map(),node=id=>{if(!nodes.has(id))nodes.set(id,{disabled:false,textContent:''});return nodes.get(id)};let next=0,calls=0,disconnects=0,active=false,resolveConnection;
const ctx={console,Set,Promise,document:{getElementById:node},window:{parkingQzRemoteHost:'192.168.1.50'},setTimeout:fn=>{timers.set(++next,fn);return next},clearTimeout:id=>timers.delete(id),qz:{websocket:{isActive:()=>active,connect:()=>{calls++;return new Promise(resolve=>resolveConnection=resolve)},disconnect:async()=>{disconnects++}},printers:{find:async()=> 'BIXOLON SRP-350III'}}};ctx.window.qz=ctx.qz;vm.createContext(ctx);vm.runInContext(fs.readFileSync(path.join(root,'backoffice/office-print.js'),'utf8'),ctx);ctx.configureParkingQzSigning=async()=>vm.runInContext('parkingQzIdentity={certificate:"saved"}',ctx);
const settle=async()=>{for(let i=0;i<5;i++)await Promise.resolve()};
(async()=>{
const a=ctx.connectParkingQz(),b=ctx.connectParkingQz();await settle();assert.equal(calls,1);resolveConnection();await Promise.all([a,b]);assert.equal(timers.size,0);
// A stalled socket produces an actionable result and prevents a second pending attempt.
const pending=ctx.connectParkingQz();await settle();assert.equal(calls,2);const rejection=assert.rejects(()=>pending,/Recarga la página/);for(const fn of [...timers.values()])fn();await rejection;assert.equal(disconnects,1);assert.equal(timers.size,0);await assert.rejects(()=>ctx.connectParkingQz(),/Recarga esta página/);assert.equal(calls,2);
// If the native connection finishes late, its active state can still be reused.
active=true;await ctx.connectParkingQz();assert.equal(calls,2);active=false;
ctx.qz.websocket.connect=async()=>{calls++;throw Error('The current connection attempt has not returned yet')};await assert.rejects(()=>ctx.connectParkingQz(),/intento pendiente/);assert.equal(disconnects,2);
// The device-check button is also protected against repeated clicks.
const source=fs.readFileSync(path.join(root,'backoffice/reinforcement.js'),'utf8');Object.assign(ctx,{reEl:node});let checks=0,release;ctx.connectParkingQz=()=>{checks++;return new Promise(resolve=>release=resolve)};vm.runInContext(source.slice(source.indexOf('let reinforcementPrinterCheckBusy='),source.indexOf('let reinforcementPrintTestBusy=')),ctx);
const first=ctx.checkReinforcementPrinter(),second=ctx.checkReinforcementPrinter();assert.equal(checks,1);assert.equal(node('reinforcementPrinterCheck').disabled,true);release();await Promise.all([first,second]);assert.equal(node('reinforcementPrinterCheck').disabled,false);assert(node('reinforcementPrinterStatus').textContent.includes('Conexión correcta'));
assert(source.includes('Abrir conexión del ordenador'));assert(source.includes("':8181/'"));
console.log('QZ connection: concurrent callers share one attempt; stalled sockets time out and close; reload guidance prevents pending retries; existing active connections and repeated device checks work.');
})().catch(e=>{console.error(e);process.exitCode=1});
