import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Récepteur des webhooks Rivage (compte de production depuis la bascule 068-069).
// Rivage ne signe pas ses requêtes : l'authentification repose sur un jeton secret passé en paramètre ?token=...
// Le jeton est dans le secret RIVAGE_WEBHOOK_TOKEN (saisi par Nicolas, jamais écrit dans le code ni la conversation).
// Sans secret, tout est refusé : l'ancien webhook du compte de test ne passe plus.
const MAX_BODY_BYTES = 1_000_000;

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const attendu = (Deno.env.get("RIVAGE_WEBHOOK_TOKEN") ?? "").trim();
  if (attendu.length < 32) {
    console.error("RIVAGE_WEBHOOK_TOKEN absent ou trop court (32 caractères au moins)");
    return new Response("Unauthorized", { status: 401 });
  }
  const token = new URL(req.url).searchParams.get("token") ?? "";
  // Comparaison des empreintes : même longueur quelle que soit la valeur reçue
  if (!token || !timingSafeEqual(await sha256Hex(token), await sha256Hex(attendu))) {
    return new Response("Unauthorized", { status: 401 });
  }

  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) return new Response("Payload too large", { status: 413 });

  let body: any;
  try {
    body = JSON.parse(raw);
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  const p = body?.payload ?? {};
  const row = {
    event_type: body?.event_type ?? null,
    model_name: body?.model_name ?? null,
    event_name: body?.event_name ?? null,
    object_id: typeof p?.id === "string" ? p.id : null,
    payload: body,
    dedup_key: await sha256Hex(raw),
  };

  const { error } = await supabase
    .from("rivage_webhook_events")
    .upsert(row, { onConflict: "dedup_key", ignoreDuplicates: true });

  if (error) {
    console.error("insert error", error.message);
    return new Response("Storage error", { status: 500 }); // Rivage retentera
  }
  return new Response("ok", { status: 200 });
});
