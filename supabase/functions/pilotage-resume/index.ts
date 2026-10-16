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
  impaye: { rpc: 'pilotage_impayes', cle: 'id', liste: 'dossiers' },
  mandat: { rpc: 'pilotage_mandats', cle: 'id', liste: 'mandats' },
  bail: { rpc: 'pilotage_baux', cle: 'bail_id', liste: 'baux' },
}

const CONSIGNES: Record<string, string> = {
  sinistre: "Il s'agit d'un incident technique (sinistre) déclaré dans le logiciel de gestion Rivage. Le champ situation décrit l'état locatif actuel du lot (occupé, libre, congé en cours, libre en attente de restitution du dépôt de garantie, avec les délais) : mentionne-le, car il conditionne l'intervention (accès au logement, imputation au locataire sortant sur son dépôt). mandat_statut indique si le mandat de gestion est actif.",
  dg: "Il s'agit d'un dossier de sortie de locataire et de restitution du dépôt de garantie. Rappel légal : restitution sous 1 mois après remise des clés si l'état des lieux de sortie est conforme à celui d'entrée, 2 mois sinon (loi du 6 juillet 1989, art. 22), majoration de 10 % du loyer HC par mois de retard commencé. Signification des champs : fin = date de fin du bail (sert de date de référence, la date réelle de remise des clés n'est pas connue) ; restitution_creee = une restitution du dépôt a été créée dans Rivage ; validee = cette restitution a été validée dans Rivage (cela ne dit RIEN de l'état des lieux) ; remboursee = le dépôt a été remboursé ; incidents = incidents techniques liés au bail, a_charge = qui les paie. La conformité de l'état des lieux de sortie n'est pas connue : ne la déduis jamais, cite les deux échéances possibles (limite_1_mois et limite_2_mois).",
  compta: "Il s'agit de la situation comptable d'un locataire sur une période de loyer (montants en euros). solde = reçu − dû : négatif = impayé, positif = trop-perçu.",
  alerte: "Il s'agit d'une alerte de contrôle automatique sur un dossier de gestion locative.",
  impaye: "Il s'agit d'un dossier de suivi d'impayé locatif (garantie loyers impayés GLI Zelok ou Mila, caution, huissier, avocat). Les champs du dossier viennent du tableau de suivi de l'agence ; echanges contient le fil des mises à jour de l'équipe (repris de Monday puis saisis dans le pilotage), du plus récent au plus ancien ; rivage contient les données du bail si le dossier y est rattaché. Résume en 4 à 6 phrases : où en est le dossier (garantie, prise en charge, indemnisation, procédure, audience), les montants connus, ce qui s'est passé de marquant dans les échanges (avec les dates), ce qui est en attente et qui doit agir. Ne recopie pas les échanges, synthétise-les. Signification des champs (vocabulaire du tableau de l'agence) : garantie = dispositif qui couvre l'impayé ; prise_en_charge = réponse de l'assureur sur la prise en charge du sinistre (OUI, En cours, NON REFUS = refusé, DECOMPTE MAJ OK = décompte à jour, VOIE HUISSIER, LOC REGUL DETTE = le locataire a régularisé) ; indemnisation_recue = indemnisation versée par l'assureur à l'agence (OK RECUE = reçue par l'agence, QUITTANCE SUBRO FINALE = quittance subrogative finale) ; indemnite_versee_bailleur = reversement de cette indemnité au propriétaire par l'agence (OK FAIT = reversée) ; dette_remb_loc = le locataire a-t-il remboursé sa dette ; solde_a_rembourser_assureur et indemnisation_a_rembourser = ce que l'agence doit rendre à l'assureur quand le locataire a payé après indemnisation ; intervenants = membres de l'équipe qui suivent le dossier ; declaration_le = date de déclaration du sinistre à l'assureur ; maj_assureur_le = dernière mise à jour du dossier chez l'assureur. Un champ vide signifie seulement que l'information n'a pas été saisie : ne le présente pas comme un manque dans le dossier sauf s'il est utile au suivi.",
  bail: "Il s'agit du suivi d'un bail géré par l'agence : échéance et procédure d'information du bailleur (echeance : type de bail, date d'échéance, date limite du congé, étape en cours, décision du bailleur, blocages), contrôle d'entrée (controle : points restant à traiter, anomalies, GO), suivis récurrents (obligations : assurance, entretien, compteurs, garanties, taxes, avec l'étape de relance à faire), paliers de loyer, actes (demandes de renouvellement, congés) et lecture du bail par l'IA si elle existe. Résume en 3 à 5 phrases : où en est le bail, ce qui est urgent (dates limites), ce qui reste à contrôler, et la prochaine action. Ne donne aucun avis juridique au-delà des règles rappelées dans les données.",
  mandat: "Il s'agit d'un mandat de gestion suivi de sa signature jusqu'à la mise en location : statut, négociateur, GO de la direction (dossier complet validé après le contrôle d'entrée), bail de mise en location. manques liste ce qui reste à faire. Un bien loué sans GO est une anomalie à signaler. Les commissions sont suivies ailleurs : n'en parle pas. Résume en 3 à 5 phrases où en est le mandat, ce qui bloque et la prochaine action.",
}

