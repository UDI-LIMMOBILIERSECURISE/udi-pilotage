// Contrôle d'entrée d'un mandat de gestion (mandats depuis 2026) puis synthèse, sur le modèle des baux.
// Pièces toutes dans Rivage (reconnues par catégorie ou par nom, vérification IA en cas de doute), croisement Rivage / mandat lu
// par l'IA, équipements et compteurs par lot (repris dans le suivi des baux). Le GO reste celui du dossier complet (commission 25 %).
import React, { useEffect, useState } from 'react';
import { supabase, rpc } from './supabase.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const court = (t) => (t || '').split(' · ')[0];
const regle = (i) => i.statut === 'ok' || i.statut === 'sans_objet';
const EQUIPEMENTS = ['Chaudière gaz', 'Chaudière fioul', 'Pompe à chaleur', 'Climatisation', 'Ballon thermodynamique', 'Cheminée ou insert', 'VMC', 'Fosse septique', 'Citerne gaz', 'Adoucisseur', 'Portail ou porte de garage motorisés', 'Extincteurs'];
const COMPTEURS = ['Eau froide', 'Eau chaude', 'Chauffage', 'Électricité', 'Gaz'];
const ligne = { display: 'grid', gridTemplateColumns: 'minmax(160px, 34%) 1fr', gap: 10, padding: '4px 0', borderTop: '1px solid var(--line)', fontSize: 13 };

export default function DossierMandat({ m, apres }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [parametrer, setParametrer] = useState(false);
  const [lecture, setLecture] = useState({ charge: false, err: '' });
  const charger = () => rpc('pilotage_mandat_dossier', { p_mandat: m.id }).then(setD).catch((e) => setErr(e.message));
  useEffect(() => { setD(null); setParametrer(false); charger(); }, [m.id]);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement du contrôle…</p>;
  const c = d.controle || { items: [] };
  const agir = async (fn, args) => { setErr(''); try { await rpc(fn, args); await charger(); apres && apres(); } catch (e) { setErr(e.message); } };
  const repondre = (i, statut, commentaire) => agir('pilotage_mandat_repondre', { p_mandat: m.id, p_cle: i.cle, p_statut: statut, p_commentaire: commentaire ?? null });
  const lire = async (fichier) => {
    setLecture({ charge: true, err: '' });
    let body = { mandat_id: m.id };
    if (fichier) {
      const buf = await fichier.arrayBuffer(); let bin = ''; const u = new Uint8Array(buf);
      for (let k = 0; k < u.length; k += 0x8000) bin += String.fromCharCode.apply(null, u.subarray(k, k + 0x8000));
      body = { ...body, pdf: btoa(bin), nom: fichier.name };
    }
    const { data, error } = await supabase.functions.invoke('pilotage-lecture-bail', { body });
    if (error || data?.error) setLecture({ charge: false, err: data?.error || 'Lecture impossible pour le moment.' });
    else { setLecture({ charge: false, err: '' }); await charger(); }
  };
  const synthese = !parametrer && (!!c.go_le || !c.soumis);
  const ctx = { m, d, c, agir, repondre, lien: d.lien };
  return <>
    <div className="row" style={{ justifyContent: 'space-between', marginTop: 18 }}>
      <h3 style={{ margin: 0 }}>{synthese ? 'Synthèse du mandat' : 'Contrôle d’entrée du mandat'}</h3>
      {synthese ? <button className="btn" onClick={() => setParametrer(true)}>Modifier le paramétrage</button>
        : (c.go_le || !c.soumis) && <button className="btn plein" onClick={() => setParametrer(false)}>Retour à la synthèse</button>}
    </div>
    {err && <div className="banner">{err}</div>}
    {synthese ? <Synthese {...ctx} parametrer={() => setParametrer(true)} /> : <>
      <div className={'mini-alerte ' + (c.go_le ? 'normale' : c.restant ? 'haute' : 'normale')}>
        {c.go_le ? <>GO donné le {date(c.go_le)} par {c.go_par || '—'}</> : <>{c.restant} point(s) à traiter avant le GO{c.lecture_le ? ` · mandat lu par l’IA le ${date(c.lecture_le)}` : ''}</>}
        <div className="row" style={{ marginTop: 6 }}>
          <button className="btn" disabled={lecture.charge} onClick={() => lire(null)}>{lecture.charge ? 'Lecture en cours…' : 'Lire le mandat déposé dans Rivage (IA)'}</button>
          <label className="btn">Lire un PDF (IA)<input type="file" accept="application/pdf" hidden onChange={(e) => e.target.files[0] && lire(e.target.files[0])} /></label>
        </div>
        {lecture.err && <div className="err">{lecture.err}</div>}
        {!c.go_le && !c.restant && <div style={{ marginTop: 4 }}>Contrôle bouclé : le GO « dossier complet » peut être donné.</div>}
      </div>
      {(d.lecture?.resultat?.anomalies || []).length > 0 && <div className="resume-ia" style={{ marginTop: 8 }}>
        <span className="resume-ia-titre">✦ Lecture du mandat</span> <span className="muted">({d.lecture.source}, le {date(d.lecture.le)})</span>
        <ul style={{ margin: '4px 0', paddingLeft: 18 }}>{d.lecture.resultat.anomalies.map((x, k) => <li key={k}>{String(x)}</li>)}</ul></div>}
      <Pieces {...ctx} />
      <Croisement {...ctx} />
      <Clauses {...ctx} />
    </>}
  </>;
}

