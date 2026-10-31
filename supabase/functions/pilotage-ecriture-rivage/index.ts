// Écriture dans Rivage depuis le pilotage (042). Premier usage : déposer une pièce dans un mandat, un bail ou un lot Rivage (lot : 106).
// Réservé à la direction (pilotage_peut_ecrire_rivage). Liste fermée d'actions et de natures ; chaque appel est journalisé
// dans pilotage.rivage_ecritures avec la réponse de Rivage. La clé API reste dans les secrets (RIVAGE_API_KEY).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const RIVAGE = 'https://rivage.immo'
const ORIGINES = ['https://udi-pilotage.vercel.app', 'http://localhost:5173', 'http://localhost:4173']
const MAX_OCTETS = 20 * 1024 * 1024
const CIBLES = ['ManagementContract', 'LeasingContract', 'Asset']
// Natures Rivage autorisées pour un dépôt depuis le pilotage (sous-ensemble de l'énumération de l'API)
const NATURES = ['management_mandate', 'landlord_identity_and_residence_proof', 'identity_document', 'property_title', 'property_ownership_certificate',
  'landlord_bank_details', 'property_insurance_contracts', 'technical_diagnostic_reports', 'lease_contract', 'move_in_inventory',
  'home_insurance_certificate', 'guarantor_documents', 'security_deposit_proof', 'maintenance_contracts', 'property_tax_declaration', 'work_estimates']
const TYPES = ['application/pdf', 'image/jpeg', 'image/png']

