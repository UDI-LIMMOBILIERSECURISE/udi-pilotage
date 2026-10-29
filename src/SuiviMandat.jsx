// Contrôle d'entrée d'un mandat de gestion (mandats depuis 2026) puis synthèse, sur le modèle des baux.
// Pièces toutes dans Rivage (reconnues par catégorie ou par nom, vérification IA en cas de doute), croisement Rivage / mandat lu
// par l'IA, équipements et compteurs par lot (repris dans le suivi des baux). Le GO reste celui du dossier complet (commission 25 %).
import React, { useEffect, useState } from 'react';
import { supabase, rpc } from './supabase.js';
import { preparer } from './mails.js';
import { EditeurMail, useFournisseurs, FOURNI_PAR } from './SuiviBaux.jsx';
import { Circuit } from './Circuit.jsx';
import MessagesDossier from './MessagesDossier.jsx';
import OrduresLots, { useOrdures } from './Ordures.jsx';
import PermisMandat from './Permis.jsx';

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
  const [auto, setAuto] = useState(null); // lecture IA lancée d'office à l'ouverture d'un mandat soumis encore jamais lu (036)
  // Propositions de l'IA tirées des états des lieux (037), rangées dans le dossier sous d.propositions
  const charger = () => Promise.all([rpc('pilotage_mandat_dossier', { p_mandat: m.id }), rpc('pilotage_mandat_propositions', { p_mandat: m.id }).catch(() => [])])
    .then(([x, p]) => setD({ ...x, propositions: p || [] })).catch((e) => setErr(e.message));
  useEffect(() => { setD(null); setParametrer(false); setAuto(null); charger(); }, [m.id]);
  useEffect(() => {
    const c0 = d?.controle;
    if (!c0 || !c0.soumis || c0.lecture_le || auto === m.id) return;
    setAuto(m.id);
    setLecture({ charge: true, err: '' });
    supabase.functions.invoke('pilotage-lecture-bail', { body: { mandat_id: m.id } }).then(({ data, error }) => {
      // Pas de mandat dans Rivage : pas d'erreur affichée, la pièce manquante est déjà signalée
      setLecture({ charge: false, err: '' });
      if (!error && !data?.error) charger();
    });
  }, [d]);
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
  const ctx = { m, d, c, agir, repondre, lien: d.lien, recharger: async () => { await charger(); apres && apres(); }, onErreur: setErr };
  return <>
    <div className="row" style={{ justifyContent: 'space-between', marginTop: 18 }}>
      <h3 style={{ margin: 0 }}>{synthese ? 'Synthèse du mandat' : 'Contrôle d’entrée du mandat'}</h3>
      {synthese ? <button className="btn" onClick={() => setParametrer(true)}>Modifier le paramétrage</button>
        : (c.go_le || !c.soumis) && <button className="btn plein" onClick={() => setParametrer(false)}>Retour à la synthèse</button>}
    </div>
    {err && <div className="banner">{err}</div>}
    {c.soumis && <Circuit objet="mandat" id={m.id} apres={async () => { await charger(); apres && apres(); }} />}
    <DeposerRivage cible_type="ManagementContract" cible_id={m.id} apres={async () => { await charger(); apres && apres(); }} />
    <MessagesDossier objet="mandat" id={m.id} apres={apres} />
    {synthese ? <Synthese {...ctx} parametrer={() => setParametrer(true)} /> : <>
      <div className={'mini-alerte ' + (c.go_le ? 'normale' : c.restant ? 'haute' : 'normale')}>
        {c.go_le ? <>GO donné le {date(c.go_le)} par {c.go_par || '—'}</> : <>{c.restant} point(s) à traiter avant la validation{c.lecture_le ? ` · mandat lu par l’IA le ${date(c.lecture_le)}` : lecture.charge ? ' · lecture du mandat par l’IA en cours…' : ''}</>}
        <div className="row" style={{ marginTop: 6 }}>
          {/* Mandat lu une seule fois : plus de bouton de lecture une fois la lecture enregistrée */}
          {!c.lecture_le && !d.lecture && <button className="btn" disabled={lecture.charge} onClick={() => lire(null)}>{lecture.charge ? 'Lecture en cours…' : 'Lire le mandat déposé dans Rivage (IA)'}</button>}
          {!c.lecture_le && !d.lecture && <label className="btn">Lire un PDF (IA)<input type="file" accept="application/pdf" hidden onChange={(e) => e.target.files[0] && lire(e.target.files[0])} /></label>}
        </div>
        {lecture.err && <div className="err">{lecture.err}</div>}
        {!c.go_le && !c.restant && <div style={{ marginTop: 4 }}>Questionnaire bouclé.</div>}
      </div>
      {(d.lecture?.resultat?.anomalies || []).length > 0 && <div className="resume-ia" style={{ marginTop: 8 }}>
        <span className="resume-ia-titre">✦ Lecture du mandat</span> <span className="muted">({d.lecture.source}, le {date(d.lecture.le)})</span>
        <ul style={{ margin: '4px 0', paddingLeft: 18 }}>{d.lecture.resultat.anomalies.map((x, k) => <li key={k}>{String(x)}</li>)}</ul></div>}
      <Pieces {...ctx} />
      <Croisement {...ctx} />
      <Clauses {...ctx} />
    </>}
    <Immeubles m={m} onErreur={setErr} apres={async () => { await charger(); apres && apres(); }} />
    <PermisMandat m={m} onErreur={setErr} />
    <SuivisMandat m={m} d={d} agir={agir} />
  </>;
}

// ----- Immeubles du mandat (groupe « immeuble » dans Rivage, monopropriété gérée en entier) : contrats communs et assurance (037) -----
const EQUIPEMENTS_IMMEUBLE = ['Chaudière collective', 'Ascenseur', 'VMC', 'Extincteurs', 'Porte de garage motorisée', 'Portail motorisé', 'Nettoyage des parties communes', 'Désenfumage', 'Interphone ou digicode'];
function Immeubles({ m, onErreur, apres }) {
  const [liste, setListe] = useState(null);
  const charger = () => rpc('pilotage_mandat_immeubles', { p_mandat: m.id }).then(setListe).catch(() => setListe([]));
  useEffect(() => { charger(); }, [m.id]);
  if (!liste?.length) return null;
  const agir = async (fn, args) => { try { await rpc(fn, args); await charger(); apres && apres(); } catch (e) { onErreur(e.message); } };
  return <>
    <div className="groupe-tete" style={{ marginTop: 14 }}><b>Immeuble{liste.length > 1 ? 's' : ''} géré{liste.length > 1 ? 's' : ''} en entier</b></div>
    {liste.map((g) => <div key={g.id} style={{ borderTop: '1px solid var(--line)', padding: '8px 0' }}>
      <b>{g.nom || 'Immeuble'}</b><span className="muted" style={{ fontSize: 13 }}> · {g.lots.length ? 'lots ' + g.lots.join(', ') : 'aucun lot rattaché dans Rivage'}</span>
      <AssuranceImmeuble m={m} g={g} agir={agir} />
      <Lot l={{ id: g.id, reference: g.nom, adresse: 'équipements et contrats communs', equipements: g.equipements }} nature="equipement" agir={agir} choix={EQUIPEMENTS_IMMEUBLE} titre="Contrats d’entretien de l’immeuble" />
      <div className="muted" style={{ fontSize: 12, marginLeft: 18 }}>Chaque équipement crée son suivi d’entretien annuel ; un ascenseur ajoute son contrôle technique tous les 5 ans.</div>
    </div>)}
  </>;
}

