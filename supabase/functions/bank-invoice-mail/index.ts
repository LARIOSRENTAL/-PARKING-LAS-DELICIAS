import {createClient} from 'npm:@supabase/supabase-js@2.117.3';
import * as PDFLib from 'npm:pdf-lib@1.17.1';
import {buildInvoicePdf} from './invoice-pdf.mjs';
const cors={'Access-Control-Allow-Origin':'https://lariosrental.github.io','Access-Control-Allow-Headers':'authorization,apikey,x-client-info,content-type','Access-Control-Allow-Methods':'POST,GET,OPTIONS'};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json'}});
const esc=(v:unknown)=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const officeMailbox = 'oficina@parkinglasdelicias.com';
const invoiceSender = 'Parking Las Delicias <' + officeMailbox + '>';
const customerMailPaused = 'El envío de facturas a clientes está pausado.';
const logoUrl = 'https://lariosrental.github.io/-PARKING-LAS-DELICIAS/backoffice/assets/logo-las-delicias.png';
let logoPromise: Promise<ArrayBuffer> | null = null;

function getInvoiceLogo() {
  return logoPromise ??= fetch(logoUrl, {signal: AbortSignal.timeout(15000)}).then(response => {
    if (!response.ok) throw new Error('No se pudo cargar el PNG original');
    return response.arrayBuffer();
  }).catch(error => {
    logoPromise = null;
    throw error;
  });
}

async function sendInvoiceEmail(apiKey: string, payload: unknown, idempotencyKey: string) {
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + apiKey,
      'Content-Type': 'application/json',
      'Idempotency-Key': idempotencyKey
    },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(20000)
  });
  const result = await response.json().catch(() => ({}));
  return {response, result};
}

