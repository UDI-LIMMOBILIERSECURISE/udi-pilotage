// Page « Biens » (136) : chaque lot sur une frise en quatre phases déduites de Rivage (entrée en gestion, mise en location, bail en cours,
// sortie), avec le détail de la phase en cours. Compteurs par phase en tête, filtre « À moi » (lots dont je suis le commercial ou qui
// portent une alerte qui m'est adressée). Lecture seule : un clic ouvre la fiche existante du mandat ou du bail.
import React, { useContext, useEffect, useMemo, useState } from 'react';
import { MoiContexte } from './moi.js';
import { rpc } from './supabase.js';
import Fiche from './Fiche.jsx';
import DossierMandat from './SuiviMandat.jsx';
import { DossierBail } from './SuiviBaux.jsx';
import { nature, texteRecherche, correspond } from './cartes.jsx';
import { SuiviSinistre, ORIGINE } from './TicketsFil.jsx';
import { EchangesLot } from './Echanges.jsx';
import { ClesLots } from './Cles.jsx';

export const PHASES = [
  ['entree', 'Entrée en gestion'],
  ['location', 'Mise en location'],
  ['bail', 'Bail en cours'],
  ['sortie', 'Sortie'],
];
// 140 : après la sortie, deux phases possibles en plus de la remise en location
export const SUITES = [['travaux', 'Travaux avant relocation'], ['fin', 'Fin de gestion']];
const COURT = { entree: 'Entrée', location: 'Location', bail: 'Bail', sortie: 'Sortie', travaux: 'Travaux', fin: 'Fin' };
const LIBELLE = Object.fromEntries([...PHASES, ...SUITES, ['hors', 'Hors gestion']]);
const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '');

