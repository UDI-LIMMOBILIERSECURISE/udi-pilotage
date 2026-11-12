// Historique des mails (145) : lit les boîtes Gmail actives (pilotage.mails_boites) avec un compte de service Google
// (délégation sur le domaine udi-immo.com, secret GOOGLE_SA_JSON, droit gmail.modify pour poser les libellés),
// garde les mails échangés avec un contact Rivage, les rattache à un lot / bail / ticket, les résume (IA) et pose un libellé Gmail.
// Appels :
//  - tâche planifiée (en-tête x-pilotage-cron) : synchronisation de toutes les boîtes actives ;
//  - membre connecté : { action: 'pj', id, cle } → lien de téléchargement d'une pièce jointe (R2, 5 min) ;
//                      { action: 'etiqueter', id } → libellé « Pilotage/Classé » après un classement à la main.
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const ORIGINES = ['https://udi-pilotage.vercel.app', 'http://localhost:5173', 'http://localhost:4173']
const DOMAINE_INTERNE = /@udi-immo\.com$/i
const LIB_CLASSE = 'Pilotage/Classé', LIB_VERIFIER = 'Pilotage/À vérifier', LIB_PRIVE = 'Privé'
const MODELE = Deno.env.get('PILOTAGE_MODELE_MAILS') || 'claude-haiku-4-5-20251001'
const MAX_PJ = 15 * 1024 * 1024, BUDGET_MS = 200_000, SEUIL = 0.8

function cors(req: Request) {
  const o = req.headers.get('origin') || ''
  return { 'Access-Control-Allow-Origin': ORIGINES.includes(o) ? o : ORIGINES[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-pilotage-cron',
    'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin' }
}

// ---------- Google : jeton d'accès pour une boîte (JWT signé par le compte de service) ----------
const b64url = (b: ArrayBuffer | Uint8Array | string) => {
  const bytes = typeof b === 'string' ? new TextEncoder().encode(b) : new Uint8Array(b as ArrayBuffer)
  let s = ''; for (const x of bytes) s += String.fromCharCode(x)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}
const deB64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0))
const jetons = new Map<string, { t: string; exp: number }>()
async function jeton(boite: string): Promise<string> {
  const c = jetons.get(boite); if (c && c.exp > Date.now() + 60_000) return c.t
  const sa = JSON.parse(Deno.env.get('GOOGLE_SA_JSON') || '{}')
  if (!sa.client_email || !sa.private_key) throw new Error('Secret GOOGLE_SA_JSON absent ou incomplet')
  const der = Uint8Array.from(atob(sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s/g, '')), (c) => c.charCodeAt(0))
  const cle = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'])
  const now = Math.floor(Date.now() / 1000)
  const corps = `${b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64url(JSON.stringify({ iss: sa.client_email, sub: boite,
    scope: 'https://www.googleapis.com/auth/gmail.modify', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 }))}`
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', cle, new TextEncoder().encode(corps))
  const r = await fetch('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${corps}.${b64url(sig)}` }) })
  const j = await r.json()
  if (!r.ok) throw new Error(`Google refuse l'accès à ${boite} : ${j.error_description || j.error || r.status}`)
  jetons.set(boite, { t: j.access_token, exp: Date.now() + j.expires_in * 1000 })
  return j.access_token
}
async function gmail(boite: string, chemin: string, init: RequestInit = {}) {
  const r = await fetch(`https://gmail.googleapis.com/gmail/v1/users/me/${chemin}`, { ...init,
    headers: { Authorization: `Bearer ${await jeton(boite)}`, 'Content-Type': 'application/json', ...(init.headers || {}) } })
  if (r.status === 404) return null
  if (!r.ok) throw new Error(`Gmail ${r.status} sur ${chemin.split('?')[0]} (${boite})`)
  return r.json()
}
const libellesCache = new Map<string, Record<string, string>>()
async function libelles(boite: string): Promise<Record<string, string>> {
  if (libellesCache.has(boite)) return libellesCache.get(boite)!
  const l = await gmail(boite, 'labels'); const m: Record<string, string> = {}
  for (const x of l?.labels || []) m[x.name] = x.id
  for (const nom of [LIB_CLASSE, LIB_VERIFIER, LIB_PRIVE]) if (!m[nom]) {  // « Privé » créé aussi : chacun peut l'utiliser tout de suite
    const c = await gmail(boite, 'labels', { method: 'POST', body: JSON.stringify({ name: nom, labelListVisibility: 'labelShow', messageListVisibility: 'show' }) })
    m[nom] = c.id
  }
  libellesCache.set(boite, m); return m
}
async function etiqueter(boite: string, gmailId: string, nom: string, retirer?: string) {
  const l = await libelles(boite)
  await gmail(boite, `messages/${gmailId}/modify`, { method: 'POST', body: JSON.stringify({ addLabelIds: [l[nom]], removeLabelIds: retirer && l[retirer] ? [l[retirer]] : [] }) })
}

