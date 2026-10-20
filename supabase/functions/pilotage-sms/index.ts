// Envoi d'un SMS au locataire depuis le pilotage (066) : Zapier (webhook) → Twilio « Send SMS », expéditeur UDIGESTION.
// Droits, numéros (toujours ceux du locataire dans Rivage) et trace : pilotage_sms_preparer, appelé avec la session de l'utilisateur.
// L'adresse du webhook Zapier est un secret de la fonction : ZAPIER_SMS_WEBHOOK.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const ORIGINES = ['https://udi-pilotage.vercel.app', 'http://localhost:5173', 'http://localhost:4173']

function cors(req: Request) {
  const o = req.headers.get('origin') || ''
  return {
    'Access-Control-Allow-Origin': ORIGINES.includes(o) ? o : ORIGINES[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  }
}

Deno.serve(async (req) => {
  const h = { ...cors(req), 'Content-Type': 'application/json' }
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: h })
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors(req) })
  if (req.method !== 'POST') return rep(405, { error: 'Méthode non autorisée' })

  const webhook = Deno.env.get('ZAPIER_SMS_WEBHOOK')
  if (!webhook || !/^https:\/\/hooks\.zapier\.com\//.test(webhook)) return rep(503, { error: 'Envoi de SMS non configuré : secret ZAPIER_SMS_WEBHOOK absent.' })

  const url = Deno.env.get('SUPABASE_URL')!
  const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const auth = req.headers.get('Authorization')
  if (!auth) return rep(401, { error: 'Non connecté' })
  const utilisateur = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } })
  const { data: u } = await utilisateur.auth.getUser()
  if (!u?.user) return rep(401, { error: 'Non connecté' })

  let c: { bail?: string; texte?: string; cle?: string; etape?: string; detail?: string }
  try { c = await req.json() } catch { return rep(400, { error: 'Requête invalide' }) }
  if (!c.bail || !/^lc_[A-Za-z0-9]+$/.test(c.bail)) return rep(400, { error: 'Bail invalide' })

  // Droits et numéros vérifiés en base avec la session de l'utilisateur
  const { data: envois, error: ep } = await utilisateur.rpc('pilotage_sms_preparer', { p_bail: c.bail, p_texte: c.texte || '', p_cle: c.cle || null, p_etape: c.etape || null })
  if (ep) return rep(400, { error: ep.message })

  const resultats: { telephone: string; ok: boolean; erreur?: string }[] = []
  for (const e of envois as { id: number; telephone: string; nom: string }[]) {
    let ok = false, erreur: string | null = null
    try {
      const r = await fetch(webhook, { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ to: e.telephone, message: (c.texte || '').trim(), nom: e.nom, bail: c.bail, envoi: e.id }) })
      ok = r.ok
      if (!r.ok) erreur = `Zapier HTTP ${r.status}`
    } catch (x) { erreur = x instanceof Error ? x.message : String(x) }
    await service.rpc('pilotage_sms_resultat', { p_id: e.id, p_ok: ok, p_erreur: erreur, p_detail: c.detail || null })
    resultats.push({ telephone: e.telephone, ok, ...(erreur ? { erreur } : {}) })
  }
  const envoyes = resultats.filter((r) => r.ok)
  return rep(envoyes.length ? 200 : 502, { ok: envoyes.length > 0, resultats, ...(envoyes.length ? {} : { error: 'SMS non transmis à Zapier' }) })
})
