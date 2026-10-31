// Lecture d'un bail ou d'un mandat de gestion par l'IA : propose une réponse à chaque question du contrôle d'entrée, avec la page et l'extrait.
// La proposition n'est jamais validée seule : la gestionnaire confirme ou corrige dans le questionnaire.
// Deux sources : le dernier bail déposé dans Rivage pour ce bail, ou un PDF envoyé depuis le poste (base64).
// Appel par un membre (gestionnaire, superviseur, direction) ou par la tâche planifiée (en-tête x-pilotage-cron) :
// dans ce cas, lit les baux commerciaux qui ont un bail déposé dans Rivage et pas encore de lecture (3 au plus par passage).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const ORIGINES = ['https://udi-pilotage.vercel.app', 'http://localhost:5173', 'http://localhost:4173']
const MODELES = [Deno.env.get('PILOTAGE_MODELE_LECTURE') || 'claude-sonnet-5-5', 'claude-haiku-4-5-20251001']
// Baux commerciaux et mandats (clauses négociées, enjeux financiers) : modèle le plus performant, puis Sonnet en secours.
// Tâches courtes (dire si un document est la bonne pièce, lire la date d'une attestation) : Sonnet, à peine plus cher que Haiku
// et plus fiable sur les scans (choix de Nicolas : privilégier la qualité tant que le coût reste modéré).
const MODELE_EXPERT = Deno.env.get('PILOTAGE_MODELE_EXPERT') || 'claude-opus-5-5'
const MODELES_SIMPLES = MODELES
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

// Identité des locataires pour la déclaration d'occupation aux impôts (110) : nom, prénoms, date et lieu de naissance ; société : dénomination, SIREN
const CONSIGNE_OCCUPANTS_CLE = `- Ajoute une clé "occupants" : liste des locataires (preneurs) désignés par le bail, sans les garants ni les cautions. Pour une personne :
  {"type": "personne", "nom": "...", "prenoms": "...", "date_naissance": "AAAA-MM-JJ" ou null, "lieu_naissance": "commune (département ou pays)" ou null, "page": n}.
  Pour une société : {"type": "societe", "denomination": "...", "siren": "9 chiffres" ou null, "page": n}. Recopie exactement ce qui est écrit, null si absent.`

const SYSTEME = `Tu lis un bail (commercial, professionnel ou d'habitation) pour une agence de gestion locative française.
On te donne le document et une liste de questions identifiées par une clé. Pour chaque clé, réponds à partir du seul document.
Règles strictes :
- N'invente rien. Si l'information n'est pas dans le document, mets "trouve": false et "valeur": null.
- "valeur" : réponse courte en français (une phrase au plus), avec les dates au format jj/mm/aaaa et les montants avec le symbole €.
- "page" : numéro de la page du PDF où se trouve l'information (1 = première page), sinon null.
- "extrait" : citation exacte et courte (200 caractères au plus) du passage qui fonde la réponse, sinon null.
- Pour les clés de dates et durée (c_rv_dates, h_rv_dates), ajoute "signature" (AAAA-MM-JJ, date de signature du bail en cours), "debut" (AAAA-MM-JJ, date de prise d'effet du bail en cours) et "duree_mois" (entier).
- Date de signature : c'est UNIQUEMENT la date écrite à côté des signatures des parties, en général sur la dernière page (« Fait à …, le … », « Signé le … », date des signatures électroniques ; s'il y en a plusieurs, la dernière). Cite ce passage dans "extrait" et sa page dans "page".
  Ne prends JAMAIS pour date de signature une date citée dans le corps du bail à propos du loyer ou d'un bail antérieur : montant et date du dernier loyer acquitté par le précédent locataire, date de la dernière révision, loyer de référence, ancien bail, bail renouvelé, avenant précédent. Si aucune date n'est écrite près des signatures, mets "signature": null et ajoute-le aux "anomalies".
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
${CONSIGNE_OCCUPANTS_CLE}
Réponds uniquement par un objet JSON valide, sans texte autour.`