export default function Biens({ moi }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [filtre, setFiltre] = useState('tous'); // tous | phase | a_moi | a_cloturer | hors
  const [q, setQ] = useState('');
  const [ouvert, setOuvert] = useState(null);
  const charger = (premier = false) => rpc('pilotage_biens').then((x) => {
    setD(x);
    // 137 : la page s'ouvre sur « À moi » quand j'ai des étapes à traiter
    if (premier && x?.compteurs?.a_moi > 0) setFiltre('a_moi');
  }).catch((e) => setErr(e.message));
  useEffect(() => { charger(true); }, []);
  const lots = useMemo(() => {
    if (!d) return [];
    const liste = d.lots.filter((l) => {
      if (filtre === 'tous' && l.phase === 'hors') return false;
      if (['entree', 'location', 'bail', 'sortie', 'travaux', 'fin', 'hors'].includes(filtre) && l.phase !== filtre) return false;
      if (filtre === 'a_moi' && !(l.a_moi && l.phase !== 'hors')) return false;
      if (filtre === 'a_cloturer' && !(l.a_cloturer > 0)) return false;
      return !q || correspond(texteRecherche(l.lot && 'lot ' + l.lot, l.adresse, l.bailleur, l.mandat && 'mandat ' + l.mandat,
        l.bail && 'bail ' + l.bail, l.locataires, l.commercial, nature(l.nature), LIBELLE[l.phase], l.a_faire?.action, l.a_faire?.prenom), q);
    });
    // « À moi » : les étapes en retard d'abord
    return filtre === 'a_moi' ? [...liste].sort((a, b) => Number(!!b.a_faire?.urgent) - Number(!!a.a_faire?.urgent)) : liste;
  }, [d, filtre, q]);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const c = d.compteurs || {};
  const tuile = (k, libelle, n, aide) => <button key={k} className={'tuile tuile-filtre' + (filtre === k ? ' on' : '')} onClick={() => setFiltre(filtre === k ? 'tous' : k)}
    aria-pressed={filtre === k} title={aide}>
    <div className="muted">{libelle}</div><div className="tuile-n">{n || 0}</div></button>;
  const enGestion = [...PHASES, ...SUITES].reduce((t, [k]) => t + (c[k] || 0), 0);
  return <>
    <div className="entete"><div><h1>Biens</h1>
      <p className="sub">Chaque lot sur sa frise : entrée en gestion, mise en location, bail en cours, sortie, puis travaux, relocation ou fin de gestion. Tout est déduit de Rivage ; un clic ouvre la fiche.</p></div></div>
    {err && <div className="banner">{err}</div>}
    <div className="tuiles">
      {tuile('tous', 'En gestion', enGestion, 'Tous les lots gérés')}
      {PHASES.map(([k, l]) => tuile(k, l, c[k]))}
      {SUITES.map(([k, l]) => tuile(k, l, c[k]))}
      {tuile('a_moi', 'À moi', c.a_moi, 'Biens dont l’étape en cours est à moi de traiter')}
    </div>
    <div className="row" style={{ marginBottom: 10 }}>
      <input className="recherche" style={{ flex: 1, minWidth: 220, marginBottom: 0 }} placeholder="Rechercher : lot, adresse, bailleur, locataire, mandat, bail, commercial"
        value={q} onChange={(e) => setQ(e.target.value)} aria-label="Rechercher un bien" />
      <button className={'chip' + (filtre === 'a_cloturer' ? ' on' : '')} onClick={() => setFiltre(filtre === 'a_cloturer' ? 'tous' : 'a_cloturer')}
        title="Baux restés « en sortie » dans Rivage plus de 2 mois après le départ">Baux à clôturer dans Rivage<span className="n">{c.a_cloturer || 0}</span></button>
      <button className={'chip' + (filtre === 'hors' ? ' on' : '')} onClick={() => setFiltre(filtre === 'hors' ? 'tous' : 'hors')}>Hors gestion<span className="n">{c.hors || 0}</span></button>
    </div>
    <p className="muted" style={{ margin: '0 0 8px' }}>{lots.length} lot{lots.length > 1 ? 's' : ''}{filtre !== 'tous' ? ' · filtre : ' + ({ a_moi: 'À moi', a_cloturer: 'Baux à clôturer dans Rivage' }[filtre] || LIBELLE[filtre]) : ''}</p>
    {!lots.length ? <div className="card">Aucun bien ne correspond.</div>
      : <div className="stack" style={{ gap: 8 }}>{lots.map((l) => <LigneBien key={l.id} l={l} ouvrir={() => setOuvert(l)} peut={d.peut} apres={() => charger()} />)}</div>}
    {ouvert && <Fiche titre={'Lot ' + (ouvert.lot || '') + ' · ' + (ouvert.adresse || '')} fermer={() => setOuvert(null)}>
      <FicheBien l={ouvert} peut={d.peut} moi={moi} apres={charger} />
    </Fiche>}
  </>;
}

