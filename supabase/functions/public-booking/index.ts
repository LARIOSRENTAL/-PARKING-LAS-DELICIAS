import {createClient} from "npm:@supabase/supabase-js@2.118.0";

import {PDFDocument, StandardFonts, rgb} from "npm:pdf-lib@1.17.1";

const site = "https://parkinglasdelicias.com/";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (data: unknown, status = 200) => Response.json(data, {status, headers: cors});
const categories = ["MOTO", "TURISMO", "XL", "XXL"];

async function stripe(path: string, key: string, params?: URLSearchParams, idempotencyKey?: string) {
  const headers: Record<string, string> = {Authorization: "Bearer " + key};
  if (params) headers["Content-Type"] = "application/x-www-form-urlencoded";
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
  const response = await fetch("https://api.stripe.com/v1/" + path, {
    method: params ? "POST" : "GET", headers, body: params, signal: AbortSignal.timeout(12000),
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => null);
    const fields = [payload?.error?.type, payload?.error?.code, payload?.error?.param]
      .filter(value => typeof value === "string" && /^[a-zA-Z0-9_\[\].-]{1,100}$/.test(value));
    const requestId = response.headers.get("request-id");
    if (requestId && /^req_[a-zA-Z0-9]+$/.test(requestId)) fields.push(requestId);
    throw new Error("Stripe HTTP " + response.status + " " + fields.join(" "));
  }
  return response.json();
}

async function validSignature(body: string, header: string, secret: string) {
  const parts = header.split(",");
  const timestamp = parts.find(part => part.startsWith("t="))?.slice(2);
  if (!timestamp || !/^\d+$/.test(timestamp) || Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false;
  const bytes = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", bytes.encode(secret), {name:"HMAC", hash:"SHA-256"}, false, ["verify"]);
  for (const part of parts) {
    if (!/^v1=[0-9a-f]{64}$/.test(part)) continue;
    const signature = Uint8Array.from(part.slice(3).match(/../g)!, pair => parseInt(pair, 16));
    if (await crypto.subtle.verify("HMAC", key, signature, bytes.encode(timestamp + "." + body))) return true;
  }
  return false;
}

const office = "oficina@parkinglasdelicias.com";
const voucherFields = "id,reference,amount_eur,created_at,entry_at,exit_at,duration_days,customer_name,customer_email,customer_phone,vehicle_make_model,plate,booking_language,vehicle_type:vehicle_types(code),status,payment_status,stripe_payment_intent_id,web_voucher_customer_message_id,web_voucher_office_message_id";
type VoucherBooking = {
  id: string;
  reference: string;
  amount_eur: number | string;
  created_at: string;
  duration_days: number;
  entry_at: string;
  exit_at: string;
  customer_name: string;
  customer_email: string;
  customer_phone: string | null;
  vehicle_make_model: string | null;
  vehicle_type: {code: string} | null;
  booking_language: BookingLanguage;
  plate: string | null;
  status: string;
  payment_status: string;
  stripe_payment_intent_id: string | null;
  web_voucher_customer_message_id: string | null;
  web_voucher_office_message_id: string | null;
};
type BookingDb = ReturnType<typeof createClient>;
type CheckoutPayment = {
  id: string;
  livemode: boolean;
  status: string;
  payment_status: string;
  mode: string;
  currency: string;
  amount_total: number;
  payment_intent: string;
  metadata: {parking_reservation?: string} | null;
};

async function findBooking(db: BookingDb, sessionId: string): Promise<VoucherBooking | null> {
  const {data, error} = await db.from("reservations").select(voucherFields)
    .eq("source", "web").eq("stripe_checkout_session_id", sessionId).maybeSingle();
  if (error) throw error;
  return data as unknown as VoucherBooking | null;
}

async function confirmPayment(db: BookingDb, row: VoucherBooking, session: CheckoutPayment) {
  if (!session.livemode || session.status !== "complete" || session.payment_status !== "paid" ||
      session.mode !== "payment" || session.currency !== "eur" || !/^pi_[A-Za-z0-9]+$/.test(session.payment_intent) ||
      session.metadata?.parking_reservation !== row.id || Math.round(Number(row.amount_eur) * 100) !== session.amount_total) {
    return null;
  }
  if (row.payment_status === "paid") return row.stripe_payment_intent_id === session.payment_intent ? row : null;
  if (row.status !== "pending_payment" || row.payment_status !== "pending") return null;
  const {error} = await db.from("reservations").update({status:"confirmed", payment_status:"paid",
    payment_method:"online", stripe_payment_intent_id:session.payment_intent, expires_at:null})
    .eq("id", row.id).eq("stripe_checkout_session_id", session.id).eq("status","pending_payment").eq("payment_status","pending");
  if (error) throw error;
  const updated = await findBooking(db, session.id);
  return updated?.payment_status === "paid" && updated.stripe_payment_intent_id === session.payment_intent ? updated : null;
}

const bookingDate = new Intl.DateTimeFormat("es-ES", {timeZone:"Europe/Madrid", dateStyle:"short", timeStyle:"short"});
const bookingAmount = new Intl.NumberFormat("es-ES", {style:"currency", currency:"EUR"});

function voucherDetails(row: VoucherBooking) {
  return {
    reference:row.reference, name:row.customer_name, plate:row.plate,
    entry:bookingDate.format(new Date(row.entry_at)), exit:bookingDate.format(new Date(row.exit_at)),
    amount:bookingAmount.format(Number(row.amount_eur)),
  };
}


const logoUrl = site + "backoffice/assets/logo-las-delicias.png";
const confidentiality = "Este correo electrónico y, en su caso, cualquier fichero anexo al mismo, contiene información de carácter confidencial exclusivamente dirigida a su destinatario o destinatarios. Queda prohibida su divulgación, copia o distribución a terceros sin la previa autorización expresa y escrita de su autor. En el caso de haber recibido este correo electrónico por error, se ruega que se notifique inmediatamente esta circunstancia mediante reenvío a la dirección electrónica del remitente. Gracias.";
const privacyNotice = "En cumplimiento del Reglamento General de Protección de Datos en relación a los datos de carácter personal que haya proporcionado o pueda proporcionar a Aparcamiento Las Delicias Malaga, S.L. o a su personal, le informamos que el responsable del tratamiento es Aparcamiento Las Delicias Malaga, S.L., con domicilio en Calle Don Rodrigo 3, 29008, Málaga, España. Las finalidades del tratamiento de los datos pueden ser, según los casos, la gestión de reservas y clientes y la gestión de derechos y obligaciones del RGPD. Si necesita más información sobre el tratamiento de datos de carácter personal, puede solicitárnosla escribiéndonos a oficina@parkinglasdelicias.com. Como interesado, tiene derecho a acceder, rectificar y suprimir los datos, solicitar su portabilidad y, si procede, oponerse al tratamiento y solicitar su limitación. Puede ejercer estos derechos por correo electrónico en oficina@parkinglasdelicias.com.";
const escapeMailHtml = (value: string) => value.replace(/[&<>"']/g, char =>
  ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[char]!));

function officialMailLink(value: string | undefined) {
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password ? url.href : null;
  } catch {
    return null;
  }
}

