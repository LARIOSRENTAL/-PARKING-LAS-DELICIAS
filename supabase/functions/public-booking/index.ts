import {createClient} from "npm:@supabase/supabase-js@2.118.0";

import {PDFDocument, StandardFonts, rgb, breakTextIntoLines} from "npm:pdf-lib@1.17.1";

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
const voucherFields = "id,reference,amount_eur,created_at,entry_at,exit_at,duration_days,customer_name,customer_email,customer_phone,vehicle_make_model,plate,vehicle_type:vehicle_types(code),status,payment_status,stripe_payment_intent_id,web_voucher_customer_message_id,web_voucher_office_message_id";
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

async function voucherPdf(row: VoucherBooking) {
  const {heading,intro,sections} = voucherContent(row);
  const pdf = await PDFDocument.create();
  pdf.setCreationDate(new Date(row.entry_at));
  pdf.setModificationDate(new Date(row.entry_at));
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const navy = rgb(.07, .19, .28);
  const green = rgb(.05, .43, .27);
  const divider = rgb(.84, .88, .92);
  const width = 595;
  const height = 842;
  const margin = 44;
  const innerWidth = width - 2 * margin;
  let page = pdf.addPage([width,height]);
  let y = height - margin;
  const png = await fetch(logoUrl, {signal:AbortSignal.timeout(5000)})
    .then(response => response.ok ? response.arrayBuffer() : null).catch(() => null);
  if (png) {
    const logo = await pdf.embedPng(png);
    const size = logo.scaleToFit(190,55);
    page.drawImage(logo,{x:margin,y:y-size.height,width:size.width,height:size.height});
    y -= size.height + 28;
  }

  const printable = (value: string) => Array.from(value.normalize("NFC"), char => {
    try { regular.encodeText(char); return char; } catch { return "?"; }
  }).join("");

  const size = 11;
  const leading = 16;
  function wrap(value: string, available: number) {
    const measure = (line: string) => regular.widthOfTextAtSize(line,size);
    const lines = breakTextIntoLines(printable(value).replace(/\s+/g," "),[" ","@","-","."],available,measure);
    return lines.flatMap(line => {
      if (measure(line) <= available) return [line];
      const chunks: string[] = [];
      let chunk = "";
      for (const char of line) {
        if (measure(chunk+char) > available) {
          chunks.push(chunk);
          chunk = "";
        }
        chunk += char;
      }
      chunks.push(chunk);
      return chunks;
    });
  }

  page.drawText(heading,{x:margin,y:y-24,size:26,font:bold,color:green});
  y -= 49;
  for (const line of wrap(intro,innerWidth)) {
    page.drawText(line,{x:margin,y,size,font:regular,color:navy});
    y -= leading;
  }
  y -= 12;

  for (const {title,fields} of sections) {
    const labelWidth = 140;
    const rows = fields.map(([label,value]) => ({label,lines:wrap(value,innerWidth-(label ? labelWidth : 0))}));
    const sectionHeight = 38 + rows.reduce((total,row) => total + row.lines.length*leading + 2,0);
    if (y-sectionHeight < margin) {
      page = pdf.addPage([width,height]);
      y = height - margin;
    }
    page.drawText(title,{x:margin,y,size:14,font:bold,color:navy});
    page.drawLine({start:{x:margin,y:y-7},end:{x:width-margin,y:y-7},thickness:.8,color:divider});
    y -= 26;
    for (const {label,lines} of rows) {
      if (label) page.drawText(label + ":",{x:margin,y,size,font:bold,color:navy});
      for (const line of lines) {
        page.drawText(line,{x:margin+(label ? labelWidth : 0),y,size,font:regular,color:navy});
        y -= leading;
      }
      y -= 2;
    }
    y -= 12;
  }
  return pdf.saveAsBase64();
}

const logoUrl = site + "backoffice/assets/logo-las-delicias.png";
const vehicleLabels: Record<string, string> = {
  MOTO: "Moto", TURISMO: "Estándar", XL: "XL", XXL: "XXL",
};
const reservationDate = new Intl.DateTimeFormat("es-ES", {timeZone:"Europe/Madrid", dateStyle:"long"});
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