const SYSTEME_MANDAT = `Tu lis un mandat de gestion locative (loi Hoguet) pour une agence de gestion française.
On te donne le document et une liste de questions identifiées par une clé. Pour chaque clé, réponds à partir du seul document.
Règles strictes :
- N'invente rien. Si l'information n'est pas dans le document, mets "trouve": false et "valeur": null.
- "valeur" : réponse courte en français (une phrase au plus), dates au format jj/mm/aaaa, montants avec le symbole €.
- "page" : numéro de la page du PDF (1 = première page), sinon null. "extrait" : citation exacte et courte (200 caractères au plus), sinon null.
- m_rv_dates : ajoute "signature" (AAAA-MM-JJ), "debut" (AAAA-MM-JJ, prise d'effet) et "duree_mois" (durée initiale, entier).
  La signature est UNIQUEMENT la date écrite à côté des signatures (en général dernière page : « Fait à …, le … », signatures électroniques : la dernière) ; jamais une date citée dans le corps du mandat. Absente : "signature": null et une anomalie.
- m_rv_reconduction : ajoute "code" parmi tacite, expresse, aucune, et "annees" (durée de chaque reconduction, entier).
- m_rv_registre : ajoute "numero" (entier, numéro d'inscription au registre des mandats).
- m_rv_gestion : ajoute "taux" (nombre : taux des honoraires de gestion en % TTC ; s'il n'est donné qu'en HT, multiplie par 1,2).
- m_rv_mandants : ajoute "noms" (liste des mandants : personnes ou sociétés).
- Ajoute une clé "anomalies" : liste de phrases courtes signalant les incohérences ou blancs du document (taux ou date en blanc, mandat non signé, numéro de registre absent...).
Réponds uniquement par un objet JSON valide, sans texte autour.`

function b64(buf: ArrayBuffer) {
  const u = new Uint8Array(buf); let s = ''
  for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000))
  return btoa(s)
}

async function lire(service: ReturnType<typeof createClient>, bail: string, pdf: string | null, nom: string | null, user: string | null, mandat = false) {
  // Questions du contrôle d'entrée pour ce bail (ou ce mandat)
  const { data: questions, error: eq } = mandat
    ? await service.rpc('pilotage_questions_mandat', { p_mandat: bail })
    : await service.rpc('pilotage_questions_bail', { p_bail: bail })
  if (eq || !questions?.length) return { status: 404, body: { error: mandat ? 'Mandat introuvable' : 'Bail introuvable' } }

  let source = nom ? `PDF envoyé : ${nom}` : ''
  if (!pdf) {
    const { data: src } = mandat
      ? await service.rpc('pilotage_mandat_source', { p_mandat: bail })
      : await service.rpc('pilotage_lecture_source', { p_bail: bail })
    if (!src?.url) return { status: 404, body: { error: mandat
      ? 'Aucun mandat de gestion repéré dans Rivage (document dont le nom contient « mandat de gestion »). Déposez-le dans Rivage ou lisez un PDF depuis votre poste.'
      : 'Aucun bail déposé dans Rivage pour ce bail. Déposez-le dans Rivage ou lisez un PDF depuis votre poste.' } }
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
  const expert = mandat || questions.some((q: { cle: string }) => q.cle.startsWith('c_'))
  for (const m of expert ? [MODELE_EXPERT, ...MODELES] : MODELES) {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': cleApi, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({
        model: m, max_tokens: 8000, system: mandat ? SYSTEME_MANDAT : SYSTEME, ...(m.includes('haiku') ? { temperature: 0 } : {}),
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
    if (r.status === 401) break  // clé refusée : inutile d'essayer un autre modèle
  }
  if (!texte) return { status: 502, body: { error: 'Le service IA n’a pas répondu' } }
  const debut = texte.indexOf('{'), fin = texte.lastIndexOf('}')
  let resultat: Record<string, unknown>
  try { resultat = JSON.parse(texte.slice(debut, fin + 1)) } catch { return { status: 502, body: { error: 'Réponse de l’IA illisible, réessayez.' } } }

  await service.rpc('pilotage_lecture_ecrire', { p_bail: bail, p_source: source, p_modele: modele, p_resultat: resultat, p_user: user })
  return { status: 200, body: { ok: true, modele, source } }
}

// Lecture de la seule identité des locataires (110), pour un bail déjà lu avant l'ajout de la clé « occupants »
async function lireOccupants(service: ReturnType<typeof createClient>, bail: string, user: string | null) {
  const { data: src } = await service.rpc('pilotage_lecture_source', { p_bail: bail })
  if (!src?.url) return { status: 404, body: { error: 'Aucun bail déposé dans Rivage pour ce bail : déposez le bail signé dans Rivage.' } }
  const r = await fetch(src.url)
  if (!r.ok) return { status: 502, body: { error: 'Le lien du document Rivage a expiré : relancez la mise à jour depuis Rivage.' } }
  const buf = await r.arrayBuffer()
  if (buf.byteLength > MAX_OCTETS) return { status: 413, body: { error: 'Document trop volumineux (25 Mo au plus).' } }
  const cleApi = Deno.env.get('ANTHROPIC_API_KEY')
  if (!cleApi) return { status: 500, body: { error: 'Service IA non configuré' } }
  const consigne = `Tu lis un bail pour une agence de gestion locative française. N'invente rien.\n${CONSIGNE_OCCUPANTS_CLE}\nRéponds uniquement par un objet JSON {"occupants": [...]}, sans texte autour.`
  for (const m of MODELES_SIMPLES) {
    const rep = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': cleApi, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: m, max_tokens: 2000, system: consigne, messages: [{ role: 'user', content: [
        { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: b64(buf) } },
        { type: 'text', text: 'Relève les locataires du bail.' },
      ] }] }),
    })
    if (rep.ok) {
      const j = await rep.json()
      const t = (j.content || []).filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text).join('\n')
      let res: { occupants?: unknown }
      try { res = JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1)) } catch { return { status: 502, body: { error: 'Réponse de l’IA illisible, réessayez.' } } }
      if (!Array.isArray(res.occupants)) return { status: 502, body: { error: 'L’IA n’a pas trouvé de locataire dans ce document.' } }
      await service.rpc('pilotage_lecture_occupants', { p_bail: bail, p_occupants: res.occupants, p_source: `Rivage : ${src.libelle || src.upload_id}`, p_modele: m, p_user: user })
      return { status: 200, body: { ok: true, occupants: res.occupants.length } }
    }
    console.error('[pilotage-lecture-bail] occupants', m, rep.status, (await rep.text()).slice(0, 300))
    if (rep.status === 401) break
  }
  return { status: 502, body: { error: 'Le service IA n’a pas répondu' } }
}