const SYSTEME = `Tu es l'assistant de supervision d'une agence de gestion locative française (UDI Gestion).
On te donne les données brutes d'un dossier, au format JSON, extraites du logiciel Rivage.
Écris en français un résumé de la situation, en 3 à 5 phrases, en texte suivi (pas de liste, pas de titre, pas de gras).
Règles strictes :
- N'utilise que les données fournies. N'invente aucun fait, aucune date, aucun montant, aucun nom.
- Si une information utile manque (null, vide), dis-le simplement plutôt que de supposer.
- Mets en avant ce qui demande une action (retard, montant à rembourser ou à réclamer, pièce ou étape manquante, incident à la charge du locataire à imputer, etc.).
- Termine par la prochaine action concrète à faire, formulée à l'infinitif.
- Dates au format jj/mm/aaaa, montants avec le symbole €. Écris toujours les échéances en dates (« avant le 15/11/2026 »), jamais en durée relative (« dans 3 jours ») : le résumé est conservé tant que le dossier ne change pas.
- Ne cite jamais les noms techniques des champs ni des valeurs comme true, false ou null : écris en français courant.
- Ne tire aucune conclusion juridique ou factuelle qui ne découle pas directement d'une donnée fournie.`

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
  if (corps.type === 'impaye') {
    const { data: notes } = await utilisateur.rpc('pilotage_impaye_notes', { p_impaye: Number(corps.id) })
    // Fil des échanges, du plus récent au plus ancien, limité pour rester lisible par l'IA
    let total = 0
    dossier.echanges = (notes || []).filter((n: { contenu: string }) => { total += (n.contenu || '').length; return total < 30000 })
      .map((n: { le: string; auteur: string; contenu: string; parent_id: number | null }) => ({ le: n.le, auteur: n.auteur, reponse: !!n.parent_id, texte: n.contenu }))
    delete dossier.actions_internes
  }
  if (corps.type === 'bail') {
    const { data: det } = await utilisateur.rpc('pilotage_bail_dossier', { p_bail: String(corps.id) })
    if (det) {
      dossier.fiche = det.fiche; dossier.paliers = det.paliers; dossier.actes = det.actes
      dossier.controle_a_traiter = (det.controle?.items || []).filter((i: { a_traiter: boolean }) => i.a_traiter).map((i: { libelle: string }) => i.libelle)
      dossier.anomalies = (det.controle?.items || []).filter((i: { statut: string }) => i.statut === 'anomalie').map((i: { libelle: string; commentaire: string; detail: string }) => ({ point: i.libelle, detail: i.commentaire || i.detail }))
      if (det.lecture) dossier.lecture_ia = { le: det.lecture.le, anomalies: det.lecture.resultat?.anomalies, refacturations: det.lecture.resultat?.refacturations }
    }
  }
  if (corps.type === 'compta') dossier.compte_locataire = (data?.comptes || []).filter((c: Record<string, unknown>) => c.bail_id === dossier.bail_id)

  const contenu = JSON.stringify(dossier)
  const cle = `${corps.type}:${corps.id}`
  const aujourdhui = new Date().toLocaleDateString('fr-FR', { timeZone: 'Europe/Paris' })
  // Résumé conservé tant que les données du dossier ne changent pas (le jour n'entre plus dans l'empreinte) :
  // l'IA n'est rappelée qu'après une mise à jour (webhook Rivage, saisie dans le pilotage) ou sur « Actualiser ».
  const emp = await empreinte(contenu)
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
      // Les modèles récents refusent le paramètre temperature : il n'est envoyé qu'au modèle de secours
      body: JSON.stringify({ model: m, max_tokens: 900, system: SYSTEME, messages: [{ role: 'user', content: message }], ...(m.includes('haiku') ? { temperature: 0 } : {}) }),
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
