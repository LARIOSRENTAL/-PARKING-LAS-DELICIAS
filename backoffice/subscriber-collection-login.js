/* A row payment is independent of the optional invoice-selection checkboxes. */
const subscriberSinglePayments=new Set();
function subscriberCollectionStatus(message,error=false){
 let box=document.getElementById('subscriberSinglePayStatus');
 if(!box){box=document.createElement('div');box.id='subscriberSinglePayStatus';box.setAttribute('role','status');document.getElementById('subscribersBody')?.before(box);}
 box.className='msg'+(error?' error':'');box.textContent=message;
}
paySubscriber=async function(id){
 const month=billingMonth()+'-01',key=month+':'+id;
 if(subscriberSinglePayments.has(key))return;
 const subscriber=monthlySubscribers.find(s=>s.id===id);if(!subscriber)return subscriberCollectionStatus('No se ha encontrado el abonado. Actualiza el listado.',true);
 if(subscriberPayment(id)||subscriber.monthly_charge?.paid)return;
 if(subscriberHasZeroCharge(subscriber))return subscriberCollectionStatus('Este abonado no tiene una cuota que cobrar.',true);
 const method=subscriberIsBank(subscriber)?'bank':document.getElementById('subPayMethod-'+id)?.value||subscriberPreferredMethod(subscriber);
 if(!['cash','card','bank'].includes(method))return subscriberCollectionStatus('Selecciona la forma de pago en la fila del abonado.',true);
 subscriberSinglePayments.add(key);
 const button=[...document.querySelectorAll('#subscribersBody button')].find(b=>b.getAttribute('onclick')==="paySubscriber('"+id+"')"),oldText=button?.textContent;
 if(button){button.disabled=true;button.textContent='Registrando e imprimiendo…';}
 subscriberCollectionStatus('Registrando el pago de '+subscriber.customer_name+'…');let saved=false;
 try{
  // The existing RPC wrapper prints the document for this returned payment ID.
  const result=await db.rpc('mark_monthly_subscription_paid',{p_subscriber_id:id,p_billing_month:month,p_payment_method:method});
  if(result.error)throw result.error;saved=true;
  const payment=result.data;if(!payment?.id)throw Error('No se recibió la referencia del pago. Actualiza el listado antes de reintentarlo.');
  // Manual bank collection also prints, while automated bank payments stay unchanged.
  if(!payment.pricing_snapshot?.training&&!subscriberPaymentPrintJobs.has(payment.id)){
   subscriberPaymentPrintJobs.set(payment.id,{id:payment.id,name:subscriber.customer_name,state:'pending'});
   await retrySubscriberPaymentPrint(payment.id);
  }
  const job=subscriberPaymentPrintJobs.get(payment.id);
  subscriberCollectionStatus(payment.pricing_snapshot?.training?'Pago de prueba registrado.':job?.state==='done'?'Pago registrado y documento enviado a la impresora.':'Pago registrado. El documento está pendiente de impresión; utiliza «Reintentar impresión sin volver a cobrar».',job?.state==='error');
  await loadMonthlyPayments();if(typeof refreshSubscriberDeadlineAlerts==='function')await refreshSubscriberDeadlineAlerts();
 }catch(e){subscriberCollectionStatus((saved?'El pago ya está registrado. Actualiza el listado; no repitas el cobro. ':'No se pudo registrar el pago. ')+e.message,true);}
 finally{subscriberSinglePayments.delete(key);if(button?.isConnected){button.disabled=!!subscriberPayment(id);button.textContent=oldText;}}
};

function setLoginPasswordVisible(visible){
 const input=document.getElementById('loginPass'),button=document.getElementById('loginPasswordToggle');if(!input||!button)return;
 input.type=visible?'text':'password';button.setAttribute('aria-pressed',String(visible));
 const label=visible?'Ocultar contraseña':'Mostrar contraseña';button.setAttribute('aria-label',label);button.title=label;
 button.querySelector('[data-eye-slash]')?.classList.toggle('hidden',!visible);
}
document.getElementById('loginPasswordToggle')?.addEventListener('click',()=>{
 const input=document.getElementById('loginPass'),start=input.selectionStart,end=input.selectionEnd;
 setLoginPasswordVisible(input.type==='password');input.focus({preventScroll:true});if(start!==null&&end!==null)input.setSelectionRange(start,end);
});
const loginBeforePasswordToggle=login;
login=async function(){setLoginPasswordVisible(false);return loginBeforePasswordToggle();};