// Ligne d'un lot (page Biens, et depuis le 12/11/2026 toutes les pages à lots) : frise, étapes, action en cours.
// Une page ajoute ce qui lui est propre : entete (petite ligne au-dessus du titre), etiquettes (à droite), complement (sous le titre).
// Sans lot connu (ticket d'immeuble, clés sans lot), la ligne garde la même forme avec le seul contenu de la page.
export function LigneLot({ l, ouvrir, peut: peutPage, apres: apresPage, entete, etiquettes, complement, gravite, titre, sel }) {
  // 12/11 : bouton « Mettre en location » sur toutes les pages (droit lu dans la liste des biens partagée si la page ne le donne pas)
  const peut = peutPage ?? !!memoBiens?.d?.peut;
  const apres = apresPage || relireBiens;
  const clic = { role: 'button', tabIndex: 0, onClick: ouvrir, onKeyDown: (e) => { if (e.key === 'Enter' && e.target === e.currentTarget) ouvrir(); } };
  if (!l) return <div className={'kcarte bien ' + (gravite || 'normale') + (sel ? ' sel' : '')} {...clic}>
    {entete && <div className="lot-entete">{entete}</div>}
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
      <div className="kcarte-titre" style={{ marginTop: 0, minWidth: 0 }}>{titre || 'Sans lot Rivage'}</div>
      {etiquettes && <div className="row" style={{ gap: 6 }}>{etiquettes}</div>}
    </div>
    {complement && <div className="lot-complement">{complement}</div>}
  </div>;
  const etape = l.etape != null ? (l.etapes || [])[l.etape] : null;
  const af = l.a_faire;
  const alerte = (l.etapes || []).some((e) => e.etat === 'alerte');
  return <div className={'kcarte bien ' + (gravite || (alerte ? 'haute' : 'normale')) + (sel ? ' sel' : '')} {...clic}>
    {entete && <div className="lot-entete">{entete}</div>}
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
      <div style={{ minWidth: 0 }}>
        <div className="kcarte-titre" style={{ marginTop: 0 }}>Lot {l.lot || '?'} · {l.adresse || 'adresse ?'}</div>
        <div className="muted">{nature(l.nature)} · {l.bailleur || 'bailleur ?'}{l.locataires ? ' · ' + l.locataires : ''}{l.commercial ? ' · ' + l.commercial : ''}</div>
      </div>
      <div className="row" style={{ gap: 6 }}>
        {etiquettes}
        {l.alertes_moi > 0 && <span className="etq rose">{l.alertes_moi} alerte{l.alertes_moi > 1 ? 's' : ''} pour moi</span>}
        {l.fin_gestion && <span className="etq violet">Fin de gestion le {date(l.fin_gestion)}</span>}
        {(l.suite || l.relocation) && <span className="etq ok">{l.suite || l.relocation}</span>}
        {l.a_cloturer > 0 && <span className="etq rose" title="Bail resté en sortie dans Rivage plus de 2 mois après le départ">{l.a_cloturer} bail à clôturer</span>}
      </div>
    </div>
    {complement && <div className="lot-complement">{complement}</div>}
    <Frise phase={l.phase} />
    {l.phase !== 'hors' && <Etapes etapes={l.etapes} courante={l.etape} />}
    {af && <div className={'a-faire' + (l.a_moi ? ' moi' : '') + (af.urgent ? ' urgent' : '')}>
      <strong>{l.a_moi ? 'À vous' : 'À faire par ' + af.prenom}</strong> : {af.action}{etape?.info ? ' · ' + etape.info : ''}
    </div>}
    {!af && etape?.info && <div className="muted" style={{ marginTop: 4 }}>{etape.libelle} : {etape.info}</div>}
    {peut && aMettreEnLocation(l) && <MettreEnLocation l={l} apres={apres} />}
  </div>;
}
const LigneBien = LigneLot;

// Liste des biens lue une fois et partagée entre les pages (gardée 60 s) : chaque page retrouve le lot de ses dossiers
// par n° de lot Rivage (référence unique), identifiant du lot ou mandat.
let memoBiens = null;
const abonnes = new Set();
// Relit la liste et met à jour toutes les pages ouvertes (après une mise en location, par exemple)
export function relireBiens() {
  return rpc('pilotage_biens').then((x) => { memoBiens = { d: x, t: Date.now() }; abonnes.forEach((f) => f(x)); }).catch(() => {});
}
export function useBiens() {
  const [d, setD] = useState(memoBiens?.d || null);
  const lire = (forcer) => {
    if (!forcer && memoBiens && Date.now() - memoBiens.t < 60000) { setD(memoBiens.d); return Promise.resolve(); }
    return relireBiens().then(() => { if (!memoBiens) setD((v) => v || { lots: [], peut: false }); });
  };
  useEffect(() => { abonnes.add(setD); lire(false); return () => { abonnes.delete(setD); }; }, []);
  const index = useMemo(() => {
    const parRef = {}, parId = {}, parMandat = {};
    (d?.lots || []).forEach((l) => { parRef[String(l.lot)] = l; parId[l.id] = l; if (l.mandat_id) (parMandat[l.mandat_id] = parMandat[l.mandat_id] || []).push(l); });
    return { parRef, parId, parMandat };
  }, [d]);
  return { d, ...index, lot: (ref) => (ref == null ? null : index.parRef[String(ref)] || null), peut: !!d?.peut, recharger: () => lire(true) };
}