function AssuranceImmeuble({ m, g, agir }) {
  const [v, setV] = useState('');
  return <div className="row" style={{ margin: '4px 0 4px 18px', fontSize: 13 }}>
    {g.assurance ? <span>Assurance de l’immeuble : échéance le {date(g.assurance.prochaine)} (suivi annuel)</span>
      : <span style={{ color: 'var(--amber)' }}>Assurance de l’immeuble : échéance à saisir</span>}
    <label className="muted">{g.assurance ? 'Modifier' : 'Échéance'} <input type="date" value={v} onChange={(e) => setV(e.target.value)} /></label>
    {v && <button className="btn" onClick={async () => { await agir('pilotage_immeuble_assurance', { p_mandat: m.id, p_immeuble: g.id, p_echeance: v }); setV(''); }}>Enregistrer</button>}
  </div>;
}

// Libellés des pièces encore manquantes (ni reçues ni sans objet) à fournir par le bailleur, repris dans ses mails (063, 064)
const piecesManquantes = (d, fourn = {}) => ((d.controle || {}).items || []).filter((i) => i.bloc === 'pieces' && !regle(i) && (fourn[i.cle] || 'bailleur') === 'bailleur').map((i) => i.libelle);

// ----- Pièces : toutes dans Rivage -----
function Pieces({ m, d, c, repondre, lien, recharger, onErreur }) {
  const fourn = useFournisseurs();
  const manq = c.items.filter((i) => i.bloc === 'pieces' && !regle(i));
  const faites = c.items.filter((i) => i.bloc === 'pieces' && regle(i));
  return <>
    <div className="groupe-tete" style={{ marginTop: 10 }}><b>Pièces du dossier</b></div>
    {piecesManquantes(d, fourn).length > 0 && <DemandePieces m={m} d={d} fourn={fourn} recharger={recharger} onErreur={onErreur} />}
    {!manq.length ? <div style={{ color: 'var(--teal)', fontSize: 13, padding: '6px 0' }}>✓ Toutes les pièces exigées sont dans Rivage.</div>
      : <div className="mini-alerte haute"><b>{manq.length} pièce(s) manquante(s)</b>
        {manq.map((i) => <div key={i.cle} className="row" style={{ justifyContent: 'space-between', borderTop: '1px solid rgba(0,0,0,.08)', padding: '5px 0', color: 'var(--ink)' }}>
          <div style={{ flex: 1, minWidth: 220 }}>{i.libelle} <span className="muted" style={{ fontSize: 12 }}>· {FOURNI_PAR[fourn[i.cle] || 'bailleur']}</span>{i.aide && <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div>}
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

// Demande des pièces manquantes au bailleur (063) : brouillon Gmail, puis suivi de relances (J+7, J+14, appel à J+21)
function DemandePieces({ m, d, fourn, recharger, onErreur }) {
  const [mail, setMail] = useState(null);
  const [moi, setMoi] = useState({ prenom: '', email: '' });
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setMoi((x) => ({ ...x, email: data?.session?.user?.email || '' })));
    rpc('pilotage_moi').then((x) => setMoi((y) => ({ ...y, prenom: x?.prenom || '' }))).catch(() => {});
  }, []);
  const ob = (d.obligations || []).find((o) => o.nature === 'mandat_pieces' && o.actif);
  const adresse = (d.lots[0] || {}).adresse || 'votre bien';
  const preparerMail = (o, modele, etape, detail) => {
    const x = preparer(modele, { bail: { adresse }, ob: o, contacts: d.contacts, mandat: d.mandat, moi, manquants: piecesManquantes(d, fourn) });
    if (x) setMail({ m: x, etape: { cle: o.cle, etape, detail } });
  };
  const demander = async () => {
    try { const o = await rpc('pilotage_mandat_pieces_demander', { p_mandat: m.id }); preparerMail(o, 'mandat_pieces', '1', 'Pièces demandées au bailleur'); }
    catch (e) { onErreur(e.message); }
  };
  const envoye = async () => {
    try { await rpc('pilotage_mandat_pieces_envoye', { p_mandat: m.id, p_etape: mail.etape.etape, p_detail: mail.etape.detail }); setMail(null); await recharger(); }
    catch (e) { onErreur(e.message); }
  };
  const premier = ob && (ob.etapes || []).find((e) => e.ordre === 1);
  return <div style={{ margin: '6px 0' }}>
    <div className="row" style={{ gap: 8 }}>
      {!ob || !premier?.fait_le
        ? <button className="btn plein" onClick={() => (ob ? preparerMail(ob, 'mandat_pieces', '1', 'Pièces demandées au bailleur') : demander())}>Demander les pièces au bailleur (mail)</button>
        : <span style={{ fontSize: 13 }}>Pièces demandées au bailleur le {date(premier.fait_le)}
            {ob.a_faire ? <> · <b>{ob.a_faire.libelle}</b> (prévu le {date(ob.a_faire.date)})</> : ob.suivante ? ` · prochaine étape le ${date(ob.suivante.date)} : ${ob.suivante.libelle.toLowerCase()}` : ''}</span>}
      {ob && premier?.fait_le && ob.a_faire?.modele && <button className="btn" onClick={() => preparerMail(ob, ob.a_faire.modele, String(ob.a_faire.ordre), ob.a_faire.libelle)}>Préparer la relance</button>}
    </div>
    {mail && <EditeurMail mail={mail} email={moi.email} peut fermer={() => setMail(null)} marquer={envoye} />}
  </div>;
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
function Clauses({ m, d, c, agir, repondre, recharger, onErreur }) {
  const it = (cle) => c.items.find((i) => i.cle === cle);
  const autres = c.items.filter((i) => i.bloc === 'clauses' && !['m_cl_equipements', 'm_cl_compteurs', 'm_cl_pack', 'm_cl_ordures'].includes(i.cle));
  return <>
    <div className="groupe-tete" style={{ marginTop: 10 }}><b>Équipements du bien et clauses</b></div>
    {it('m_cl_pack') && <ClauseSimple i={it('m_cl_pack')} repondre={repondre} />}
    {['m_cl_equipements', 'm_cl_compteurs'].map((cle) => it(cle) && <Equipements key={cle} i={it(cle)} d={d} agir={agir} repondre={repondre} recharger={recharger} onErreur={onErreur} />)}
    {it('m_cl_ordures') && <OrduresLots i={it('m_cl_ordures')} lots={d.lots} repondre={repondre} onErreur={onErreur} regle={regle(it('m_cl_ordures'))} />}
    {autres.map((i) => <ClauseSimple key={i.cle} i={i} repondre={repondre} />)}
  </>;
}

function Equipements({ i, d, agir, repondre, recharger, onErreur }) {
  const compteur = i.cle === 'm_cl_compteurs';
  const nature = compteur ? 'compteur' : 'equipement';
  // Lots marqués « aucun équipement » / « pas de compteur » (062)
  const [sans, setSans] = useState([]);
  const lireSans = () => rpc('pilotage_lots_sans', { p_assets: d.lots.map((l) => l.id) }).then((x) => setSans((x || []).filter((y) => y.nature === nature))).catch(() => setSans([]));
  useEffect(() => { lireSans(); }, [d]);
  const marquer = async (l, oui) => { try { await rpc('pilotage_lot_sans', { p_asset: l.id, p_nature: nature, p_sans: oui }); await lireSans(); } catch (e) { onErreur(e.message); } };
  const nbLot = (l) => l.equipements.filter((e) => e.nature === nature).length;
  const estSans = (l) => sans.some((x) => x.asset_id === l.id);
  const restants = d.lots.filter((l) => !nbLot(l) && !estSans(l));
  const toutSans = d.lots.length > 0 && d.lots.every((l) => !nbLot(l) && estSans(l));
  const aucunTxt = compteur ? 'Pas de compteur dans ce lot' : 'Aucun équipement dans ce lot';
  const ajouterRecharger = async () => { await recharger(); await lireSans(); };
  const agirLot = async (fn, args) => { await agir(fn, args); await lireSans(); };
  return <div style={{ borderTop: '1px solid var(--line)', padding: '8px 0' }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <div><span style={{ color: regle(i) ? 'var(--teal)' : 'var(--amber)', fontWeight: 700 }}>{i.statut === 'ok' ? '✓' : i.statut === 'sans_objet' ? '–' : '○'}</span> <b>{i.libelle}</b>
        <span style={{ marginLeft: 8, fontSize: 11, fontWeight: 700, color: 'var(--blue)', background: 'var(--blue-bg)', borderRadius: 10, padding: '1px 8px' }}>Suivi back-office</span>
        <div className="muted" style={{ fontSize: 12 }}>{i.aide} Pour chaque lot : ajouter autant {compteur ? 'de compteurs' : 'd’équipements'} que nécessaire, ou indiquer qu’il n’y en a pas.</div></div>
      <div className="row">
        {i.repondu ? <><span className="muted" style={{ fontSize: 12 }}>{i.statut === 'sans_objet' ? (compteur ? 'Pas de compteurs divisionnaires' : 'Aucun équipement à entretenir') : 'Validé'} ({i.par}, {date(i.le)})</span>
          <button className="lien" onClick={() => repondre(i, null)}>Revenir</button></>
          : <><button className="btn" disabled={restants.length > 0} title={restants.length ? `${restants.length} lot(s) sans réponse` : ''}
              onClick={() => repondre(i, toutSans ? 'sans_objet' : 'ok')}>Valider la saisie{restants.length ? ` (${restants.length} lot${restants.length > 1 ? 's' : ''} à renseigner)` : ''}</button></>}
      </div>
    </div>
    {i.statut !== 'sans_objet' && d.lots.map((l) => <div key={l.id} style={{ margin: compteur ? '8px 0 8px 18px' : '4px 0', paddingBottom: 6, borderBottom: '1px dashed var(--line)' }}>
      {estSans(l) && !nbLot(l)
        ? <div className="row" style={{ fontSize: 13, gap: 8, marginLeft: compteur ? 0 : 18 }}><b>Lot {l.reference || l.id}</b><span className="muted">· {l.adresse}</span>
            <span className="etq ok">✓ {aucunTxt}</span><button className="lien" onClick={() => marquer(l, false)}>Annuler</button></div>
        : <>
          {compteur
            ? <><b style={{ fontSize: 13 }}>Lot {l.reference || l.id}</b><span className="muted" style={{ fontSize: 13 }}> · {l.adresse}</span>
                <Propositions props={(d.propositions || []).filter((p) => p.asset_id === l.id && p.nature === 'compteur')} agir={agirLot} />
                <Compteurs asset={l.id} compteurs={l.compteurs || []} typeDefaut="mandat" recharger={ajouterRecharger} onErreur={onErreur} /></>
            : <Lot l={l} nature={nature} agir={agirLot} props={(d.propositions || []).filter((p) => p.asset_id === l.id)} />}
          {!nbLot(l) && <button className="btn gris" style={{ marginLeft: compteur ? 0 : 18, marginTop: 4 }} onClick={() => marquer(l, true)}>{aucunTxt}</button>}
        </>}
    </div>)}
  </div>;
}

// Proposition de l'IA (état des lieux) : à confirmer ou ignorer, rien n'est créé sans clic
function Propositions({ props, agir }) {
  if (!props?.length) return null;
  return <div style={{ background: 'var(--blue-bg)', borderRadius: 6, padding: '4px 8px', margin: '4px 0', fontSize: 13 }}>
    <div style={{ fontWeight: 700 }}>✦ Trouvé dans l’état des lieux{props[0].document ? ` « ${props[0].document} »` : ''}</div>
    {props.map((p) => <div key={p.id} className="row" style={{ gap: 8 }}>
      <span>{p.libelle}{p.nature === 'compteur' ? `${p.situation ? ' · ' + p.situation : ''}${p.numero ? ' · n° ' + p.numero : ''}${p.index != null ? ' · index ' + p.index : ''}${p.date ? ' au ' + date(p.date) : ''}` : ''}
        {p.page ? <span className="muted"> (page {p.page})</span> : null}</span>
      <button className="btn" onClick={() => agir('pilotage_lot_proposition', { p_id: p.id, p_accepter: true })}>Confirmer</button>
      <button className="lien" onClick={() => agir('pilotage_lot_proposition', { p_id: p.id, p_accepter: false })}>Ignorer</button>
    </div>)}
  </div>;
}

function Lot({ l, nature, agir, choix, titre, props }) {
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
    <div><b>{titre || 'Lot ' + (l.reference || l.id)}</b><span className="muted"> · {l.adresse}{l.construction ? ` · construit en ${l.construction}` : ''}{nature === 'equipement' && l.chauffage ? ` · chauffage Rivage : ${({ electric: 'électrique', gas: 'gaz', fuel: 'fioul', heat_pump: 'pompe à chaleur', wood: 'bois' })[l.chauffage] || l.chauffage}${l.chauffage_type ? ({ individual: ', individuel', collective: ', collectif' })[l.chauffage_type] || ', ' + l.chauffage_type : ''}` : ''}</span></div>
    <Propositions props={(props || []).filter((p) => p.nature === nature)} agir={agir} />
    {liste.map((e) => <div key={e.id} className="row" style={{ gap: 8 }}>
      <span>• {e.libelle}</span>
      {nature === 'equipement' && <span className="muted">{e.contrat_entretien === true ? `contrat d’entretien${e.prestataire ? ' : ' + e.prestataire : ''}` : e.contrat_entretien === false ? 'pas de contrat d’entretien' : ''}{e.dernier_entretien ? ` · dernier entretien ${date(e.dernier_entretien)}` : ''}</span>}
      <button className="lien" onClick={() => agir('pilotage_lot_equipement', { p_asset: l.id, p_id: e.id, p_nature: nature, p_libelle: e.libelle, p_contrat: null, p_prestataire: null, p_dernier: null, p_commentaire: null, p_supprimer: true })}>Retirer</button>
    </div>)}
    <div className="row" style={{ gap: 6, marginTop: 4 }}>
      <select value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} aria-label="Équipement">
        <option value="">{liste.length ? (nature === 'equipement' ? '+ Ajouter un autre équipement…' : '+ Ajouter un autre compteur…') : (nature === 'equipement' ? '+ Ajouter un équipement…' : '+ Ajouter un compteur…')}</option>
        {(choix || (nature === 'equipement' ? EQUIPEMENTS : COMPTEURS)).map((x) => <option key={x} value={x}>{x}</option>)}<option value="autre">Autre…</option></select>
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
  // Pack de gestion (045) : un clic, le taux Rivage est ensuite contrôlé contre le barème
  if (i.cle === 'm_cl_pack') return <div className="row" style={{ justifyContent: 'space-between', borderTop: '1px solid var(--line)', padding: '8px 0' }}>
    <div style={{ flex: 1, minWidth: 220 }}><span style={{ color: i.repondu ? 'var(--teal)' : 'var(--amber)', fontWeight: 700 }}>{i.repondu ? '✓' : '○'}</span> {i.libelle}
      {i.aide && <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div>}
      {i.repondu && <div style={{ fontSize: 13 }}>Pack {i.commentaire} <span className="muted">({i.par}, {date(i.le)})</span></div>}</div>
    <div className="row">{i.repondu ? <button className="lien" onClick={() => repondre(i, null)}>Revenir</button>
      : ['Essentiel', 'Confort', 'Pro'].map((p) => <button key={p} className="btn" onClick={() => repondre(i, 'ok', p)}>{p}</button>)}</div>
  </div>;
  // Garantie des loyers impayés (045) : option du barème, souscrite ou non, en un clic
  if (i.cle === 'm_cl_gli') return <div className="row" style={{ justifyContent: 'space-between', borderTop: '1px solid var(--line)', padding: '8px 0' }}>
    <div style={{ flex: 1, minWidth: 220 }}><span style={{ color: i.repondu ? 'var(--teal)' : 'var(--amber)', fontWeight: 700 }}>{i.repondu ? '✓' : '○'}</span> {i.libelle}
      {i.repondu && <div style={{ fontSize: 13 }}>{i.commentaire || 'Oui'} <span className="muted">({i.par}, {date(i.le)})</span></div>}</div>
    <div className="row">{i.repondu ? <button className="lien" onClick={() => repondre(i, null)}>Revenir</button> : <>
      <button className="btn" onClick={() => repondre(i, 'ok', 'Souscrite')}>Souscrite</button>
      <button className="btn" onClick={() => repondre(i, 'ok', 'Non souscrite')}>Non souscrite</button></>}</div>
  </div>;
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

// ----- Suivis du mandat : PNO, échéance du mandat, entretien d'un lot vacant, DPE d'un lot -----
// Échéance et entretien des lots vacants sont créés automatiquement (034) ; PNO et DPE se saisissent ici.
// Un justificatif PNO ou DPE déposé dans Rivage fait passer le suivi à l'échéance suivante.
export const NATURES_MANDAT = { mandat_pieces: 'Pièces du dossier à obtenir du bailleur', pno: 'Assurance PNO du bailleur', mandat_echeance: 'Échéance du mandat', entretien_lot: 'Entretien (lot vacant)', dpe: 'Validité du DPE',
  entretien_immeuble: 'Entretien (immeuble)', ascenseur_ct: 'Contrôle technique de l’ascenseur', assurance_immeuble: 'Assurance de l’immeuble',
  permis_a_demander: 'Permis de louer à demander', permis_demande: 'Permis de louer : réponse de la mairie', permis_attestation: 'Attestation d’accord tacite',
  permis_refus: 'Permis de louer refusé', permis_caducite: 'Validité du permis de louer', permis_declaration: 'Déclaration de mise en location', permis_absent: 'Bail signé sans permis de louer',
  permis_depot_agence: 'Permis de louer : dépôt par l’agence', permis_depot_bailleur: 'Permis de louer : dépôt par le bailleur' };
const CANAL_M = { mail_bailleur: 'Mail au bailleur', tache: 'Tâche', lrar: 'Recommandé', mail_locataire: 'Mail au locataire', sms: 'SMS', sms_rivage: 'SMS' };
const plusMois = (iso, n) => { const x = new Date(iso); x.setMonth(x.getMonth() + n); return x.toISOString().slice(0, 10); };

function SuivisMandat({ m, d, agir }) {
  const fourn = useFournisseurs();
  const [mail, setMail] = useState(null);
  const [ajout, setAjout] = useState(false);
  const [email, setEmail] = useState('');
  const [prenom, setPrenom] = useState('');
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setEmail(data?.session?.user?.email || ''));
    rpc('pilotage_moi').then((x) => setPrenom(x?.prenom || '')).catch(() => {});
  }, []);
  const obs = d.obligations || [];
  const adresse = (ob) => (d.lots.find((l) => l.id === ob.asset_id) || d.lots[0] || {}).adresse || 'votre bien';
  const ouvrir = (ob) => {
    const x = preparer(ob.a_faire.modele, { bail: { adresse: adresse(ob) }, ob, contacts: d.contacts, mandat: d.mandat, moi: { prenom, email }, manquants: piecesManquantes(d, fourn) });
    if (x) setMail({ m: x, etape: { cle: ob.cle, etape: String(ob.a_faire.ordre), detail: ob.a_faire.libelle } });
  };
  const fait = (cle, etape, detail) => agir('pilotage_suivi_etape', { p_cle: cle, p_etape: etape, p_detail: detail, p_annuler: false });
  const actifs = obs.filter((o) => o.actif);
  return <>
    <div className="groupe-tete" style={{ marginTop: 14 }}><b>Suivis du mandat ({actifs.length})</b></div>
    {!obs.length && <p className="muted" style={{ fontSize: 13 }}>Aucun suivi. L’échéance du mandat et l’entretien des lots vacants se créent automatiquement ; ajoutez ici l’assurance PNO et le DPE.</p>}
    {obs.map((o) => <details key={o.id} className={'mini-alerte ' + (o.actif ? o.gravite : 'normale')} style={{ opacity: o.actif ? 1 : 0.6 }} open={o.actif && (!!o.a_faire || o.en_retard)}>
      <summary style={{ cursor: 'pointer' }}><b>{o.libelle}</b>{o.lot ? ` · lot ${o.lot}` : ''} · échéance le {date(o.prochaine)}{o.periodicite_mois ? ` · tous les ${o.periodicite_mois} mois` : ''}{!o.actif ? (o.nature === 'entretien_lot' ? ' · lot loué : suivi repris par le bail' : ' · clos') : o.en_retard ? ' · en retard' : ''}
        {o.a_faire && o.actif && <div style={{ fontSize: 13 }}>→ {o.a_faire.libelle} ({CANAL_M[o.a_faire.canal]}, prévu le {date(o.a_faire.date)})</div>}</summary>
      <ol className="etapes">{(o.etapes || []).map((e) => <li key={e.ordre} className={e.fait_le ? 'fait' : e.du ? 'retard' : ''}>
        <span className="puce">{e.fait_le ? '✓' : ''}</span><span>{e.libelle}<span className="muted"> · {date(e.date)}{e.fait_le ? ' · fait le ' + date(e.fait_le) : ''}</span>
        {e.fait_le && <button className="lien" style={{ marginLeft: 8 }} onClick={() => agir('pilotage_suivi_etape', { p_cle: o.cle, p_etape: String(e.ordre), p_detail: null, p_annuler: true })}>Annuler</button>}</span></li>)}</ol>
      {o.derniere_le && <div className="muted">Dernière réalisation : {date(o.derniere_le)}</div>}
      {['pno', 'dpe'].includes(o.nature) && <div className="muted" style={{ fontSize: 12 }}>Justificatif à déposer dans Rivage, catégorie « {o.nature === 'pno' ? 'Contrats d’assurance du bien' : 'Diagnostic de Performance Énergétique'} » (mandat, lot ou fiche du bailleur) : reconnu automatiquement.</div>}
      {o.nature === 'mandat_pieces' && o.actif && <div className="muted" style={{ fontSize: 12 }}>Pièces encore attendues du bailleur : {piecesManquantes(d, fourn).join(', ') || 'aucune'}. Le suivi se ferme tout seul quand elles sont toutes dans Rivage (ou déclarées sans objet).</div>}
      {o.nature === 'mandat_echeance' && <div className="muted" style={{ fontSize: 12 }}>Créé d’après la date de fin du mandat dans Rivage. Après reconduction, mettez à jour la date de fin dans Rivage : le suivi repart tout seul sur la nouvelle date.</div>}
      {o.actif && <div className="row" style={{ marginTop: 6 }}>
        {o.a_faire?.modele && <button className="btn plein" onClick={() => ouvrir(o)}>Préparer le mail</button>}
        {o.a_faire && <button className="btn" onClick={() => fait(o.cle, String(o.a_faire.ordre), o.a_faire.libelle)}>Marquer fait</button>}
        <RealiseMandat ob={o} agir={agir} />
        {!o.auto && <button className="btn gris" onClick={() => agir('pilotage_mandat_obligation', { p_mandat: m.id, p_id: o.id, p_nature: o.nature, p_libelle: null, p_periodicite: null, p_prochaine: null, p_actif: false, p_asset: null })}>Arrêter ce suivi</button>}
      </div>}
    </details>)}
    {mail && <EditeurMail mail={mail} email={email} peut fermer={() => setMail(null)} marquer={async () => { await fait(mail.etape.cle, mail.etape.etape, mail.etape.detail); setMail(null); }} />}
    {ajout ? <NouveauSuiviMandat m={m} d={d} agir={agir} fini={() => setAjout(false)} />
      : <button className="lien" onClick={() => setAjout(true)}>+ Ajouter un suivi (assurance PNO, DPE d’un lot)</button>}
  </>;
}

