import {createClient} from "npm:@supabase/supabase-js@2.118.0";

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
  if (!response.ok) throw new Error("Stripe HTTP " + response.status);
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

Deno.serve(async req => {
  const key = Deno.env.get("PARKING_STRIPE_SECRET_KEY");
  const signingSecret = Deno.env.get("PARKING_STRIPE_WEBHOOK_SECRET");
  const ready = Boolean(key?.startsWith("sk_live_") && signingSecret?.startsWith("whsec_") &&
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
      if (event.type !== "checkout.session.completed" || session.payment_status !== "paid" ||
          session.mode !== "payment" || session.currency !== "eur" || typeof session.payment_intent !== "string") {
        return json({received:true});
      }
      const {data:row,error:readError} = await db.from("reservations")
        .select("amount_eur,status,payment_status,stripe_payment_intent_id")
        .eq("id",hold).eq("source","web").eq("stripe_checkout_session_id",session.id).maybeSingle();
      if (readError) throw readError;
      if (!row || Math.round(Number(row.amount_eur)*100) !== session.amount_total) return json({error:"Pago sin correspondencia"},409);
      if (row.payment_status === "paid" && row.stripe_payment_intent_id === session.payment_intent) return json({received:true});
      if (row.status !== "pending_payment") return json({error:"La reserva requiere revisión"},409);
      const {error} = await db.from("reservations").update({status:"confirmed",payment_status:"paid",
        payment_method:"online",stripe_payment_intent_id:session.payment_intent,expires_at:null})
        .eq("id",hold).eq("stripe_checkout_session_id",session.id).eq("status","pending_payment").eq("payment_status","pending");
      if (error) throw error;
      return json({received:true});
    }

    const body = await req.json();
    if (body.action === "status") {
      if (typeof body.sessionId !== "string" || !/^cs_live_[A-Za-z0-9]+$/.test(body.sessionId)) return json({error:"Sesión no válida"},400);
      const {data,error} = await db.from("reservations").select("reference,payment_status")
        .eq("source","web").eq("stripe_checkout_session_id",body.sessionId).maybeSingle();
      if (error) throw error;
      return data?.payment_status === "paid" ? json({paid:true,reference:data.reference}) : json({paid:false});
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
        mode:"payment", "payment_method_types[0]":"card", locale:"es", "customer_email":email,
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