// ---------- Cloudflare R2 (mêmes secrets que la GED) : dépôt et lien de lecture signés (AWS SigV4) ----------
async function r2(methode: 'PUT' | 'GET', cle: string, contenu?: Uint8Array, type?: string): Promise<string | boolean> {
  const compte = Deno.env.get('R2_ACCOUNT_ID'), acces = Deno.env.get('R2_ACCESS_KEY_ID'), secret = Deno.env.get('R2_SECRET_ACCESS_KEY')
  const seau = Deno.env.get('R2_BUCKET_NAME') || 'udigestion-documents'
  if (!compte || !acces || !secret) throw new Error('Secrets R2 absents')
  const enc = new TextEncoder()
  const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b)).map((x) => x.toString(16).padStart(2, '0')).join('')
  const hmac = async (k: ArrayBuffer | Uint8Array, d: string) => crypto.subtle.sign('HMAC', await crypto.subtle.importKey('raw', k, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']), enc.encode(d))
  const hote = `${compte}.r2.cloudflarestorage.com`
  const date = new Date().toISOString().replace(/[:-]|\.\d{3}/g, ''), jour = date.slice(0, 8)
  const portee = `${jour}/auto/s3/aws4_request`
  const chemin = `/${seau}/${cle.split('/').map(encodeURIComponent).join('/')}`
  const q = new URLSearchParams({ 'X-Amz-Algorithm': 'AWS4-HMAC-SHA256', 'X-Amz-Credential': `${acces}/${portee}`, 'X-Amz-Date': date, 'X-Amz-Expires': '300', 'X-Amz-SignedHeaders': 'host' })
  const qs = q.toString().replace(/\+/g, '%20')
  const canon = [methode, chemin, qs, `host:${hote}\n`, 'host', 'UNSIGNED-PAYLOAD'].join('\n')
  const aSigner = ['AWS4-HMAC-SHA256', date, portee, hex(await crypto.subtle.digest('SHA-256', enc.encode(canon)))].join('\n')
  let k = await hmac(enc.encode(`AWS4${secret}`), jour)
  for (const x of ['auto', 's3', 'aws4_request']) k = await hmac(k, x)
  const url = `https://${hote}${chemin}?${qs}&X-Amz-Signature=${hex(await hmac(k, aSigner))}`
  if (methode === 'GET') return url
  const r = await fetch(url, { method: 'PUT', body: contenu, headers: { 'Content-Type': type || 'application/octet-stream' } })
  if (!r.ok) throw new Error(`R2 ${r.status}`)
  return true
}

// ---------- Lecture d'un message Gmail ----------
type Part = { mimeType?: string; filename?: string; body?: { data?: string; attachmentId?: string; size?: number }; parts?: Part[]; headers?: { name: string; value: string }[] }
const adresses = (v: string) => (v.match(/[A-Z0-9._%+'-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi) || []).map((x) => x.toLowerCase())
const sansHtml = (h: string) => h.replace(/<style[\s\S]*?<\/style>|<script[\s\S]*?<\/script>/gi, '').replace(/<br\s*\/?>|<\/p>|<\/div>/gi, '\n')
  .replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#39;/g, "'").replace(/&quot;/g, '"').replace(/\n{3,}/g, '\n\n').trim()
function parcourir(p: Part, texte: { plain: string; html: string }, pj: Part[]) {
  if (p.filename && p.body?.attachmentId) { pj.push(p); return }
  const d = p.body?.data ? new TextDecoder().decode(deB64url(p.body.data)) : ''
  if (p.mimeType === 'text/plain' && d) texte.plain += d + '\n'
  else if (p.mimeType === 'text/html' && d) texte.html += d
  for (const s of p.parts || []) parcourir(s, texte, pj)
}

async function resumerEtChoisir(m: { objet: string; de: string; a: string[]; corps: string; sens: string }, candidats: unknown, choisir: boolean) {
  const cleApi = Deno.env.get('ANTHROPIC_API_KEY'); if (!cleApi) return null
  const consigne = `Tu classes les mails d'une agence de gestion locative (UDI Gestion). Réponds uniquement en JSON :
{"resume": "une phrase en français, factuelle, qui dit qui demande ou annonce quoi"${choisir ? ', "lot_id": "identifiant du lot choisi parmi les candidats ou null", "ticket_id": "identifiant du ticket choisi ou null", "confiance": nombre de 0 à 1' : ''}}
${choisir ? "Choisis le lot (et le ticket si le mail en parle clairement) uniquement d'après l'adresse, le nom du locataire, le sujet. Si tu hésites, confiance basse. N'invente jamais un identifiant absent des candidats." : ''}`
  const r = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': cleApi, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: MODELE, max_tokens: 400, temperature: 0, system: consigne, messages: [{ role: 'user', content:
      `Sens : ${m.sens === 'envoye' ? "envoyé par l'agence" : "reçu par l'agence"}\nDe : ${m.de}\nÀ : ${m.a.join(', ')}\nObjet : ${m.objet}\n\n${m.corps.slice(0, 8000)}${choisir ? `\n\nCandidats :\n${JSON.stringify(candidats)}` : ''}` }] }) })
  if (!r.ok) { console.error('[pilotage-mails] IA', r.status, (await r.text()).slice(0, 200)); return null }
  const t = ((await r.json()).content || []).map((c: { text?: string }) => c.text || '').join('')
  try { return JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1)) } catch { return null }
}