// Fiche ouverte depuis une page : la fiche du bien, avec le dossier propre à la page juste après « Où en est le bien ».
// sansDossier : la page montre déjà le dossier complet (bail, mandat), on ne le répète pas en bas de la fiche.
export function FicheLot({ l, titre, peut, apres, sansDossier, children }) {
  if (!l) return children;
  return <FicheBien l={l} peut={peut} apres={apres} sansDossier={sansDossier} bloc={children && <section className="fb-bloc fb-page">
    {titre && <h3 className="fb-titre">{titre}</h3>}{children}</section>} />;
}
export const titreLot = (l, defaut) => (l ? 'Lot ' + (l.lot || '') + ' · ' + (l.adresse || '') : defaut);

// Mise en location depuis la ligne du bien (même effet que le bouton de la page « À louer ») : gestion et direction
function MettreEnLocation({ l, apres }) {
  const [ouvert, setOuvert] = useState(false);
  const [f, setF] = useState({ dispo: new Date().toISOString().slice(0, 10), loyer: '' });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const stop = (e) => e.stopPropagation();
  const valider = async () => {
    setErr(''); setBusy(true);
    try {
      await rpc('pilotage_a_louer_maj', { p_asset: l.id, p_action: 'ajouter', p_disponible: f.dispo || null,
        p_loyer: f.loyer === '' ? null : Number(String(f.loyer).replace(',', '.')), p_motif: 'Mis en location depuis la page Biens', p_note: null });
      setOuvert(false); apres();
    } catch (e) { setErr(e.message); } finally { setBusy(false); }
  };
  return <div className="row" style={{ marginTop: 8, gap: 8 }} onClick={stop} onKeyDown={stop}>
    {!ouvert ? <button className="btn plein" onClick={() => setOuvert(true)}>Mettre en location</button> : <>
      <label className="muted">Disponible le <input type="date" value={f.dispo} onChange={(e) => setF({ ...f, dispo: e.target.value })} /></label>
      <label className="muted">Loyer CC <input type="number" inputMode="decimal" value={f.loyer} onChange={(e) => setF({ ...f, loyer: e.target.value })} style={{ width: 90 }} /></label>
      <button className="btn plein" disabled={busy} onClick={valider}>{busy ? 'Enregistrement…' : 'Valider'}</button>
      <button className="btn gris" onClick={() => setOuvert(false)}>Annuler</button>
    </>}
    {err && <span className="err">{err}</span>}
  </div>;
}

// Les quatre phases, la phase en cours marquée ; après la sortie, la suite (travaux, relocation, fin de gestion)
export function Frise({ phase, issues = false }) {
  if (phase === 'hors') return <div className="frise"><span className="frise-phase hors">Hors gestion</span></div>;
  const suite = phase === 'travaux' || phase === 'fin';
  const i = suite ? PHASES.length : PHASES.findIndex(([k]) => k === phase);
  return <div className="frise-bloc">
    <ol className="frise" aria-label={'Phase : ' + LIBELLE[phase]}>
      {PHASES.map(([k, lib], n) => <li key={k} className={'frise-phase ' + (n < i ? 'passee' : n === i ? 'courante' : 'a-venir')}
        aria-current={n === i ? 'step' : undefined}><span className="long">{lib}</span><span className="court" aria-hidden="true">{COURT[k]}</span></li>)}
      {suite && <li className={'frise-phase courante ' + phase} aria-current="step"><span className="long">{LIBELLE[phase]}</span><span className="court" aria-hidden="true">{COURT[phase]}</span></li>}
    </ol>
    {/* 12/11 : les suites possibles seulement pendant la sortie (pendant le bail, elles se lisaient comme l'état du lot) */}
    {issues && phase === 'sortie' && <div className="issues" aria-label="Suites possibles après la sortie">
      <span className="muted">Après la sortie :</span>
      <span className="issue travaux">Travaux avant relocation</span><span className="issue relouer">Relouer</span><span className="issue fin">Fin de gestion</span>
    </div>}
  </div>;
}

