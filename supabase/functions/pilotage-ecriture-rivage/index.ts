// Écriture dans Rivage depuis le pilotage (042). Premier usage : déposer une pièce dans un mandat ou un bail Rivage.
// Réservé à la direction (pilotage_peut_ecrire_rivage). Liste fermée d'actions et de natures ; chaque appel est journalisé
// dans pilotage.rivage_ecritures avec la réponse de Rivage. La clé API reste dans les secrets (RIVAGE_API_KEY).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const RIVAGE = 'https://rivage.immo'
const ORIGINES = ['https://udi-pilotage.vercel.app', 'http://localhost:5173', 'http://localhost:4173']
const MAX_OCTETS = 20 * 1024 * 1024
const CIBLES = ['ManagementContract', 'LeasingContract']
// Natures Rivage autorisées pour un dépôt depuis le pilotage (sous-ensemble de l'énumération de l'API)
const NATURES = ['management_mandate', 'landlord_identity_and_residence_proof', 'identity_document', 'property_title', 'property_ownership_certificate',
  'landlord_bank_details', 'property_insurance_contracts', 'technical_diagnostic_reports', 'lease_contract', 'move_in_inventory',
  'home_insurance_certificate', 'guarantor_documents', 'security_deposit_proof', 'maintenance_contracts']
const TYPES = ['application/pdf', 'image/jpeg', 'image/png']

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

  const url = Deno.env.get('SUPABASE_URL')!
  const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const auth = req.headers.get('Authorization')
  if (!auth) return rep(401, { error: 'Non connecté' })
  const utilisateur = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } })
  const { data: u } = await utilisateur.auth.getUser()
  if (!u?.user) return rep(401, { error: 'Non connecté' })
  const { data: peut, error: ep } = await utilisateur.rpc('pilotage_peut_ecrire_rivage')
  if (ep) return rep(500, { error: 'Script 042 non passé : journal des écritures absent.' })
  if (peut !== true) return rep(403, { error: 'Écriture dans Rivage réservée à la direction.' })

  let c: { action?: string; cible_type?: string; cible_id?: string; nature?: string; titre?: string; nom?: string; type_mime?: string; fichier?: string }
  try { c = await req.json() } catch { return rep(400, { error: 'Requête invalide' }) }
  if (c.action !== 'upload') return rep(400, { error: 'Action non prévue' })
  if (!c.cible_type || !CIBLES.includes(c.cible_type) || !c.cible_id || !/^(mc|lc)_[A-Za-z0-9]+$/.test(c.cible_id)) return rep(400, { error: 'Mandat ou bail Rivage invalide' })
  if (!c.nature || !NATURES.includes(c.nature)) return rep(400, { error: 'Nature de document non prévue' })
  if (!c.fichier || !c.nom) return rep(400, { error: 'Fichier manquant' })
  const type = TYPES.includes(c.type_mime || '') ? c.type_mime! : 'application/pdf'
  const bin = Uint8Array.from(atob(c.fichier), (x) => x.charCodeAt(0))
  if (bin.byteLength > MAX_OCTETS) return rep(413, { error: 'Fichier trop volumineux (20 Mo au plus)' })

  const brute = Deno.env.get('RIVAGE_API_KEY')
  if (!brute) return rep(500, { error: 'Clé API Rivage non configurée (secret RIVAGE_API_KEY)' })
  const cle = brute.trim().replace(/^Bearer\s+/i, '').replace(/\s+/g, '')
  const titre = (c.titre || c.nom).slice(0, 150)

  // La documentation Rivage décrit les champs à plat mais mentionne aussi un objet « upload » : on essaie à plat, puis imbriqué si refus 422.
  const envoyer = async (imbrique: boolean) => {
    const f = new FormData()
    const k = (n: string) => (imbrique ? `upload[${n}]` : n)
    f.append(k('nature'), c.nature!)
    f.append(k('title'), titre)
    f.append(k('label'), titre)
    f.append(k('resourceable_type'), c.cible_type!)
    f.append(k('resourceable_id'), c.cible_id!)
    f.append(imbrique ? 'upload[file]' : 'file', new Blob([bin], { type }), c.nom!)
    const r = await fetch(`${RIVAGE}/api/v1/uploads`, { method: 'POST', headers: { Authorization: `Bearer ${cle}`, Accept: 'application/json' }, body: f })
    let corps: Record<string, unknown> = {}
    try { corps = await r.json() } catch { corps = { message: (await r.text().catch(() => '')).slice(0, 300) } }
    return { r, corps }
  }
  let { r, corps } = await envoyer(false)
  if (r.status === 422) ({ r, corps } = await envoyer(true))

  const rattache = Array.isArray(corps.resourceables) && (corps.resourceables as { id?: string }[]).some((x) => x.id === c.cible_id)
  const ok = r.ok
  // Journal : résumé de la réponse, sans le lien de téléchargement (valable 7 jours, sans authentification)
  const resume = { id: corps.id ?? null, nature: corps.nature ?? null, label: corps.label ?? null,
    resourceables: Array.isArray(corps.resourceables) ? (corps.resourceables as { id?: string; type?: string }[]).map((x) => ({ id: x.id, type: x.type })) : null,
    error: corps.error ?? null, message: typeof corps.message === 'string' ? (corps.message as string).slice(0, 500) : null }
  const { error: ej } = await service.rpc('pilotage_ecriture_rivage_noter', { p_par: u.user.id, p_action: 'upload', p_cible_type: c.cible_type, p_cible_id: c.cible_id,
    p_nature: c.nature, p_libelle: c.nom, p_statut: r.status, p_ok: ok, p_rivage_id: (corps.id as string) || null, p_reponse: resume })
  if (ej) console.error('[pilotage-ecriture-rivage] journal', ej.message)
  if (!ok) {
    console.error('[pilotage-ecriture-rivage]', r.status, JSON.stringify(corps).slice(0, 300))
    const msg = r.status === 401 || r.status === 403 ? 'Rivage refuse l’écriture : la clé API n’a pas les droits d’écriture.' : `Rivage a refusé le dépôt (${r.status}) : ${(corps.message as string) || (corps.error as string) || 'raison non précisée'}`
    return rep(502, { error: msg })
  }
  return rep(200, { ok: true, upload_id: corps.id, rattache, nature: corps.nature,
    avertissement: rattache ? null : 'Pièce créée dans Rivage mais pas rattachée au dossier : la rattacher dans la GED Rivage.' })
})