function voucherContent(row: VoucherBooking) {
  const heading = "Reserva confirmada";
  const details = voucherDetails(row);
  const intro = "Hola, " + details.name + ", tu reserva ha sido realizada correctamente, queda poco para que disfrutes de un servicio hecho a tu medida. Mientras tanto, aquí tienes los datos de tu reserva:";
  const vehicle = [
    ["Marca", row.vehicle_make_model],
    ["Matrícula", details.plate],
  ].filter((field): field is [string, string] => Boolean(field[1]?.trim()));
  const spaceCode = row.vehicle_type?.code;
  const space = spaceCode ? vehicleLabels[spaceCode] ?? spaceCode : "—";
  const sections = [
    {title:"Tu reserva", fields:[["Código de reserva",details.reference],["Fecha",reservationDate.format(new Date(row.created_at))]]},
    {title:"Información personal", fields:[["Nombre",details.name],["Correo electrónico",row.customer_email],["Teléfono",row.customer_phone ?? "—"]]},
    ...(vehicle.length ? [{title:"Vehículo",fields:vehicle}] : []),
    {title:"Entrada", fields:[["Fecha y hora",details.entry]]},
    {title:"Salida", fields:[["Fecha y hora",details.exit]]},
    {title:"Estancia", fields:[["",row.duration_days + (row.duration_days === 1 ? " día" : " días") + " - " + details.amount]]},
    {title:"Plaza reservada", fields:[["",space]]},
  ];
  return {heading,intro,sections};
}

function voucherEmail(row: VoucherBooking, links: {terms?: string; privacy?: string}) {
  const {heading,intro,sections} = voucherContent(row);
  const terms = officialMailLink(links.terms);
  const privacy = officialMailLink(links.privacy);
  const termsText = terms ? "Puede consultar todas las condiciones de su reserva en el siguiente enlace: Condiciones generales (" + terms + ")."
    : "Puede solicitar las condiciones generales de la reserva en " + office + ".";
  const privacyText = privacy ? "En la página web Política de privacidad (" + privacy + ") puede consultar nuestra política de privacidad."
    : "Puede solicitar nuestra política de privacidad en " + office + ".";
  const mailto = '<a href="mailto:' + office + '">' + office + '</a>';
  const termsHtml = terms ? 'Puede consultar todas las condiciones de su reserva en el siguiente enlace: <a href="' + escapeMailHtml(terms) + '">Condiciones generales</a>.'
    : 'Puede solicitar las condiciones generales de la reserva en ' + mailto + '.';
  const privacyHtml = privacy ? 'En la página web <a href="' + escapeMailHtml(privacy) + '">Política de privacidad</a> puede consultar nuestra política de privacidad.'
    : 'Puede solicitar nuestra política de privacidad en ' + mailto + '.';
  const contact = ["Calle Don Rodrigo 3","29008, Málaga (España)","+34 952 212 478",office];
  const text = [
    "Parking Las Delicias", heading, intro,
    ...sections.map(({title,fields}) => [title, ...fields.map(([label,value]) => label ? label + ": " + value : value)].join("\n")),
    "Parking Las Delicias\n" + contact.join("\n"), "Condiciones de la reserva\n" + termsText, "Aviso de confidencialidad\n" + confidentiality,
    "Aviso de protección de datos de carácter personal\n" + privacyNotice + "\n" + privacyText,
  ].join("\n\n");
  const html = `<!doctype html><html lang="es"><body style="margin:0;background:#eef3f7;color:#153047;font-family:Arial,sans-serif">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:20px 12px">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:620px;background:#ffffff;border:1px solid #d7e1ea;border-radius:12px">
<tr><td style="padding:28px;line-height:1.55">
<img src="cid:parking-las-delicias-logo" width="190" alt="Parking Las Delicias" style="display:block;max-width:100%;height:auto">
<h1 style="color:#118257;font-size:26px;margin:20px 0 12px">${heading}</h1>
<p>${escapeMailHtml(intro)}</p>
${sections.map(({title,fields}) => `<h2 style="font-size:17px;margin:20px 0 6px;border-bottom:1px solid #d7e1ea">${title}</h2>
<div>${fields.map(([label,value]) => label ? '<strong>' + label + ':</strong> ' + escapeMailHtml(value) : escapeMailHtml(value)).join('<br>')}</div>`).join('')}
</td></tr>
<tr><td style="padding:24px 28px;background:#f6f8fb;border-top:1px solid #d7e1ea;line-height:1.55">
<img src="cid:parking-las-delicias-logo" width="150" alt="Parking Las Delicias" style="display:block;max-width:100%;height:auto">
<p style="margin:12px 0 20px">${contact.slice(0,2).join('<br>')}<br><a href="tel:+34952212478">${contact[2]}</a><br>${mailto}</p>
<div style="font-size:13px">
<h2 style="font-size:15px">Condiciones de la reserva</h2><p>${termsHtml}</p>
<h2 style="font-size:15px">Aviso de confidencialidad</h2><p>${confidentiality}</p>
<h2 style="font-size:15px">Aviso de protección de datos de carácter personal</h2>
<p>${privacyNotice.replaceAll(office,mailto)} ${privacyHtml}</p>
</div></td></tr></table></td></tr></table></body></html>`;
  return {text,html};
}

