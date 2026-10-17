// Mise à jour du reflet pilotage depuis l'API Rivage (lecture seule).
// Appelée chaque semaine (et chaque mois pour les référentiels comptables) par pg_cron (en-tête x-pilotage-cron), ou à la demande par la direction (jeton de session).
// Complète les webhooks : rattrape ce qui n'a pas été envoyé et les objets créés avant leur mise en place.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const RIVAGE = 'https://rivage.immo'
const ORIGINES = ['https://udi-pilotage.vercel.app', 'http://localhost:5173', 'http://localhost:4173']

// Modèle Rivage -> chemin API. Ordre : référentiels d'abord.
// Les webhooks mettent le reflet à jour en continu, dès qu'un objet change dans Rivage. L'API ne donne pas de date de
// modification ni de filtre « modifié depuis » : la relecture complète ne sert donc qu'au rattrapage, et elle est espacée.
//   hebdo   : chaque semaine (mandats, lots, baux, profils, incidents)
//   mensuel : chaque mois (référentiels comptables, volumineux et peu changeants)
// Un appel à la demande (bouton « Mettre à jour maintenant ») relit tout.
const MODELES: [string, string, 'hebdo' | 'mensuel'][] = [
  ['GliProvider', '/api/v1/gli_providers', 'hebdo'],
  ['ManagementContract', '/api/v1/management_contracts', 'hebdo'],
  ['AssetGroup', '/api/v1/asset_groups', 'hebdo'],
  ['Asset', '/api/v1/assets', 'hebdo'],
  ['LeasingContract', '/api/v1/leasing_contracts', 'hebdo'],
  ['Profile', '/api/v1/profiles', 'hebdo'],
  ['Incident', '/api/v1/incidents', 'hebdo'],
  ['AccountingEventGroup', '/api/v1/accounting_event_groups', 'mensuel'],
  ['AccountingAccount', '/api/v1/accounting_accounts', 'mensuel'],
]

// Données personnelles : on ne garde que ce qui sert au suivi (identité, e-mail, téléphone).
const PERSONNE = ['id', 'nature', 'civility', 'first_name', 'last_name', 'company_name', 'email', 'phone_number', 'reference']
const garder = (o: Record<string, unknown>, cles: string[]) => Object.fromEntries(cles.filter((k) => k in o).map((k) => [k, o[k]]))

function nettoyer(modele: string, o: Record<string, unknown>) {
  if (modele === 'Profile') return garder(o, PERSONNE)
  if (modele === 'LeasingContract') {
    // La date de naissance des locataires est gardée : contrôle des plus de 65 ans avant un congé (036)
    o.tenants = ((o.tenants as Record<string, unknown>[]) || []).map((t) => garder(t, [...PERSONNE, 'birth_date']))
    o.guarantors = ((o.guarantors as Record<string, unknown>[]) || []).map((g) => ({ id: g.id }))
  }
  return o
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

  // Qui appelle : la tâche planifiée (secret partagé) ou un membre de la direction
  let declencheur = 'cron'
  const enteteCron = req.headers.get('x-pilotage-cron')
  // Le secret de la tâche planifiée est dans le coffre (Vault) de la base : vérification côté base
  const cronValide = enteteCron ? (await service.rpc('pilotage_cron_valide', { p_secret: enteteCron })).data === true : false
  if (!cronValide) {
    const auth = req.headers.get('Authorization')
    if (!auth) return rep(401, { error: 'Non autorisé' })
    const utilisateur = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } })
    const { data: moi } = await utilisateur.rpc('pilotage_moi')
    if (!moi || moi.role !== 'direction') return rep(403, { error: 'Réservé à la direction' })
    declencheur = moi.prenom
  }

  const brute = Deno.env.get('RIVAGE_API_KEY')
  if (!brute) return rep(500, { error: 'Clé API Rivage non configurée (secret RIVAGE_API_KEY)' })
  // Tolère « Bearer » et les espaces collés par erreur ; diagnostic du format sans jamais afficher la clé
  const cle = brute.trim().replace(/^Bearer\s+/i, '').replace(/\s+/g, '')
  if (!/^pk_[A-Za-z0-9]+:sk_[A-Za-z0-9]+$/.test(cle)) {
    const diag = `format attendu pk_…:sk_… ; reçu : commence par pk_ ${cle.startsWith('pk_') ? 'oui' : 'non'}, deux-points ${cle.includes(':') ? 'oui' : 'non'}, contient sk_ ${cle.includes('sk_') ? 'oui' : 'non'}, ${cle.length} caractères`
    await service.rpc('pilotage_sync_fin', { p_id: (await service.rpc('pilotage_sync_debut', { p_declencheur: declencheur })).data, p_compteurs: {}, p_erreur: 'Clé Rivage mal formée : ' + diag })
    return rep(500, { error: 'Clé Rivage mal formée : ' + diag })
  }

  // Tâche planifiée : relecture hebdomadaire (corps vide) ou mensuelle ({"mode":"mensuel"}) ; à la demande : tout
  let mode = 'complet'
  if (cronValide) { try { mode = (await req.json())?.mode === 'mensuel' ? 'mensuel' : 'hebdo' } catch { mode = 'hebdo' } }
  const aLire = MODELES.filter(([, , f]) => mode !== 'hebdo' || f === 'hebdo')

  const { data: syncId } = await service.rpc('pilotage_sync_debut', { p_declencheur: declencheur + (mode === 'complet' ? '' : ' (' + mode + ')') })
  const compteurs: Record<string, number> = {}
  try {
    for (const [modele, chemin] of aLire) {
      let page = 1, total = 1, n = 0
      while (page <= total) {
        const r = await fetch(`${RIVAGE}${chemin}?page=${page}&limit=100`, { headers: { Authorization: `Bearer ${cle}`, Accept: 'application/json' } })
        if (!r.ok) throw new Error(`${modele} page ${page} : HTTP ${r.status}`)
        const j = await r.json()
        total = j.pagination?.total_pages || 1
        const lot = (j.data || []).map((o: Record<string, unknown>) => nettoyer(modele, o))
        if (lot.length) {
          const { error } = await service.rpc('pilotage_sync_appliquer', { p_modele: modele, p_objets: lot })
          if (error) throw new Error(`${modele} : ${error.message}`)
        }
        n += lot.length
        page++
      }
      compteurs[modele] = n
    }
    await service.rpc('pilotage_sync_fin', { p_id: syncId, p_compteurs: compteurs, p_erreur: null })
    return rep(200, { ok: true, compteurs })
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    await service.rpc('pilotage_sync_fin', { p_id: syncId, p_compteurs: compteurs, p_erreur: msg })
    return rep(500, { error: msg, compteurs })
  }
})
