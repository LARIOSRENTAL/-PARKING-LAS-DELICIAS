const assert=require('node:assert/strict'),fs=require('fs'),path=require('path'),vm=require('vm');
const source=fs.readFileSync(path.join(__dirname,'../backoffice/parking-layout.js'),'utf8');const ctx={window:{addEventListener(){}},esc:v=>String(v||''),fmt:v=>v};
vm.createContext(ctx);vm.runInContext(source,ctx);
const position=n=>Object.fromEntries(ctx.parkingMapPosition('J','J-'+n).split(';').map(v=>{const [key,value]=v.split(':');return[key,parseFloat(value)]}));
for(const n of [5,13,28,29,38,39,42,47,54,55,62]){const p=position(n);assert.equal(p.width,position(47).width);assert.equal(p.height,position(47).height);assert(p.top+p.height<=100)}
for(let n=5;n<28;n++)assert(position(n).top+position(n).height<position(n+1).top);
let detail=ctx.parkingSpotOperationDetails({inventory_state:'available'},[],[{id:'stay',plate:'1234ABC',entry_at:'2026-10-19',exit_at:'2026-10-22 10:00'}],{reservation_id:'stay',plate:'1234ABC'});
assert(detail.includes('Estancia'));assert(detail.includes('Fin previsto:'));assert(detail.includes('2026-10-22 10:00'));assert.equal(detail.match(/1234ABC/g).length,1);
detail=ctx.parkingSpotOperationDetails({},[],[],{plate:'5678DEF',entry_at:'2026-10-19'});assert(detail.includes('Rotación'));assert(detail.includes('5678DEF'));
detail=ctx.parkingSpotOperationDetails({inventory_state:'fixed'},[{customer_name:'Titular',plate:'9012GHI'}],[],null);assert(detail.includes('Abonado'));assert(detail.includes('9012GHI'));
detail=ctx.parkingSpotOperationDetails({},[],[],{reservation_id:'stay',plate:'3456JKL',planned_exit_at:'2026-10-25'});assert(detail.includes('Fin previsto:'));assert(detail.includes('2026-10-25'));
assert(source.includes("parkingPlanZone==='J'?960:360"));
console.log('Jaulas: laterales del mismo tamaño sin solapamientos, plano ampliado y detalles de estancia/rotación/abonado verificados.');
