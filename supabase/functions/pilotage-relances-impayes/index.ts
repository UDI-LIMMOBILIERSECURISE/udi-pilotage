// Relances automatiques des impayés (163) : appelée chaque matin par la tâche planifiée « pilotage-relances-impayes ».
// La base décide de tout (pilotage_relances_impayes_preparer : cycles du mois, étape due, textes, adresses Rivage, trace) ;
// la fonction ne fait que transmettre aux Zaps déjà en place et noter le résultat :
//  - SMS : secret ZAPIER_SMS_WEBHOOK → Twilio « Send SMS », expéditeur UDI GESTION (comme pilotage-sms) ;
//  - mails : secret ZAPIER_MAIL_WEBHOOK → Gmail « Send Email » depuis votregestionnaire@udi-immo.com (comme pilotage-mail).
// Rien ne part tant que la règle « Relances automatiques des impayés » est désactivée dans Règles de relance.
// Appel accepté seulement avec l'en-tête x-pilotage-cron (secret pilotage_cron_secret du coffre, vérifié en base).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const EXPEDITEUR = 'votregestionnaire@udi-immo.com'
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'Méthode non autorisée' })
  const service = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const cron = req.headers.get('x-pilotage-cron')
  if (!cron || (await service.rpc('pilotage_cron_valide', { p_secret: cron })).data !== true) return json(401, { error: 'Non autorisé' })

  const smsHook = Deno.env.get('ZAPIER_SMS_WEBHOOK') || ''
  const mailHook = Deno.env.get('ZAPIER_MAIL_WEBHOOK') || ''
  if (!/^https:\/\/hooks\.zapier\.com\//.test(smsHook) || !/^https:\/\/hooks\.zapier\.com\//.test(mailHook)) {
    return json(503, { error: 'Secrets ZAPIER_SMS_WEBHOOK ou ZAPIER_MAIL_WEBHOOK absents : aucun envoi' })
  }

  const { data: lot, error } = await service.rpc('pilotage_relances_impayes_preparer')
  if (error) return json(500, { error: error.message })
  if (!lot?.actif) return json(200, { ok: true, actif: false })

  const envoyer = async (hook: string, corps: unknown) => {
    try {
      const r = await fetch(hook, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corps) })
      return { ok: r.ok, erreur: r.ok ? null : `Zapier HTTP ${r.status}` }
    } catch (x) { return { ok: false, erreur: x instanceof Error ? x.message : String(x) } }
  }

  let smsOk = 0, smsKo = 0, mailOk = 0, mailKo = 0
  for (const s of (lot.sms || []) as { id: number; telephone: string; texte: string; nom: string; bail: string }[]) {
    const r = await envoyer(smsHook, { to: s.telephone, message: s.texte, nom: s.nom, bail: s.bail, envoi: s.id })
    await service.rpc('pilotage_sms_resultat', { p_id: s.id, p_ok: r.ok, p_erreur: r.erreur, p_detail: 'Relance automatique (SMS)' })
    if (r.ok) smsOk++; else smsKo++
  }
  for (const m of (lot.mails || []) as { id: number; to: string[]; objet: string; corps: string; bail: string }[]) {
    const r = await envoyer(mailHook, { from: EXPEDITEUR, to: m.to.join(','), subject: m.objet, body: m.corps, bail: m.bail, envoi: m.id })
    await service.rpc('pilotage_mail_resultat', { p_id: m.id, p_ok: r.ok, p_erreur: r.erreur, p_detail: 'Relance automatique (mail)' })
    if (r.ok) mailOk++; else mailKo++
  }
  return json(200, { ok: true, actif: true, nouveaux: lot.nouveaux, sms: { envoyes: smsOk, erreurs: smsKo }, mails: { envoyes: mailOk, erreurs: mailKo } })
})