function RealiseMandat({ ob, agir }) {
  const [ouvert, setOuvert] = useState(false);
  const [le, setLe] = useState(new Date().toISOString().slice(0, 10));
  const [proch, setProch] = useState('');
  const lib = ob.nature === 'mandat_echeance' ? 'Reconduction vérifiée' : ['entretien_lot', 'entretien_immeuble'].includes(ob.nature) ? 'Entretien réalisé'
    : ob.nature === 'ascenseur_ct' ? 'Contrôle réalisé' : 'Justificatif reçu';
  if (!ouvert) return <button className="btn" onClick={() => setOuvert(true)}>{lib}</button>;
  return <span className="row">
    {ob.nature !== 'mandat_echeance' && <label className="muted">Le <input type="date" value={le} onChange={(e) => setLe(e.target.value)} /></label>}
    <label className="muted">Prochaine échéance <input type="date" value={proch} onChange={(e) => setProch(e.target.value)} /></label>
    <button className="btn plein" onClick={() => agir('pilotage_mandat_obligation_realisee', { p_id: ob.id, p_le: le, p_prochaine: proch || null })}>Valider</button>
    <span className="muted" style={{ fontSize: 12 }}>{ob.periodicite_mois ? `Sans date, prochaine échéance dans ${ob.periodicite_mois} mois.` : 'Sans date, le suivi sera clos.'}</span>
  </span>;
}