// Vérification d'une pièce déposée dans Rivage (en cas de doute sur son nom) : l'IA dit si le document est bien la pièce attendue.
async function verifierPiece(service: ReturnType<typeof createClient>, bail: string, upload: string, piece: string, mandat = false) {
  const { data: src } = mandat
    ? await service.rpc('pilotage_piece_mandat_source', { p_mandat: bail, p_upload: upload })
    : await service.rpc('pilotage_piece_source', { p_bail: bail, p_upload: upload })
  if (!src?.url) return { status: 404, body: { error: mandat ? 'Document introuvable dans Rivage pour ce mandat.' : 'Document introuvable dans Rivage pour ce bail.' } }
  const r = await fetch(src.url)
  if (!r.ok) return { status: 502, body: { error: 'Le lien du document Rivage a expiré : relancez la mise à jour depuis Rivage.' } }
  const buf = await r.arrayBuffer()
  if (buf.byteLength > MAX_OCTETS) return { status: 413, body: { error: 'Document trop volumineux (25 Mo au plus).' } }
  const type = (r.headers.get('content-type') || '').split(';')[0].trim()
  const bloc = type.startsWith('image/') && ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].includes(type)
    ? { type: 'image', source: { type: 'base64', media_type: type, data: b64(buf) } }
    : { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: b64(buf) } }
  const cleApi = Deno.env.get('ANTHROPIC_API_KEY')
  if (!cleApi) return { status: 500, body: { error: 'Service IA non configuré' } }
  const consigne = `Pièce attendue dans le dossier d'un ${mandat ? 'mandat de gestion' : 'bail'} : « ${piece} ». Nom du fichier dans Rivage : « ${src.libelle || ''} ».
Dis si ce document est bien cette pièce. N'invente rien. Réponds uniquement par un objet JSON :
{"conforme": true ou false, "type_document": "ce qu'est réellement le document, en quelques mots", "date": "AAAA-MM-JJ ou null (date du document)", "raison": "une phrase"}`
  for (const m of MODELES_SIMPLES) {
    const rep = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': cleApi, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: m, max_tokens: 600, ...(m.includes('haiku') ? { temperature: 0 } : {}),
        messages: [{ role: 'user', content: [bloc, { type: 'text', text: consigne }] }] }),
    })
    if (rep.ok) {
      const j = await rep.json()
      const t = (j.content || []).filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text).join('\n')
      try { return { status: 200, body: { ok: true, modele: m, ...JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1)) } } }
      catch { return { status: 502, body: { error: 'Réponse de l’IA illisible, réessayez.' } } }
    }
    console.error('[pilotage-lecture-bail] verif', m, rep.status, (await rep.text()).slice(0, 300))
    if (rep.status === 401) break
  }
  return { status: 502, body: { error: 'Le service IA n’a pas répondu' } }
}