const locales = {es:"es-ES",en:"en-GB",fr:"fr-FR",it:"it-IT",de:"de-DE"} as const;
type BookingLanguage = keyof typeof locales;
function bookingLanguage(value: unknown): BookingLanguage {
  return typeof value === "string" && Object.hasOwn(locales,value) ? value as BookingLanguage : "es";
}

const spanishLabels = {
  title:"Reserva confirmada", voucher:"Comprobante de reserva", thanks:"Gracias por reservar con Parking Las Delicias.",
  ref:"Número de reserva", date:"Fecha de reserva", dates:"Fechas de la reserva", in:"Entrada", out:"Salida",
  summary:"Resumen de la estancia", duration:"Duración", space:"Plaza reservada", total:"Importe total",
  details:"Datos de la reserva", holder:"Titular", car:"Vehículo", name:"Nombre", email:"Correo",
  phone:"Teléfono", model:"Marca / modelo", plate:"Matrícula", one:"día", many:"días", standard:"Estándar",
  terms:"Condiciones de la reserva", general:"Condiciones generales", privacy:"Política de privacidad",
  confidentiality:"Aviso de confidencialidad", data:"Aviso de protección de datos de carácter personal", country:"España",
  termsText:"Puede consultar todas las condiciones de su reserva en el siguiente enlace",
  privacyText:"Puede consultar nuestra política de privacidad aquí",
  ask:"Puede solicitar más información en",
  confidentialText:confidentiality, privacyNoticeText:privacyNotice,
};
const labels: Record<BookingLanguage, typeof spanishLabels> = {
  es:spanishLabels,
  en:{
    title:"Booking confirmed",voucher:"Booking voucher",thanks:"Thank you for booking with Parking Las Delicias.",
    ref:"Booking number",date:"Booking date",dates:"Booking dates",in:"Entry",out:"Exit",
    summary:"Stay summary",duration:"Duration",space:"Reserved space",total:"Total amount",details:"Booking details",
    holder:"Booking holder",car:"Vehicle",name:"Name",email:"Email",phone:"Phone",model:"Make / model",plate:"Registration number",
    one:"day",many:"days",standard:"Standard",terms:"Booking terms",general:"General terms and conditions",privacy:"Privacy policy",
    confidentiality:"Confidentiality notice",data:"Personal data protection notice",country:"Spain",
    termsText:"You can find all your booking terms at the following link",privacyText:"Read our privacy policy here",ask:"You can request more information at",
    confidentialText:"This email and any attachments are confidential and intended solely for the addressee. Disclosure, copying or distribution to third parties requires the sender’s prior written consent. If you received this message in error, please forward it to the sender immediately.",
    privacyNoticeText:"Aparcamiento Las Delicias Malaga, S.L., Calle Don Rodrigo 3, 29008 Málaga, Spain, is the controller of your personal data. It processes the data to manage reservations and customers and to handle GDPR rights and obligations. You may request information or exercise your rights of access, rectification, erasure, portability, objection or restriction, where applicable, by contacting oficina@parkinglasdelicias.com.",
  },
  fr:{
    title:"Réservation confirmée",voucher:"Bon de réservation",thanks:"Merci d’avoir réservé auprès de Parking Las Delicias.",
    ref:"Numéro de réservation",date:"Date de réservation",dates:"Dates de réservation",in:"Entrée",out:"Sortie",
    summary:"Récapitulatif du séjour",duration:"Durée",space:"Place réservée",total:"Montant total",details:"Détails de la réservation",
    holder:"Titulaire",car:"Véhicule",name:"Nom",email:"E-mail",phone:"Téléphone",model:"Marque / modèle",plate:"Immatriculation",
    one:"jour",many:"jours",standard:"Standard",terms:"Conditions de réservation",general:"Conditions générales",privacy:"Politique de confidentialité",
    confidentiality:"Avis de confidentialité",data:"Avis relatif à la protection des données personnelles",country:"Espagne",
    termsText:"Vous pouvez consulter toutes les conditions de votre réservation via ce lien",privacyText:"Consultez notre politique de confidentialité ici",ask:"Pour plus d’informations, écrivez à",
    confidentialText:"Ce courriel et ses éventuelles pièces jointes sont confidentiels et destinés exclusivement à leurs destinataires. Toute divulgation, copie ou distribution à des tiers requiert l’autorisation écrite préalable de l’expéditeur. Si vous avez reçu ce message par erreur, veuillez le transférer immédiatement à l’expéditeur.",
    privacyNoticeText:"Aparcamiento Las Delicias Malaga, S.L., Calle Don Rodrigo 3, 29008 Málaga, Espagne, est responsable du traitement de vos données personnelles. Elles sont traitées pour gérer les réservations et les clients, ainsi que les droits et obligations prévus par le RGPD. Pour obtenir des informations ou exercer vos droits d’accès, de rectification, d’effacement, de portabilité, d’opposition ou de limitation, selon le cas, écrivez à oficina@parkinglasdelicias.com.",
  },
  it:{
    title:"Prenotazione confermata",voucher:"Voucher di prenotazione",thanks:"Grazie per aver prenotato con Parking Las Delicias.",
    ref:"Numero di prenotazione",date:"Data della prenotazione",dates:"Date della prenotazione",in:"Ingresso",out:"Uscita",
    summary:"Riepilogo della sosta",duration:"Durata",space:"Posto prenotato",total:"Importo totale",details:"Dettagli della prenotazione",
    holder:"Intestatario",car:"Veicolo",name:"Nome",email:"E-mail",phone:"Telefono",model:"Marca / modello",plate:"Targa",
    one:"giorno",many:"giorni",standard:"Standard",terms:"Condizioni di prenotazione",general:"Condizioni generali",privacy:"Informativa sulla privacy",
    confidentiality:"Avviso di riservatezza",data:"Informativa sulla protezione dei dati personali",country:"Spagna",
    termsText:"Può consultare tutte le condizioni della prenotazione al seguente link",privacyText:"Può consultare qui la nostra informativa sulla privacy",ask:"Per maggiori informazioni, scriva a",
    confidentialText:"Questa e-mail e gli eventuali allegati sono riservati e destinati esclusivamente ai destinatari. La divulgazione, la copia o la distribuzione a terzi richiede il previo consenso scritto del mittente. Se ha ricevuto il messaggio per errore, lo inoltri immediatamente al mittente.",
    privacyNoticeText:"Aparcamiento Las Delicias Malaga, S.L., Calle Don Rodrigo 3, 29008 Málaga, Spagna, è il titolare del trattamento dei dati personali. I dati sono trattati per gestire prenotazioni e clienti e per adempiere ai diritti e agli obblighi previsti dal GDPR. Per informazioni o per esercitare, ove applicabili, i diritti di accesso, rettifica, cancellazione, portabilità, opposizione o limitazione del trattamento, scriva a oficina@parkinglasdelicias.com.",
  },
  de:{
    title:"Buchung bestätigt",voucher:"Buchungsbeleg",thanks:"Vielen Dank für Ihre Buchung bei Parking Las Delicias.",
    ref:"Buchungsnummer",date:"Buchungsdatum",dates:"Buchungszeitraum",in:"Einfahrt",out:"Ausfahrt",
    summary:"Übersicht zur Parkdauer",duration:"Dauer",space:"Reservierter Stellplatz",total:"Gesamtbetrag",details:"Buchungsdetails",
    holder:"Buchungsinhaber",car:"Fahrzeug",name:"Name",email:"E-Mail",phone:"Telefon",model:"Marke / Modell",plate:"Kennzeichen",
    one:"Tag",many:"Tage",standard:"Standard",terms:"Buchungsbedingungen",general:"Allgemeine Bedingungen",privacy:"Datenschutzerklärung",
    confidentiality:"Vertraulichkeitshinweis",data:"Hinweis zum Schutz personenbezogener Daten",country:"Spanien",
    termsText:"Alle Buchungsbedingungen finden Sie unter folgendem Link",privacyText:"Unsere Datenschutzerklärung finden Sie hier",ask:"Weitere Informationen erhalten Sie unter",
    confidentialText:"Diese E-Mail und etwaige Anhänge sind vertraulich und ausschließlich für die Empfänger bestimmt. Eine Offenlegung, Vervielfältigung oder Weitergabe an Dritte bedarf der vorherigen schriftlichen Genehmigung des Absenders. Falls Sie diese Nachricht irrtümlich erhalten haben, leiten Sie sie bitte umgehend an den Absender zurück.",
    privacyNoticeText:"Aparcamiento Las Delicias Malaga, S.L., Calle Don Rodrigo 3, 29008 Málaga, Spanien, ist für die Verarbeitung Ihrer personenbezogenen Daten verantwortlich. Die Daten werden zur Verwaltung von Buchungen und Kunden sowie zur Wahrnehmung von Rechten und Pflichten nach der DSGVO verarbeitet. Für Auskünfte und zur Ausübung Ihrer Rechte auf Auskunft, Berichtigung, Löschung, Datenübertragbarkeit, Widerspruch oder Einschränkung der Verarbeitung wenden Sie sich gegebenenfalls an oficina@parkinglasdelicias.com.",
  },
};