// ----- Pièces : toutes dans Rivage -----
function Pieces({ m, c, repondre, lien }) {
  const manq = c.items.filter((i) => i.bloc === 'pieces' && !regle(i));
  const faites = c.items.filter((i) => i.bloc === 'pieces' && regle(i));
  return <>
    <div className="groupe-tete" style={{ marginTop: 10 }}><b>Pièces du dossier</b></div>
    {!manq.length ? <div style={{ color: 'var(--teal)', fontSize: 13, padding: '6px 0' }}>✓ Toutes les pièces exigées sont dans Rivage.</div>
      : <div className="mini-alerte haute"><b>{manq.length} pièce(s) manquante(s)</b>
        {manq.map((i) => <div key={i.cle} className="row" style={{ justifyContent: 'space-between', borderTop: '1px solid rgba(0,0,0,.08)', padding: '5px 0', color: 'var(--ink)' }}>
          <div style={{ flex: 1, minWidth: 220 }}>{i.libelle}{i.aide && <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div>}
            {i.statut === 'anomalie' && i.commentaire && <div style={{ fontSize: 12, color: 'var(--red)' }}>{i.commentaire}</div>}</div>
          <div className="row"><a className="btn" href={lien} target="_blank" rel="noreferrer">Déposer dans Rivage ↗</a>
            <button className="lien" onClick={() => repondre(i, 'sans_objet')}>Sans objet</button></div>
        </div>)}
        <div style={{ fontSize: 12, marginTop: 4 }}>À déposer sur le mandat, le lot ou la fiche du mandant : la pièce est reconnue par sa catégorie Rivage ou par son nom (même approximatif).</div>
      </div>}
    {faites.length > 0 && <details style={{ padding: '4px 0' }}>
      <summary style={{ cursor: 'pointer', color: 'var(--muted)', fontSize: 13 }}>{faites.length} pièce(s) dans Rivage ou sans objet</summary>
      <ul style={{ margin: '4px 0', paddingLeft: 18, fontSize: 13 }}>{faites.map((i) => <li key={i.cle}>{i.libelle} · {i.repondu ? (i.statut === 'ok' ? (i.commentaire || 'reçue') : 'sans objet') + ` (${i.par || '—'}, ${date(i.le)})` : i.detail}
        {i.auto === 'ok' && i.piece?.par_nom && !i.repondu && <VerifPiece i={i} m={m} repondre={repondre} />}
        {i.repondu && <button className="lien" style={{ marginLeft: 8 }} onClick={() => repondre(i, null)}>Revenir</button>}</li>)}</ul></details>}
  </>;
}