function NouveauSuiviMandat({ m, d, agir, fini }) {
  const [nature, setNature] = useState('pno');
  const [asset, setAsset] = useState('');
  const [proch, setProch] = useState('');
  return <div className="row" style={{ margin: '6px 0', background: 'var(--bg)', padding: 8, borderRadius: 8 }}>
    <select value={nature} onChange={(e) => setNature(e.target.value)} aria-label="Nature du suivi">
      <option value="pno">Assurance PNO du bailleur (annuelle)</option><option value="dpe">Validité du DPE d’un lot</option></select>
    {nature === 'dpe' && <select value={asset} onChange={(e) => setAsset(e.target.value)} aria-label="Lot"><option value="">Lot…</option>
      {d.lots.map((l) => <option key={l.id} value={l.id}>Lot {l.reference || l.id}</option>)}</select>}
    <label className="muted">{nature === 'pno' ? 'Échéance de l’attestation' : 'Fin de validité'} <input type="date" value={proch} onChange={(e) => setProch(e.target.value)} /></label>
    <button className="btn plein" disabled={!proch || (nature === 'dpe' && !asset)} onClick={async () => {
      await agir('pilotage_mandat_obligation', { p_mandat: m.id, p_id: null, p_nature: nature, p_libelle: nature === 'pno' ? 'Attestation PNO' : 'Validité du DPE',
        p_periodicite: nature === 'pno' ? 12 : null, p_prochaine: proch, p_actif: true, p_asset: nature === 'dpe' ? asset : null });
      fini();
    }}>Créer</button>
    {nature === 'pno' && !proch && <button className="lien" onClick={() => setProch(plusMois(new Date().toISOString().slice(0, 10), 1))}>Attestation non reçue : demander tout de suite</button>}
    <button className="lien" onClick={fini}>Annuler</button>
  </div>;
}