function voucherContent(row: VoucherBooking, language: BookingLanguage) {
  const copy = labels[language];
  const locale = locales[language];
  const date = (value: string, options: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat(locale,{timeZone:"Europe/Madrid",...options}).format(new Date(value));
  const arrival = date(row.entry_at,{dateStyle:"medium",timeStyle:"short"});
  const departure = date(row.exit_at,{dateStyle:"medium",timeStyle:"short"});
  const cost = new Intl.NumberFormat(locale,{style:"currency",currency:"EUR"}).format(Number(row.amount_eur));
  const duration = row.duration_days + " " + (row.duration_days === 1 ? copy.one : copy.many);
  const spaceCode = row.vehicle_type?.code ?? "";
  const space = spaceCode === "MOTO" ? (language === "en" ? "Motorcycle" : language === "de" ? "Motorrad" : "Moto") : spaceCode === "TURISMO" ? copy.standard : spaceCode || "—";
  const holder = [[copy.name,row.customer_name],[copy.email,row.customer_email],[copy.phone,row.customer_phone ?? "—"]];
  const vehicle = [[copy.model,row.vehicle_make_model],[copy.plate,row.plate]]
    .filter((field): field is [string,string] => Boolean(field[1]?.trim()));
  return {copy,date,arrival,departure,cost,duration,space,holder,vehicle};
}

async function voucherPdf(row: VoucherBooking, language: BookingLanguage) {
  const {copy,date,cost,duration,space,holder,vehicle} = voucherContent(row,language);
  const pdf = await PDFDocument.create();
  pdf.setCreationDate(new Date(row.created_at));
  pdf.setModificationDate(new Date(row.created_at));
  pdf.setLanguage(language);
  pdf.setTitle(copy.voucher + " " + row.reference);
  const page = pdf.addPage([595,842]);
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const navy = rgb(.052,.11,.26), dark = rgb(.078,.16,.23), muted = rgb(.38,.45,.55);
  const green = rgb(.04,.46,.32), paleGreen = rgb(.906,.955,.932), pale = rgb(.94,.955,.974), line = rgb(.83,.87,.93);
  const printable = (value: string) => Array.from(value.normalize("NFC"),char => {
    if (/\s/.test(char)) return " ";
    try { regular.encodeText(char); return char; } catch { return "?"; }
  }).join("");
  function draw(value: string,x: number,y: number,size: number,font=regular,color=dark,max=510) {
    const text = printable(value);
    const fitted = Math.min(size, size*max/Math.max(1,font.widthOfTextAtSize(text,size)));
    page.drawText(text,{x,y,size:fitted,font,color});
  }
  const label = (value: string,x: number,y: number) => draw(value.toLocaleUpperCase(language),x,y,8.3,bold,muted);
  const rule = (y: number) => page.drawLine({start:{x:44,y},end:{x:551,y},color:line,thickness:.65});
  function card(x: number,y: number,w: number,h: number,color: ReturnType<typeof rgb>,border=false) {
    const r = 12;
    const path = `M0,${r} Q0,0 ${r},0 H${w-r} Q${w},0 ${w},${r} V${h-r} Q${w},${h} ${w-r},${h} H${r} Q0,${h} 0,${h-r} Z`;
    page.drawSvgPath(path,{x,y:y+h,color,borderColor:border ? line : undefined,borderWidth:border ? .8 : undefined});
  }
  const imageBytes = await fetch(logoUrl,{signal:AbortSignal.timeout(5000)}).then(r=>r.ok?r.arrayBuffer():null).catch(()=>null);
  if (imageBytes) {
    const logo = await pdf.embedPng(imageBytes);
    const dim = logo.scaleToFit(188,58);
    page.drawImage(logo,{x:44,y:737,width:dim.width,height:dim.height});
  } else {
    draw("Parking Las Delicias",44,760,19,bold,navy);
  }
  label(copy.voucher,405,777);
  draw(date(row.created_at,{dateStyle:"long"}),405,758,9,regular,dark,145);
  rule(720);
  card(44,629,507,76,paleGreen);
  page.drawCircle({x:74,y:676,size:14,color:green});
  page.drawLine({start:{x:70,y:676},end:{x:73,y:672},color:rgb(1,1,1),thickness:1.4});
  page.drawLine({start:{x:73,y:672},end:{x:79,y:680},color:rgb(1,1,1),thickness:1.4});
  draw(copy.title,101,677,20,bold,green);
  draw(copy.thanks,101,654,10);
  label(copy.ref,44,600);
  draw(row.reference,44,575,22,bold,navy);
  rule(559);
  draw(copy.dates.toLocaleUpperCase(language),44,537,9.2,bold,navy);
  for (const [title,value,x] of [[copy.in,row.entry_at,44],[copy.out,row.exit_at,305]] as const) {
    card(x,430,246,92,pale);
    label(title,x+15,500);
    draw(date(value,{weekday:"short",day:"numeric",month:"long",year:"numeric"}),x+15,474,12,bold,dark,215);
    draw(date(value,{hour:"2-digit",minute:"2-digit",hourCycle:"h23"}),x+15,451,17,bold,navy);
  }
  draw(copy.summary.toLocaleUpperCase(language),44,407,9.2,bold,navy);
  card(44,303,507,89,rgb(1,1,1),true);
  const cells = [[copy.duration,duration,59,navy],[copy.space,space,228,navy],[copy.total,cost,397,green]] as const;
  for (const [title,value,x,color] of cells) { label(title,x,364); draw(value,x,329,16,bold,color,147); }
  for (const x of [213,382]) page.drawLine({start:{x,y:318},end:{x,y:377},color:line,thickness:.65});
  draw(copy.details.toLocaleUpperCase(language),44,273,9.2,bold,navy);
  card(44,129,507,128,pale);
  for (const [title,fields,x] of [[copy.holder,holder,61],[copy.car,vehicle,303]] as const) {
    if (fields.length === 0) continue;
    label(title,x,238);
    fields.forEach(([name,value],i)=>{
      draw(name,x,215-29*i,8,regular,muted);
      draw(value,x,201-29*i,10.5,bold,dark,vehicle.length ? 225 : 470);
    });
  }
  rule(87);
  draw("PARKING LAS DELICIAS",44,70,9,bold,navy);
  draw("Calle Don Rodrigo 3 · 29008 Málaga ("+copy.country+")",44,55,8.5,regular,muted);
  draw("+34 952 212 478 · "+office,44,43,8.5,regular,muted);
  return pdf.saveAsBase64();
}

function voucherEmail(row: VoucherBooking, language: BookingLanguage) {
  const {copy,date,arrival,departure,cost,duration,space,holder,vehicle} = voucherContent(row,language);
  const terms = officialMailLink(Deno.env.get("PARKING_BOOKING_TERMS_URL") ?? site+"condiciones-generales.html");
  const privacy = officialMailLink(Deno.env.get("PARKING_PRIVACY_POLICY_URL") ?? site+"politica-de-privacidad.html");
  const sections = [
    {title:copy.ref,fields:[[copy.ref,row.reference],[copy.date,date(row.created_at,{dateStyle:"long"})]]},
    {title:copy.dates,fields:[[copy.in,arrival],[copy.out,departure]]},
    {title:copy.summary,fields:[[copy.duration,duration],[copy.space,space],[copy.total,cost]]},
    {title:copy.holder,fields:holder},
    ...(vehicle.length ? [{title:copy.car,fields:vehicle}] : []),
  ];
  const contact = ["Calle Don Rodrigo 3","29008, Málaga ("+copy.country+")","+34 952 212 478",office];
  const ask = copy.ask + " " + office + ".";
  const mailto = '<a href="mailto:'+office+'">'+office+'</a>';
  const text = [copy.title,copy.thanks,
    ...sections.map(({title,fields}) => [title,...fields.map(([key,value])=>key+": "+value)].join("\n")),
    "Parking Las Delicias\n"+contact.join("\n"),
    copy.terms+"\n"+(terms ? copy.termsText+": "+copy.general+" ("+terms+")" : ask),
    copy.confidentiality+"\n"+copy.confidentialText,
    copy.data+"\n"+copy.privacyNoticeText+"\n"+(privacy ? copy.privacyText+": "+privacy : ask),
  ].join("\n\n");
  const img = '<img src="cid:parking-las-delicias-logo" width="180" alt="Parking Las Delicias" style="display:block;max-width:100%;height:auto">';
  const link = (url: string|null,intro: string,title: string) => url
    ? intro+': <a href="'+escapeMailHtml(url)+'">'+title+'</a>' : copy.ask+' '+mailto+'.';
  const html = `<!doctype html><html lang="${language}"><body style="margin:0;background:#eef3f7;color:#153047;font-family:Arial,sans-serif">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:20px 12px">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:620px;background:white;border:1px solid #d7e1ea">
  <tr><td style="padding:28px;line-height:1.55">${img}<h1 style="color:#118257;font-size:26px">${copy.title}</h1><p>${copy.thanks}</p>
  ${sections.map(({title,fields})=>`<h2 style="font-size:17px;border-bottom:1px solid #d7e1ea">${title}</h2><div>${fields.map(([key,value])=>'<strong>'+key+':</strong> '+escapeMailHtml(value)).join('<br>')}</div>`).join('')}
  </td></tr><tr><td style="padding:24px 28px;background:#f6f8fb;border-top:1px solid #d7e1ea;line-height:1.55;font-size:13px">${img}
  <p>${contact.slice(0,2).join('<br>')}<br><a href="tel:+34952212478">${contact[2]}</a><br>${mailto}</p>
  <h2 style="font-size:15px">${copy.terms}</h2><p>${link(terms,copy.termsText,copy.general)}</p>
  <h2 style="font-size:15px">${copy.confidentiality}</h2><p>${copy.confidentialText}</p>
  <h2 style="font-size:15px">${copy.data}</h2><p>${copy.privacyNoticeText.replaceAll(office,mailto)} ${link(privacy,copy.privacyText,copy.privacy)}</p>
  </td></tr></table></td></tr></table></body></html>`;
  return {text,html};
}

function voucherMessage(row: VoucherBooking, to: string, language: BookingLanguage, pdf: string, prefix = "") {
  return {
    from:"Parking Las Delicias <"+office+">", to:[to], reply_to:office,
    subject:prefix + labels[language].title + " " + row.reference + " · Parking Las Delicias",
    ...voucherEmail(row,language),
    attachments:[
      {filename:"Parking-Las-Delicias-"+row.reference+"-"+language+".pdf",content:pdf,content_type:"application/pdf"},
      {filename:"logo-las-delicias.png",path:logoUrl,content_id:"parking-las-delicias-logo",content_type:"image/png"},
    ],
  };
}

async function sendVouchers(db: BookingDb, row: VoucherBooking, customerPdf?: string) {
  const apiKey = Deno.env.get("INVOICE_RESEND_API_KEY");
  const customerLanguage = bookingLanguage(row.booking_language);
  const deliveries = [
    {column:"web_voucher_customer_message_id",to:row.customer_email,kind:"customer",language:customerLanguage},
    {column:"web_voucher_office_message_id",to:office,kind:"office",language:"es"},
  ] as const;
  const pending = deliveries.filter(item => !row[item.column]);
  if (!pending.length) return;
  const pdfs = new Map<BookingLanguage,Promise<string>>();
  if (customerPdf) pdfs.set(customerLanguage, Promise.resolve(customerPdf));
  const results = await Promise.allSettled(pending.map(async item => {
    if (!apiKey || !item.to) throw new Error("Correo de reserva sin configurar: " + item.kind);
    let pdf = pdfs.get(item.language);
    if (!pdf) {
      pdf = voucherPdf(row,item.language);
      pdfs.set(item.language,pdf);
    }
    const message = voucherMessage(row,item.to,item.language,await pdf);
    const response = await fetch("https://api.resend.com/emails", {
      method:"POST", signal:AbortSignal.timeout(7000),
      headers:{Authorization:"Bearer " + apiKey,"Content-Type":"application/json",
        "Idempotency-Key":"parking-voucher-" + row.id + "-" + item.kind},
      body:JSON.stringify(message),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok || !result.id) throw new Error("Resend justificante " + item.kind + " HTTP " + response.status);
    const {error} = await db.from("reservations").update({[item.column]:result.id}).eq("id", row.id).is(item.column,null);
    if (error) throw new Error("No se pudo registrar el envío del justificante: " + item.kind);
  }));
  for (const result of results) {
    if (result.status === "rejected") throw result.reason;
  }
}

function sendVouchersInBackground(db: BookingDb, row: VoucherBooking, pdf: string) {
  const task = sendVouchers(db,row,pdf).catch(error => console.error("Parking justificante:",error.message));
  const runtime = (globalThis as typeof globalThis & {EdgeRuntime?: {waitUntil(task:Promise<void>):void}}).EdgeRuntime;
  runtime?.waitUntil(task);
}

Deno.serve(async req => {
  const key = Deno.env.get("PARKING_STRIPE_SECRET_KEY");
  const signingSecret = Deno.env.get("PARKING_STRIPE_WEBHOOK_SECRET");
  const ready = Boolean(key && /^(?:rk|sk)_live_/.test(key) && signingSecret?.startsWith("whsec_") &&
    Deno.env.get("PARKING_WEB_PAYMENTS_ENABLED") === "true");
  if (req.method === "OPTIONS") return new Response(null, {headers:cors});
  if (req.method === "GET") return json({ready});
  if (req.method !== "POST") return json({error:"Método no permitido"}, 405);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    {auth:{persistSession:false}});

  try {
    const signature = req.headers.get("stripe-signature");
    if (signature) {
      const raw = await req.text();
      if (!signingSecret || !await validSignature(raw, signature, signingSecret)) return json({error:"Firma no válida"}, 400);
      const event = JSON.parse(raw);
      const session = event.data?.object;
      const hold = session?.metadata?.parking_reservation;
      if (!event.livemode || !hold || !session.id?.startsWith("cs_live_")) return json({received:true});
      if (event.type === "checkout.session.expired") {
        const {error} = await db.from("reservations").update({status:"expired",payment_status:"failed"})
          .eq("id", hold).eq("stripe_checkout_session_id", session.id).eq("status","pending_payment");
        if (error) throw error;
        return json({received:true});
      }
      if (!["checkout.session.completed","checkout.session.async_payment_succeeded"].includes(event.type) ||
          session.payment_status !== "paid") return json({received:true});
      const row = await findBooking(db, session.id);
      const confirmed = row && await confirmPayment(db, row, session);
      if (!confirmed) return json({error:"Pago sin correspondencia o reserva requiere revisión"},409);
      if (!confirmed.web_voucher_customer_message_id || !confirmed.web_voucher_office_message_id) {
        await sendVouchers(db,confirmed);
      }
      return json({received:true});
    }

    const body = await req.json();
    if (body.action === "status") {
      if (typeof body.sessionId !== "string" || !/^cs_live_[A-Za-z0-9]+$/.test(body.sessionId)) return json({error:"Sesión no válida"},400);
      let row = await findBooking(db, body.sessionId);
      if (!row) return json({paid:false});
      if (row.status === "pending_payment" && row.payment_status === "pending" && key) {
        const session = await stripe("checkout/sessions/" + body.sessionId,key);
        if (session.id !== body.sessionId) return json({paid:false});
        row = await confirmPayment(db,row,session);
      }
      if (!row || row.payment_status !== "paid") return json({paid:false});
      const pdf = await voucherPdf(row,bookingLanguage(row.booking_language));
      sendVouchersInBackground(db,row,pdf);
      return json({paid:true,reference:row.reference,voucher:voucherDetails(row),pdf});
    }
    if (!ready || !key) return json({error:"El pago online todavía no está disponible. No se ha creado ninguna reserva."},503);
    const language = bookingLanguage(body.language);
    const vehicle = String(body.vehicleType || "").toUpperCase();
    const days = Number(body.durationDays);
    const entry = new Date(String(body.entryAt || ""));
    const requestedExitAt = String(body.exitAt || "");
    const checkout = new Date(requestedExitAt);
    const billableDays = Number(body.billableDays || days);
    const localDate = (value: Date) => {
      const parts = new Intl.DateTimeFormat("en-CA", {timeZone:"Europe/Madrid",year:"numeric",month:"2-digit",day:"2-digit"}).formatToParts(value);
      return parts.find(part => part.type === "year")!.value + "-" +
        parts.find(part => part.type === "month")!.value + "-" + parts.find(part => part.type === "day")!.value;
    };
    const autoExit = new Date(entry.getTime() + days * 86400000);
    const name = String(body.customerName || "").trim();
    const email = String(body.customerEmail || "").trim().toLowerCase();
    const phone = String(body.customerPhone || "").trim();
    const plate = String(body.plate || "").trim().toUpperCase();
    const model = String(body.vehicleMakeModel || "").trim();
    if (!categories.includes(vehicle) || !Number.isInteger(days) || days < 1 || days > 24 ||
        !Number.isInteger(billableDays) || billableDays < days || billableDays > 24 ||
        !Number.isFinite(entry.getTime()) || entry.getTime() <= Date.now() || entry.getTime() % 900000 !== 0 ||
        !Number.isFinite(checkout.getTime()) || checkout <= entry || checkout.getTime() % 900000 !== 0 ||
        localDate(checkout) !== localDate(autoExit) ||
        Math.max(days, Math.ceil((checkout.getTime() - entry.getTime()) / 86400000)) !== billableDays ||
        name.length < 2 || name.length > 120 || phone.length < 5 || phone.length > 30 ||
        email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
        (plate.length > 0 && plate.length < 3) || plate.length > 16 || model.length > 120) {
      return json({error:"Revisa los datos de la reserva y la fecha de salida."},400);
    }
    const entryAt = entry.toISOString();
    const exitAt = checkout.toISOString();
    const {data:quote,error:quoteError} = await db.rpc("quote_public_parking_checkout",{
      p_vehicle_type_code:vehicle,p_entry_at:entryAt,p_billable_days:billableDays,p_exit_at:exitAt,
    });
    if (quoteError) throw quoteError;
    if (!quote?.[0] || quote[0].available_spaces < 1) return json({error:"No hay plazas disponibles."},409);
    const price = Number(quote[0].price_eur);
    const cents = Math.round(price*100);
    if (!Number.isSafeInteger(cents) || cents < 1) throw new Error("Tarifa no disponible");
    if (cents !== Math.round(Number(body.expectedPriceEur)*100)) return json({error:"El precio ha cambiado. Consulta de nuevo la disponibilidad."},409);
    const {data:vt,error:typeError} = await db.from("vehicle_types").select("id").eq("code",vehicle).eq("active",true).single();
    if (typeError) throw typeError;

    const expires = Math.floor(Date.now()/1000) + 31*60;
    const {data:hold,error:holdError} = await db.from("reservations").insert({
      vehicle_type_id:vt.id,entry_at:entryAt,exit_at:exitAt,duration_days:billableDays,customer_name:name,customer_email:email,
      customer_phone:phone,plate:plate||null,vehicle_make_model:model||null,source:"web",status:"pending_payment",booking_language:language,
      payment_status:"pending",manual_price_override:true,amount_eur:price,
      expires_at:new Date((expires+15*60)*1000).toISOString(),
    }).select("id").single();
    if (holdError) {
      if (/plaza.*(disponible|ocupada)/i.test(holdError.message)) return json({error:"No hay plazas disponibles."},409);
      throw holdError;
    }

    let session;
    try {
      const params = new URLSearchParams({
        mode:"payment", locale:language, "customer_email":email,
        "line_items[0][price_data][currency]":"eur","line_items[0][price_data][unit_amount]":String(cents),
        "line_items[0][price_data][product_data][name]":"Parking Las Delicias · "+vehicle+" · "+billableDays+" día(s)",
        "line_items[0][quantity]":"1","metadata[parking_reservation]":hold.id,expires_at:String(expires),
        success_url:site+"?pago={CHECKOUT_SESSION_ID}",cancel_url:site+"?pago=cancelado",
      });
      session = await stripe("checkout/sessions",key,params,"parking-"+hold.id);
      if (!session.livemode || !session.url || !session.id?.startsWith("cs_live_")) throw new Error("Sesión de pago no válida");
      const {error} = await db.from("reservations").update({stripe_checkout_session_id:session.id,
        tariff_amount_eur:price}).eq("id",hold.id).eq("status","pending_payment").select("id").single();
      if (error) throw error;
      return json({checkoutUrl:session.url});
    } catch (error) {
      if (session?.id) await stripe("checkout/sessions/"+session.id+"/expire",key,new URLSearchParams()).catch(console.error);
      await db.from("reservations").update({status:"cancelled",payment_status:"failed"}).eq("id",hold.id).eq("status","pending_payment");
      throw error;
    }
  } catch (error) {
    console.error("Parking checkout:", error instanceof Error ? error.message : "Error de operación");
    return json({error:"No se pudo completar la operación. Si ya pagaste, contacta con el Parking antes de intentarlo otra vez."},500);
  }
});
