(function(){
const nav=document.getElementById('rotationNav');
if(!nav)return;
const bar=document.createElement('div');bar.id='zoneAvailability';bar.style.cssText='display:none;flex-wrap:wrap;gap:6px;padding:8px;background:#eef5f9;border-bottom:1px solid #dce5ef;font-size:13px;position:relative;z-index:93';nav.after(bar);bar.textContent='Consultando ocupación de plazas…';
let running=false;
async function refresh(){
 const area=document.querySelector('.mainNav button.active')?.dataset.area;
 const shown=!document.hidden&&!document.getElementById('mainView')?.classList.contains('hidden')&&(area==='rotation'||area==='stays');
 bar.style.display=shown?'flex':'none';if(!shown||running)return;running=true;
 try{
  const [availability,inventory]=await Promise.all([db.rpc('parking_available_rotation_spots',{p_tariff_code:null}),db.from('parking_spots').select('zone').eq('active',true)]);
  if(availability.error)throw availability.error;if(inventory.error)throw inventory.error;
  const freeByZone=new Map(),totalByZone=new Map();
  for(const item of availability.data||[]){const z=String(item.zone||'OTRAS').toUpperCase();freeByZone.set(z,(freeByZone.get(z)||0)+1)}
  for(const item of inventory.data||[]){const z=String(item.zone||'OTRAS').toUpperCase();totalByZone.set(z,(totalByZone.get(z)||0)+1)}
  const order=['A','M','J','C','B','LL','P','MOTO','RESERVA'];
  const keys=[...totalByZone.keys()].sort((a,b)=>(order.indexOf(a)<0?99:order.indexOf(a))-(order.indexOf(b)<0?99:order.indexOf(b))||a.localeCompare(b));
  const total=[...totalByZone.values()].reduce((sum,n)=>sum+n,0),free=[...freeByZone.values()].reduce((sum,n)=>sum+n,0),unavailable=Math.max(0,total-free);
  bar.replaceChildren();
  const summary=document.createElement('strong');summary.style.cssText='padding:5px 9px;background:#e2edf5;border:1px solid #cbdce8;border-radius:7px;white-space:nowrap';summary.textContent='TOTAL · '+total+' plazas · '+unavailable+' ocupadas / no disponibles · '+free+' libres';bar.append(summary);
  for(const z of keys){const count=totalByZone.get(z),available=Math.min(count,freeByZone.get(z)||0),busy=count-available,chip=document.createElement('span');chip.style.cssText='padding:5px 9px;background:white;border:1px solid #cbdce8;border-radius:7px;font-weight:bold;white-space:nowrap';chip.title='Incluye plazas ocupadas, fijas, bloqueadas o reservadas';chip.textContent=z+' · '+busy+' ocupadas · '+available+' libres';bar.append(chip)}
 }catch(e){bar.textContent='No se pudo consultar la ocupación de plazas';console.warn(e)}finally{running=false}
}
setInterval(refresh,10000);
document.addEventListener('visibilitychange',refresh);
document.querySelectorAll('.mainNav button').forEach(b=>b.addEventListener('click',()=>setTimeout(refresh,50)));
setTimeout(refresh,1000);
})();