function VerifPiece({ i, m, repondre }) {
  const [etat, setEtat] = useState({ charge: false, err: '' });
  const verifier = async () => {
    setEtat({ charge: true, err: '' });
    const { data, error } = await supabase.functions.invoke('pilotage-lecture-bail', { body: { mandat_id: m.id, upload_id: i.piece.id, piece: i.libelle } });
    if (error || data?.error) { setEtat({ charge: false, err: data?.error || 'Vérification impossible pour le moment.' }); return; }
    await repondre(i, data.conforme ? 'ok' : 'anomalie', data.conforme
      ? `Confirmé par l’IA : « ${i.piece.libelle} » est ${data.type_document || 'la pièce attendue'}${data.date ? ' du ' + date(data.date) : ''}`
      : `Selon l’IA, « ${i.piece.libelle} » n’est pas la pièce attendue : ${data.type_document || 'document différent'}${data.raison ? ' (' + data.raison + ')' : ''}`);
    setEtat({ charge: false, err: '' });
  };
  return <><button className="lien" style={{ marginLeft: 8 }} disabled={etat.charge} onClick={verifier}>{etat.charge ? 'Lecture…' : 'Vérifier avec l’IA'}</button>
    {etat.err && <span className="err" style={{ marginLeft: 8 }}>{etat.err}</span>}</>;
}

// ----- Croisement avec Rivage -----
function Croisement({ c, repondre, lien }) {
  const ouverts = c.items.filter((i) => i.bloc === 'rivage' && !regle(i)).sort((x, y) => (y.auto === 'anomalie') - (x.auto === 'anomalie'));
  const faits = c.items.filter((i) => i.bloc === 'rivage' && regle(i));
  return <>
    <div className="groupe-tete" style={{ marginTop: 10 }}><b>Croisement avec Rivage</b></div>
    {!ouverts.length && <div style={{ color: 'var(--teal)', fontSize: 13, padding: '6px 0' }}>✓ Aucun point à traiter.</div>}
    {ouverts.map((i) => <PointRivage key={i.cle} i={i} repondre={repondre} lien={lien} />)}
    {faits.length > 0 && <details style={{ borderTop: '1px solid var(--line)', padding: '6px 0' }}>
      <summary style={{ cursor: 'pointer', color: 'var(--teal)', fontSize: 13 }}>✓ {faits.length} point(s) conforme(s)</summary>
      <ul style={{ margin: '4px 0', paddingLeft: 18, fontSize: 13 }}>{faits.map((i) => <li key={i.cle}>{i.libelle} · {i.detail}
        {i.repondu && <span className="muted"> · {i.statut === 'sans_objet' ? 'sans objet' : i.auto === 'anomalie' ? 'écart justifié : ' + (i.commentaire || '—') : 'validé'} ({i.par || '—'}, {date(i.le)})</span>}
        {i.repondu && <button className="lien" style={{ marginLeft: 8 }} onClick={() => repondre(i, null)}>Revenir</button>}</li>)}</ul></details>}
  </>;
}

function PointRivage({ i, repondre, lien }) {
  const ecart = i.auto === 'anomalie';
  const [motif, setMotif] = useState(false); const [com, setCom] = useState('');
  const type = !ecart ? '' : /non renseigné/.test(i.detail || '') ? 'Non renseigné dans Rivage' : /le mandat indique/.test(i.detail || '') ? 'Écart entre le mandat et Rivage' : 'Incohérence';
  return <div style={ecart ? { borderLeft: '4px solid var(--red)', background: 'var(--red-bg)', padding: '8px 10px', margin: '6px 0', borderRadius: 6 } : { borderTop: '1px solid var(--line)', padding: '8px 0' }}>
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
      <div style={{ flex: 1, minWidth: 220 }}>
        {ecart && <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--red)', textTransform: 'uppercase' }}>⚠ {type} · à traiter</div>}
        <span style={{ fontWeight: 600 }}>{i.libelle}</span>
        {i.aide && <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div>}
        <div style={{ fontSize: 13 }}>Rivage : {i.detail}</div>
        {i.ia?.extrait && <div className="muted" style={{ fontSize: 12 }}>✦ « {i.ia.extrait} »{i.ia.page ? ` (page ${i.ia.page})` : ''}</div>}
      </div>
      <div className="row" style={{ justifyContent: 'flex-end' }}>
        {motif ? <>
          <input autoFocus placeholder="Cause de l’écart et justificatif" value={com} onChange={(e) => setCom(e.target.value)} style={{ width: 260 }} />
          <button className="btn" disabled={!com.trim()} onClick={() => repondre(i, 'ok', com.trim())}>Valider conforme</button>
          <button className="lien" onClick={() => setMotif(false)}>Annuler</button>
        </> : <>
          <a className={'btn' + (ecart ? ' plein' : '')} href={lien} target="_blank" rel="noreferrer">Corriger dans Rivage ↗</a>
          <button className="btn" onClick={() => (ecart ? setMotif(true) : repondre(i, 'ok'))}>Conforme</button>
          <button className="btn gris" onClick={() => repondre(i, 'sans_objet')}>Sans objet</button>
        </>}
      </div>
    </div>
  </div>;
}

