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
export function ApercuRelances() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => { rpc('pilotage_relances_impayes_apercu').then(setD).catch((e) => setErr(e.message)); }, []);
  if (err) return <div className="banner">{err}</div>;
  if (!d) return null;
  const lignes = d.lignes || [];
  const enCours = lignes.filter((l) => l.cycle && !l.cycle.pause_motif);
  const pause = lignes.filter((l) => l.cycle?.pause_motif);
  const relancables = lignes.filter((l) => !l.cycle && !l.motif);
  const ecartes = lignes.filter((l) => !l.cycle && l.motif);
  const ligne = (l, info) => <div key={l.bail_id} className="row" style={{ justifyContent: 'space-between', gap: 8, padding: '3px 0', borderBottom: '1px solid var(--line)' }}>
    <span>{l.locataires || l.bail_id}{l.reference ? <span className="muted"> · bail {l.reference}</span> : null} · {euro(l.dette)} · {ORIGINE[l.origine] || l.origine}</span>
    <span className="muted" style={{ fontSize: 12, textAlign: 'right' }}>{info}</span></div>;
  return <section className="card" style={{ marginBottom: 14 }}>
    <h2 style={{ fontSize: 17, margin: '0 0 6px' }}>Relances automatiques</h2>
    {!d.actif && <div className="mini-alerte normale">Désactivées : rien ne part. Pour les lancer, activer « Relances automatiques des impayés » dans Règles de relance, après avoir coupé les relances d’impayés dans Rivage. Seuls les impayés détectés à partir de ce jour-là seront relancés.</div>}
    {d.actif && <p className="muted" style={{ margin: '0 0 6px' }}>Chaque matin vers 9 h : SMS et mails selon le calendrier du mois ; appels et mise en demeure dans Ma journée d’Audrey.</p>}
    {enCours.length > 0 && <details open><summary><b>En cours ({enCours.length})</b></summary>
      {enCours.map((l) => ligne(l, l.cycle.prochaine ? `${l.cycle.prochaine.libelle} : ${l.cycle.prochaine.statut === 'erreur' ? 'non envoyé' : date(l.cycle.prochaine.le)}` : 'plus rien de prévu ce mois-ci'))}</details>}
    {pause.length > 0 && <details><summary><b>En pause ({pause.length})</b></summary>{pause.map((l) => ligne(l, l.cycle.pause_motif))}</details>}
    {relancables.length > 0 && <details open={!d.actif}><summary><b>{d.actif ? 'En dette, sans relance automatique ce mois-ci' : 'Seraient relancés si les relances étaient actives'} ({relancables.length})</b></summary>
      {relancables.map((l) => ligne(l, 'premier envoi au ' + date(l.j0)))}</details>}
    {ecartes.length > 0 && <details><summary><b>Écartés, suivis à la main ({ecartes.length})</b></summary>{ecartes.map((l) => ligne(l, l.motif))}</details>}
    {!lignes.length && <p className="muted">Aucun bail en dette au-delà du seuil.</p>}
  </section>;
}
