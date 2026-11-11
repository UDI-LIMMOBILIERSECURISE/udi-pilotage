// Envoi automatique d'un mail depuis le pilotage (142) : Zapier (webhook) → Gmail « Send Email » depuis votregestionnaire@udi-immo.com.
// Droits, adresses (toujours celles du bail dans Rivage) et trace : pilotage_mail_preparer, appelé avec la session de l'utilisateur.
// L'adresse du webhook Zapier est un secret de la fonction : ZAPIER_MAIL_WEBHOOK.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const ORIGINES = ['https://udi-pilotage.vercel.app', 'http://localhost:5173', 'http://localhost:4173']
const EXPEDITEUR = 'votregestionnaire@udi-immo.com'

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

  const webhook = Deno.env.get('ZAPIER_MAIL_WEBHOOK')
  if (!webhook || !/^https:\/\/hooks\.zapier\.com\//.test(webhook)) return rep(503, { error: 'Envoi automatique des mails non configuré : secret ZAPIER_MAIL_WEBHOOK absent.' })

  const url = Deno.env.get('SUPABASE_URL')!
  const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const auth = req.headers.get('Authorization')
  if (!auth) return rep(401, { error: 'Non connecté' })
  const utilisateur = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } })
  const { data: u } = await utilisateur.auth.getUser()
  if (!u?.user) return rep(401, { error: 'Non connecté' })

  let c: { bail?: string; to?: string[]; objet?: string; corps?: string; cle?: string; etape?: string; detail?: string }
  try { c = await req.json() } catch { return rep(400, { error: 'Requête invalide' }) }
  if (!c.bail || !/^lc_[A-Za-z0-9]+$/.test(c.bail)) return rep(400, { error: 'Bail invalide' })

  const { data: envoi, error: ep } = await utilisateur.rpc('pilotage_mail_preparer', {
    p_bail: c.bail, p_to: c.to || [], p_objet: c.objet || '', p_corps: c.corps || '', p_cle: c.cle || null, p_etape: c.etape || null })
  if (ep) return rep(400, { error: ep.message })

  let ok = false, erreur: string | null = null
  try {
    const r = await fetch(webhook, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: EXPEDITEUR, to: (envoi.to as string[]).join(','), subject: c.objet, body: c.corps, bail: c.bail, envoi: envoi.id }) })
    ok = r.ok
    if (!r.ok) erreur = `Zapier HTTP ${r.status}`
  } catch (x) { erreur = x instanceof Error ? x.message : String(x) }
  await service.rpc('pilotage_mail_resultat', { p_id: envoi.id, p_ok: ok, p_erreur: erreur, p_detail: c.detail || null })
  return rep(ok ? 200 : 502, { ok, to: envoi.to, ...(erreur ? { error: erreur } : {}) })
})