// ----- Clauses : équipements et compteurs par lot, puis questions simples -----
function Clauses({ m, d, c, agir, repondre }) {
  const it = (cle) => c.items.find((i) => i.cle === cle);
  const autres = c.items.filter((i) => i.bloc === 'clauses' && !['m_cl_equipements', 'm_cl_compteurs'].includes(i.cle));
  return <>
    <div className="groupe-tete" style={{ marginTop: 10 }}><b>Équipements du bien et clauses</b></div>
    {['m_cl_equipements', 'm_cl_compteurs'].map((cle) => it(cle) && <Equipements key={cle} i={it(cle)} d={d} agir={agir} repondre={repondre} />)}
    {autres.map((i) => <ClauseSimple key={i.cle} i={i} repondre={repondre} />)}
  </>;
}

function Equipements({ i, d, agir, repondre }) {
  const compteur = i.cle === 'm_cl_compteurs';
  const nature = compteur ? 'compteur' : 'equipement';
  const total = d.lots.reduce((t, l) => t + l.equipements.filter((e) => e.nature === nature).length, 0);
  return <div style={{ borderTop: '1px solid var(--line)', padding: '8px 0' }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <div><span style={{ color: regle(i) ? 'var(--teal)' : 'var(--amber)', fontWeight: 700 }}>{i.statut === 'ok' ? '✓' : i.statut === 'sans_objet' ? '–' : '○'}</span> <b>{i.libelle}</b>
        <span style={{ marginLeft: 8, fontSize: 11, fontWeight: 700, color: 'var(--blue)', background: 'var(--blue-bg)', borderRadius: 10, padding: '1px 8px' }}>Suivi back-office</span>
        <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div></div>
      <div className="row">
        {i.repondu ? <><span className="muted" style={{ fontSize: 12 }}>{i.statut === 'sans_objet' ? (compteur ? 'Pas de compteurs divisionnaires' : 'Aucun équipement à entretenir') : 'Validé'} ({i.par}, {date(i.le)})</span>
          <button className="lien" onClick={() => repondre(i, null)}>Revenir</button></>
          : <><button className="btn" disabled={!total} onClick={() => repondre(i, 'ok')}>Valider la saisie</button>
            <button className="btn gris" onClick={() => repondre(i, 'sans_objet')}>{compteur ? 'Pas de compteurs divisionnaires' : 'Aucun équipement'}</button></>}
      </div>
    </div>
    {i.statut !== 'sans_objet' && d.lots.map((l) => <Lot key={l.id} l={l} nature={nature} agir={agir} />)}
  </div>;
}

function Lot({ l, nature, agir }) {
  const liste = l.equipements.filter((e) => e.nature === nature);
  // Suggestion d'après le mode de chauffage saisi dans Rivage (valeurs Rivage observées : electric ; les autres sont reconnues par mot-clé)
  const suggere = nature === 'equipement' && /gas|gaz/i.test(l.chauffage || '') && !liste.some((e) => /gaz/i.test(e.libelle)) ? 'Chaudière gaz'
    : nature === 'equipement' && /fuel|fioul|oil/i.test(l.chauffage || '') && !liste.some((e) => /fioul/i.test(e.libelle)) ? 'Chaudière fioul'
    : nature === 'equipement' && /heat_pump|pump|pompe/i.test(l.chauffage || '') && !liste.some((e) => /pompe/i.test(e.libelle)) ? 'Pompe à chaleur' : '';
  const vide = { libelle: suggere, autre: '', contrat: '', prestataire: '', dernier: '' };
  const [f, setF] = useState(vide);
  const ajouter = async () => {
    const libelle = f.libelle === 'autre' ? f.autre : f.libelle;
    await agir('pilotage_lot_equipement', { p_asset: l.id, p_id: null, p_nature: nature, p_libelle: libelle, p_contrat: f.contrat === '' ? null : f.contrat === 'oui',
      p_prestataire: f.prestataire || null, p_dernier: f.dernier || null, p_commentaire: null, p_supprimer: false });
    setF({ ...vide, libelle: '' });
  };
  return <div style={{ margin: '6px 0 6px 18px', fontSize: 13 }}>
    <div><b>Lot {l.reference || l.id}</b><span className="muted"> · {l.adresse}{l.construction ? ` · construit en ${l.construction}` : ''}{nature === 'equipement' && l.chauffage ? ` · chauffage Rivage : ${({ electric: 'électrique', gas: 'gaz', fuel: 'fioul', heat_pump: 'pompe à chaleur', wood: 'bois' })[l.chauffage] || l.chauffage}${l.chauffage_type ? ({ individual: ', individuel', collective: ', collectif' })[l.chauffage_type] || ', ' + l.chauffage_type : ''}` : ''}</span></div>
    {liste.map((e) => <div key={e.id} className="row" style={{ gap: 8 }}>
      <span>• {e.libelle}</span>
      {nature === 'equipement' && <span className="muted">{e.contrat_entretien === true ? `contrat d’entretien${e.prestataire ? ' : ' + e.prestataire : ''}` : e.contrat_entretien === false ? 'pas de contrat d’entretien' : ''}{e.dernier_entretien ? ` · dernier entretien ${date(e.dernier_entretien)}` : ''}</span>}
      <button className="lien" onClick={() => agir('pilotage_lot_equipement', { p_asset: l.id, p_id: e.id, p_nature: nature, p_libelle: e.libelle, p_contrat: null, p_prestataire: null, p_dernier: null, p_commentaire: null, p_supprimer: true })}>Retirer</button>
    </div>)}
    <div className="row" style={{ gap: 6, marginTop: 4 }}>
      <select value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} aria-label="Équipement">
        <option value="">{nature === 'equipement' ? 'Ajouter un équipement…' : 'Ajouter un compteur…'}</option>
        {(nature === 'equipement' ? EQUIPEMENTS : COMPTEURS).map((x) => <option key={x} value={x}>{x}</option>)}<option value="autre">Autre…</option></select>
      {f.libelle === 'autre' && <input placeholder="Lequel ?" value={f.autre} onChange={(e) => setF({ ...f, autre: e.target.value })} style={{ width: 140 }} />}
      {nature === 'equipement' && f.libelle && <>
        <select value={f.contrat} onChange={(e) => setF({ ...f, contrat: e.target.value })} aria-label="Contrat d’entretien"><option value="">Contrat d’entretien ?</option><option value="oui">Contrat d’entretien : oui</option><option value="non">Pas de contrat</option></select>
        {f.contrat === 'oui' && <input placeholder="Prestataire" value={f.prestataire} onChange={(e) => setF({ ...f, prestataire: e.target.value })} style={{ width: 130 }} />}
        <label className="muted">Dernier entretien <input type="date" value={f.dernier} onChange={(e) => setF({ ...f, dernier: e.target.value })} /></label></>}
      {f.libelle && <button className="btn" disabled={f.libelle === 'autre' && !f.autre.trim()} onClick={ajouter}>Ajouter</button>}
    </div>
  </div>;
}