async function traiterMessage(service: SupabaseClient, boite: string, id: string, prive: string | undefined) {
  const g = await gmail(boite, `messages/${id}?format=full`); if (!g) return 'disparu'
  const lab: string[] = g.labelIds || []
  if (lab.some((x) => ['DRAFT', 'SPAM', 'TRASH', 'CHAT'].includes(x)) || (prive && lab.includes(prive))) return 'exclu'
  const h = (n: string) => (g.payload?.headers || []).find((x: { name: string }) => x.name.toLowerCase() === n.toLowerCase())?.value || ''
  const messageId = h('Message-ID') || `gmail:${g.id}`
  const deja = (await service.rpc('pilotage_mails_deja_vu', { p_message_id: messageId, p_boite: boite, p_gmail: g.id })).data
  if (deja) { if (deja.statut !== 'ignore') await etiqueter(boite, g.id, deja.statut === 'classe' ? LIB_CLASSE : LIB_VERIFIER).catch(() => {}); return 'doublon' }
  const de = adresses(h('From'))[0] || '', a = adresses(h('To')), cc = adresses(h('Cc'))
  const externes = [...new Set([de, ...a, ...cc].filter((x) => x && !DOMAINE_INTERNE.test(x)))]
  if (!externes.length) return 'interne'
  const le = new Date(Number(g.internalDate)).toISOString(), objet = h('Subject')
  const texte = { plain: '', html: '' }, parts: Part[] = []
  parcourir(g.payload, texte, parts)
  const corps = (texte.plain.trim() || sansHtml(texte.html)).slice(0, 60000)
  // 146 : référence [UDI L.. T..] insérée dans le texte par le module Gmail, prise en compte comme dans l'objet
  const refCorps = /\[UDI\s+L/i.test(objet) ? null : (corps.match(/\[UDI\s+L[A-Za-z0-9-]+(?:\s+T\d+)?\]/i) || [null])[0]
  // 148 : mail envoyé — choix du dossier fait dans le module Gmail ; consommé dans tous les cas, utilisé seulement si la référence a disparu du mail
  let refChoix: string | null = null
  if (lab.includes('SENT')) {
    const { data: ch } = await service.rpc('pilotage_mails_choix_prendre', { p_boite: boite, p_le: le, p_dest: externes, p_objet: objet, p_message_id: messageId })
    if (ch && !refCorps && !/\[UDI\s+L/i.test(objet)) refChoix = ch as string
  }
  const refAjout = refCorps || refChoix
  const { data: prep, error } = await service.rpc('pilotage_mails_preparer', { p_emails: externes, p_le: le, p_objet: refAjout ? `${objet} ${refAjout}` : objet, p_thread: g.threadId })
  if (error) throw new Error(error.message)
  if (!prep?.garder) return 'hors_rivage'
  const sens = lab.includes('SENT') ? 'envoye' : 'recu'
  const pj: { nom: string; type: string; taille: number; cle?: string; omis?: string }[] = []
  for (const p of parts) {
    const nom = p.filename!, taille = p.body?.size || 0
    if (taille > MAX_PJ) { pj.push({ nom, type: p.mimeType || '', taille, omis: 'trop volumineuse (reste dans Gmail)' }); continue }
    const att = await gmail(boite, `messages/${g.id}/attachments/${p.body!.attachmentId}`)
    if (!att?.data) continue
    const cle = `mails/${le.slice(0, 7)}/${g.id}/${nom.replace(/[\\/]/g, '_')}`
    await r2('PUT', cle, deB64url(att.data), p.mimeType)
    pj.push({ nom, type: p.mimeType || '', taille, cle })
  }

  let statut = 'a_verifier', methode = prep.methode || null, confiance = prep.certain ? 1 : null
  let lot = prep.lot_id || null, ticket = prep.ticket_id || null, bail = prep.bail_id || null, mandat = prep.mandat_id || null
  const cand = (prep.candidats || []) as { lot_id: string; bail_id: string; mandat_id: string; tickets: { ticket_id: string }[] }[]
  const ia = await resumerEtChoisir({ objet, de, a, corps, sens }, cand, !prep.certain && cand.length > 0)
  if (prep.certain) statut = 'classe'
  else if (ia && cand.length) {
    const c = cand.find((x) => x.lot_id === ia.lot_id)
    if (c && Number(ia.confiance) >= SEUIL) {
      statut = 'classe'; methode = 'ia'; confiance = Number(ia.confiance)
      lot = c.lot_id; bail = c.bail_id; mandat = c.mandat_id
      ticket = (c.tickets || []).some((t) => t.ticket_id === ia.ticket_id) ? ia.ticket_id : null
    } else confiance = Number(ia?.confiance) || null
  }
  await service.rpc('pilotage_mails_enregistrer', { p: { message_id: messageId, thread_id: g.threadId, boites: { [boite]: g.id }, sens, de, a, cc, objet, le,
    extrait: g.snippet, corps, pj, parties: prep.parties, statut, methode, confiance, resume: ia?.resume || null,
    lot_id: statut === 'classe' ? lot : null, bail_id: statut === 'classe' ? bail : null, mandat_id: statut === 'classe' ? mandat : null,
    ticket_id: statut === 'classe' ? ticket : null, candidats: cand } })
  await etiqueter(boite, g.id, statut === 'classe' ? LIB_CLASSE : LIB_VERIFIER)
  return statut
}

async function synchroniser(service: SupabaseClient) {
  const debut = Date.now()
  const { data: boites } = await service.rpc('pilotage_mails_boites')
  const bilan: Record<string, unknown> = {}
  for (const b of (boites || []) as { adresse: string; history_id: string | null; import_jours: number }[]) {
    const compte: Record<string, number> = {}
    try {
      const prive = (await libelles(b.adresse))[LIB_PRIVE]
      let ids: string[] = [], nouveau: string | null = null
      if (!b.history_id) {
        nouveau = (await gmail(b.adresse, 'profile'))?.historyId
        if (b.import_jours > 0) {
          let page = ''
          do {
            const l = await gmail(b.adresse, `messages?q=${encodeURIComponent(`newer_than:${b.import_jours}d -in:chats`)}&maxResults=100${page ? '&pageToken=' + page : ''}`)
            ids.push(...(l?.messages || []).map((m: { id: string }) => m.id)); page = l?.nextPageToken || ''
          } while (page)
        }
      } else {
        let page = ''
        do {
          const h = await gmail(b.adresse, `history?startHistoryId=${b.history_id}&historyTypes=messageAdded&maxResults=500${page ? '&pageToken=' + page : ''}`)
          if (h === null) { // curseur trop ancien : reprise des 2 derniers jours
            const l = await gmail(b.adresse, `messages?q=${encodeURIComponent('newer_than:2d -in:chats')}&maxResults=200`)
            ids = (l?.messages || []).map((m: { id: string }) => m.id); nouveau = (await gmail(b.adresse, 'profile'))?.historyId; break
          }
          for (const x of h.history || []) for (const m of x.messagesAdded || []) ids.push(m.message.id)
          nouveau = h.historyId; page = h.nextPageToken || ''
        } while (page)
      }
      ids = [...new Set(ids)]
      if (!b.history_id) ids.reverse()  // reprise d'historique : du plus ancien au plus récent
      // Budget de temps par passage : si tout n'est pas traité, le curseur n'avance pas ; au passage suivant les mails déjà vus
      // (gardés ou écartés) repassent vite et le traitement reprend plus loin
      let traites = 0
      for (const id of ids) {
        if (Date.now() - debut > BUDGET_MS) break
        const r = await traiterMessage(service, b.adresse, id, prive); compte[r] = (compte[r] || 0) + 1; traites++
      }
      const reste = ids.length - traites
      if (reste > 0) nouveau = null
      await service.rpc('pilotage_mails_boite_maj', { p_adresse: b.adresse, p_history: nouveau, p_erreur: null })
      bilan[b.adresse] = { ...compte, restant: reste }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      console.error('[pilotage-mails]', b.adresse, msg)
      await service.rpc('pilotage_mails_boite_maj', { p_adresse: b.adresse, p_history: null, p_erreur: msg.slice(0, 500) })
      bilan[b.adresse] = { erreur: msg }
    }
  }
  return bilan
}

Deno.serve(async (req) => {
  const h = { ...cors(req), 'Content-Type': 'application/json' }
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: h })
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors(req) })
  if (req.method !== 'POST') return rep(405, { error: 'Méthode non autorisée' })
  const url = Deno.env.get('SUPABASE_URL')!
  const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  const cron = req.headers.get('x-pilotage-cron')
  if (cron) {
    if ((await service.rpc('pilotage_cron_valide', { p_secret: cron })).data !== true) return rep(401, { error: 'Non autorisé' })
    if (!Deno.env.get('GOOGLE_SA_JSON')) return rep(200, { ok: true, inactif: 'Secret GOOGLE_SA_JSON absent' })
    return rep(200, { ok: true, bilan: await synchroniser(service) })
  }

  const auth = req.headers.get('Authorization'); if (!auth) return rep(401, { error: 'Non connecté' })
  const utilisateur = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } })
  let c: { action?: string; id?: number; cle?: string } = {}
  try { c = await req.json() } catch { return rep(400, { error: 'Requête invalide' }) }
  try {
    // Les droits sont vérifiés en base avec la session de l'utilisateur
    if (c.action === 'pj') {
      const { data: m, error } = await utilisateur.rpc('pilotage_mail_lire', { p_id: c.id })
      if (error || !m) return rep(403, { error: error?.message || 'Accès refusé' })
      const p = (m.pj_complet || []).find((x: { cle?: string }) => x.cle && x.cle === c.cle)
      if (!p) return rep(404, { error: 'Pièce jointe introuvable' })
      return rep(200, { ok: true, url: await r2('GET', p.cle) })
    }
    if (c.action === 'etiqueter') {
      // Appel de la fonction pilotage-gmail (clé de service : droits déjà vérifiés par elle) ou d'un membre qui peut classer
      const interne = auth === `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`
      if (!interne && (await utilisateur.rpc('pilotage_mails_peut_classer')).data !== true) return rep(403, { error: 'Accès refusé' })
      const { data: x } = await service.rpc('pilotage_mail_gmail', { p_id: c.id })
      for (const [boite, gid] of Object.entries((x?.boites || {}) as Record<string, string>)) {
        await (x.statut === 'ignore' ? (async () => { const l = await libelles(boite)
            await gmail(boite, `messages/${gid}/modify`, { method: 'POST', body: JSON.stringify({ removeLabelIds: [l[LIB_CLASSE], l[LIB_VERIFIER]] }) }) })()
          : etiqueter(boite, gid, LIB_CLASSE, LIB_VERIFIER)).catch((e) => console.error('[pilotage-mails] libellé', boite, e))
      }
      return rep(200, { ok: true })
    }
  } catch (e) { return rep(500, { error: e instanceof Error ? e.message : String(e) }) }
  return rep(400, { error: 'Action inconnue' })
})