// Lecture d'un justificatif de suivi déposé dans Rivage (assurance, entretien, caution, DPE, régularisation) : dates d'expiration et du document.
const ATTENDU: Record<string, string> = {
  assurance: "attestation d'assurance habitation ou multirisque du locataire, en cours de validité",
  entretien: "attestation d'entretien (chaudière, pompe à chaleur, climatisation...) ou contrat d'entretien",
  dpe: 'diagnostic de performance énergétique (DPE)',
  garantie: 'acte de caution ou garantie bancaire', caution: 'acte de caution',
  charges_regul: 'avis de régularisation annuelle des charges',
}
async function lireJustificatif(service: ReturnType<typeof createClient>, j: { upload_id: string; obligation_id: number; nature: string; libelle: string; categorie: string; nom: string | null; url: string }) {
  const r = await fetch(j.url)
  if (!r.ok) return { upload: j.upload_id, erreur: 'lien expiré' }
  const buf = await r.arrayBuffer()
  if (buf.byteLength > MAX_OCTETS) return { upload: j.upload_id, erreur: 'trop volumineux' }
  const type = (r.headers.get('content-type') || '').split(';')[0].trim()
  const bloc = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].includes(type)
    ? { type: 'image', source: { type: 'base64', media_type: type, data: b64(buf) } }
    : { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: b64(buf) } }
  const cleApi = Deno.env.get('ANTHROPIC_API_KEY')
  if (!cleApi) return { upload: j.upload_id, erreur: 'IA non configurée' }
  const consigne = `Document déposé comme justificatif du suivi « ${j.libelle} » (catégorie « ${j.categorie} »). Pièce attendue : ${ATTENDU[j.nature] || j.libelle}.
N'invente rien. Réponds uniquement par un objet JSON :
{"conforme": true si le document est bien la pièce attendue, sinon false,
 "type_document": "ce qu'est le document, en quelques mots (avec l'assureur ou le prestataire s'il est indiqué)",
 "date_document": "AAAA-MM-JJ ou null (date d'émission, ou date de l'intervention pour un entretien)",
 "date_expiration": "AAAA-MM-JJ ou null (fin de validité ou de la période couverte, si elle est écrite)",
 "raison": "une phrase"}`
  for (const m of MODELES_SIMPLES) {
    const rep = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': cleApi, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: m, max_tokens: 600, ...(m.includes('haiku') ? { temperature: 0 } : {}),
        messages: [{ role: 'user', content: [bloc, { type: 'text', text: consigne }] }] }),
    })
    if (rep.ok) {
      const t = ((await rep.json()).content || []).filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text).join('\n')
      let res: Record<string, unknown>
      try { res = JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1)) } catch { return { upload: j.upload_id, erreur: 'réponse illisible' } }
      await service.rpc('pilotage_justificatif_ia', { p_upload: j.upload_id, p_obligation: j.obligation_id, p_resultat: { ...res, modele: m } })
      return { upload: j.upload_id, conforme: res.conforme, expiration: res.date_expiration }
    }
    console.error('[pilotage-lecture-bail] justificatif', m, rep.status, (await rep.text()).slice(0, 300))
    if (rep.status === 401) break
  }
  return { upload: j.upload_id, erreur: 'IA indisponible' }
}