function ClauseSimple({ i, repondre }) {
  const [v, setV] = useState('');
  const anomalies = i.cle === 'm_cl_anomalies';
  return <div className="row" style={{ justifyContent: 'space-between', borderTop: '1px solid var(--line)', padding: '8px 0' }}>
    <div style={{ flex: 1, minWidth: 220 }}><span style={{ color: regle(i) ? 'var(--teal)' : i.statut === 'anomalie' ? 'var(--red)' : 'var(--amber)', fontWeight: 700 }}>{i.statut === 'ok' ? '✓' : i.statut === 'anomalie' ? '!' : i.statut === 'sans_objet' ? '–' : '○'}</span> {i.libelle}
      {i.aide && <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div>}
      {i.ia?.valeur && !i.repondu && <div style={{ fontSize: 13, background: 'var(--blue-bg)', padding: '4px 8px', borderRadius: 6, marginTop: 4 }}>✦ Lu dans le mandat : {i.ia.valeur}{i.ia.page ? ` (page ${i.ia.page})` : ''}</div>}
      {i.repondu && <div style={{ fontSize: 13 }}>{i.commentaire || (i.statut === 'sans_objet' ? 'Sans objet' : 'Oui')} <span className="muted">({i.par}, {date(i.le)})</span></div>}</div>
    <div className="row">
      {i.repondu ? <button className="lien" onClick={() => repondre(i, null)}>Revenir</button> : <>
        <input placeholder={anomalies ? 'Anomalie relevée' : 'Ce que prévoit le mandat'} value={v} onChange={(e) => setV(e.target.value)} style={{ width: 220 }} />
        {i.ia?.valeur && !v && <button className="lien" onClick={() => setV(i.ia.valeur)}>Reprendre la lecture IA</button>}
        <button className="btn" disabled={!v.trim()} onClick={() => repondre(i, anomalies ? 'anomalie' : 'ok', v.trim())}>Enregistrer</button>
        <button className="btn gris" onClick={() => repondre(i, anomalies ? 'ok' : 'sans_objet', anomalies ? 'Aucune' : null)}>{anomalies ? 'Aucune' : 'Non prévu'}</button></>}
    </div>
  </div>;
}

