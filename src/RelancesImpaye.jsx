// Relances automatiques des impayés (163) : bloc du dossier d'impayé (étapes du mois, pause, mise en demeure à valider)
// et aperçu du mois dans l'onglet « À faire ce mois-ci » (ce qui part, ce qui est en pause, ce qui est écarté et pourquoi).
// Décisions de Nicolas du 13/11/2026 : le pilotage relance seul (Rivage coupé), SMS et mails automatiques, mise en demeure
// validée par Audrey, calendrier serré avant la déclaration Zelok. Délais et interrupteur : Règles de relance.
import React, { useEffect, useState } from 'react';
import { supabase, rpc } from './supabase.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const euro = (n) => (n == null ? '—' : Number(n).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €');
const ORIGINE = { virement: 'virement non reçu', rejet: 'prélèvement rejeté', prelevement: 'prélèvement non encaissé' };
const MARQUE = { fait: ['fait', '✓'], sautee: ['', '–'], due: ['alerte', '!'], erreur: ['alerte', '✗'], a_venir: ['', '•'], pause: ['', '‖'], annulee: ['', '–'] };

async function erreurFonction(data, error) {
  let msg = data?.error;
  if (!msg && error?.context?.json) { try { msg = (await error.context.json()).error; } catch { /* réponse illisible */ } }
  return msg || error?.message || 'Échec';
}

function texteEtape(e) {
  const quand = e.statut === 'fait' ? `fait le ${date(e.fait_le)}` : e.statut === 'sautee' ? 'non envoyé (étape suivante déjà due)'
    : e.statut === 'erreur' ? 'non envoyé : voir l’alerte' : e.statut === 'annulee' ? 'annulé' : e.statut === 'pause' ? 'en pause'
    : e.statut === 'due' ? (e.auto ? 'part ce matin' : 'à faire depuis le ' + date(e.le)) : 'prévu le ' + date(e.le);
  return `${e.libelle}${e.auto ? '' : ' (Audrey)'} · ${quand}`;
}

