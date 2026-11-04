const vm=require('vm'),fs=require('fs'),path=require('path'),assert=require('assert');
const root=path.resolve(__dirname,'..'),nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{value:'',innerHTML:'',textContent:'',remove(){},classList:{toggle(name,state){this[name]=state}},append(child){nodes.set(child.id,child)}});return nodes.get(id)};
let staySessions=[],stayError=null;
const inventory=require('../docs/parking-inventory.json');const ctx=vm.createContext({console,Set,Map,Number,Date,Math,currentProfile:{role:'employee'},spots:inventory.map((s,i)=>({...s,id:String(i),vehicle_type_id:'t',polyvalent:s.zone==='RESERVA'})),vehicleTypes:[{id:'t',code:'TURISMO',name:'Turismo'}],tariffs:[],rotationTariffs:[],rotationSegments:[],insideSessions:[],outsideSessions:[],reservations:[],capacityBlocks:[],window:{addEventListener(){}},db:{rpc:async()=>({data:[]}),from:table=>({select(){return this},eq(){return this},order(){return this},then(resolve){return Promise.resolve({error:table==='parking_sessions'?stayError:null,data:table==='parking_sessions'?staySessions:table==='parking_spots'?inventory.map((s,i)=>({...s,id:String(i),vehicle_type_id:'t',polyvalent:s.zone==='RESERVA'})):[]}).then(resolve)}})},document:{querySelectorAll:()=>[],getElementById:node,querySelector:s=>s.includes('parkingMap')?null:node('ratesButton'),createElement:()=>({})},loadCapacityBlocks:async()=>{},localInput:d=>d.toISOString(),esc:s=>String(s||''),fmt:s=>s,money:n=>n+' €',renderQuickBlocks(){},reservedOutsideSpotIds:()=>new Set(),activeBlockForSpot:()=>null,renderDailyRates(){},renderHourlyRates(){}});
vm.runInContext(fs.readFileSync(path.join(root,'backoffice/parking-layout.js'),'utf8'),ctx);vm.runInContext(fs.readFileSync(path.join(root,'backoffice/rates-planning.js'),'utf8'),ctx);
(async()=>{vm.runInContext('configureRatesAccess()',ctx);assert(node('ratesButton').classList.hidden);vm.runInContext("currentProfile={role:'manager'};configureRatesAccess()",ctx);assert.equal(node('ratesButton').classList.hidden,false);
node('spotPlanDate').value='2026-10-15';await vm.runInContext('loadSpots()',ctx);assert.equal((node('spotsBody').innerHTML.match(/class="spot /g)||[]).length,248);assert(node('spotsBody').innerHTML.includes('J-62'));node('spotStateFilter').value='FIJO';await vm.runInContext('loadSpots()',ctx);assert.equal((node('spotsBody').innerHTML.match(/class="spot /g)||[]).length,68);
const free=vm.runInContext("freeSpotsFor('t')",ctx);assert.equal(free.length,172);assert.equal(free.filter(x=>x.polyvalent).length,30);assert(free.every(x=>x.inventory_state==='available'));
// Early check-in must occupy today's space even if the stored entry date is future.
node('spotStateFilter').value='';node('spotPlanDate').value=new Date().toISOString().slice(0,10);
const cage=ctx.spots.find(s=>s.code==='J-29'),future=new Date(Date.now()+3*86400000).toISOString(),exit=new Date(Date.now()+27*86400000).toISOString();
const state=()=>vm.runInContext('parkingPlanDetails',ctx).get(cage.id);
ctx.reservations=[{id:'early',assigned_spot_id:cage.id,plate:'YRM96J',status:'checked_in',vehicle_presence:'DENTRO',last_movement_at:new Date().toISOString(),entry_at:future,exit_at:exit}];
await ctx.loadSpots();assert.equal(state().state,'DENTRO');assert(!state().actions.includes('Bloquear por fechas'));
// The current session is authoritative even when cached reservations are stale.
ctx.reservations=[];staySessions=[{id:'session',reservation_id:'early',spot_id:cage.id,plate:'YRM96J',actual_entry_at:future,planned_entry_at:future,planned_exit_at:exit}];
await ctx.loadSpots();assert.equal(state().state,'DENTRO');assert(state().detail.includes('YRM96J'));
// Releasing the session updates the planning without reloading the page.
staySessions=[];await ctx.loadSpots();assert.notEqual(state().state,'DENTRO');
ctx.reservations=[{id:'future',assigned_spot_id:cage.id,status:'confirmed',entry_at:future,exit_at:exit}];
await ctx.loadSpots();assert.notEqual(state().state,'DENTRO');
node('spotPlanDate').value=future.slice(0,10);await ctx.loadSpots();assert.equal(state().state,'RESERVADA');
stayError={message:'test failure'};await ctx.loadSpots();assert(node('spotsBody').textContent.includes('test failure'));stayError=null;
node('rateService').value='hourly';node('rateMode').value='period';node('rateCategory').value='r';vm.runInContext("rotationTariffs=[{id:'r',name:'Turismo',daily_cap_eur:20}];renderRateFields()",ctx);assert(node('rateFields').innerHTML.includes('rateStart'));assert(node('rateFields').innerHTML.includes('rateEnd'));assert(node('rateFields').innerHTML.includes('rateIncrease'));
const html=fs.readFileSync(path.join(root,'backoffice/index.html'),'utf8');assert(!html.includes('data-tab="planning"'));assert(html.includes("if(area==='rates'&&!canManageRates())return"));assert(html.includes('rates-planning.js'));assert(!html.includes('id="planning"'));
console.log('UI: employee tariff navigation hidden and guarded, single planning view, 248 spots, 68 fixed, 30 polyvalent, blocked/fixed exclusion and dated rate fields verified.');})().catch(e=>{console.error(e);process.exitCode=1});