// Lecture d'un état des lieux d'entrée (037) : l'IA propose les équipements à entretenir et les compteurs du lot.
// Rien n'est créé : chaque proposition est confirmée ou ignorée d'un clic dans le pilotage.
const CONSIGNE_EDL = `Tu lis un état des lieux d'entrée d'un logement ou d'un local, pour une agence de gestion locative française.
Relève uniquement ce qui est écrit dans le document. N'invente rien.
1. "equipements" : les équipements qui demandent un entretien périodique, choisis UNIQUEMENT dans cette liste (libellé exact) :
   Chaudière gaz, Chaudière fioul, Chaudière bois ou granulés, Pompe à chaleur, Climatisation, Ballon thermodynamique, Cheminée ou insert,
   Poêle à bois ou à granulés, VMC, Fosse septique, Citerne gaz, Adoucisseur, Portail ou porte de garage motorisés.
   Un simple radiateur électrique ou un chauffe-eau électrique classique n'est pas un équipement à entretenir : ne le cite pas.
   Pour chacun : {"libelle": "...", "extrait": "citation courte (150 caractères au plus)", "page": n}.
2. "compteurs" : les compteurs relevés (eau froide, eau chaude, chauffage, électricité, gaz), chacun :
   {"libelle": "Eau froide|Eau chaude|Chauffage|Électricité|Gaz", "situation": "individuel" ou "divisionnaire" ou null (si l'état des lieux le précise),
    "numero": "numéro du compteur ou null", "index": "index relevé (nombre) ou null", "date": "AAAA-MM-JJ (date de l'état des lieux) ou null",
    "extrait": "citation courte", "page": n}.
Réponds uniquement par un objet JSON {"equipements": [...], "compteurs": [...]}, sans texte autour.`

async function lireEdl(service: ReturnType<typeof createClient>, j: { upload_id: string; asset_id: string; url: string; libelle: string | null }) {
  const r = await fetch(j.url)
  if (!r.ok) return { upload: j.upload_id, erreur: 'lien expiré' }
  const buf = await r.arrayBuffer()
  if (buf.byteLength > MAX_OCTETS) {
    await service.rpc('pilotage_edl_ecrire', { p_upload: j.upload_id, p_asset: j.asset_id, p_modele: null, p_resultat: { erreur: 'document trop volumineux' } })
    return { upload: j.upload_id, erreur: 'trop volumineux' }
  }
  const type = (r.headers.get('content-type') || '').split(';')[0].trim()
  const bloc = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].includes(type)
    ? { type: 'image', source: { type: 'base64', media_type: type, data: b64(buf) } }
    : { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: b64(buf) } }
  const cleApi = Deno.env.get('ANTHROPIC_API_KEY')
  if (!cleApi) return { upload: j.upload_id, erreur: 'IA non configurée' }
  for (const m of MODELES_SIMPLES) {
    const rep = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': cleApi, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: m, max_tokens: 3000, ...(m.includes('haiku') ? { temperature: 0 } : {}),
        messages: [{ role: 'user', content: [bloc, { type: 'text', text: CONSIGNE_EDL }] }] }),
    })
    if (rep.ok) {
      const t = ((await rep.json()).content || []).filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text).join('\n')
      let res: Record<string, unknown>
      try { res = JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1)) } catch { return { upload: j.upload_id, erreur: 'réponse illisible' } }
      const { data: n } = await service.rpc('pilotage_edl_ecrire', { p_upload: j.upload_id, p_asset: j.asset_id, p_modele: m, p_resultat: res })
      return { upload: j.upload_id, propositions: n }
    }
    console.error('[pilotage-lecture-bail] edl', m, rep.status, (await rep.text()).slice(0, 300))
    if (rep.status === 401) break
  }
  return { upload: j.upload_id, erreur: 'IA indisponible' }
}