// Détail de la phase en cours : chaque étape avec son état (fait, en cours, à venir, alerte)
const MARQUE = { fait: '✓', en_cours: '●', alerte: '!', a_venir: '○' };
// 12/11 : une étape non faite dit ce qui reste à faire (« Bail signé » en cours se lisait comme un bail déjà signé, lot 140)
const A_FAIRE = { 'Bail signé': 'Bail à signer', 'Dépôt de garantie restitué': 'Dépôt de garantie à restituer', 'Bail clos dans Rivage': 'Bail à clôturer dans Rivage',
  'Mis en location': 'À mettre en location' };
const libelleEtape = (e) => (e.etat !== 'fait' && A_FAIRE[e.libelle]) || e.libelle;
// 12/11 : « Mettre en location » proposé dès que l'étape en cours le demande, même quand le lot est passé en vérification
// direction (libre depuis plus de 90 jours, 141 : plus d'action à la gestion, mais mettre le lot « À louer » reste la bonne suite)
const aMettreEnLocation = (l) => (l.etapes || []).some((e) => e.etat !== 'fait' && e.etat !== 'a_venir' && (e.action || '').startsWith('Mettre le lot'))
  || !!l.a_faire?.action?.startsWith('Mettre le lot');
export function Etapes({ etapes, courante }) {
  if (!etapes?.length) return null;
  return <ol className="etapes">
    {etapes.map((e, n) => <li key={n} className={'etape e-' + e.etat + (n === courante ? ' courante' : '')} title={e.info || ''}>
      <span className="etape-marque" aria-hidden="true">{MARQUE[e.etat] || '○'}</span>
      {/* 12/11 : une étape en alerte dit pourquoi (avant : seulement au survol) */}
      <span>{libelleEtape(e)}{e.date ? ' · ' + date(e.date) : ''}{e.etat === 'alerte' && (e.info || e.info_direction) ? ' : ' + (e.info || e.info_direction) : ''}</span>
      <span className="sr">{{ fait: ' (fait)', en_cours: ' (en cours)', alerte: ' (à traiter)', a_venir: ' (à venir)' }[e.etat]}</span>
    </li>)}
  </ol>;
}

