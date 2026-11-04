(function(){
const nav=document.querySelector('.mainNav');
if(!nav)return;
const bar=document.createElement('div');bar.id='zoneAvailability';bar.style.cssText='display:none;flex-wrap:wrap;gap:6px;padding:8px;background:#eef5f9;border-bottom:1px solid #dce5ef;font-size:13px';nav.after(bar);
let running=false;
async function refresh(){
const area=document.querySelector('.mainNav button.active')?.dataset.area;
const shown=!document.hidden&&!document.getElementById('mainView')?.classList.contains('hidden')&&(area==='rotation'||area==='stays');
bar.style.display=shown?'flex':'none';if(!shown||running)return;running=true;
try{
const result=await db.rpc('parking_available_rotation_spots',{p_tariff_code:null});if(result.error)throw result.error;
const counts=new Map();
for(const item of result.data||[]){const z=String(item.zone||'').toUpperCase();if(z)counts.set(z,(counts.get(z)||0)+1)}
if(typeof spots!=='undefined')for(const item of spots||[]){const z=String(item.zone||'').toUpperCase();if(z&&!counts.has(z))counts.set(z,0)}
const order=['A','M','J','C','B','LL','P','MOTO','RESERVA'];
const keys=[...counts.keys()].sort((a,b)=>(order.indexOf(a)<0?99:order.indexOf(a))-(order.indexOf(b)<0?99:order.indexOf(b))||a.localeCompare(b));
bar.replaceChildren();
for(const z of keys){const chip=document.createElement('span');chip.style.cssText='padding:5px 9px;background:white;border:1px solid #cbdce8;border-radius:7px;font-weight:bold;white-space:nowrap';chip.textContent=z+' · '+counts.get(z)+' libres';bar.append(chip)}
}catch(e){bar.textContent='No se pudo consultar la disponibilidad';console.warn(e)}finally{running=false}
}
setInterval(refresh,10000);
document.addEventListener('visibilitychange',refresh);
document.querySelectorAll('.mainNav button').forEach(b=>b.addEventListener('click',()=>setTimeout(refresh,50)));
setTimeout(refresh,1000);
})();