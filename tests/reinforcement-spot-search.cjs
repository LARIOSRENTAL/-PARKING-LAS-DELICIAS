const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const root=path.join(__dirname,'../backoffice'),source=fs.readFileSync(path.join(root,'reinforcement.js'),'utf8');
const dom=new JSDOM(fs.readFileSync(path.join(root,'refuerzo.html'),'utf8'),{runScripts:'outside-only',pretendToBeVisual:true}),w=dom.window,d=w.document,el=id=>d.getElementById(id);
let spots=[{id:'2',code:'J-2',tariffs:['TURISMO'],types:['tourism']},{id:'3',code:'J-3',tariffs:['TURISMO'],types:['tourism']}],pending=null,fail=false,writes=0;
Object.assign(w,{reinforcementCode:'token',reinforcementData:{spots},reEl:el,reEscape:String,reShowMessage:message=>el('result').textContent=message,rotationEntry:async()=>writes++,createStay:async()=>writes++,setInterval:()=>{},reCall:async name=>{if(fail)throw Error('offline');if(pending){const wait=pending;pending=null;await wait.promise;}return name==='parking_reinforcement_options'?{spots}:spots;}});
el('tariff').innerHTML='<option value="TURISMO">Turismo</option>';el('type').innerHTML='<option value="tourism">Turismo</option>';
w.eval(source.slice(source.indexOf('function reinforcementFreeSpots'),source.indexOf('function reEscape'))+'\n'+source.slice(source.indexOf('let reinforcementStaySpots=')));
const pauseRequest=()=>{let resolve;pending={promise:new Promise(r=>resolve=r)};return resolve;};
(async()=>{
 await w.refreshReinforcementAvailability();
 for(const [id,list] of [['spot','spotOptions'],['staySpot','staySpotOptions']]){
  const field=el(id);field.focus();field.value='J-';field.setSelectionRange(1,2);const first=el(list).firstChild;
  await w.refreshReinforcementAvailability();await w.refreshReinforcementAvailability();
  assert.equal(field.value,'J-');assert.equal(d.activeElement,field);assert.equal(field.selectionStart,1);assert.equal(field.selectionEnd,2);assert.equal(el(list).firstChild,first,'Unchanged options do not rebuild the datalist');
  field.blur();await w.refreshReinforcementAvailability();assert.equal(field.value,'J-','Partial search survives updates even after blur');
 }
 // A response started before the user edits must use the text present on arrival.
 for(const [id,reload] of [['spot','reloadReinforcementSpots'],['staySpot','reloadReinforcementStaySpots']]){
  const field=el(id);field.focus();field.value='J-2';const resolve=pauseRequest(),request=w[reload]();field.value='J-3';field.setSelectionRange(2,2);resolve();await request;assert.equal(field.value,'J-3');assert.equal(field.selectionStart,2);
  field.value='J-2';const resolvePartial=pauseRequest(),partial=w[reload]();field.value='J';resolvePartial();await partial;assert.equal(field.value,'J');
 }
 // A known spot becoming occupied still warns and is refused before writing.
 for(const [id,reload,submit,help] of [['spot','reloadReinforcementSpots','rotationEntry','spotHelp'],['staySpot','reloadReinforcementStaySpots','createStay','staySpotHelp']]){
  spots=[{id:'2',code:'J-2',tariffs:['TURISMO'],types:['tourism']}];await w[reload]();el(id).focus();el(id).value='J-2';spots=[];await w[reload]();assert.equal(el(id).value,'J-2','Editing is never erased');assert.match(el(help).textContent,/ya no está disponible/);const before=writes;await w[submit]();assert.equal(writes,before,'An occupied spot must not be assigned');
 }
 el('spot').value='J';el('staySpot').value='J-';fail=true;await w.refreshReinforcementAvailability();assert.equal(el('spot').value,'J');assert.equal(el('staySpot').value,'J-');assert.match(el('reinforcementAvailabilityStatus').textContent,/No se pudieron actualizar/);
 dom.window.close();console.log('PASS: both searches retain partial text, caret, focus and unchanged datalist options across polling; delayed responses keep current edits; occupied spots and offline preflight remain blocked.');
})().catch(error=>{console.error(error);dom.window.close();process.exitCode=1;});