const base64=(bytes:Uint8Array)=>{let s='';for(let i=0;i<bytes.length;i+=32768)s+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(s)};
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 // Public liveness exposes no credentials, recipients, invoice data or configured address.
 const apiKey = Deno.env.get('INVOICE_RESEND_API_KEY');
 const customerSendingEnabled = Deno.env.get('INVOICE_CUSTOMER_EMAIL_ENABLED') === 'true';
 if (req.method === 'GET') return json({ok:true,apiConfigured:!!apiKey,senderConfigured:true,customerSendingEnabled});
 if(req.method!=='POST')return json({error:'Método no permitido'},405);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});let lease:string|null=null;
 try{const token=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');if(!token)return json({error:'No autorizado'},401);
 const internal=await admin.rpc('parking_mail_worker_authorized',{p_token:token});if(internal.error)throw internal.error;
 if(!internal.data){const {data,error}=await admin.auth.getUser(token);if(error||!data.user)return json({error:'No autorizado'},401);const staff=await admin.from('staff_profiles').select('active').eq('user_id',data.user.id).maybeSingle();if(staff.error||!staff.data?.active)return json({error:'No autorizado'},403)}
 const body = await req.json();
 const configError = apiKey ? null : 'Falta configurar INVOICE_RESEND_API_KEY en el servicio de correo del parking.';
 if (body.action === 'selftest' || body.action === 'send_test') {
   if (!internal.data) return json({error:'No autorizado'},403);
   if (body.action === 'send_test' && !apiKey) return json({error:configError},503);
   const now = new Date().toISOString();
   const pdf = await buildInvoicePdf({
     number:'PRUEBA - NO FISCAL', issued_at:now, billing_month:now.slice(0,7)+'-01',
     customer_name:'Cliente ficticio', customer_tax_id:'B00000000',
     customer_address:'Calle de prueba 1, 29008 Málaga', vehicle:'Vehículo de prueba',
     plate:'0000ZZZ', amount_before_vat:123.97, discount_eur:6.2, vat_eur:24.73, total_eur:142.5
   }, PDFLib, await getInvoiceLogo());
   const pages = (await PDFLib.PDFDocument.load(pdf)).getPageCount();
   if (body.action === 'selftest') {
     return json({pdfBytes:pdf.length,pages,customerCopyOnly:true,emailSent:false,mailReady:!configError,mailError:configError,customerSendingEnabled});
   }
   const {response,result} = await sendInvoiceEmail(apiKey!, {
     from:invoiceSender, to:[officeMailbox], reply_to:officeMailbox,
     subject:'PRUEBA INTERNA · Factura ficticia · Parking Las Delicias',
     text:'Prueba interna del envío de facturas. El PDF adjunto contiene datos ficticios y carece de validez fiscal.',
     attachments:[{filename:'Factura-de-prueba-sin-validez-fiscal.pdf',content:base64(pdf)}]
   }, 'parking-invoice-office-test-' + crypto.randomUUID());
   if (!response.ok || !result.id) {
     return json({emailSent:false,providerStatus:response.status,error:String(result.message||'Resend no confirmó el envío').slice(0,800)},502);
   }
   return json({emailSent:true,providerId:result.id,pages,pdfBytes:pdf.length,customerSendingEnabled});
 }
 if (body.action === 'status') {
   const error = customerSendingEnabled ? configError : customerMailPaused;
   return json({ready:!error,sender:invoiceSender,error,customerSendingEnabled});
 }
 if (body.action === 'send_customer') {
   if (!apiKey) return json({error:configError},503);
   const recipient=String(body.recipient||'').trim().toLowerCase();
   const invoiceId=String(body.invoice_id||'').trim();
   if (!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(recipient) || recipient.length>254) return json({error:'Introduce un correo electrónico válido.'},400);
   if (!/^[0-9a-f-]{36}$/i.test(invoiceId)) return json({error:'No se encontró la factura.'},400);
   const {data:invoice,error:invoiceError}=await admin.from('parking_invoices').select('*').eq('id',invoiceId).maybeSingle();
   if(invoiceError)throw invoiceError;
   if(!invoice)return json({error:'La factura ya no está disponible.'},404);
   const actualInvoice={...invoice,number:invoice.display_number||invoice.number};
   const pdf=await buildInvoicePdf(actualInvoice,PDFLib,await getInvoiceLogo());
   const pending=body.pending_payment===true;
   const message=pending
     ? 'Adjuntamos la factura '+actualInvoice.number+' correspondiente a los bonos diarios solicitados. La factura está pendiente de pago. Le rogamos que nos envíe el justificante de la transferencia para poder venir a recoger los bonos diarios solicitados.'
     : 'Adjuntamos la factura '+actualInvoice.number+' correspondiente a su operación con Parking Las Delicias.';
   const payload:any={
     from:invoiceSender,to:[recipient],reply_to:officeMailbox,
     subject:(pending?'Factura pendiente de pago ':'Factura ')+actualInvoice.number+' · Parking Las Delicias',
     html:'<p>Hola '+esc(actualInvoice.customer_name)+',</p><p>'+esc(message)+'</p><p>Gracias,<br>Parking Las Delicias</p>',
     text:'Hola '+actualInvoice.customer_name+',\\n\\n'+message+'\\n\\nParking Las Delicias',
     attachments:[{filename:'Factura-'+actualInvoice.number+'.pdf',content:base64(pdf)}]
   };
   const {response,result}=await sendInvoiceEmail(apiKey,payload,'parking-customer-invoice-'+invoiceId+'-'+crypto.randomUUID());
   if(!response.ok||!result.id)return json({emailSent:false,providerStatus:response.status,error:String(result.message||'El servicio de correo no confirmó el envío').slice(0,800)},502);
   return json({emailSent:true,recipient,providerId:result.id,invoiceNumber:actualInvoice.number,pdfBytes:pdf.length});
 }
 if (body.action !== 'process') return json({error:'Acción inválida'},400);
 if (!customerSendingEnabled || !apiKey) {
   return json({ok:true,ready:false,sent:0,blocked:0,failed:0,error:customerSendingEnabled ? configError : customerMailPaused});
 }
 const start=await admin.rpc('parking_mail_worker_start');if(start.error)throw start.error;lease=start.data;if(!lease)return json({ok:true,busy:true});let sent=0,failed=0;
 for(let i=0;i<10;i++){const claim=await admin.rpc('parking_claim_bank_invoice_mail');if(claim.error)throw claim.error;const job=claim.data;if(!job)break;if(job.skipped)continue;
 let status='error',providerId:null|string=null,detail:null|string=null;
 try {
  const pdf=await buildInvoicePdf(job.invoice,PDFLib,await getInvoiceLogo()),invoice=job.invoice,month=new Date(invoice.billing_month+'T12:00:00Z').toLocaleDateString('es-ES',{month:'long',year:'numeric'}),message='Adjuntamos la factura '+invoice.number+' de su abono mensual de '+month+'. El pago se ha registrado mediante banco.';
  const payload:any={from:invoiceSender,to:[job.recipient],reply_to:officeMailbox,subject:'Factura '+invoice.number+' · Parking Las Delicias · '+month,html:'<p>Hola '+esc(invoice.customer_name)+',</p><p>'+esc(message)+'</p><p>Gracias,<br>Parking Las Delicias</p>',text:'Hola '+invoice.customer_name+',\n\n'+message+'\n\nParking Las Delicias',attachments:[{filename:'Factura-'+invoice.number+'.pdf',content:base64(pdf)}]};
  const {response,result}=await sendInvoiceEmail(apiKey,payload,'parking-bank-invoice-'+job.id);
  if(!response.ok||!result.id){detail=String(result.message||'Servicio de correo: HTTP '+response.status).slice(0,800);status=response.status===401||response.status===403?'provider_unconfigured':'error';failed++}else{status='sent';providerId=result.id;sent++}
 }catch(e){detail=String((e as Error).message||e).slice(0,800);failed++}await new Promise(resolve=>setTimeout(resolve,700))
 const complete=await admin.rpc('parking_complete_bank_invoice_mail',{p_job_id:job.id,p_status:status,p_provider_id:providerId,p_error:detail});if(complete.error)throw complete.error;
 }
 return json({ok:true,sent,blocked:0,failed,ready:true,error:null});
 }catch(e){console.error('Bank invoice worker failed:',(e as Error).message);return json({error:'No se pudo completar el envío de facturas'},500)}finally{if(lease)await admin.rpc('parking_mail_worker_finish',{p_lease:lease})}
});
