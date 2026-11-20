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
const voucherFields = "id,reference,amount_eur,entry_at,exit_at,customer_name,customer_email,plate,status,payment_status,stripe_payment_intent_id,web_voucher_customer_message_id,web_voucher_office_message_id";
type VoucherBooking = {
  id: string;
  reference: string;
  amount_eur: number | string;
  entry_at: string;
  exit_at: string;
  customer_name: string;
  customer_email: string;
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
  return data as VoucherBooking | null;
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
  const details = voucherDetails(row);
  const pdf = await PDFDocument.create();
  pdf.setCreationDate(new Date(row.entry_at));
  pdf.setModificationDate(new Date(row.entry_at));
  const page = pdf.addPage([595, 420]);
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const navy = rgb(.07, .19, .28);
  const green = rgb(.05, .43, .27);
  const png = await fetch(site + "backoffice/assets/logo-las-delicias.png", {signal:AbortSignal.timeout(5000)})
    .then(response => response.ok ? response.arrayBuffer() : null).catch(() => null);
  if (png) {
    const logo = await pdf.embedPng(png);
    const size = logo.scaleToFit(190, 55);
    page.drawImage(logo, {x:42,y:343,width:size.width,height:size.height});
  }
  const printable = (value: string) => Array.from(value.normalize("NFC"), char => {
    try { regular.encodeText(char); return char; } catch { return "?"; }
  }).join("");
  page.drawText("Justificante de reserva", {x:42,y:305,size:24,font:bold,color:navy});
  page.drawText("Reserva confirmada · " + details.reference, {x:42,y:273,size:16,font:bold,color:green});
  const lines = [
    "Titular: " + details.name, "Entrada: " + details.entry, "Salida prevista: " + details.exit,
    ...(details.plate ? ["Matrícula: " + details.plate] : []), "Importe pagado: " + details.amount,
    "Parking Las Delicias · C. Don Rodrigo, 3 · Málaga",
    "Presenta este justificante al llegar al parking.",
  ];
  for (const [index, line] of lines.entries()) {
    page.drawText(printable(line), {x:42,y:237-index*25,size:12,font:regular,color:navy,lineHeight:14,maxWidth:510});
  }
  return pdf.saveAsBase64();
}

async function sendVouchers(db: BookingDb, row: VoucherBooking, pdf: string) {
  const apiKey = Deno.env.get("INVOICE_RESEND_API_KEY");
  const deliveries = [
    {column:"web_voucher_customer_message_id",to:row.customer_email,kind:"customer"},
    {column:"web_voucher_office_message_id",to:office,kind:"office"},
  ] as const;
  const results = await Promise.allSettled(deliveries.filter(item => !row[item.column]).map(async item => {
    if (!apiKey || !item.to) throw new Error("Correo de reserva sin configurar: " + item.kind);
    const response = await fetch("https://api.resend.com/emails", {
      method:"POST", signal:AbortSignal.timeout(7000),
      headers:{Authorization:"Bearer " + apiKey,"Content-Type":"application/json",
        "Idempotency-Key":"parking-voucher-" + row.id + "-" + item.kind},
      body:JSON.stringify({
        from:"Parking Las Delicias <" + office + ">", to:[item.to], reply_to:office,
        subject:"Reserva confirmada " + row.reference + " · Parking Las Delicias",
        text:"Reserva " + row.reference + " confirmada para " + row.customer_name + ".\nEntrada: " +
          bookingDate.format(new Date(row.entry_at)) + "\nSalida prevista: " + bookingDate.format(new Date(row.exit_at)) +
          "\nImporte pagado: " + bookingAmount.format(Number(row.amount_eur)) + "\n\nAdjuntamos el justificante de la reserva.",
        attachments:[{filename:"Reserva-" + row.reference + ".pdf",content:pdf}],
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