// Fiche unique du bien (refonte du 11/11/2026) : en-tête, frise et suites, action en cours, dossiers ouverts, puis le dossier complet
export function FicheBien({ l, peut, moi: moiPage, apres, bloc, sansDossier }) {
  const moiCtx = useContext(MoiContexte);
  const moi = moiPage || moiCtx;
  const [x, setX] = useState(null);
  const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_bien', { p_asset: l.id }).then(setX).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, [l.id]);
  const etape = l.etape != null ? (l.etapes || [])[l.etape] : null;
  const af = l.a_faire;
  return <div className="fiche-bien">
    <div className="fb-etiquettes">
      <span className={'etq phase-' + l.phase}>{LIBELLE[l.phase]}</span>
      {(x?.tickets || []).find((t) => t.occupation) && <span className="etq neutre">Logement {(x.tickets.find((t) => t.occupation)).occupation}</span>}
      {l.fin_gestion && <span className="etq violet">Fin de gestion le {date(l.fin_gestion)}</span>}
    </div>
    <dl className="fb-faits">
      <div><dt>Bailleur</dt><dd>{l.bailleur || '—'}</dd></div>
      <div><dt>{l.phase === 'sortie' ? 'Locataire sortant' : 'Locataire'}</dt><dd>{l.locataires || '—'}</dd></div>
      {l.depart && <div><dt>Départ</dt><dd>{date(l.depart)}</dd></div>}
      <div><dt>Mandat</dt><dd>{l.mandat ? 'n° ' + l.mandat : '—'}</dd></div>
      {l.commercial && <div><dt>Commercial</dt><dd>{l.commercial}</dd></div>}
      {l.bail && <div><dt>Bail</dt><dd>{l.bail}</dd></div>}
    </dl>
    <section className="fb-bloc">
      <h3 className="fb-titre">Où en est le bien</h3>
      <Frise phase={l.phase} issues />
      {l.suite && <p className="fb-suite">Suite prévue : <b>{l.suite}</b></p>}
      <div className="fb-deux">
        <div>{l.phase !== 'hors' && <Etapes etapes={l.etapes} courante={l.etape} />}
          {(l.etapes || []).filter((e) => e.info || e.info_direction).length > 0 && <ul className="muted" style={{ margin: '8px 0 0', paddingLeft: 18 }}>
            {l.etapes.filter((e) => e.info || e.info_direction).map((e, n) => <li key={n}>{libelleEtape(e)} : {e.info_direction || e.info}</li>)}</ul>}</div>
        {af && <div className={'fb-action' + (af.urgent ? ' urgent' : '') + (l.a_moi ? ' moi' : '')}>
          <div className="fb-action-qui">{l.a_moi ? 'À vous, maintenant' : 'À faire par ' + af.prenom}</div>
          <div className="fb-action-quoi">{af.action}</div>
          {etape?.info && <div className="muted">{etape.info}</div>}
          {peut && aMettreEnLocation(l) && <MettreEnLocation l={l} apres={apres} />}
        </div>}
        {!af && peut && aMettreEnLocation(l) && <div className="fb-action">
          <div className="fb-action-qui">Vérification par la direction</div>
          <div className="fb-action-quoi">Lot libre depuis longtemps : vérifier Rivage, ou le mettre « À louer »</div>
          <MettreEnLocation l={l} apres={apres} />
        </div>}
      </div>
    </section>
    {bloc}
    {err && <div className="banner">{err}</div>}
    <section className="fb-bloc">
      <h3 className="fb-titre">Dossiers ouverts sur ce bien</h3>
      {!x ? <p className="muted">Chargement…</p> : <Dossiers x={x} l={l} recharger={charger} />}
    </section>
    {/* 12/11 : clés du lot sur toutes les fiches : n° du trousseau, prise et retour, ajout (n° libres proposés) */}
    <section className="fb-bloc"><h3 className="fb-titre">Clés</h3><ClesLots assets={[l.id]} ouvert /></section>
    <HistoriqueTickets l={l} />
    <EchangesLot lotId={l.id} />
    {!sansDossier && <details className="fb-bloc fb-complet" open={!!(af && (af.action || '').match(/contrôle|dossier|GO/i))}>
      <summary>Dossier complet du {l.bail_id ? 'bail' : 'mandat'} (contrôle, suivis, messages)</summary>
      {l.bail_id
        ? <DossierBail b={{ bail_id: l.bail_id, reference: l.bail, locataires: l.locataires, adresse: l.adresse, bailleur: l.bailleur, mandat: l.mandat ? 'Mandat n°' + l.mandat : null, mandat_id: l.mandat_id }}
            peut={peut} moi={moi} apres={apres} />
        : l.mandat_id ? <DossierMandat m={{ id: l.mandat_id }} apres={apres} />
        : <p className="muted">Aucun mandat ni bail rattaché à ce lot dans Rivage.</p>}
    </details>}
  </div>;
}

// Étapes d'un ticket Sinistre ou Travaux, lues dans Rivage (artisan sélectionné = devis accepté par le bailleur)
const ETAPES_TICKET = [['declare', 'Déclaré'], ['devis_a_demander', 'Devis à demander'], ['devis_demande', 'Devis demandé'], ['devis_accepte', 'Devis accepté'],
  ['planifie', 'Planifié'], ['en_cours', 'En cours'], ['fait', 'Faits'], ['facture', 'Facturé']];
const rangTicket = (e) => (e === 'fin_depassee' ? 5 : ETAPES_TICKET.findIndex(([k]) => k === e));
// 153 : ticket PL / DMEL : étapes du permis de louer (suivi du lot), plus celles des travaux
const ETAPES_DMEL = [['permis_a_deposer', 'À déposer'], ['recepisse_attendu', 'Déposée'], ['permis_termine', 'Récépissé reçu']];
const ETAPES_PL = [['permis_a_deposer', 'À déposer'], ['reponse_attendue', 'Déposée'], ['attestation_attendue', 'Accord tacite'], ['permis_termine', 'Permis obtenu']];
const estPermis = (t) => t.permis && !t.sinistre && !t.travaux;

