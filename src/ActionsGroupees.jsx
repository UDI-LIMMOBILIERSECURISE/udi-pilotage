// Actions groupées de Ma journée (142) : alertes cochées en masse, puis envoi des relances prévues (mail automatique depuis
// votregestionnaire@udi-immo.com ou SMS UDI GESTION) et/ou « Traité ». Chaque relance est relue avant l'envoi et peut être décochée.
// Les recommandés (LRAR) ne partent jamais en masse : ils restent à faire depuis la fiche du bail.
import React, { useEffect, useState } from 'react';
import { supabase, rpc } from './supabase.js';
import { preparer, SMS, avecMentionRgpd } from './mails.js';
import { chargerModeles, texteSmsGestion } from './messages.js';

export const REGLES_RELANCE = ['bail_suivi', 'bail_suivi_retard'];
const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '');

async function erreurFonction(data, error) {
  let msg = data?.error;
  if (!msg && error?.context?.json) { try { msg = (await error.context.json()).error; } catch { /* réponse illisible */ } }
  return msg || error?.message || 'Échec';
}

// Relances prévues aujourd'hui sur les baux des alertes cochées
async function preparerRelances(alertes) {
  const [moi, sess, mod] = await Promise.all([rpc('pilotage_moi').catch(() => ({})), supabase.auth.getSession(), chargerModeles().catch(() => null)]);
  const modeles = mod?.modeles || [];
  const ctxMoi = { prenom: moi?.prenom || '', email: sess?.data?.session?.user?.email || '' };
  const baux = [...new Map(alertes.filter((a) => REGLES_RELANCE.includes(a.regle) && a.objet_type === 'LeasingContract').map((a) => [a.objet_id, a])).values()];
  const lignes = [];
  for (const a of baux) {
    let d;
    try { d = await rpc('pilotage_bail_dossier', { p_bail: a.objet_id }); } catch (e) { lignes.push({ cle: a.objet_id, a, erreur: e.message }); continue; }
    const b = { bail_id: a.objet_id, reference: a.dossier?.ref, locataires: a.dossier?.locataires, adresse: a.dossier?.adresse, bailleur: a.bailleur };
    const ctx = { bail: b, fiche: d.fiche || {}, ech: d.echeance || {}, contacts: d.contacts || {}, moi: ctxMoi };
    // En retard alors que toutes les relances prévues sont faites : rien à envoyer, on le dit au lieu d'une fenêtre vide
    for (const ob of (d.obligations || []).filter((o) => o.actif && !o.a_faire && o.en_retard)) {
      const faites = (ob.etapes || []).filter((e) => e.fait_le);
      const der = faites.length ? date(faites.map((e) => e.fait_le).sort().pop()) : null;
      lignes.push({ cle: ob.cle + ':info', a, b, ob, canal: 'info', titre: ob.libelle + ' : en retard',
        manuel: ob.suivante ? `Prochaine relance prévue le ${date(ob.suivante.date)} (${ob.suivante.libelle})`
          : `Toutes les relances prévues sont faites${der ? ' (dernière le ' + der + ')' : ''} : il reste à obtenir le justificatif et le déposer dans la fiche du bail, ou à décider de la suite avec le bailleur. Rien à envoyer.` });
    }
    for (const ob of (d.obligations || []).filter((o) => o.actif && o.a_faire)) {
      const f = ob.a_faire;
      const base = { cle: ob.cle + ':' + f.ordre, a, b, ob, etape: { cle: ob.cle, etape: String(f.ordre), detail: f.libelle } };
      if (f.canal === 'lrar') { lignes.push({ ...base, canal: 'lrar', manuel: 'Recommandé : à envoyer depuis la fiche du bail' }); continue; }
      if (['sms', 'sms_rivage'].includes(f.canal)) {
        const texte = texteSmsGestion(modeles, f.modele, { '{date_echeance}': date(ob.prochaine) }) ?? SMS[f.modele]?.({ ...ctx, ob });
        const tels = (d.contacts?.locataires || []).map((l) => l.telephone).filter(Boolean);
        lignes.push({ ...base, canal: 'sms', texte, dest: tels.join(', '), coche: !!texte && tels.length > 0, manuel: !tels.length ? 'Aucun portable du locataire dans Rivage' : !texte ? 'Modèle de SMS introuvable' : null });
        continue;
      }
      const m = f.modele ? preparer(f.modele, { ...ctx, ob }) : null;
      lignes.push({ ...base, canal: 'mail', mail: m, dest: (m?.to || []).join(', '), coche: !!m && (m.to || []).length > 0,
        manuel: !m ? 'Modèle de mail introuvable' : !(m.to || []).length ? `Aucune adresse e-mail du ${m.dest} dans Rivage` : null });
    }
  }
  return lignes;
}

