// Lecture d'un bail par l'IA : propose une réponse à chaque question du contrôle d'entrée, avec la page et l'extrait.
// La proposition n'est jamais validée seule : la gestionnaire confirme ou corrige dans le questionnaire.
// Deux sources : le dernier bail déposé dans Rivage pour ce bail, ou un PDF envoyé depuis le poste (base64).
// Appel par un membre (gestionnaire, superviseur, direction) ou par la tâche planifiée (en-tête x-pilotage-cron) :
// dans ce cas, lit les baux commerciaux qui ont un bail déposé dans Rivage et pas encore de lecture (3 au plus par passage).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const ORIGINES = ['https://udi-pilotage.vercel.app', 'http://localhost:5173', 'http://localhost:4173']
const MODELES = [Deno.env.get('PILOTAGE_MODELE_LECTURE') || 'claude-sonnet-5-5', 'claude-haiku-4-5-20251001']
const MAX_OCTETS = 25 * 1024 * 1024

function cors(req: Request) {
  const o = req.headers.get('origin') || ''
  return {
    'Access-Control-Allow-Origin': ORIGINES.includes(o) ? o : ORIGINES[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-pilotage-cron',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  }
}

const SYSTEME = `Tu lis un bail (commercial, professionnel ou d'habitation) pour une agence de gestion locative française.
On te donne le document et une liste de questions identifiées par une clé. Pour chaque clé, réponds à partir du seul document.
Règles strictes :
- N'invente rien. Si l'information n'est pas dans le document, mets "trouve": false et "valeur": null.
- "valeur" : réponse courte en français (une phrase au plus), avec les dates au format jj/mm/aaaa et les montants avec le symbole €.
- "page" : numéro de la page du PDF où se trouve l'information (1 = première page), sinon null.
- "extrait" : citation exacte et courte (200 caractères au plus) du passage qui fonde la réponse, sinon null.
- Pour les clés de dates et durée (c_rv_dates, h_rv_dates), ajoute "signature" (AAAA-MM-JJ, date de signature du bail en cours), "debut" (AAAA-MM-JJ, date de prise d'effet du bail en cours) et "duree_mois" (entier).
- Pour les clés de dépôt de garantie (c_rv_dg, h_rv_dg), ajoute "montant" (nombre, en euros).
- Pour les clés de loyer (c_rv_loyer, h_rv_loyer), ajoute "montant_mensuel" (loyer mensuel hors charges et hors taxes, nombre ; loyer annuel divisé par 12 s'il est exprimé à l'année).
- Pour les clés de charges (c_rv_charges, h_rv_charges), ajoute "montant_mensuel" (provision ou forfait mensuel, nombre ; 0 s'il n'y en a pas).
- Pour la clé de TVA (c_rv_tva), ajoute "taux" (nombre : 20 si le loyer est soumis à la TVA à 20 %, 0 s'il ne l'est pas).
- Pour les clés d'indice (c_rv_indice, h_rv_indice), ajoute "code" parmi : irl, ilc, ilat, icc.
- Pour la clé de révision (c_rv_revision), ajoute "annees" (entier : 1 pour une révision annuelle, 3 pour une révision triennale).
- Pour les clés de type de bail (c_cl_type, h_cl_type), ajoute "code" parmi : vide, meuble, etudiant, mobilite, mixte, commercial, derogatoire, professionnel, autre.
- Ajoute une clé "paliers" : liste des paliers ou franchises de loyer prévus par le bail, chacun {"nature": "palier" ou "franchise", "debut": "AAAA-MM-JJ", "fin": "AAAA-MM-JJ" ou null, "loyer_annuel_ht": nombre ou null, "page": n}. Liste vide s'il n'y en a pas.
- Ajoute une clé "refacturations" : liste des sommes que le bail permet de refacturer au preneur (taxes, assurances, honoraires, travaux...), chacune {"nature": "...", "article": "...", "page": n}.
- Ajoute une clé "anomalies" : liste de phrases courtes signalant les incohérences ou blancs du document (montant non rempli, dates contradictoires, document qui n'est pas un bail...).
Réponds uniquement par un objet JSON valide, sans texte autour.`

function b64(buf: ArrayBuffer) {
  const u = new Uint8Array(buf); let s = ''
  for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000))
  return btoa(s)
}

