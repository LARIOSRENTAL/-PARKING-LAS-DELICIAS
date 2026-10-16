import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json; charset=utf-8" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  try {
    const body = await req.json();
    const vehicleType = String(body.vehicleType || "").toUpperCase();
    const entryAt = String(body.entryAt || "");
    const durationDays = Number(body.durationDays);
    if (!["MOTO", "TURISMO", "XL", "XXL"].includes(vehicleType)) return json({ error: "Tipo de vehículo no válido" }, 400);
    if (!Number.isInteger(durationDays) || durationDays < 1 || durationDays > 24) return json({ error: "La estancia debe ser de 1 a 24 días" }, 400);
    if (!entryAt || Number.isNaN(Date.parse(entryAt))) return json({ error: "Fecha de entrada no válida" }, 400);
    const entryDate = new Date(entryAt);
    if (entryDate.getUTCMinutes() % 15 !== 0 || entryDate.getUTCSeconds() !== 0) return json({ error: "La hora de entrada debe ser en intervalos de 15 minutos" }, 400);

    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data, error } = await db.rpc("quote_public_parking", {
      p_vehicle_type_code: vehicleType,
      p_entry_at: entryAt,
      p_duration_days: durationDays,
    });
    if (error) throw error;
    const q = data?.[0];
    if (!q) return json({ error: "No se pudo calcular la tarifa" }, 500);
    return json({
      vehicleType: q.vehicle_type,
      entryAt: q.entry_at,
      exitAt: q.exit_at,
      durationDays: q.duration_days,
      priceEur: Number(q.price_eur),
      availableSpaces: Number(q.available_spaces),
      available: Number(q.available_spaces) > 0,
    });
  } catch (e) {
    console.error(e);
    return json({ error: "No se pudo consultar la disponibilidad", detail: String(e?.message || e) }, 500);
  }
});