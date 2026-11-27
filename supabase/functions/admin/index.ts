import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

async function sha256(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const pick = (o: Record<string, unknown>, keys: string[]) =>
  Object.fromEntries(keys.filter((k) => k in o).map((k) => [k, o[k]]));

const PARTIDO_COLS = ["id", "fecha", "temporada", "rival", "lugar", "hora", "jornada", "competicion", "condicion", "gf", "gc", "fuente", "mvp_id", "mvpnt_id"];
const JUGADOR_COLS = ["id", "nombre", "nombre_ficha", "dorsal", "fijo", "activo", "en_ficha", "orden", "alias", "estado_defecto", "motivo_defecto", "posicion", "foto", "invitado", "icono"];
const RESP_COLS = ["partido_id", "jugador_id", "estado", "motivo", "cerveza", "motivo_cerveza"];
const MULTA_COLS = ["jugador_id", "partido_id", "concepto", "importe", "pagada"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  let body: { pin?: string; action?: string; payload?: Record<string, unknown> };
  try { body = await req.json(); } catch { return json({ error: "JSON inválido" }, 400); }

  const { data: cfg } = await db.from("admin_config").select("value").eq("key", "pin_hash").maybeSingle();
  if (!cfg || !body.pin || (await sha256(String(body.pin))) !== cfg.value) {
    await new Promise((r) => setTimeout(r, 800));
    return json({ error: "PIN incorrecto" }, 401);
  }

  const p = body.payload ?? {};
  let r;
  switch (body.action) {
    case "check": return json({ ok: true });
    case "respuesta_upsert":
      r = await db.from("respuestas").upsert(pick(p, RESP_COLS)).select(); break;
    case "respuesta_delete":
      r = await db.from("respuestas").delete().eq("partido_id", p.partido_id).eq("jugador_id", p.jugador_id); break;
    case "partido_upsert":
      r = await db.from("partidos").upsert({ ...pick(p, PARTIDO_COLS), updated_at: new Date().toISOString() }).select(); break;
    case "partido_delete":
      r = await db.from("partidos").delete().eq("id", p.id); break;
    case "jugador_upsert":
      r = await db.from("jugadores").upsert(pick(p, JUGADOR_COLS)).select(); break;
    case "multa_insert":
      r = await db.from("multas").insert(pick(p, MULTA_COLS)).select(); break;
    case "multa_update":
      r = await db.from("multas").update(pick(p, MULTA_COLS)).eq("id", p.id).select(); break;
    case "multa_delete":
      r = await db.from("multas").delete().eq("id", p.id); break;
    case "propuesta_delete":
      r = await db.from("multa_propuestas").delete().eq("id", p.id); break;
    case "mvp_delete":
      r = await db.from("votos_mvp").delete().eq("partido_id", p.partido_id).eq("votante_id", p.votante_id).eq("tipo", p.tipo); break;
    case "foto_delete": {
      const { data: f } = await db.from("fotos").select("path").eq("id", p.id).maybeSingle();
      if (f?.path) await db.storage.from("fotos").remove([f.path]);
      r = await db.from("fotos").delete().eq("id", p.id); break;
    }
    case "foto_update":
      if (p.portada === true && p.partido_id) await db.from("fotos").update({ portada: false }).eq("partido_id", p.partido_id);
      r = await db.from("fotos").update(pick(p, ["pie", "portada", "partido_id"])).eq("id", p.id).select(); break;
    case "liga_set":
      r = await db.from("liga").upsert({ id: "actual", data: p.data, updated_at: new Date().toISOString() }).select(); break;
    default:
      return json({ error: "Acción desconocida" }, 400);
  }
  if (r.error) return json({ error: r.error.message }, 400);
  return json({ ok: true, data: r.data ?? null });
});
