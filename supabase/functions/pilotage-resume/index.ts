// Résumé IA d'une carte du pilotage.
// Les données sont relues côté serveur avec les droits de l'utilisateur connecté (mêmes fonctions que l'appli) :
// personne ne peut faire résumer un dossier qu'il n'a pas le droit de voir, ni envoyer un texte libre à l'IA.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const ORIGINES = ['https://udi-pilotage.vercel.app', 'http://localhost:5173', 'http://localhost:4173']
const MODELES = [Deno.env.get('PILOTAGE_MODELE') || 'claude-sonnet-5-5', 'claude-haiku-4-5-20251001']

const SOURCES: Record<string, { rpc: string; cle: string; liste?: string }> = {
  sinistre: { rpc: 'pilotage_sinistres', cle: 'id' },
  dg: { rpc: 'pilotage_dg', cle: 'bail_id' },
  compta: { rpc: 'pilotage_compta', cle: 'id', liste: 'periodes' },
  alerte: { rpc: 'pilotage_agence', cle: 'id' },
}

const CONSIGNES: Record<string, string> = {
  sinistre: "Il s'agit d'un incident technique (sinistre) déclaré dans le logiciel de gestion Rivage.",
  dg: "Il s'agit d'un dossier de sortie de locataire et de restitution du dépôt de garantie. Rappel légal : restitution sous 1 mois après remise des clés si l'état des lieux de sortie est conforme à celui d'entrée, 2 mois sinon (loi du 6 juillet 1989, art. 22), majoration de 10 % du loyer HC par mois de retard commencé. La date réelle de remise des clés et la conformité de l'EDL ne sont pas connues : la date de fin du bail sert de référence.",
  compta: "Il s'agit de la situation comptable d'un locataire sur une période de loyer (montants en euros). solde = reçu − dû : négatif = impayé, positif = trop-perçu.",
  alerte: "Il s'agit d'une alerte de contrôle automatique sur un dossier de gestion locative.",
}

const SYSTEME = `Tu es l'assistant de supervision d'une agence de gestion locative française (UDI Gestion).
On te donne les données brutes d'un dossier, au format JSON, extraites du logiciel Rivage.
Écris en français un résumé de la situation, en 3 à 5 phrases, en texte suivi (pas de liste, pas de titre, pas de gras).
Règles strictes :
- N'utilise que les données fournies. N'invente aucun fait, aucune date, aucun montant, aucun nom.
- Si une information utile manque (null, vide), dis-le simplement plutôt que de supposer.
- Mets en avant ce qui demande une action (retard, montant à rembourser ou à réclamer, pièce ou étape manquante, incident à la charge du locataire à imputer, etc.).
- Termine par la prochaine action concrète à faire, formulée à l'infinitif.
- Dates au format jj/mm/aaaa, montants avec le symbole €.`

function cors(req: Request) {
  const o = req.headers.get('origin') || ''
  return {
    'Access-Control-Allow-Origin': ORIGINES.includes(o) ? o : ORIGINES[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  }
}

async function empreinte(s: string) {
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))
  return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

Deno.serve(async (req) => {
  const h = { ...cors(req), 'Content-Type': 'application/json' }
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: h })
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors(req) })
  if (req.method !== 'POST') return rep(405, { error: 'Méthode non autorisée' })

  const auth = req.headers.get('Authorization')
  if (!auth) return rep(401, { error: 'Non connecté' })
  let corps: { type?: string; id?: string | number; forcer?: boolean }
  try { corps = await req.json() } catch { return rep(400, { error: 'Requête invalide' }) }
  const src = SOURCES[corps.type || '']
  if (!src || corps.id == null) return rep(400, { error: 'Type ou identifiant manquant' })

  const url = Deno.env.get('SUPABASE_URL')!
  const utilisateur = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } })
  const { data: u } = await utilisateur.auth.getUser()
  if (!u?.user) return rep(401, { error: 'Non connecté' })

  // Données lues avec les droits de l'utilisateur
  const { data, error } = await utilisateur.rpc(src.rpc)
  if (error) return rep(403, { error: 'Accès refusé' })
  const liste = (src.liste ? data?.[src.liste] : data) || []
  const dossier = liste.find((x: Record<string, unknown>) => String(x[src.cle]) === String(corps.id))
  if (!dossier) return rep(404, { error: 'Dossier introuvable ou non visible' })
  if (corps.type === 'compta') dossier.compte_locataire = (data?.comptes || []).filter((c: Record<string, unknown>) => c.bail_id === dossier.bail_id)

  const contenu = JSON.stringify(dossier)
  const cle = `${corps.type}:${corps.id}`
  const aujourdhui = new Date().toLocaleDateString('fr-FR', { timeZone: 'Europe/Paris' })
  // Le jour fait partie de l'empreinte : un résumé qui parle de délais est refait chaque jour
  const emp = await empreinte(aujourdhui + contenu)
  const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  if (!corps.forcer) {
    const { data: cache } = await service.rpc('pilotage_resume_lire', { p_cle: cle, p_empreinte: emp })
    if (cache) return rep(200, { ...cache, cache: true })
  }

  const cleApi = Deno.env.get('ANTHROPIC_API_KEY')
  if (!cleApi) return rep(500, { error: 'Service IA non configuré' })
  const message = `${CONSIGNES[corps.type!]}\nDate du jour : ${aujourdhui}.\n\nDonnées du dossier :\n${contenu}`

  let texte = '', modele = ''
  for (const m of MODELES) {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': cleApi, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: m, max_tokens: 600, temperature: 0, system: SYSTEME, messages: [{ role: 'user', content: message }] }),
    })
    if (r.ok) {
      const j = await r.json()
      texte = (j.content || []).filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text).join('\n').trim()
      modele = m
      break
    }
    console.error('[pilotage-resume]', m, r.status, (await r.text()).slice(0, 300))
    if (r.status !== 404 && r.status !== 400) break
  }
  if (!texte) return rep(502, { error: 'Le service IA n’a pas répondu' })

  await service.rpc('pilotage_resume_ecrire', { p_cle: cle, p_empreinte: emp, p_texte: texte, p_modele: modele, p_user: u.user.id })
  return rep(200, { texte, modele, genere_le: new Date().toISOString(), cache: false })
})