async function sendVouchers(db: BookingDb, row: VoucherBooking, pdf: string) {
  const apiKey = Deno.env.get("INVOICE_RESEND_API_KEY");
  const deliveries = [
    {column:"web_voucher_customer_message_id",to:row.customer_email,kind:"customer"},
    {column:"web_voucher_office_message_id",to:office,kind:"office"},
  ] as const;
  const pending = deliveries.filter(item => !row[item.column]);
  if (!pending.length) return;
  const content = voucherEmail(row,{
    terms:Deno.env.get("PARKING_BOOKING_TERMS_URL"),
    privacy:Deno.env.get("PARKING_PRIVACY_POLICY_URL"),
  });
  const results = await Promise.allSettled(pending.map(async item => {
    if (!apiKey || !item.to) throw new Error("Correo de reserva sin configurar: " + item.kind);
    const response = await fetch("https://api.resend.com/emails", {
      method:"POST", signal:AbortSignal.timeout(7000),
      headers:{Authorization:"Bearer " + apiKey,"Content-Type":"application/json",
        "Idempotency-Key":"parking-voucher-" + row.id + "-" + item.kind},
      body:JSON.stringify({
        from:"Parking Las Delicias <" + office + ">", to:[item.to], reply_to:office,
        subject:"Reserva confirmada " + row.reference + " · Parking Las Delicias",
        ...content,
        attachments:[
          {filename:"Reserva-" + row.reference + ".pdf",content:pdf,content_type:"application/pdf"},
          {filename:"logo-las-delicias.png",path:logoUrl,content_id:"parking-las-delicias-logo",content_type:"image/png"},
        ],
      }),
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
        await sendVouchers(db,confirmed,await voucherPdf(confirmed));
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
      const pdf = await voucherPdf(row);
      sendVouchersInBackground(db,row,pdf);
      return json({paid:true,reference:row.reference,voucher:voucherDetails(row),pdf});
    }
    if (!ready || !key) return json({error:"El pago online todavía no está disponible. No se ha creado ninguna reserva."},503);
    const vehicle = String(body.vehicleType || "").toUpperCase();
    const days = Number(body.durationDays);
    const entry = new Date(String(body.entryAt || ""));
    const name = String(body.customerName || "").trim();
    const email = String(body.customerEmail || "").trim().toLowerCase();
    const phone = String(body.customerPhone || "").trim();
    const plate = String(body.plate || "").trim().toUpperCase();
    const model = String(body.vehicleMakeModel || "").trim();
    if (!categories.includes(vehicle) || !Number.isInteger(days) || days < 1 || days > 24 ||
        !Number.isFinite(entry.getTime()) || entry.getTime() <= Date.now() || entry.getTime() % 900000 !== 0 ||
        name.length < 2 || name.length > 120 || phone.length < 5 || phone.length > 30 ||
        email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
        (plate.length > 0 && plate.length < 3) || plate.length > 16 || model.length > 120) {
      return json({error:"Revisa los datos de la reserva y la fecha de entrada."},400);
    }
    const entryAt = entry.toISOString();
    const {data:quote,error:quoteError} = await db.rpc("quote_public_parking",{
      p_vehicle_type_code:vehicle,p_entry_at:entryAt,p_duration_days:days,
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
      vehicle_type_id:vt.id,entry_at:entryAt,duration_days:days,customer_name:name,customer_email:email,
      customer_phone:phone,plate:plate||null,vehicle_make_model:model||null,source:"web",status:"pending_payment",
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
        mode:"payment", locale:"es", "customer_email":email,
        "line_items[0][price_data][currency]":"eur","line_items[0][price_data][unit_amount]":String(cents),
        "line_items[0][price_data][product_data][name]":"Parking Las Delicias · "+vehicle+" · "+days+" día(s)",
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