// Lecture d'une pièce de la GED WeRoof (UDIGESTION), stockée sur Cloudflare R2 : URL présignée (AWS SigV4) avec les secrets R2 du projet
async function lireR2(cle: string): Promise<Uint8Array | null> {
  const compte = Deno.env.get('R2_ACCOUNT_ID'), acces = Deno.env.get('R2_ACCESS_KEY_ID'), secret = Deno.env.get('R2_SECRET_ACCESS_KEY')
  const seau = Deno.env.get('R2_BUCKET_NAME') || 'udigestion-documents'
  if (!compte || !acces || !secret) return null
  const enc = new TextEncoder()
  const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b)).map((x) => x.toString(16).padStart(2, '0')).join('')
  const hmac = async (k: ArrayBuffer | Uint8Array, d: string) => crypto.subtle.sign('HMAC', await crypto.subtle.importKey('raw', k, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']), enc.encode(d))
  const hote = `${compte}.r2.cloudflarestorage.com`
  const date = new Date().toISOString().replace(/[:-]|\.\d{3}/g, ''), jour = date.slice(0, 8)
  const portee = `${jour}/auto/s3/aws4_request`
  const chemin = `/${seau}/${cle.split('/').map(encodeURIComponent).join('/')}`
  const q = new URLSearchParams({ 'X-Amz-Algorithm': 'AWS4-HMAC-SHA256', 'X-Amz-Credential': `${acces}/${portee}`, 'X-Amz-Date': date, 'X-Amz-Expires': '300', 'X-Amz-SignedHeaders': 'host' })
  const qs = q.toString().replace(/\+/g, '%20')
  const canon = ['GET', chemin, qs, `host:${hote}\n`, 'host', 'UNSIGNED-PAYLOAD'].join('\n')
  const aSigner = ['AWS4-HMAC-SHA256', date, portee, hex(await crypto.subtle.digest('SHA-256', enc.encode(canon)))].join('\n')
  let k = await hmac(enc.encode(`AWS4${secret}`), jour)
  for (const x of ['auto', 's3', 'aws4_request']) k = await hmac(k, x)
  const r = await fetch(`https://${hote}${chemin}?${qs}&X-Amz-Signature=${hex(await hmac(k, aSigner))}`)
  if (!r.ok) { console.error('[pilotage-ecriture-rivage] R2', r.status); return null }
  return new Uint8Array(await r.arrayBuffer())
}

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

  let c: { action?: string; cible_type?: string; cible_id?: string; nature?: string; titre?: string; nom?: string; type_mime?: string; fichier?: string; document_weroof?: string; test_profil_interne?: string }
  try { c = await req.json() } catch { return rep(400, { error: 'Requête invalide' }) }
  if (c.action !== 'upload') return rep(400, { error: 'Action non prévue' })
  if (!c.cible_type || !CIBLES.includes(c.cible_type) || !c.cible_id || !/^(mc|lc|a)_[A-Za-z0-9]+$/.test(c.cible_id)) return rep(400, { error: 'Mandat, bail ou lot Rivage invalide' })
  // Essais du 17/10 : la pièce est créée dans Rivage mais aucun rattachement n'est pris en compte (mandat, puis lot), quel que soit
  // l'emplacement des paramètres resourceable_*. Chaque essai laissait une pièce orpheline dans la GED : dépôt sur un mandat suspendu
  // tant que Rivage n'a pas indiqué comment rattacher une pièce par l'API.
  // Test du 19/10 : la GED Rivage rattache une pièce au propriétaire avec son numéro interne (formulaire Rivage : resourceable_type=Profile,
  // resourceable_id=62522) et non avec l'identifiant public de l'API. Ce test seul lève la pause, pour la direction.
  const testProfil = c.test_profil_interne && /^\d{1,10}$/.test(c.test_profil_interne) ? c.test_profil_interne : null
  // 31/10 : Rivage a indiqué le format du rattachement à un lot (upload[resourceable_type]=Asset, upload[resourceable_id]=identifiant public
  // du lot, upload[label], upload[nature], file). Le dépôt sur un mandat reprend : la pièce va sur le lot du mandat.
  let bin: Uint8Array
  if (c.document_weroof) {
    // Pièce de la GED WeRoof : elle doit faire partie des pièces rapprochées de ce mandat (même adresse et même propriétaire)
    if (c.cible_type !== 'ManagementContract' || !/^[0-9a-f-]{36}$/.test(c.document_weroof)) return rep(400, { error: 'Pièce WeRoof invalide' })
    const { data: src } = await service.rpc('pilotage_document_weroof_source', { p_mandat: c.cible_id, p_document: c.document_weroof })
    if (!src?.storage_path) return rep(404, { error: 'Pièce WeRoof introuvable ou non rattachée à ce mandat.' })
    const lu = await lireR2(src.storage_path)
    if (!lu) return rep(502, { error: 'Pièce WeRoof illisible dans le stockage (R2).' })
    bin = lu; c.nom = src.nom || 'piece.pdf'; c.type_mime = src.type_mime || 'application/pdf'; c.nature = c.nature || src.nature
  } else {
    if (!c.fichier || !c.nom) return rep(400, { error: 'Fichier manquant' })
    bin = Uint8Array.from(atob(c.fichier), (x) => x.charCodeAt(0))
  }
  if (!c.nature || !NATURES.includes(c.nature)) return rep(400, { error: 'Nature de document non prévue' })
  const type = TYPES.includes(c.type_mime || '') ? c.type_mime! : 'application/pdf'
  if (bin.byteLength > MAX_OCTETS) return rep(413, { error: 'Fichier trop volumineux (20 Mo au plus)' })

  const brute = Deno.env.get('RIVAGE_API_KEY')
  if (!brute) return rep(500, { error: 'Clé API Rivage non configurée (secret RIVAGE_API_KEY)' })
  const cle = brute.trim().replace(/^Bearer\s+/i, '').replace(/\s+/g, '')
  const titre = (c.titre || c.nom!.replace(/\.[a-z0-9]+$/i, '')).slice(0, 150)

  // Rattachement (essais du 17/10) : un rattachement à un mandat (ManagementContract) est ignoré par Rivage.
  // Mandat : la pièce est rattachée au lot du mandat (Asset), que le contrôle du mandat reconnaît. Bail : adresse dédiée de l'API.
  let rattacheA = c.cible_id!, typeRattache = c.cible_type!
  if (testProfil) { rattacheA = testProfil; typeRattache = 'Profile' }
  else if (c.cible_type === 'ManagementContract') {
    const { data: lots } = await service.rpc('pilotage_lots_mandat', { p_mandat: c.cible_id })
    if (!Array.isArray(lots) || !lots.length) return rep(400, { error: 'Aucun lot rattaché à ce mandat dans Rivage : impossible d’y rattacher la pièce.' })
    rattacheA = lots[0]; typeRattache = 'Asset'
  }
  const adresse = c.cible_type === 'LeasingContract' ? `${RIVAGE}/api/v1/leasing_contracts/${encodeURIComponent(c.cible_id!)}/uploads` : `${RIVAGE}/api/v1/uploads`
  // Rivage (Rails) exige les métadonnées dans un objet « upload » (refus 400 « param is missing: upload » sinon).
  // Le fichier est attendu dans « file » selon la documentation ; repli sur « upload[file] » si Rivage refuse.
  const envoyer = async (fichierDansUpload: boolean) => {
    const f = new FormData()
    // Format indiqué par Rivage le 31/10 : rattachement dans l'objet « upload » seulement (plus de doublon hors « upload »)
    f.append('upload[label]', titre)
    f.append('upload[nature]', c.nature!)
    if (c.cible_type !== 'LeasingContract') {
      f.append('upload[resourceable_type]', typeRattache)
      f.append('upload[resourceable_id]', rattacheA)
    }
    f.append(fichierDansUpload ? 'upload[file]' : 'file', new Blob([bin], { type }), c.nom!)
    const r = await fetch(adresse, { method: 'POST', headers: { Authorization: `Bearer ${cle}`, Accept: 'application/json' }, body: f })
    const t = await r.text()
    let corps: Record<string, unknown> = {}
    try { corps = JSON.parse(t) } catch { corps = { message: t.slice(0, 300) } }
    return { r, corps }
  }
  let { r, corps } = await envoyer(false)
  if (r.status === 400 || r.status === 422) {
    const premier = { statut: r.status, message: corps.message }
    ;({ r, corps } = await envoyer(true))
    if (!r.ok) corps = { ...corps, premier_essai: premier }
  }

  const rattache = Array.isArray(corps.resourceables) && (testProfil ? (corps.resourceables as unknown[]).length > 0 : (corps.resourceables as { id?: string }[]).some((x) => x.id === rattacheA))
  const ok = r.ok
  // Journal : résumé de la réponse, sans le lien de téléchargement (valable 7 jours, sans authentification)
  const resume = { id: corps.id ?? null, nature: corps.nature ?? null, label: corps.label ?? null,
    resourceables: Array.isArray(corps.resourceables) ? (corps.resourceables as { id?: string; type?: string }[]).map((x) => ({ id: x.id, type: x.type })) : null,
    document_weroof: c.document_weroof || null, rattache_a: rattacheA, premier_essai: corps.premier_essai ?? null, error: corps.error ?? null, message: typeof corps.message === 'string' ? (corps.message as string).slice(0, 500) : null }
  const { error: ej } = await service.rpc('pilotage_ecriture_rivage_noter', { p_par: u.user.id, p_action: 'upload', p_cible_type: c.cible_type, p_cible_id: c.cible_id,
    p_nature: c.nature, p_libelle: c.nom, p_statut: r.status, p_ok: ok, p_rivage_id: (corps.id as string) || null, p_reponse: resume })
  if (ej) console.error('[pilotage-ecriture-rivage] journal', ej.message)
  if (!ok) {
    console.error('[pilotage-ecriture-rivage]', r.status, JSON.stringify(corps).slice(0, 300))
    const msg = r.status === 401 || r.status === 403 ? 'Rivage refuse l’écriture : la clé API n’a pas les droits d’écriture.' : `Rivage a refusé le dépôt (${r.status}) : ${(corps.message as string) || (corps.error as string) || 'raison non précisée'}`
    return rep(502, { error: msg })
  }
  return rep(200, { ok: true, upload_id: corps.id, rattache, nature: corps.nature,
    rattache_a: typeRattache === 'Asset' ? 'lot' : typeRattache === 'Profile' ? 'propriétaire' : 'bail',
    avertissement: rattache ? null : 'Pièce créée dans Rivage mais pas rattachée au dossier : la rattacher dans la GED Rivage.' })
})