// ----- Synthèse après le GO (ou mandat antérieur à 2026) -----
function Synthese({ d, c, lien, parametrer }) {
  const aRevoir = c.items.filter((i) => i.bloc === 'rivage' && !regle(i) && i.auto === 'anomalie');
  const pieces = c.items.filter((i) => i.bloc === 'pieces' && !regle(i));
  const conditions = c.items.filter((i) => i.bloc === 'rivage' && i.statut !== 'sans_objet' && i.detail);
  const clauses = c.items.filter((i) => i.bloc === 'clauses' && i.repondu && i.statut !== 'sans_objet' && !['m_cl_equipements', 'm_cl_compteurs', 'm_cl_pack', 'm_cl_ordures'].includes(i.cle));
  const [ord] = useOrdures(d.lots.map((l) => l.id));
  const ordures = (l) => { const r = ord?.lots?.[l.id]?.reponse; return r ? ' · ordures : ' + (r.mode === 'taxe_fonciere' ? 'taxe foncière' : (r.organisme?.nom || 'organisme externe')) : ''; };
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
          {co.length ? ' · compteurs divisionnaires : ' + co.map((e) => e.libelle).join(', ') : ''}{ordures(l)}</span></div>; })}
    </div>
  </>;
}

// ----- Compteurs divisionnaires : situation, relevés datés et calcul des consommations (mandat et bail) -----
const UNITE = (l) => (/eau|gaz/i.test(l) ? 'm³' : 'kWh');
const nb = (x, d = 3) => (x == null ? '—' : Number(x).toLocaleString('fr-FR', { maximumFractionDigits: d }));
const TYPES_RELEVE = { mandat: 'Relevé à la prise de mandat', entree: 'Entrée du locataire', periodique: 'Relevé périodique', sortie: 'Sortie du locataire' };

