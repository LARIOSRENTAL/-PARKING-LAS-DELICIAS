/* Additional vehicles share the subscriber's existing subscription and space. */
let subscriberExtraPlates=[];
function subscriberExtraPlatesFor(id){return subscriberExtraPlates.filter(x=>x.subscriber_id===id).map(x=>x.plate)}
async function loadSubscriberExtraPlates(){const r=await db.from('monthly_subscriber_extra_plates').select('subscriber_id,plate').order('plate');if(r.error)throw new Error('No se pudieron cargar las matrículas adicionales: '+r.error.message);subscriberExtraPlates=r.data||[]}
function addSubscriberPlateRow(value=''){
 const row=document.createElement('div');row.className='actions';row.style.marginBottom='8px';
 const input=document.createElement('input');input.type='text';input.autocomplete='off';input.maxLength=20;input.placeholder='Matrícula adicional';input.value=value;input.dataset.extraSubscriberPlate='';input.style.cssText='flex:1;min-width:160px;padding:11px;border:1px solid var(--line);border-radius:11px';
 const remove=document.createElement('button');remove.type='button';remove.className='mini red';remove.textContent='Quitar';remove.onclick=()=>row.remove();row.append(input,remove);opsEl('subscriberExtraPlateRows').appendChild(row);return input;
}
function renderSubscriberExtraPlateEditor(id){
 let field=opsEl('subscriberExtraPlateEditor');if(!field){field=document.createElement('div');field.id='subscriberExtraPlateEditor';field.className='field';opsEl('editSubPlate').closest('.grid2').insertAdjacentElement('afterend',field)}
 field.innerHTML='<label>Matrículas adicionales del mismo abonado</label><div id="subscriberExtraPlateRows"></div><div><button type="button" class="mini blue" id="addSubscriberPlate">Añadir matrícula</button></div><small class="muted">Todas pertenecen al mismo abono y comparten su plaza.</small>';
 opsEl('addSubscriberPlate').onclick=()=>addSubscriberPlateRow().focus();subscriberExtraPlatesFor(id).forEach(addSubscriberPlateRow);
}
function subscriberExtraPlateValues(){const values=[...document.querySelectorAll('[data-extra-subscriber-plate]')].map(x=>normalizeRotationPlate(x.value)).filter(Boolean);if(values.some(x=>!/^[A-Z0-9]{3,16}$/.test(x)))throw Error('Revisa las matrículas adicionales: entre 3 y 16 letras o números.');return [...new Set(values)]}
function showSubscriberExtraPlates(id){const plates=subscriberExtraPlatesFor(id);const section=document.createElement('div');section.className='profileSection';section.innerHTML='<h4>Matrículas del abono</h4><div class="actions">'+[monthlySubscribers.find(x=>x.id===id)?.plate,...plates].filter(Boolean).map(x=>'<span class="tag blue">'+esc(x)+'</span>').join('')+'</div>';opsEl('subscriberProfileBody').appendChild(section)}