// Recherche du permis de louer d'une commune (038) : recherche web, résultat enregistré « à confirmer » par la gestion.
async function rechercherCommune(service: ReturnType<typeof createClient>, c: { commune: string; code_postal: string | null }) {
  const cleApi = Deno.env.get('ANTHROPIC_API_KEY')
  if (!cleApi) return { commune: c.commune, erreur: 'IA non configurée' }
  const consigne = `Commune : ${c.commune}${c.code_postal ? ' (' + c.code_postal + ')' : ''}, France.
Cherche sur le web si cette commune applique le « permis de louer » (loi ALUR, articles L634-1 et L635-1 du code de la construction et de l'habitation) :
autorisation préalable de mise en location, ou déclaration de mise en location, sur toute la commune ou sur un périmètre (quartiers, rues).
Privilégie le site officiel de la commune ou de l'intercommunalité, et les délibérations ou arrêtés. N'invente rien.
Réponds uniquement par un objet JSON :
{"resultat": "detecte" ou "aucun", "regime": "autorisation" ou "declaration" ou null, "perimetre": "commune" ou "partiel" ou null,
 "detail": "une ou deux phrases : ce qui s'applique, depuis quand, quel périmètre", "source": "adresse de la page officielle la plus fiable, ou null"}`
  for (const m of MODELES_SIMPLES) {
    const rep = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': cleApi, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: m, max_tokens: 2000,
        tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5, user_location: { type: 'approximate', country: 'FR', timezone: 'Europe/Paris' } }],
        messages: [{ role: 'user', content: consigne }] }),
    })
    if (rep.ok) {
      const j = await rep.json()
      const blocs = (j.content || []).filter((b: { type: string }) => b.type === 'text') as { text: string; citations?: { url: string; title: string }[] }[]
      const t = blocs.map((b) => b.text).join('\n')
      const sources = [...new Set(blocs.flatMap((b) => (b.citations || []).map((x) => x.url)))].slice(0, 5)
      let res: Record<string, unknown>
      try { res = JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1)) } catch { return { commune: c.commune, erreur: 'réponse illisible' } }
      res = { ...res, sources, modele: m, recherche_le: new Date().toISOString() }
      if (!res.source && sources.length) res.source = sources[0]
      await service.rpc('pilotage_permis_recherche_ecrire', { p_commune: c.commune, p_resultat: res })
      return { commune: c.commune, resultat: res.resultat, regime: res.regime }
    }
    console.error('[pilotage-lecture-bail] commune', m, rep.status, (await rep.text()).slice(0, 300))
    if (rep.status === 401) break
  }
  return { commune: c.commune, erreur: 'IA indisponible' }
}