export function Compteurs({ asset, compteurs, bail, typeDefaut = 'periodique', recharger, onErreur }) {
  const [nouveau, setNouveau] = useState({ libelle: '', autre: '', situation: '', numero: '', le: new Date().toISOString().slice(0, 10), index: '' });
  const appel = async (fn, args) => { try { await rpc(fn, args); await recharger(); return true; } catch (e) { onErreur ? onErreur(e.message) : alert(e.message); return false; } };
  const ajouterCompteur = async () => {
    const libelle = nouveau.libelle === 'autre' ? nouveau.autre.trim() : nouveau.libelle;
    let id;
    try {
      id = await rpc('pilotage_lot_equipement', { p_asset: asset, p_id: null, p_nature: 'compteur', p_libelle: libelle, p_contrat: null, p_prestataire: null, p_dernier: null,
        p_commentaire: null, p_supprimer: false, p_situation: nouveau.situation || null, p_numero: nouveau.numero || null, p_unite: UNITE(libelle), p_prix: null });
      if (nouveau.index !== '') await rpc('pilotage_releve', { p_compteur: id, p_id: null, p_le: nouveau.le, p_index: Number(String(nouveau.index).replace(',', '.')), p_type: typeDefaut, p_bail: bail || null, p_commentaire: null, p_supprimer: false });
    } catch (e) { onErreur ? onErreur(e.message) : alert(e.message); }
    setNouveau({ ...nouveau, libelle: '', autre: '', situation: '', numero: '', index: '' });
    await recharger();
  };
  return <div style={{ fontSize: 13 }}>
    {compteurs.map((c) => <Compteur key={c.id} c={c} asset={asset} bail={bail} typeDefaut={typeDefaut} appel={appel} />)}
    <div className="row" style={{ gap: 6, marginTop: 6, flexWrap: 'wrap' }}>
      <select value={nouveau.libelle} onChange={(e) => setNouveau({ ...nouveau, libelle: e.target.value })} aria-label="Compteur">
        <option value="">{compteurs.length ? '+ Ajouter un autre compteur…' : '+ Ajouter un compteur…'}</option>{COMPTEURS.map((x) => <option key={x} value={x}>{x}</option>)}<option value="autre">Autre…</option></select>
      {nouveau.libelle && <>
        {nouveau.libelle === 'autre' && <input placeholder="Lequel ?" value={nouveau.autre} onChange={(e) => setNouveau({ ...nouveau, autre: e.target.value })} style={{ width: 120 }} />}
        <input placeholder="Situation (cave, palier, cuisine…)" value={nouveau.situation} onChange={(e) => setNouveau({ ...nouveau, situation: e.target.value })} style={{ width: 200 }} />
        <input placeholder="N° du compteur" value={nouveau.numero} onChange={(e) => setNouveau({ ...nouveau, numero: e.target.value })} style={{ width: 120 }} />
        <label className="muted">Relevé du <input type="date" value={nouveau.le} onChange={(e) => setNouveau({ ...nouveau, le: e.target.value })} /></label>
        <input placeholder={'Index (' + UNITE(nouveau.libelle === 'autre' ? nouveau.autre : nouveau.libelle) + ')'} inputMode="decimal" value={nouveau.index} onChange={(e) => setNouveau({ ...nouveau, index: e.target.value })} style={{ width: 110 }} />
        <button className="btn" disabled={nouveau.libelle === 'autre' && !nouveau.autre.trim()} onClick={ajouterCompteur}>Ajouter</button></>}
    </div>
  </div>;
}