// ----- Synthèse après le GO (ou mandat antérieur à 2026) -----
function Synthese({ d, c, lien, parametrer }) {
  const aRevoir = c.items.filter((i) => i.bloc === 'rivage' && !regle(i) && i.auto === 'anomalie');
  const pieces = c.items.filter((i) => i.bloc === 'pieces' && !regle(i));
  const conditions = c.items.filter((i) => i.bloc === 'rivage' && i.statut !== 'sans_objet' && i.detail);
  const clauses = c.items.filter((i) => i.bloc === 'clauses' && i.repondu && i.statut !== 'sans_objet' && !['m_cl_equipements', 'm_cl_compteurs'].includes(i.cle));
  return <>
    <div className="muted" style={{ fontSize: 12 }}>{c.go_le ? `Dossier complet validé (GO) le ${date(c.go_le)} par ${c.go_par || '—'}.` : 'Mandat antérieur à 2026 : contrôle d’entrée non requis. « Modifier le paramétrage » permet de le compléter.'}</div>
    {(aRevoir.length > 0 || pieces.length > 0) && <div className="mini-alerte haute">
      {aRevoir.length > 0 && <div><b>À revoir :</b> {aRevoir.map((i) => `${i.libelle} (${i.detail})`).join(' ; ')}</div>}
      {pieces.length > 0 && <div><b>Pièces manquantes dans Rivage :</b> {pieces.map((i) => i.libelle).join(', ')}</div>}
      <div className="row" style={{ marginTop: 6 }}><a className="btn" href={lien} target="_blank" rel="noreferrer">Corriger dans Rivage ↗</a><button className="btn gris" onClick={parametrer}>Traiter</button></div>
    </div>}
    <div style={{ marginTop: 8 }}>
      {conditions.map((i) => <div key={i.cle} style={ligne}><b>{i.libelle}</b><span>{court(i.detail)}{i.repondu && i.auto === 'anomalie' && i.statut === 'ok' && <span className="muted"> · écart justifié : {i.commentaire}</span>}</span></div>)}
      {clauses.map((i) => <div key={i.cle} style={ligne}><b>{i.libelle}</b><span>{i.statut === 'anomalie' ? '⚠ ' : ''}{i.commentaire || 'Oui'}</span></div>)}
      {d.lots.map((l) => { const eq = l.equipements.filter((e) => e.nature === 'equipement'); const co = l.equipements.filter((e) => e.nature === 'compteur');
        return <div key={l.id} style={ligne}><b>Lot {l.reference || l.id}</b><span>
          {eq.length ? eq.map((e) => e.libelle + (e.contrat_entretien ? ` (contrat${e.prestataire ? ' ' + e.prestataire : ''})` : '')).join(', ') : 'Aucun équipement saisi'}
          {co.length ? ' · compteurs divisionnaires : ' + co.map((e) => e.libelle).join(', ') : ''}</span></div>; })}
    </div>
  </>;
}