// Échec d'une lecture automatique (041) : au 2e échec, le document n'est plus retenté par les tâches planifiées.
async function echec(service: ReturnType<typeof createClient>, cle: string, nature: string, corps: unknown) {
  const c = corps as { error?: string; erreur?: string }
  await service.rpc('pilotage_lecture_echec', { p_cle: cle, p_nature: nature, p_erreur: c?.error || c?.erreur || 'échec' })
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
    let c: { justificatifs?: boolean; mandats?: boolean; edl?: boolean; communes?: boolean; audit?: boolean; occupants?: boolean } = {}
    try { c = await req.json() } catch { /* corps vide : lecture des baux */ }
    // Audit du stock (040) : tous les baux en cours et mandats actifs pas encore lus, 3 + 3 par passage (toutes les 10 minutes)
    if (c.audit) {
      const { data: liste } = await service.rpc('pilotage_audit_a_lire', { p_max: 1 })
      const faits: unknown[] = []
      for (const x of (liste || []) as { type: string; id: string }[]) {
        const r = await lire(service, x.id, null, null, null, x.type === 'mandat')
        if (r.status !== 200) await echec(service, x.id, x.type, r.body)
        faits.push({ ...x, ...r.body })
      }
      return rep(200, { ok: true, faits })
    }
    // Identité des locataires des baux en entrée ou en sortie, lus avant la clé « occupants » (112) : toutes les 5 minutes, 3 au plus
    if (c.occupants) {
      const { data: liste } = await service.rpc('pilotage_occupants_a_lire', { p_max: 3 })
      const faits: unknown[] = []
      for (const id of (liste || []) as string[]) {
        const r = await lireOccupants(service, id, null)
        if (r.status !== 200) await echec(service, 'occ:' + id, 'occupants', r.body)
        faits.push({ bail: id, ...r.body })
      }
      return rep(200, { ok: true, faits })
    }
    // Communes des logements gérés absentes de la table du permis de louer (038) : chaque heure, 2 au plus
    if (c.communes) {
      const { data: liste } = await service.rpc('pilotage_communes_a_rechercher', { p_max: 2 })
      const faits: unknown[] = []
      for (const x of (liste || [])) {
        const r = await rechercherCommune(service, x)
        if ('erreur' in r) await echec(service, x.commune, 'commune', r)
        faits.push(r)
      }
      return rep(200, { ok: true, faits })
    }
    // États des lieux d'entrée pas encore lus (037) : chaque heure, 3 au plus
    if (c.edl) {
      const { data: liste } = await service.rpc('pilotage_edl_a_lire', { p_max: 3 })
      const faits: unknown[] = []
      for (const j of (liste || [])) {
        const r = await lireEdl(service, j)
        if ('erreur' in r && r.erreur !== 'trop volumineux') await echec(service, j.upload_id, 'edl', r)
        faits.push(r)
      }
      return rep(200, { ok: true, faits })
    }
    // Mandats soumis au contrôle d'entrée et pas encore lus (036) : chaque heure
    if (c.mandats) {
      const { data: liste } = await service.rpc('pilotage_mandats_a_lire', { p_max: 3 })
      const faits: unknown[] = []
      for (const id of (liste || []) as string[]) {
        const r = await lire(service, id, null, null, null, true)
        if (r.status !== 200) await echec(service, id, 'mandat', r.body)
        faits.push({ mandat: id, ...r.body })
      }
      return rep(200, { ok: true, faits })
    }
    if (c.justificatifs) {
      const { data: liste } = await service.rpc('pilotage_justificatifs_a_lire', { p_max: 5 })
      const faits: unknown[] = []
      for (const j of (liste || [])) {
        const r = await lireJustificatif(service, j)
        if ('erreur' in r) await echec(service, j.upload_id, 'justificatif', r)
        faits.push(r)
      }
      return rep(200, { ok: true, faits })
    }
    const { data: aLire } = await service.rpc('pilotage_baux_a_lire', { p_max: 3 })
    const faits: unknown[] = []
    for (const id of (aLire || []) as string[]) {
      const r = await lire(service, id, null, null, null)
      if (r.status !== 200) await echec(service, id, 'bail', r.body)
      faits.push({ bail: id, ...r.body })
    }
    return rep(200, { ok: true, faits })
  }

  const auth = req.headers.get('Authorization')
  if (!auth) return rep(401, { error: 'Non connecté' })
  const utilisateur = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } })
  const { data: u } = await utilisateur.auth.getUser()
  if (!u?.user) return rep(401, { error: 'Non connecté' })
  const { data: moi } = await utilisateur.rpc('pilotage_moi')
  if (!moi) return rep(403, { error: 'Accès refusé' })

  let corps: { bail_id?: string; mandat_id?: string; pdf?: string; nom?: string; upload_id?: string; piece?: string; occupants?: boolean }
  try { corps = await req.json() } catch { return rep(400, { error: 'Requête invalide' }) }
  const mandat = !!corps.mandat_id
  const id = corps.mandat_id || corps.bail_id
  if (!id) return rep(400, { error: 'Bail ou mandat manquant' })
  // La gestion lit tous les dossiers ; le commercial, seulement les siens (négociateur du mandat, « loué par » du bail) (036)
  if (!['direction', 'superviseur', 'gestionnaire'].includes(moi.role)) {
    const { data: permis } = await utilisateur.rpc('pilotage_peut_lire', { p_objet: mandat ? 'mandat' : 'bail', p_id: id })
    if (permis !== true) return rep(403, { error: 'Ce dossier ne vous est pas attribué' })
  }
  if (corps.occupants && !mandat) {
    const o = await lireOccupants(service, id, u.user.id)
    return rep(o.status, o.body)
  }
  if (corps.upload_id) {
    const v = await verifierPiece(service, id, corps.upload_id, corps.piece || 'pièce du dossier', mandat)
    return rep(v.status, v.body)
  }
  const r = await lire(service, id, corps.pdf || null, corps.nom || null, u.user.id, mandat)
  return rep(r.status, r.body)
})