async function lire(service: ReturnType<typeof createClient>, bail: string, pdf: string | null, nom: string | null, user: string | null) {
  // Questions du contrôle d'entrée pour ce bail
  const { data: questions, error: eq } = await service.rpc('pilotage_questions_bail', { p_bail: bail })
  if (eq || !questions?.length) return { status: 404, body: { error: 'Bail introuvable' } }

  let source = nom ? `PDF envoyé : ${nom}` : ''
  if (!pdf) {
    const { data: src } = await service.rpc('pilotage_lecture_source', { p_bail: bail })
    if (!src?.url) return { status: 404, body: { error: 'Aucun bail déposé dans Rivage pour ce bail. Déposez-le dans Rivage ou lisez un PDF depuis votre poste.' } }
    const r = await fetch(src.url)
    if (!r.ok) return { status: 502, body: { error: 'Le lien du document Rivage a expiré ou ne répond pas : relancez la mise à jour depuis Rivage, ou lisez le PDF depuis votre poste.' } }
    const buf = await r.arrayBuffer()
    if (buf.byteLength > MAX_OCTETS) return { status: 413, body: { error: 'Document trop volumineux pour la lecture (25 Mo au plus).' } }
    pdf = b64(buf); source = `Rivage : ${src.libelle || src.upload_id}`
  }
  if (pdf.length * 0.75 > MAX_OCTETS) return { status: 413, body: { error: 'Document trop volumineux pour la lecture (25 Mo au plus).' } }

  const cleApi = Deno.env.get('ANTHROPIC_API_KEY')
  if (!cleApi) return { status: 500, body: { error: 'Service IA non configuré' } }
  const liste = questions.map((q: { cle: string; libelle: string; aide?: string }) => `- ${q.cle} : ${q.libelle}${q.aide ? ' (' + q.aide + ')' : ''}`).join('\n')

  let texte = '', modele = ''
  for (const m of MODELES) {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': cleApi, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({
        model: m, max_tokens: 8000, system: SYSTEME, ...(m.includes('haiku') ? { temperature: 0 } : {}),
        messages: [{ role: 'user', content: [
          { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: pdf } },
          { type: 'text', text: `Questions :\n${liste}` },
        ] }],
      }),
    })
    if (r.ok) {
      const j = await r.json()
      texte = (j.content || []).filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text).join('\n')
      modele = m
      break
    }
    console.error('[pilotage-lecture-bail]', m, r.status, (await r.text()).slice(0, 300))
    if (r.status !== 404 && r.status !== 400) break
  }
  if (!texte) return { status: 502, body: { error: 'Le service IA n’a pas répondu' } }
  const debut = texte.indexOf('{'), fin = texte.lastIndexOf('}')
  let resultat: Record<string, unknown>
  try { resultat = JSON.parse(texte.slice(debut, fin + 1)) } catch { return { status: 502, body: { error: 'Réponse de l’IA illisible, réessayez.' } } }

  await service.rpc('pilotage_lecture_ecrire', { p_bail: bail, p_source: source, p_modele: modele, p_resultat: resultat, p_user: user })
  return { status: 200, body: { ok: true, modele, source } }
}

Deno.serve(async (req) => {
  const h = { ...cors(req), 'Content-Type': 'application/json' }
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: h })
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors(req) })
  if (req.method !== 'POST') return rep(405, { error: 'Méthode non autorisée' })

  const url = Deno.env.get('SUPABASE_URL')!
  const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  // Tâche planifiée : baux commerciaux sans lecture
  const enteteCron = req.headers.get('x-pilotage-cron')
  if (enteteCron) {
    const ok = (await service.rpc('pilotage_cron_valide', { p_secret: enteteCron })).data === true
    if (!ok) return rep(401, { error: 'Non autorisé' })
    const { data: aLire } = await service.rpc('pilotage_baux_a_lire', { p_max: 3 })
    const faits: unknown[] = []
    for (const id of (aLire || []) as string[]) faits.push({ bail: id, ...(await lire(service, id, null, null, null)).body })
    return rep(200, { ok: true, faits })
  }

  const auth = req.headers.get('Authorization')
  if (!auth) return rep(401, { error: 'Non connecté' })
  const utilisateur = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } })
  const { data: u } = await utilisateur.auth.getUser()
  if (!u?.user) return rep(401, { error: 'Non connecté' })
  const { data: moi } = await utilisateur.rpc('pilotage_moi')
  if (!moi || !['direction', 'superviseur', 'gestionnaire'].includes(moi.role)) return rep(403, { error: 'Réservé à la direction, au superviseur et aux gestionnaires' })

  let corps: { bail_id?: string; pdf?: string; nom?: string }
  try { corps = await req.json() } catch { return rep(400, { error: 'Requête invalide' }) }
  if (!corps.bail_id) return rep(400, { error: 'Bail manquant' })
  const r = await lire(service, corps.bail_id, corps.pdf || null, corps.nom || null, u.user.id)
  return rep(r.status, r.body)
})