function Compteur({ c, asset, bail, typeDefaut, appel }) {
  const [r, setR] = useState({ le: new Date().toISOString().slice(0, 10), index: '', type: typeDefaut, com: '' });
  const [prix, setPrix] = useState(c.prix_unitaire ?? '');
  const rel = c.releves || [];
  const [du, setDu] = useState(''); const [au, setAu] = useState('');
  const i1 = rel.find((x) => String(x.id) === du) || rel[0]; const i2 = rel.find((x) => String(x.id) === au) || rel[rel.length - 1];
  const conso = i1 && i2 && i2 !== i1 ? i2.index - i1.index : null;
  const jours = i1 && i2 && i2 !== i1 ? Math.round((new Date(i2.le) - new Date(i1.le)) / 86400000) : null;
  const pu = prix === '' ? null : Number(String(prix).replace(',', '.'));
  const enregistrer = async () => {
    const ok = await appel('pilotage_releve', { p_compteur: c.id, p_id: null, p_le: r.le, p_index: Number(String(r.index).replace(',', '.')), p_type: r.type, p_bail: bail || null, p_commentaire: r.com || null, p_supprimer: false });
    if (ok) setR({ ...r, index: '', com: '' });
  };
  return <div style={{ border: '1px solid var(--line)', borderRadius: 8, padding: '6px 10px', margin: '6px 0' }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <span><b>{c.libelle}</b>{c.situation ? ` · ${c.situation}` : ''}{c.numero ? ` · n° ${c.numero}` : ''} <span className="muted">({c.unite})</span></span>
      <span className="row" style={{ gap: 6 }}>
        <label className="muted">Prix unitaire <input inputMode="decimal" value={prix} onChange={(e) => setPrix(e.target.value)} style={{ width: 70 }}
          onBlur={() => String(prix) !== String(c.prix_unitaire ?? '') && appel('pilotage_lot_equipement', { p_asset: asset, p_id: c.id, p_nature: 'compteur', p_libelle: c.libelle, p_contrat: null, p_prestataire: null, p_dernier: null, p_commentaire: null, p_supprimer: false, p_situation: c.situation, p_numero: c.numero, p_unite: c.unite, p_prix: pu })} /> €/{c.unite}</label>
        <button className="lien" onClick={() => window.confirm(`Retirer le compteur « ${c.libelle} » et ses relevés ?`) && appel('pilotage_lot_equipement', { p_asset: asset, p_id: c.id, p_nature: 'compteur', p_libelle: c.libelle, p_contrat: null, p_prestataire: null, p_dernier: null, p_commentaire: null, p_supprimer: true })}>Retirer</button>
      </span>
    </div>
    {rel.length > 0 && <div className="table-wrap"><table className="table-imp" style={{ fontSize: 12 }}>
      <thead><tr><th>Date</th><th>Relevé</th><th>Index</th><th>Consommation</th><th>Jours</th><th>Par jour</th><th>Montant</th><th></th></tr></thead>
      <tbody>{rel.map((x) => <tr key={x.id}><td>{date(x.le)}</td><td>{TYPES_RELEVE[x.type] || x.type}{x.commentaire ? ' · ' + x.commentaire : ''}</td><td>{nb(x.index)}</td>
        <td>{x.conso != null ? nb(x.conso) + ' ' + c.unite : '—'}</td><td>{x.jours ?? '—'}</td><td>{x.par_jour != null ? nb(x.par_jour) : '—'}</td>
        <td>{x.montant != null ? Number(x.montant).toLocaleString('fr-FR', { style: 'currency', currency: 'EUR' }) : '—'}</td>
        <td><button className="lien" onClick={() => appel('pilotage_releve', { p_compteur: c.id, p_id: x.id, p_le: null, p_index: null, p_type: null, p_bail: null, p_commentaire: null, p_supprimer: true })}>Supprimer</button></td></tr>)}</tbody></table></div>}
    {rel.length >= 2 && <div className="row" style={{ gap: 6, marginTop: 4, background: 'var(--blue-bg)', padding: '4px 8px', borderRadius: 6 }}>
      <b>Calcul</b> du <select value={du || String(rel[0].id)} onChange={(e) => setDu(e.target.value)}>{rel.map((x) => <option key={x.id} value={x.id}>{date(x.le)} ({nb(x.index)})</option>)}</select>
      au <select value={au || String(rel[rel.length - 1].id)} onChange={(e) => setAu(e.target.value)}>{rel.map((x) => <option key={x.id} value={x.id}>{date(x.le)} ({nb(x.index)})</option>)}</select>
      <span>: {conso != null ? <><b>{nb(conso)} {c.unite}</b> sur {jours} jours ({jours ? nb(conso / jours) : '—'} {c.unite}/jour){pu != null ? <> · <b>{(conso * pu).toLocaleString('fr-FR', { style: 'currency', currency: 'EUR' })}</b> à {nb(pu, 4)} €/{c.unite}</> : ' · saisir le prix unitaire pour le montant'}</> : 'choisir deux relevés différents'}</span>
    </div>}
    <div className="row" style={{ gap: 6, marginTop: 4 }}>
      <label className="muted">Nouveau relevé le <input type="date" value={r.le} onChange={(e) => setR({ ...r, le: e.target.value })} /></label>
      <input placeholder={'Index (' + c.unite + ')'} inputMode="decimal" value={r.index} onChange={(e) => setR({ ...r, index: e.target.value })} style={{ width: 110 }} />
      <select value={r.type} onChange={(e) => setR({ ...r, type: e.target.value })} aria-label="Type de relevé">{Object.entries(TYPES_RELEVE).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
      {r.index !== '' && rel.length > 0 && Number(String(r.index).replace(',', '.')) < rel[rel.length - 1].index && <input placeholder="Compteur changé ? (obligatoire)" value={r.com} onChange={(e) => setR({ ...r, com: e.target.value })} style={{ width: 190 }} />}
      <button className="btn" disabled={r.index === '' || !r.le} onClick={enregistrer}>Enregistrer le relevé</button>
      {r.index !== '' && rel.length > 0 && <span className="muted">Consommation depuis le {date(rel[rel.length - 1].le)} : {nb(Number(String(r.index).replace(',', '.')) - rel[rel.length - 1].index)} {c.unite}</span>}
    </div>
  </div>;
}

// Dépôt d'une pièce dans Rivage depuis le pilotage (042, direction seulement pour l'instant)
const NATURES_DEPOT = [['management_mandate', 'Mandat de gestion signé'], ['landlord_identity_and_residence_proof', 'Identité du bailleur (Kbis, statuts, pièce d’identité)'],
  ['property_title', 'Titre de propriété'], ['landlord_bank_details', 'RIB du bailleur'], ['property_insurance_contracts', 'Assurance (PNO)'],
  ['technical_diagnostic_reports', 'Diagnostics (DPE, ERP, amiante, plomb)'], ['property_tax_declaration', 'Taxe foncière']];
export function DeposerRivage({ cible_type, cible_id, apres }) {
  const [peut, setPeut] = useState(false);
  const [f, setF] = useState({ nature: 'management_mandate', fichier: null });
  const [etat, setEtat] = useState({ charge: false, err: '', ok: '' });
  const [journal, setJournal] = useState([]);
  const [weroof, setWeroof] = useState([]);
  const [envoi, setEnvoi] = useState(null);
  const charger = () => {
    rpc('pilotage_ecritures_rivage', { p_cible: cible_id }).then(setJournal).catch(() => {});
    if (cible_type === 'ManagementContract') rpc('pilotage_documents_weroof', { p_mandat: cible_id }).then(setWeroof).catch(() => setWeroof([]));
  };
  useEffect(() => { rpc('pilotage_peut_ecrire_rivage').then((x) => { setPeut(x === true); if (x === true) charger(); }).catch(() => setPeut(false)); }, [cible_id]);
  if (!peut) return null;
  // Dépôt dans un mandat suspendu le 17/10 : l'API Rivage crée la pièce sans la rattacher (question posée à Rivage)
  if (cible_type === 'ManagementContract') return <div className="muted" style={{ fontSize: 12, margin: '8px 0' }}>Dépôt de pièces dans Rivage depuis le pilotage : en pause, en attente de Rivage (l’API crée la pièce sans la rattacher au mandat).{weroof.length ? ` ${weroof.length} pièce(s) WeRoof rapprochée(s) de ce mandat, prêtes à envoyer dès la reprise.` : ''}</div>;
  const appeler = async (body) => {
    const { data, error } = await supabase.functions.invoke('pilotage-ecriture-rivage', { body });
    let msg = data?.error;
    if (error && !msg) { try { msg = (await error.context?.json())?.error; } catch { /* corps illisible */ } }
    return { ok: !error && !data?.error, msg: msg || 'Dépôt impossible pour le moment.', data };
  };
  const envoyerWeroof = async (doc) => {
    setEnvoi(doc.id); setEtat({ charge: true, err: '', ok: '' });
    const r = await appeler({ action: 'upload', cible_type, cible_id, document_weroof: doc.id });
    setEnvoi(null);
    if (!r.ok) setEtat({ charge: false, err: `${doc.nom} : ${r.msg}`, ok: '' });
    else { setEtat({ charge: false, err: '', ok: r.data.avertissement || `${doc.nom} déposé dans Rivage. Il apparaîtra dans le dossier dès que Rivage l’aura transmis (webhook).` }); charger(); apres && apres(); }
  };
  const envoyer = async () => {
    const fichier = f.fichier; if (!fichier) return;
    setEtat({ charge: true, err: '', ok: '' });
    const buf = await fichier.arrayBuffer(); let bin = ''; const u = new Uint8Array(buf);
    for (let k = 0; k < u.length; k += 0x8000) bin += String.fromCharCode.apply(null, u.subarray(k, k + 0x8000));
    const { data, error } = await supabase.functions.invoke('pilotage-ecriture-rivage', { body: { action: 'upload', cible_type, cible_id, nature: f.nature,
      nom: fichier.name, titre: fichier.name.replace(/\.[a-z0-9]+$/i, ''), type_mime: fichier.type, fichier: btoa(bin) } });
    let msg = data?.error;
    if (error && !msg) { try { msg = (await error.context?.json())?.error; } catch { /* corps illisible */ } }
    if (error || data?.error) setEtat({ charge: false, err: msg || 'Dépôt impossible pour le moment.', ok: '' });
    else { setEtat({ charge: false, err: '', ok: data.avertissement || 'Pièce déposée dans Rivage. Elle apparaîtra ici dès que Rivage l’aura transmise (webhook).' }); setF({ ...f, fichier: null }); charger(); apres && apres(); }
  };
  return <details className="replie" style={{ margin: '8px 0' }}>
    <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Déposer une pièce dans Rivage{journal.length ? ` (${journal.length} dépôt(s))` : ''}</summary>
    <div className="row" style={{ marginTop: 6 }}>
      <select value={f.nature} onChange={(e) => setF({ ...f, nature: e.target.value })}>{NATURES_DEPOT.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
      <input type="file" accept="application/pdf,image/jpeg,image/png" onChange={(e) => setF({ ...f, fichier: e.target.files[0] || null })} />
      <button className="btn plein" disabled={!f.fichier || etat.charge} onClick={envoyer}>{etat.charge ? 'Envoi…' : 'Envoyer dans Rivage'}</button>
    </div>
    <div className="muted" style={{ fontSize: 12 }}>La pièce est créée dans la GED Rivage et rattachée à ce dossier. Chaque dépôt est tracé.</div>
    {cible_type === 'ManagementContract' && <div style={{ marginTop: 8 }}>
      <b style={{ fontSize: 13 }}>Pièces trouvées dans WeRoof ({weroof.length})</b>
      <div className="muted" style={{ fontSize: 12 }}>Rapprochées par l’adresse du lot et le nom du propriétaire. Vérifier chaque pièce avant l’envoi (date, bon propriétaire).</div>
      {!weroof.length && <div className="muted" style={{ fontSize: 12 }}>Aucune pièce WeRoof rapprochée de ce mandat.</div>}
      {weroof.map((w) => <div key={w.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13, borderTop: '1px solid var(--line)', padding: '4px 0' }}>
        <span>{w.nom} <span className="muted">· {(NATURES_DEPOT.find(([v]) => v === w.nature) || [null, w.nature])[1]}{w.taille ? ` · ${Math.round(w.taille / 1024)} Ko` : ''}</span></span>
        {w.envoye ? <span className="etq ok">envoyé</span>
          : <button className="btn" disabled={etat.charge} onClick={() => envoyerWeroof(w)}>{envoi === w.id ? 'Envoi…' : 'Envoyer dans Rivage'}</button>}
      </div>)}
    </div>}
    {etat.err && <div className="err">{etat.err}</div>}
    {etat.ok && <div style={{ fontSize: 13, color: 'var(--teal)' }}>{etat.ok}</div>}
    {journal.map((j, i) => <div key={i} className="muted" style={{ fontSize: 12 }}>{new Date(j.le).toLocaleString('fr-FR')} · {j.par || '—'} · {j.libelle} · {j.ok ? 'déposé' : `refusé (${j.statut}) ${j.message || ''}`}</div>)}
  </details>;
}
