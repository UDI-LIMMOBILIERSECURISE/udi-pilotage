// Module « Pilotage UDI » dans Gmail (146) : appelé par le module Apps Script (dossier gmail-addon/) avec le jeton d'identité Google
// de la personne (ScriptApp.getIdentityToken). Le jeton est vérifié auprès de Google (émetteur, adresse vérifiée, domaine udi-immo.com,
// destinataire = le module si GMAIL_ADDON_AUD est renseigné) ; les droits sont ensuite ceux du membre du pilotage qui a cette adresse.
// Actions : contexte (mail ouvert), chercher (lot / bail / ticket), classer (rattacher un mail à un lot, et à un ticket),
// choisir (148 : dossier choisi à la rédaction, gardé pour ranger le mail envoyé même si la référence est effacée),
// importer (148 : « Ajouter au pilotage » pour un mail arrivé avant le branchement de la boîte).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const DOMAINE = 'udi-immo.com'

async function identite(jeton: string): Promise<string> {
  const r = await fetch(`https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(jeton)}`)
  if (!r.ok) throw new Error('Jeton Google refusé')
  const t = await r.json()
  if (!['accounts.google.com', 'https://accounts.google.com'].includes(t.iss)) throw new Error('Jeton Google invalide')
  if (String(t.email_verified) !== 'true' || !t.email) throw new Error('Adresse non vérifiée')
  if (t.hd !== DOMAINE) throw new Error('Réservé aux comptes ' + DOMAINE)
  const aud = Deno.env.get('GMAIL_ADDON_AUD')
  if (aud && t.aud !== aud) throw new Error('Jeton émis pour une autre application')
  return String(t.email).toLowerCase()
}

Deno.serve(async (req) => {
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
  if (req.method !== 'POST') return rep(405, { error: 'Méthode non autorisée' })
  let c: { id_token?: string; action?: string; message_id?: string; emails?: string[]; q?: string; mail_id?: number; lot_id?: string; ticket_id?: string | null; mandat_id?: string | null; bailleur?: string | null; ref?: string; objet?: string; gmail_id?: string } = {}
  try { c = await req.json() } catch { return rep(400, { error: 'Requête invalide' }) }
  let email: string
  try { email = await identite(c.id_token || '') } catch (e) { return rep(401, { error: e instanceof Error ? e.message : 'Non autorisé' }) }
  const url = Deno.env.get('SUPABASE_URL')!, cle = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const service = createClient(url, cle)
  const appel = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await service.rpc(fn, args)
    if (error) throw new Error(error.message)
    return data
  }
  try {
    if (c.action === 'contexte')
      return rep(200, await appel('pilotage_addon_contexte', { p_email: email, p_message_id: c.message_id || '', p_emails: (c.emails || []).slice(0, 30) }))
    if (c.action === 'chercher')
      // 168 : bailleurs (tous leurs biens) et mandats en plus des lots
      return rep(200, { lots: await appel('pilotage_addon_chercher', { p_email: email, p_q: c.q || '' }),
        niveaux: await appel('pilotage_addon_chercher_niveaux', { p_email: email, p_q: c.q || '' }) })
    if (c.action === 'classer') {
      if (c.mandat_id || c.bailleur) await appel('pilotage_addon_classer_niveau', { p_email: email, p_mail: c.mail_id, p_mandat: c.mandat_id || null, p_bailleur: c.bailleur || null })
      else await appel('pilotage_addon_classer', { p_email: email, p_mail: c.mail_id, p_lot: c.lot_id, p_ticket: c.ticket_id || null })
      // Libellé Gmail « Pilotage/Classé » posé par la fonction de lecture des boîtes
      await fetch(`${url}/functions/v1/pilotage-mails`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cle}` },
        body: JSON.stringify({ action: 'etiqueter', id: c.mail_id }) }).catch(() => {})
      return rep(200, { ok: true })
    }
    if (c.action === 'importer') {
      // 148 : mail arrivé avant le branchement de la boîte — lu et rangé à la demande, dans la boîte de la personne
      if (!(await appel('pilotage_mails_boite_active', { p_boite: email }))) return rep(400, { error: 'Votre boîte n\'est pas branchée au pilotage' })
      const r = await fetch(`${url}/functions/v1/pilotage-mails`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cle}` },
        body: JSON.stringify({ action: 'importer', boite: email, gmail_id: c.gmail_id || '' }) })
      const j = await r.json().catch(() => ({}))
      return rep(r.ok ? 200 : 400, j)
    }
    if (c.action === 'choisir') {
      await appel('pilotage_addon_choisir', { p_email: email, p_ref: c.ref || '', p_dest: (c.emails || []).slice(0, 50), p_objet: c.objet || '' })
      return rep(200, { ok: true })
    }
    return rep(400, { error: 'Action inconnue' })
  } catch (e) { return rep(400, { error: e instanceof Error ? e.message : String(e) }) }
})