export function EnvoiGroupe({ alertes, fermer, apres }) {
  const [lignes, setLignes] = useState(null);
  const [err, setErr] = useState('');
  const [encours, setEncours] = useState(false);
  const [ouverte, setOuverte] = useState(null);
  useEffect(() => { preparerRelances(alertes).then(setLignes).catch((e) => setErr(e.message)); }, []);
  const maj = (cle, x) => setLignes((l) => l.map((y) => (y.cle === cle ? { ...y, ...x } : y)));
  const aEnvoyer = (lignes || []).filter((l) => l.coche && !l.manuel && !l.ok);
  const envoyer = async () => {
    setEncours(true); setErr('');
    for (const l of aEnvoyer) {
      maj(l.cle, { etat: 'Envoi…' });
      const corps = l.canal === 'sms'
        ? { fn: 'pilotage-sms', body: { bail: l.b.bail_id, texte: l.texte, ...l.etape } }
        : { fn: 'pilotage-mail', body: { bail: l.b.bail_id, to: l.mail.to, objet: l.mail.objet, corps: avecMentionRgpd(l.mail.corps), ...l.etape } };
      const { data, error } = await supabase.functions.invoke(corps.fn, { body: corps.body });
      if (error || !data?.ok) maj(l.cle, { etat: null, echec: await erreurFonction(data, error) });
      else maj(l.cle, { etat: null, ok: true, echec: null });
    }
    setEncours(false);
    apres && apres();
  };
  return <div className="modale-fond" role="dialog" aria-modal="true" aria-label="Envoi groupé des relances">
    <div className="modale">
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h2 style={{ margin: 0, fontSize: 18 }}>Relances prévues sur {new Set(alertes.filter((a) => REGLES_RELANCE.includes(a.regle)).map((a) => a.objet_id)).size} bail(s)</h2>
        <button className="btn gris" onClick={fermer}>Fermer</button>
      </div>
      <p className="muted" style={{ margin: '6px 0 12px' }}>Mails envoyés depuis votregestionnaire@udi-immo.com, SMS depuis UDI GESTION. Décochez ce qui ne doit pas partir ; un clic sur une ligne montre le texte. Chaque envoi réussi marque l’étape faite.</p>
      {err && <div className="banner">{err}</div>}
      {!lignes ? <p className="muted">Préparation des relances…</p> : !lignes.length ? <p>Rien à envoyer aujourd’hui sur ces baux : la relance du jour est déjà faite, ou la prochaine étape tombe plus tard (elle est visible dans la fiche du bail).</p> :
        <div className="stack" style={{ gap: 6, maxHeight: '55vh', overflow: 'auto' }}>
          {lignes.map((l) => <div key={l.cle} className={'eg-ligne' + (l.ok ? ' ok' : l.echec ? ' ko' : '')}>
            <div className="row" style={{ gap: 8, alignItems: 'flex-start', flexWrap: 'nowrap' }}>
              {l.canal !== 'info' && <input type="checkbox" aria-label="Envoyer cette relance" checked={!!l.coche && !l.manuel} disabled={!!l.manuel || l.ok || encours}
                onChange={(e) => maj(l.cle, { coche: e.target.checked })} style={{ marginTop: 4 }} />}
              <button className="eg-texte" onClick={() => setOuverte(ouverte === l.cle ? null : l.cle)} aria-expanded={ouverte === l.cle}>
                <b>{l.canal === 'info' ? 'À suivre · ' + l.titre : `${l.canal === 'sms' ? 'SMS' : l.canal === 'mail' ? 'Mail' : 'Recommandé'} · ${l.ob?.a_faire?.libelle || l.ob?.libelle}`}</b>
                <span className="muted">Bail {l.b?.reference || '?'} · {l.b?.locataires || ''}{l.dest ? ' · à ' + l.dest : ''}</span>
                {l.manuel && <span className="muted" style={l.canal === 'info' ? {} : { color: 'var(--red)' }}>{l.manuel}</span>}
                {l.erreur && <span style={{ color: 'var(--red)' }}>{l.erreur}</span>}
              </button>
              <span style={{ flex: 'none', fontSize: 13 }}>{l.etat || (l.ok ? 'Envoyé ✓' : '')}</span>
            </div>
            {l.echec && <div className="err">{l.echec}</div>}
            {ouverte === l.cle && (l.canal === 'sms'
              ? <textarea rows={3} style={{ width: '100%', marginTop: 6 }} value={l.texte || ''} disabled={l.ok} onChange={(e) => maj(l.cle, { texte: e.target.value })} />
              : l.mail && <div style={{ marginTop: 6 }}>
                <input style={{ width: '100%' }} value={l.mail.objet} disabled={l.ok} onChange={(e) => maj(l.cle, { mail: { ...l.mail, objet: e.target.value } })} aria-label="Objet" />
                <textarea rows={8} style={{ width: '100%', marginTop: 4 }} value={l.mail.corps} disabled={l.ok} onChange={(e) => maj(l.cle, { mail: { ...l.mail, corps: e.target.value } })} aria-label="Texte" />
              </div>)}
          </div>)}
        </div>}
      {lignes && lignes.some((l) => l.ok || l.echec) && !encours && (() => {
        const ok = lignes.filter((l) => l.ok).length, ko = lignes.filter((l) => l.echec && !l.ok).length;
        return <div className={ko ? 'banner' : 'eg-bilan'} role="status" style={{ marginTop: 12 }}>
          {ok} relance{ok > 1 ? 's' : ''} envoyée{ok > 1 ? 's' : ''}{ko ? ` · ${ko} en échec (en rouge ci-dessus, vous pouvez réessayer)` : ' · les étapes sont marquées faites dans le suivi des baux'}
        </div>;
      })()}
      <div className="row" style={{ marginTop: 12, justifyContent: 'flex-end' }}>
        <button className="btn plein" disabled={encours || !aEnvoyer.length} onClick={envoyer}>{encours ? 'Envoi en cours…' : `Envoyer ${aEnvoyer.length} relance${aEnvoyer.length > 1 ? 's' : ''}`}</button>
      </div>
    </div>
  </div>;
}
