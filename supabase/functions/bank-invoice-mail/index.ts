import {createClient} from 'npm:@supabase/supabase-js@2.117.3';
import * as PDFLib from 'npm:pdf-lib@1.17.1';
import {buildInvoicePdf} from './invoice-pdf.mjs';
const cors={'Access-Control-Allow-Origin':'https://lariosrental.github.io','Access-Control-Allow-Headers':'authorization,apikey,x-client-info,content-type','Access-Control-Allow-Methods':'POST,GET,OPTIONS'};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json'}});
const esc=(v:unknown)=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
let configCache:{expires:number;value:any}|null=null,logoPromise:Promise<ArrayBuffer>|null=null;
async function mailConfiguration(){if(configCache&&configCache.expires>Date.now())return configCache.value;const apiKey=Deno.env.get('RESEND_API_KEY');if(!apiKey)return{ready:false,error:'Falta configurar RESEND_API_KEY en el servicio de correo del parking'};
 let sender=Deno.env.get('INVOICE_EMAIL_FROM')||Deno.env.get('BOOKING_EMAIL_FROM')||'';
 const email=sender.match(/<([^>]+)>/)?.[1]||sender,domain=email.split('@')[1]?.toLowerCase();
 let replyTo=Deno.env.get('INVOICE_EMAIL_REPLY_TO')||Deno.env.get('BOOKING_EMAIL_REPLY_TO')||undefined;
 let verified:any[]=[];let domainsKnown=false;
 try{const r=await fetch('https://api.resend.com/domains',{headers:{Authorization:'Bearer '+apiKey},signal:AbortSignal.timeout(15000)});if(r.ok){const data=await r.json();verified=(data.data||[]).filter((d:any)=>d.status==='verified');domainsKnown=true}}catch{}
 const invalidPublicDomain=!domain||/^(gmail\.com|googlemail\.com|hotmail\.com|outlook\.com|resend\.dev)$/i.test(domain);
 if(invalidPublicDomain||(domainsKnown&&!verified.some((d:any)=>d.name===domain))){const owned=verified.filter((d:any)=>/(lariosrental|lasdelicias)/i.test(d.name));if(owned.length===1){if(!replyTo&&email.includes('@')&&!/@resend\.dev$/i.test(email))replyTo=email;sender='Parking Las Delicias <facturas@'+owned[0].name+'>'}else sender=''}
 const value=!sender?{ready:false,error:'El remitente configurado no tiene un dominio verificado en Resend. Hace falta configurar un remitente autorizado para enviar facturas a clientes.'}:{ready:true,sender,replyTo};configCache={expires:Date.now()+60000,value};return value;
}
const base64=(bytes:Uint8Array)=>{let s='';for(let i=0;i<bytes.length;i+=32768)s+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(s)};
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 // Public liveness exposes no credentials, recipients, invoice data or configured address.
 if(req.method==='GET')return json({ok:true,apiConfigured:!!Deno.env.get('RESEND_API_KEY'),senderConfigured:!!(Deno.env.get('INVOICE_EMAIL_FROM')||Deno.env.get('BOOKING_EMAIL_FROM'))});
 if(req.method!=='POST')return json({error:'Método no permitido'},405);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});let lease:string|null=null;
 try{const token=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');if(!token)return json({error:'No autorizado'},401);
 const internal=await admin.rpc('parking_mail_worker_authorized',{p_token:token});if(internal.error)throw internal.error;
 if(!internal.data){const {data,error}=await admin.auth.getUser(token);if(error||!data.user)return json({error:'No autorizado'},401);const staff=await admin.from('staff_profiles').select('active').eq('user_id',data.user.id).maybeSingle();if(staff.error||!staff.data?.active)return json({error:'No autorizado'},403)}
 const body=await req.json(),config=await mailConfiguration();
 if(body.action==='selftest'){if(!internal.data)return json({error:'No autorizado'},403);const image=await fetch('https://lariosrental.github.io/-PARKING-LAS-DELICIAS/backoffice/assets/logo-las-delicias.png',{signal:AbortSignal.timeout(15000)});if(!image.ok)throw new Error('Logo original no disponible');const pdf=await buildInvoicePdf({number:'PRUEBA - NO FISCAL',issued_at:new Date().toISOString(),billing_month:'2026-10-01',customer_name:'Cliente de prueba',customer_tax_id:'B12345678',customer_address:'Calle de prueba 1, 29008 Málaga',vehicle:'Vehículo de prueba',plate:'1234ABC',amount_before_vat:123.97,discount_eur:6.2,vat_eur:24.73,total_eur:142.5},PDFLib,await image.arrayBuffer());const parsed=await PDFLib.PDFDocument.load(pdf);return json({pdfBytes:pdf.length,pages:parsed.getPageCount(),customerCopyOnly:true,emailSent:false,mailReady:config.ready,mailError:config.error||null})}
 if(body.action==='status')return json({ready:config.ready,sender:config.ready?config.sender:null,error:config.error||null});if(body.action!=='process')return json({error:'Acción inválida'},400);
 const start=await admin.rpc('parking_mail_worker_start');if(start.error)throw start.error;lease=start.data;if(!lease)return json({ok:true,busy:true});let sent=0,blocked=0,failed=0;
 for(let i=0;i<10;i++){const claim=await admin.rpc('parking_claim_bank_invoice_mail');if(claim.error)throw claim.error;const job=claim.data;if(!job)break;if(job.skipped)continue;
 let status='error',providerId:null|string=null,detail:null|string=null;
 if(!config.ready){status='provider_unconfigured';detail=config.error;blocked++}else{try{
  if(!logoPromise)logoPromise=fetch('https://lariosrental.github.io/-PARKING-LAS-DELICIAS/backoffice/assets/logo-las-delicias.png',{signal:AbortSignal.timeout(15000)}).then(r=>{if(!r.ok)throw new Error('No se pudo cargar el PNG original');return r.arrayBuffer()});
  const pdf=await buildInvoicePdf(job.invoice,PDFLib,await logoPromise),invoice=job.invoice,month=new Date(invoice.billing_month+'T12:00:00Z').toLocaleDateString('es-ES',{month:'long',year:'numeric'}),message='Adjuntamos la factura '+invoice.number+' de su abono mensual de '+month+'. El pago se ha registrado mediante banco.';
  const payload:any={from:config.sender,to:[job.recipient],subject:'Factura '+invoice.number+' · Parking Las Delicias · '+month,html:'<p>Hola '+esc(invoice.customer_name)+',</p><p>'+esc(message)+'</p><p>Gracias,<br>Parking Las Delicias</p>',text:'Hola '+invoice.customer_name+',\n\n'+message+'\n\nParking Las Delicias',attachments:[{filename:'Factura-'+invoice.number+'.pdf',content:base64(pdf)}]};if(config.replyTo)payload.reply_to=config.replyTo;
  const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:'Bearer '+Deno.env.get('RESEND_API_KEY'),'Content-Type':'application/json','Idempotency-Key':'parking-bank-invoice-'+job.id},body:JSON.stringify(payload),signal:AbortSignal.timeout(20000)}),result=await response.json().catch(()=>({}));
  if(!response.ok){detail=String(result.message||'Servicio de correo: HTTP '+response.status).slice(0,800);status=response.status===401||response.status===403?'provider_unconfigured':'error';failed++}else{status='sent';providerId=result.id;sent++}
 }catch(e){detail=String((e as Error).message||e).slice(0,800);failed++;logoPromise=null}await new Promise(resolve=>setTimeout(resolve,700))}
 const complete=await admin.rpc('parking_complete_bank_invoice_mail',{p_job_id:job.id,p_status:status,p_provider_id:providerId,p_error:detail});if(complete.error)throw complete.error;
 }
 return json({ok:true,sent,blocked,failed,ready:config.ready,error:config.error||null});
 }catch(e){console.error('Bank invoice worker failed:',(e as Error).message);return json({error:'No se pudo completar el envío de facturas'},500)}finally{if(lease)await admin.rpc('parking_mail_worker_finish',{p_lease:lease})}
});
