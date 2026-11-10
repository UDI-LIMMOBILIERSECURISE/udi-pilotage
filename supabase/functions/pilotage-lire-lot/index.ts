// Diagnostic (10/11/2026) : lecture brute de l'API Rivage (GET seulement, chemins /api/v1/...), pour inventorier les champs exposés.
// Lecture seule. Appel réservé à la base (secret de la tâche planifiée, en-tête x-pilotage-cron).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const RIVAGE = 'https://rivage.immo'

Deno.serve(async (req) => {
  const rep = (s: number, b: unknown) => new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } })
  const service = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const entete = req.headers.get('x-pilotage-cron')
  const ok = entete ? (await service.rpc('pilotage_cron_valide', { p_secret: entete })).data === true : false
  if (!ok) return rep(401, { error: 'Non autorisé' })
  let corps: { lot?: string; chemins?: string[] } = {}
  try { corps = await req.json() } catch { /* vide */ }
  const chemins = (corps.chemins || (corps.lot ? [`/api/v1/assets/${corps.lot}`] : [])).slice(0, 12)
  if (!chemins.length || chemins.some((c) => !/^\/api\/v1\/[a-z_]+(\/[a-zA-Z0-9_-]+)*(\?[a-z_]+=[a-zA-Z0-9_-]+(&[a-z_]+=[a-zA-Z0-9_-]+)*)?$/.test(c)))
    return rep(400, { error: 'chemins GET /api/v1/... attendus' })
  const cle = (Deno.env.get('RIVAGE_API_KEY') || '').trim().replace(/^Bearer\s+/i, '').replace(/\s+/g, '')
  const sortie: Record<string, unknown> = {}
  for (const c of chemins) {
    try {
      const r = await fetch(`${RIVAGE}${c}`, { headers: { Authorization: `Bearer ${cle}`, Accept: 'application/json' } })
      const t = await r.text()
      let j: unknown = t.slice(0, 500)
      try { j = JSON.parse(t) } catch { /* texte */ }
      sortie[c] = { statut: r.status, corps: j }
    } catch (e) { sortie[c] = { erreur: e instanceof Error ? e.message : String(e) } }
    await new Promise((f) => setTimeout(f, 700))
  }
  return rep(200, sortie)
})
