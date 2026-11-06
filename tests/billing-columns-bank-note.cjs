const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{pathToFileURL}=require('node:url'),{JSDOM}=require('jsdom');
const root=path.join(__dirname,'..'),html=fs.readFileSync(path.join(root,'backoffice/index.html'),'utf8');
(async()=>{
 const dom=new JSDOM(html,{url:'https://lariosrental.github.io/-PARKING-LAS-DELICIAS/backoffice/',runScripts:'outside-only'}),w=dom.window;
 Object.assign(w,{TextEncoder,TextDecoder,currentProfile:{role:'admin'},opsEl:id=>w.document.getElementById(id),esc:v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),fmt:String,money:v=>Number(v).toFixed(2)+' €',paymentMethodLabel:v=>({bank:'Banco',cash:'Efectivo',card:'Tarjeta',online:'Online'}[v]||v||'')});
 w.eval(fs.readFileSync(path.join(root,'backoffice/billing-exports.js'),'utf8'));
 const row={kind:'income',document_series:'OFM',document_number:'000123',document_date:'2026-11-01',customer_name:'=HYPERLINK("test")',customer_tax_id:'B12345678',customer_address:'Calle Ejemplo, 1',customer_postal_code:'01234',customer_phone:'+34 600 000 000',vehicle:'VOLVO',plate:'0012ABC',base_eur:117.77,discount_eur:6.2,vat_eur:24.73,amount_eur:142.5,payment_method:'bank'};
 const sheet=w.reportFiscalInvoices([row,{...row,kind:'expense'},{...row,document_series:null}]);
 assert.deepEqual(Array.from(sheet.rows[0]),['Serie','Número','Fecha','Nombre','NIF','Domicilio','Codigo Postal','Telefono','Vehiculo','Matricula','Base imponible (€)','Descuento','IVA (€)','Total (€)','Forma de Pago']);
 assert.equal(sheet.rows.length,2);assert.deepEqual(Array.from(sheet.rows[1]),['OFM','000123','2026-11-01',row.customer_name,'B12345678','Calle Ejemplo, 1','01234','+34 600 000 000','VOLVO','0012ABC',117.77,6.2,24.73,142.5,'Banco']);assert.equal(Math.round((sheet.rows[1][10]+sheet.rows[1][12])*100),Math.round(sheet.rows[1][13]*100));
 const out=process.env.PARKING_BILLING_QA_DIR||'/tmp/parking-billing-columns-test';fs.mkdirSync(out,{recursive:true});fs.writeFileSync(path.join(out,'columns.xlsx'),Buffer.from(w.parkingReportXlsx({sheets:[sheet]})));
 const start=html.indexOf('function buildParkingInvoiceHtml(invoice){'),end=html.indexOf('\nfunction openSubscriberProfile',start);w.eval(html.slice(start,end));
 const invoice={number:'OFM 2664721',issued_at:'2026-11-01T08:00:00Z',billing_month:'2026-11-01',entity_type:'subscriber',customer_name:'Cliente de prueba',customer_tax_id:'B12345678',customer_address:'Calle Ejemplo 1, 01234 Málaga',vehicle:'VOLVO',plate:'0012ABC',amount_before_vat:123.97,discount_eur:6.2,vat_eur:24.73,total_eur:142.5};
 const note='El abono de esta factura se acreditara con el adeudo en Cta. de la misma';
 for(const method of ['bank','bank_transfer','transferencia','domiciliación bancaria','direct_debit','sepa']){
  const result=w.buildParkingInvoiceHtml({...invoice,payment_context:{payment_method:method}}),d=new JSDOM(result).window.document;assert.equal(d.querySelector('.bank-payment-note span').textContent,note);assert.match(d.querySelector('.totals').textContent,/142,50/);
 }
 for(const method of ['cash','card','online'])assert(!new JSDOM(w.buildParkingInvoiceHtml({...invoice,payment_context:{payment_method:method}})).window.document.querySelector('.bank-payment-note'));
 assert(!new JSDOM(w.buildParkingInvoiceHtml({...invoice,payment_context:{payment_method:'cash',automatic_bank_payment:true}})).window.document.querySelector('.bank-payment-note'),'Saved cash payment takes precedence over flags');
 fs.writeFileSync(path.join(out,'invoice.html'),w.buildParkingInvoiceHtml({...invoice,payment_context:{payment_method:'bank'}}));
 const pdfModule=await import(pathToFileURL(path.join(root,'supabase/functions/bank-invoice-mail/invoice-pdf.mjs'))),pdfLib=require('pdf-lib'),logoPath=process.env.PARKING_TEST_LOGO;
 if(logoPath){const logo=fs.readFileSync(logoPath);for(const method of ['bank','transfer','cash']){const bytes=await pdfModule.buildInvoicePdf({...invoice,payment_context:{payment_method:method}},pdfLib,logo);assert.equal((await pdfLib.PDFDocument.load(bytes)).getPageCount(),1);fs.writeFileSync(path.join(out,'invoice-'+method+'.pdf'),bytes);}}
 dom.window.close();console.log('PASS: exact A–O column order, text postal codes/phone/identifiers, numeric amounts, no duplicate discount deduction, bank/transfer notes in HTML and one-page PDF, cash/card excluded.');
})().catch(e=>{console.error(e);process.exitCode=1;});