// Bloc du dossier d'impayé
export function RelancesBail({ bail, apres }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [motif, setMotif] = useState('');
  const [pause, setPause] = useState(false);
  const [med, setMed] = useState(null);
  const [envoi, setEnvoi] = useState('');
  const charger = () => rpc('pilotage_relances_impaye', { p_bail: bail }).then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, [bail]);
  if (!d) return err ? <div className="err">{err}</div> : null;
  const c = d.cycle && !d.cycle.clos_le ? d.cycle : null;
  const agir = async (fn, args) => { setErr(''); try { await rpc(fn, args); setPause(false); setMotif(''); await charger(); apres && apres(); } catch (e) { setErr(e.message); } };
  const preparerMed = async () => { setErr(''); try { setMed(await rpc('pilotage_relance_impaye_med', { p_bail: bail })); } catch (e) { setErr(e.message); } };
  const envoyerMed = async () => {
    setEnvoi('Envoi…'); setErr('');
    const { data, error } = await supabase.functions.invoke('pilotage-mail', { body: { bail, to: med.to, objet: med.objet, corps: med.corps,
      cle: med.cle, etape: 'med', detail: 'Mise en demeure envoyée par mail' } });
    if (error || !data?.ok) { setEnvoi(''); setErr(await erreurFonction(data, error)); return; }
    setEnvoi('Mail envoyé. Envoie aussi la lettre recommandée avec le même texte.'); await charger(); apres && apres();
  };
  const medDue = c && (c.etapes || []).some((e) => e.etape === 'med' && e.statut === 'due');
  return <div className="panneau" style={{ margin: '10px 0' }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <b>Relances automatiques</b>
      {!d.actif && <span className="muted">désactivées (Règles de relance)</span>}
    </div>
    {err && <div className="err">{err}</div>}
    {!c && <p className="muted" style={{ margin: '4px 0' }}>{d.cycle?.clos_le ? `Dernier cycle (${date(d.cycle.j0)}) arrêté : ${d.cycle.clos_motif || 'clos'}.` : 'Aucune relance automatique en cours.'}
      {d.candidat?.motif ? ' ' + d.candidat.motif + '.' : ''}</p>}
    {c && <>
      <div className="muted" style={{ fontSize: 13 }}>Depuis le {date(c.j0)} ({ORIGINE[c.origine] || c.origine}{c.rejet_le ? ' le ' + date(c.rejet_le) : ''}), dette de départ {euro(c.dette_initiale)}.
        {c.pause_le ? ` En pause depuis le ${date(c.pause_le)}${c.pause_par ? ' (' + c.pause_par + ')' : ''} : ${c.pause_motif}.` : ''}</div>
      <ul className="etapes" style={{ flexDirection: 'column', gap: 2 }} aria-label="Étapes des relances automatiques">
        {(c.etapes || []).map((e) => { const [cl, m] = MARQUE[e.statut] || ['', '•'];
          return <li key={e.etape} className={'etape e-' + cl} title={e.detail || ''}><span className="etape-marque">{m}</span>{texteEtape(e)}</li>; })}
      </ul>
      {d.peut && <div className="row" style={{ gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
        {medDue && !med && <button className="btn plein" onClick={preparerMed}>Préparer la mise en demeure</button>}
        {c.pause_le ? <button className="btn" onClick={() => agir('pilotage_relance_impaye_pause', { p_bail: bail, p_pause: false, p_motif: null })}>Reprendre les relances</button>
          : !pause ? <button className="btn gris" onClick={() => setPause(true)}>Mettre en pause</button>
            : <><input value={motif} onChange={(e) => setMotif(e.target.value)} placeholder="Motif (plan d’apurement, erreur Rivage…)" style={{ flex: '1 1 220px' }} aria-label="Motif de la pause" />
              <button className="btn plein" disabled={!motif.trim()} onClick={() => agir('pilotage_relance_impaye_pause', { p_bail: bail, p_pause: true, p_motif: motif })}>Confirmer la pause</button>
              <button className="lien" onClick={() => setPause(false)}>Annuler</button></>}
      </div>}
      {med && <div style={{ marginTop: 10 }}>
        {(med.manquants || []).length > 0 && <div className="err">Champs non remplis : {med.manquants.join(', ')}</div>}
        <div className="muted" style={{ fontSize: 13 }}>À : {(med.to || []).join(', ') || 'aucune adresse e-mail du locataire dans Rivage'}
          {(med.garants || []).length > 0 ? ` · garant(s) : ${med.garants.map((g) => g.nom).join(', ')} (à informer par courrier, pas en copie du mail)` : ''}</div>
        <label className="champ-imp" style={{ display: 'block' }}><span>Objet</span><input value={med.objet || ''} onChange={(e) => setMed({ ...med, objet: e.target.value })} /></label>
        <textarea rows="14" style={{ width: '100%' }} value={med.corps || ''} onChange={(e) => setMed({ ...med, corps: e.target.value })} aria-label="Texte de la mise en demeure" />
        <div className="row" style={{ gap: 8 }}>
          <button className="btn plein" disabled={!!envoi || !(med.to || []).length} onClick={envoyerMed}>Envoyer le mail</button>
          <button className="btn gris" onClick={() => navigator.clipboard?.writeText(med.corps || '')}>Copier le texte (lettre recommandée)</button>
          <button className="lien" onClick={() => { setMed(null); setEnvoi(''); }}>Fermer</button>
        </div>
        {envoi && <p className="muted">{envoi}</p>}
      </div>}
    </>}
  </div>;
}

// Aperçu du mois (onglet « À faire ce mois-ci »)
// 165 (13/11, Nicolas : « on peut tout sélectionner ou juste un et envoyer les SMS, le message est éditable ») : envoi manuel des SMS de
// relance, sans attendre les relances automatiques. Texte de départ ci-dessous, modifiable avant l'envoi ; {nom} est remplacé pour chaque
// locataire, {dette}, {adresse}, {constat_sms}… pour chaque bail. Envoi par pilotage-sms (Twilio, UDI GESTION), noté dans le dossier.
const SMS_DEFAUT = 'Bonjour {nom}, {constat_sms}. Il reste {dette} à régler pour le logement {adresse}. Merci de faire le virement aujourd’hui ou de nous contacter si vous rencontrez une difficulté. UDI Gestion';

async function erreurEnvoi(data, error) { return erreurFonction(data, error); }

export function ApercuRelances() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [sel, setSel] = useState(() => new Set());
  const [texte, setTexte] = useState('');
  const [apercus, setApercus] = useState(null);
  const [etat, setEtat] = useState({});
  const [encours, setEncours] = useState(false);
  const charger = () => rpc('pilotage_relances_impayes_apercu').then(setD).catch((e) => setErr(e.message));
  useEffect(() => {
    charger();
    setTexte((t) => t || SMS_DEFAUT);   // pas le modèle automatique (J0), qui renvoie au mail envoyé en même temps
  }, []);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return null;
  const lignes = d.lignes || [];
  const enCours = lignes.filter((l) => l.cycle && !l.cycle.pause_motif);
  const pause = lignes.filter((l) => l.cycle?.pause_motif);
  const relancables = lignes.filter((l) => !l.cycle && !l.motif);
  const ecartes = lignes.filter((l) => !l.cycle && l.motif);
  const basculer = (id) => { setApercus(null); setSel((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; }); };
  const tous = (liste, oui) => { setApercus(null); setSel((s) => { const n = new Set(s); liste.forEach((l) => (oui ? n.add(l.bail_id) : n.delete(l.bail_id))); return n; }); };
  const nom = (id) => lignes.find((l) => l.bail_id === id)?.locataires || id;
  const verifier = async () => {
    setErr('');
    try { setApercus(await rpc('pilotage_relances_sms_textes', { p_baux: [...sel], p_texte: texte })); } catch (e) { setErr(e.message); }
  };
  const envoyer = async () => {
    setEncours(true); setErr('');
    const jour = new Date().toISOString().slice(0, 10);
    for (const a of apercus || []) {
      if (!a.portables || (a.manquants || []).length || etat[a.bail_id]?.ok) continue;
      setEtat((e) => ({ ...e, [a.bail_id]: { txt: 'Envoi…' } }));
      const { data, error } = await supabase.functions.invoke('pilotage-sms', { body: { bail: a.bail_id, texte: a.texte,
        cle: `rim:${a.bail_id}:${jour}`, etape: 'sms_manuel', detail: 'Relance impayé envoyée à la main' } });
      if (error || !data?.ok) { const m = await erreurEnvoi(data, error); setEtat((e) => ({ ...e, [a.bail_id]: { ko: true, txt: m } })); }
      else setEtat((e) => ({ ...e, [a.bail_id]: { ok: true, txt: `envoyé (${(data.resultats || []).filter((r) => r.ok).length} SMS)` } }));
    }
    setEncours(false);
  };
  const ligne = (l, info, cochable = true) => <label key={l.bail_id} className="row" style={{ justifyContent: 'space-between', gap: 8, padding: '3px 0', borderBottom: '1px solid var(--line)', cursor: cochable ? 'pointer' : 'default' }}>
    <span>{cochable && <input type="checkbox" checked={sel.has(l.bail_id)} onChange={() => basculer(l.bail_id)} style={{ marginRight: 6 }} aria-label={'Sélectionner ' + (l.locataires || l.bail_id)} />}
      {l.locataires || l.bail_id}{l.reference ? <span className="muted"> · bail {l.reference}</span> : null} · {euro(l.dette)} · {ORIGINE[l.origine] || l.origine}</span>
    <span className="muted" style={{ fontSize: 12, textAlign: 'right' }}>{etat[l.bail_id] ? <b style={{ color: etat[l.bail_id].ko ? 'var(--red)' : 'var(--teal)' }}>{etat[l.bail_id].txt}</b> : info}</span></label>;
  const tousCoches = (liste) => liste.length > 0 && liste.every((l) => sel.has(l.bail_id));
  const entete = (titre, liste) => <summary style={{ cursor: 'pointer' }}><b>{titre} ({liste.length})</b>
    {liste.length > 0 && <button className="lien" onClick={(e) => { e.preventDefault(); tous(liste, !tousCoches(liste)); }}>{tousCoches(liste) ? 'tout désélectionner' : 'tout sélectionner'}</button>}</summary>;
  const prets = (apercus || []).filter((a) => a.portables && !(a.manquants || []).length && !etat[a.bail_id]?.ok);
  return <section className="card" style={{ marginBottom: 14 }}>
    <h2 style={{ fontSize: 17, margin: '0 0 6px' }}>Relances des impayés</h2>
    {err && <div className="banner">{err}</div>}
    <p className="muted" style={{ margin: '0 0 6px' }}>Coche un, plusieurs ou tous les locataires, ajuste le message, puis envoie : SMS de UDI GESTION aux portables connus dans Rivage, noté dans le dossier d’impayé.
      {d.actif ? ' Relances automatiques actives en plus (chaque matin vers 9 h).' : ' Relances automatiques (sans clic) : désactivées, voir Règles de relance.'}</p>
    {enCours.length > 0 && <details open>{entete('Relances automatiques en cours', enCours)}
      {enCours.map((l) => ligne(l, l.cycle.prochaine ? `${l.cycle.prochaine.libelle} : ${l.cycle.prochaine.statut === 'erreur' ? 'non envoyé' : date(l.cycle.prochaine.le)}` : 'plus rien de prévu ce mois-ci'))}</details>}
    {pause.length > 0 && <details>{entete('En pause', pause)}{pause.map((l) => ligne(l, l.cycle.pause_motif))}</details>}
    {relancables.length > 0 && <details open>{entete('Impayés du mois', relancables)}
      {relancables.map((l) => ligne(l, 'impayé depuis le ' + date(l.j0)))}</details>}
    {ecartes.length > 0 && <details>{entete('Dettes suivies à la main (anciennes, en procédure, plus de 2 mois)', ecartes)}{ecartes.map((l) => ligne(l, l.motif))}</details>}
    {!lignes.length && <p className="muted">Aucun bail en dette au-delà du seuil.</p>}

    {sel.size > 0 && <div className="panneau" style={{ marginTop: 10, position: 'sticky', bottom: 8, zIndex: 5, background: '#fff', boxShadow: '0 -6px 20px rgba(16,24,40,.15)' }}>
      <b>SMS à {sel.size} bail{sel.size > 1 ? 'x' : ''}</b>
      <textarea rows="4" style={{ width: '100%', marginTop: 6 }} value={texte} onChange={(e) => { setTexte(e.target.value); setApercus(null); }} aria-label="Texte du SMS" />
      <div className="muted" style={{ fontSize: 12 }}>{texte.length} caractères · champs remplis pour chaque bail : {'{nom}'} (chaque locataire), {'{dette}'}, {'{adresse}'}, {'{constat_sms}'}, {'{reference}'}.</div>
      {!apercus ? <button className="btn plein" style={{ marginTop: 6 }} onClick={verifier}>Voir les SMS avant l’envoi</button> : <>
        <div className="stack" style={{ gap: 4, maxHeight: 260, overflow: 'auto', marginTop: 6 }}>
          {apercus.map((a) => <div key={a.bail_id} style={{ fontSize: 13, borderBottom: '1px solid var(--line)', padding: '4px 0' }}>
            <b>{nom(a.bail_id)}</b>{!a.portables ? <span style={{ color: 'var(--red)' }}> · aucun portable dans Rivage : pas d’envoi</span>
              : (a.manquants || []).length ? <span style={{ color: 'var(--red)' }}> · champ non rempli : {a.manquants.join(', ')}</span> : <span className="muted"> · {a.portables} portable{a.portables > 1 ? 's' : ''}</span>}
            <div className="muted">{a.texte}</div></div>)}
        </div>
        <div className="row" style={{ gap: 8, marginTop: 6 }}>
          <button className="btn plein" disabled={encours || !prets.length} onClick={envoyer}>{encours ? 'Envoi en cours…' : `Envoyer ${prets.length} SMS`}</button>
          <button className="lien" disabled={encours} onClick={() => setApercus(null)}>Modifier</button>
          <button className="lien" disabled={encours} onClick={() => { setSel(new Set()); setApercus(null); setEtat({}); charger(); }}>Terminer</button>
        </div></>}
    </div>}
  </section>;
}