function Dossiers({ x, l, recharger }) {
  const cartes = [];
  (x.tickets || []).forEach((t) => {
    const types = [t.sinistre && 'Sinistre', t.travaux && 'Travaux', t.permis && (t.tags.includes('pl') ? 'Permis de louer' : 'Déclaration de mise en location')].filter(Boolean);
    const r = rangTicket(t.etape);
    cartes.push(<article key={t.id} className="fb-carte">
      <header><div><h4>{types.length ? types.join(' + ') : 'Ticket à classer'} · n°{t.numero}</h4><div className="muted">{t.titre}</div></div>
        <a className="lien" href={t.lien} target="_blank" rel="noreferrer">Ouvrir dans Rivage ↗</a></header>
      {(t.sinistre || t.travaux) && <ol className="fb-pas" aria-label={'Étape : ' + t.etape_libelle}>
        {ETAPES_TICKET.map(([k, lib], n) => <li key={k} className={n < r ? 'fait' : n === r ? 'cour' : ''}>{lib}</li>)}</ol>}
      {estPermis(t) && t.etape !== 'permis_refuse' && (() => { const et = t.tags.includes('pl') ? ETAPES_PL : ETAPES_DMEL; const rp = et.findIndex(([k]) => k === t.etape);
        return <ol className="fb-pas" aria-label={'Étape : ' + t.etape_libelle}>{et.map(([k, lib], n) => <li key={k} className={n < rp ? 'fait' : n === rp ? 'cour' : ''}>{lib}</li>)}</ol>; })()}
      <div className="fb-carte-pied">
        <span>{t.etape_libelle}{t.action && (t.sinistre || t.travaux || estPermis(t)) ? ' · ' + t.action : ''}</span>
        {t.retard >= 0 && (t.sinistre || t.travaux) && <span className="etq rose">Relance : sans changement depuis le {date(t.depuis)}</span>}
        {!types.length && <span className="etq rose">Poser le tag Sinistre, Travaux, PL ou DMEL dans Rivage</span>}
        {t.a_facturer && <span className="etq violet">À facturer (Audrey et gestion)</span>}
        {t.occupation && <span className="etq neutre">Logement {t.occupation}</span>}
      </div>
    </article>);
  });
  if (x.impaye) cartes.push(<article key="impaye" className="fb-carte"><header><div><h4>Impayé</h4><div className="muted">Suivi : Audrey (comptabilité)</div></div></header>
    <div className="fb-carte-pied"><span>{x.impaye.montant != null ? String(x.impaye.montant).replace('.', ',') + ' € dus' : 'Montant à vérifier'}{x.impaye.depuis ? ' · ouvert le ' + date(x.impaye.depuis) : ''}</span></div></article>);
  if (x.assurance) cartes.push(<article key="assurance" className="fb-carte"><header><div><h4>Assurance habitation du locataire</h4><div className="muted">Relance automatique</div></div></header>
    <div className="fb-carte-pied"><span>Prochaine échéance le {date(x.assurance.prochaine)}</span>
      {new Date(x.assurance.prochaine) <= new Date(Date.now() + 45 * 864e5) && <span className="etq rose">Relances en cours</span>}</div></article>);
  return <>
    <div className="fb-cartes">{cartes}</div>
    {!cartes.length && <p className="muted">Aucun dossier ouvert : ni ticket, ni impayé, ni relance d’assurance en cours sur ce bien.</p>}
    <DonneesACorriger l={l} liste={x.donnees || []} recharger={recharger} />
  </>;
}

