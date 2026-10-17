// Circuit de validation des mandats et des baux (036) :
//   À finaliser (le commercial complète) → En attente de validation (automatique dès que tout est complet) → Validé par la gestion.
// Un champ Rivage vide bloque jusqu'à sa correction dans Rivage ; seuls Nicolas et Romain peuvent forcer, avec une justification.
// Chaque dossier a son fil de discussion : un message peut viser une question ; une demande de correction reste à faire tant
// qu'elle n'est pas traitée, sans changer l'état du dossier.
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';
import DossierMandat from './SuiviMandat.jsx';
import { DossierBail } from './SuiviBaux.jsx';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const dateHeure = (d) => (d ? new Date(d).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—');
export const ETAT = { a_finaliser: 'À finaliser', en_attente: 'En attente de validation', valide: 'Validé', non_soumis: 'Contrôle non requis' };
const COULEUR = { a_finaliser: 'haute', en_attente: 'normale', valide: 'normale', non_soumis: 'normale' };

// ----- Liste « Mes dossiers » en tête de la journée -----
export default function MesDossiers({ moi }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [sel, setSel] = useState(null);
  const charger = () => rpc('pilotage_mes_dossiers').then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  if (err) return <div className="banner">{err}</div>;
  if (!d) return null;
  const liste = d.dossiers || [];
  if (!liste.length && !sel) return null;
  const attente = liste.filter((x) => x.etat === 'en_attente');
  const finaliser = liste.filter((x) => x.etat === 'a_finaliser');
  const gestion = !!d.gestion;
  const ouvert = sel && liste.find((x) => x.objet === sel.objet && x.id === sel.id);
  const groupe = (titre, items, aide, ouvrir = true) => items.length > 0 && <details className="replie" open={ouvrir} style={{ marginBottom: 10 }}>
    <summary style={{ cursor: 'pointer', fontWeight: 700 }}>{titre} <span className="pastille">{items.length}</span></summary>
    {aide && <div className="muted" style={{ fontSize: 12, margin: '4px 0' }}>{aide}</div>}
    <div className="stack" style={{ gap: 6, marginTop: 6 }}>{items.map((x) => <Ligne key={x.objet + x.id} x={x} gestion={gestion}
      sel={sel && sel.objet === x.objet && sel.id === x.id} choisir={() => setSel(sel && sel.id === x.id ? null : { objet: x.objet, id: x.id })} />)}</div>
  </details>;
  return <section className="card" style={{ marginBottom: 16 }}>
    <h2 style={{ fontSize: 17, margin: '0 0 8px' }}>{gestion ? 'Dossiers des commerciaux' : 'Mes dossiers à finaliser'}</h2>
    {gestion ? <>
      {groupe('À valider', attente, 'Le commercial a tout complété : vérifier les écarts et les justifications, puis valider ou lui écrire.')}
      {groupe('En cours chez le commercial', finaliser, null, !attente.length)}
    </> : <>
      {groupe('À finaliser', finaliser, 'Répondre aux questions, déposer les pièces dans Rivage et y corriger les champs vides : le dossier part seul en validation.')}
      {groupe('En attente de validation', attente, 'Plus rien à faire, sauf si la gestion vous écrit.', !finaliser.length)}
    </>}
    {ouvert && <section className="panneau" style={{ marginTop: 12 }}>
      <button className="fermer" onClick={() => setSel(null)} aria-label="Fermer le dossier">×</button>
      <Dossier x={ouvert} moi={moi} apres={charger} />
    </section>}
  </section>;
}

function Ligne({ x, gestion, sel, choisir }) {
  const vides = x.vides || [];
  return <button className={'kcarte ' + (sel ? 'sel ' : '') + (x.demandes > 0 ? 'critique' : x.etat === 'a_finaliser' ? 'haute' : 'normale')} onClick={choisir} style={{ textAlign: 'left' }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <span className="kcarte-titre">{x.objet === 'mandat' ? 'Mandat · ' : ''}{x.titre}</span>
      <span className={'sev ' + COULEUR[x.etat]}>{ETAT[x.etat]}</span>
    </div>
    <div className="muted" style={{ fontSize: 12 }}>{x.sous_titre || ''}{gestion ? ' · commercial : ' + (x.commercial || 'non attribué') : ''}</div>
    <div className="row" style={{ gap: 6, marginTop: 4, fontSize: 12 }}>
      {x.etat === 'a_finaliser' && x.restant > 0 && <span className="etq">{x.restant} point(s) à traiter</span>}
      {vides.length > 0 && <span className="etq rose" title={vides.join(', ')}>{vides.length} champ(s) vide(s) dans Rivage</span>}
      {x.force && <span className="etq violet">Forcé</span>}
      {x.demandes > 0 && <span className="etq rose">{x.demandes} demande(s) de correction</span>}
      {x.non_lus > 0 && <span className="etq ok">{x.non_lus} message(s) non lu(s)</span>}
    </div>
  </button>;
}

// Le bandeau du circuit est affiché par le dossier lui-même (mandat ou bail)
function Dossier({ x, moi, apres }) {
  return x.objet === 'mandat'
    ? <DossierMandat m={{ id: x.id }} apres={apres} />
    : <DossierBail b={x.ligne} peut moi={moi} apres={apres} />;
}

// ----- Bandeau du circuit, actions et fil de discussion (affiché en tête du dossier) -----
export function Circuit({ objet, id, apres }) {
  const [e, setE] = useState(null);
  const [err, setErr] = useState('');
  const [forcer, setForcer] = useState(null);
  const charger = () => rpc('pilotage_dossier_etat', { p_objet: objet, p_id: id }).then(setE).catch((x) => setErr(x.message));
  useEffect(() => { setE(null); charger(); }, [objet, id]);
  if (err && !e) return <div className="banner">{err}</div>;
  if (!e) return null;
  const agir = async (fn, args) => { setErr(''); try { await rpc(fn, args); await charger(); apres && apres(); } catch (x) { setErr(x.message); } };
  const vides = e.vides || [];
  return <div className={'mini-alerte ' + COULEUR[e.etat]} style={{ marginBottom: 10 }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <b>{ETAT[e.etat]}</b>
      <span className="muted" style={{ fontSize: 12 }}>Commercial : {e.commercial_prenom || 'non attribué'}</span>
    </div>
    {err && <div className="err">{err}</div>}
    {e.etat === 'a_finaliser' && <div style={{ fontSize: 13, marginTop: 4 }}>
      {e.restant > 0 && <div>{e.restant} point(s) à traiter dans le questionnaire.</div>}
      {vides.length > 0 && <div style={{ color: 'var(--red)' }}><b>Champ(s) non rempli(s) dans Rivage :</b> {vides.join(', ')}. À corriger dans Rivage : une réponse dans le pilotage ne suffit pas.</div>}
      {!e.restant && !vides.length && <div>Tout est complet.</div>}
    </div>}
    {e.etat === 'en_attente' && <div style={{ fontSize: 13, marginTop: 4 }}>{e.forcage
      ? <>Dossier <b>forcé</b> par {e.forcage.par} le {date(e.forcage.le)} : « {e.forcage.justification} ».{vides.length > 0 && <> Toujours vide dans Rivage : {vides.join(', ')}.</>}</>
      : 'Le commercial a tout complété. La gestion vérifie les écarts et les justifications, puis valide.'}</div>}
    {e.etat === 'valide' && <div style={{ fontSize: 13, marginTop: 4 }}>Validé le {date(e.valide_le)} par {e.valide_par || '—'}.</div>}
    <div className="row" style={{ marginTop: 6 }}>
      {e.peut_valider && e.etat === 'en_attente' && <button className="btn plein" onClick={() => agir('pilotage_dossier_valider', { p_objet: objet, p_id: id, p_oui: true })}>Valider le dossier</button>}
      {e.peut_valider && e.etat === 'valide' && objet === 'mandat' && <button className="btn gris" onClick={() => agir('pilotage_dossier_valider', { p_objet: objet, p_id: id, p_oui: false })}>Annuler la validation</button>}
      {e.peut_forcer && e.etat === 'a_finaliser' && forcer === null && <button className="btn" onClick={() => setForcer('')}>Forcer le dossier</button>}
      {e.peut_forcer && e.forcage && e.etat !== 'valide' && <button className="btn gris" onClick={() => agir('pilotage_dossier_lever_forcage', { p_objet: objet, p_id: id })}>Lever le forçage</button>}
    </div>
    {forcer !== null && <div style={{ marginTop: 6 }}>
      <textarea rows={2} style={{ width: '100%' }} placeholder="Justification (obligatoire) : pourquoi le dossier peut passer en validation malgré ce qui manque"
        value={forcer} onChange={(x) => setForcer(x.target.value)} />
      <div className="row"><button className="btn plein" disabled={forcer.trim().length < 10}
        onClick={async () => { await agir('pilotage_dossier_forcer', { p_objet: objet, p_id: id, p_justification: forcer }); setForcer(null); }}>Confirmer le forçage</button>
        <button className="btn gris" onClick={() => setForcer(null)}>Annuler</button></div>
      <div className="muted" style={{ fontSize: 12 }}>Le forçage est tracé ; les champs vides restent signalés jusqu’à leur correction dans Rivage.</div>
    </div>}
    <Fil objet={objet} id={id} questions={e.questions} apres={apres} />
  </div>;
}

function Fil({ objet, id, questions, apres }) {
  const [m, setM] = useState(null);
  const [texte, setTexte] = useState('');
  const [cle, setCle] = useState('');
  const [demande, setDemande] = useState(false);
  const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_dossier_fil', { p_objet: objet, p_id: id }).then(setM).catch((x) => setErr(x.message));
  useEffect(() => { setM(null); charger(); }, [objet, id]);
  const envoyer = async () => {
    setErr('');
    try { await rpc('pilotage_dossier_ecrire', { p_objet: objet, p_id: id, p_cle: cle || null, p_texte: texte, p_demande: demande }); setTexte(''); setCle(''); setDemande(false); await charger(); apres && apres(); }
    catch (x) { setErr(x.message); }
  };
  const traiter = async (msg, oui) => { try { await rpc('pilotage_dossier_message_traiter', { p_message: msg.id, p_oui: oui }); await charger(); apres && apres(); } catch (x) { setErr(x.message); } };
  if (!m) return null;
  const ouvertes = m.filter((x) => x.demande && !x.traite_le);
  return <details className="replie" open={ouvertes.length > 0} style={{ marginTop: 8 }}>
    <summary style={{ cursor: 'pointer', fontWeight: 700, fontSize: 13 }}>Échanges sur le dossier ({m.length}){ouvertes.length ? ` · ${ouvertes.length} demande(s) de correction` : ''}</summary>
    {err && <div className="err">{err}</div>}
    <div className="stack" style={{ gap: 6, marginTop: 6 }}>{m.map((x) => <div key={x.id} className={'note' + (x.moi ? ' reponse' : '')}>
      <div className="muted" style={{ fontSize: 12 }}>{x.auteur} · {dateHeure(x.le)}{x.question ? ' · sur « ' + x.question + ' »' : ''}</div>
      {x.demande && <div style={{ fontSize: 12, fontWeight: 700, color: x.traite_le ? 'var(--teal)' : 'var(--red)' }}>
        {x.traite_le ? `✓ Correction traitée (${x.traite_par || '—'}, ${date(x.traite_le)})` : 'Demande de correction à traiter'}</div>}
      <div className="note-texte">{x.texte}</div>
      {x.demande && <button className="lien" onClick={() => traiter(x, !x.traite_le)}>{x.traite_le ? 'Rouvrir' : 'Marquer comme traitée'}</button>}
    </div>)}</div>
    <div className="saisie-note" style={{ marginTop: 6 }}>
      <textarea rows={2} style={{ width: '100%' }} placeholder="Écrire au commercial ou à la gestion…" value={texte} onChange={(x) => setTexte(x.target.value)} />
      <div className="row">
        {questions?.length > 0 && <select value={cle} onChange={(x) => setCle(x.target.value)}><option value="">Question visée (facultatif)</option>
          {questions.map((q) => <option key={q.cle} value={q.cle}>{q.libelle}</option>)}</select>}
        <label className="switch"><input type="checkbox" checked={demande} onChange={(x) => setDemande(x.target.checked)} /> Demande de correction</label>
        <button className="btn plein" disabled={!texte.trim()} onClick={envoyer}>Envoyer</button>
      </div>
    </div>
  </details>;
}