// Données Rivage douteuses : signalées à Nicolas (direction), qui les fait corriger
function DonneesACorriger({ l, liste, recharger }) {
  const [ouvert, setOuvert] = useState(false);
  const [motif, setMotif] = useState('');
  const [err, setErr] = useState('');
  const envoyer = async () => {
    setErr('');
    try { await rpc('pilotage_donnee_signaler', { p_objet_type: 'Asset', p_objet_id: l.id, p_motif: motif }); setMotif(''); setOuvert(false); recharger(); }
    catch (e) { setErr(e.message); }
  };
  const ouvertes = liste.filter((d) => !d.corrige_le);
  return <div className="fb-donnees">
    {ouvertes.map((d) => <div key={d.id} className="fb-donnee"><b>Donnée à corriger</b> · {d.motif} <span className="muted">(signalé{d.par ? ' par ' + d.par : ''} le {date(d.le)}, suivi par la direction)</span></div>)}
    {!ouvert ? <button className="lien" onClick={() => setOuvert(true)}>Signaler une donnée Rivage douteuse sur ce bien</button>
      : <div className="row" style={{ gap: 8 }}>
        <label className="sr" htmlFor={'dc-' + l.id}>Ce qui semble faux</label>
        <input id={'dc-' + l.id} style={{ flex: 1, minWidth: 240 }} placeholder="Ce qui semble faux dans Rivage (ex. loué mais aucun bail sur ce lot)" value={motif} onChange={(e) => setMotif(e.target.value)} />
        <button className="btn plein" disabled={!motif.trim()} onClick={envoyer}>Envoyer à la direction</button>
        <button className="btn gris" onClick={() => setOuvert(false)}>Annuler</button>
      </div>}
    {err && <div className="err">{err}</div>}
  </div>;
}

// Historique de tous les tickets du lot (12/11/2026) : incidents Rivage (ouverts et clos) et dossiers repris de Monday / WeRoof,
// avec leur fil de mises à jour (liens vers les mails Gmail et pièces jointes). Chargé à l'ouverture seulement.
function HistoriqueTickets({ l }) {
  const [ouvert, setOuvert] = useState(false);
  const [liste, setListe] = useState(null);
  const [err, setErr] = useState('');
  const [sel, setSel] = useState(null);
  const charger = () => rpc('pilotage_sinistres').then((d) => setListe((d || []).filter((t) => (l.lot && t.lot === l.lot) || (!t.lot && l.adresse && t.adresse === l.adresse))
    .sort((a, b) => String(b.declare_le || '').localeCompare(String(a.declare_le || ''))))).catch((e) => setErr(e.message));
  useEffect(() => { if (ouvert && !liste) charger(); }, [ouvert]);
  return <details className="fb-bloc fb-complet" onToggle={(e) => setOuvert(e.currentTarget.open)}>
    <summary>Historique des tickets du lot (Rivage, Monday, WeRoof){liste ? ` · ${liste.length}` : ''}</summary>
    {err && <div className="banner">{err}</div>}
    {ouvert && !liste && !err && <p className="muted">Chargement…</p>}
    {liste && !liste.length && <p className="muted">Aucun ticket sur ce lot, ni dans Rivage ni dans les dossiers repris de Monday / WeRoof.</p>}
    {liste && liste.map((t) => <div key={t.id} className="fb-carte" style={{ marginTop: 8 }}>
      <button className="eg-texte" aria-expanded={sel === t.id} onClick={() => setSel(sel === t.id ? null : t.id)}>
        <b>{t.titre || 'Sans titre'}</b>
        <span className="muted">{t.source === 'monday' ? 'Repris de ' + ORIGINE(t) + (t.reference ? ' · ' + t.reference : '') : 'Rivage n°' + t.numero}
          {' · '}{t.clos ? 'Clos' : 'En cours'}{t.declare_le ? ' · ouvert le ' + date(t.declare_le) : ''}{t.resolu_le ? ' · clos le ' + date(t.resolu_le) : ''}
          {t.locataires ? ' · ' + t.locataires : ''}{t.nb_notes ? ' · 💬 ' + t.nb_notes : ''}</span>
      </button>
      {sel === t.id && <div style={{ marginTop: 8 }}>
        {t.description && <p style={{ whiteSpace: 'pre-wrap' }}>{t.description}</p>}
        {t.lien && <p><a className="lien" href={t.lien} target="_blank" rel="noreferrer">{t.source === 'monday' ? 'Ouvrir dans ' + ORIGINE(t) : 'Ouvrir dans Rivage'} ↗</a></p>}
        <SuiviSinistre dossier={t} recharger={charger} />
      </div>}
    </div>)}
  </details>;
}
