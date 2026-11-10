// Page « Biens » (136) : chaque lot sur une frise en quatre phases déduites de Rivage (entrée en gestion, mise en location, bail en cours,
// sortie), avec le détail de la phase en cours. Compteurs par phase en tête, filtre « À moi » (lots dont je suis le commercial ou qui
// portent une alerte qui m'est adressée). Lecture seule : un clic ouvre la fiche existante du mandat ou du bail.
import React, { useEffect, useMemo, useState } from 'react';
import { rpc } from './supabase.js';
import Fiche from './Fiche.jsx';
import DossierMandat from './SuiviMandat.jsx';
import { DossierBail } from './SuiviBaux.jsx';
import { nature, texteRecherche, correspond } from './cartes.jsx';

export const PHASES = [
  ['entree', 'Entrée en gestion'],
  ['location', 'Mise en location'],
  ['bail', 'Bail en cours'],
  ['sortie', 'Sortie'],
];
const COURT = { entree: 'Entrée', location: 'Location', bail: 'Bail', sortie: 'Sortie' };
const LIBELLE = Object.fromEntries([...PHASES, ['hors', 'Hors gestion']]);
const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '');

export default function Biens({ moi }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [filtre, setFiltre] = useState('tous'); // tous | entree | location | bail | sortie | a_moi | a_cloturer | hors
  const [q, setQ] = useState('');
  const [ouvert, setOuvert] = useState(null);
  const charger = () => rpc('pilotage_biens').then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  const lots = useMemo(() => {
    if (!d) return [];
    return d.lots.filter((l) => {
      if (filtre === 'tous' && l.phase === 'hors') return false;
      if (['entree', 'location', 'bail', 'sortie', 'hors'].includes(filtre) && l.phase !== filtre) return false;
      if (filtre === 'a_moi' && !(l.a_moi && l.phase !== 'hors')) return false;
      if (filtre === 'a_cloturer' && !(l.a_cloturer > 0)) return false;
      return !q || correspond(texteRecherche(l.lot && 'lot ' + l.lot, l.adresse, l.bailleur, l.mandat && 'mandat ' + l.mandat,
        l.bail && 'bail ' + l.bail, l.locataires, l.commercial, nature(l.nature), LIBELLE[l.phase]), q);
    });
  }, [d, filtre, q]);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const c = d.compteurs || {};
  const tuile = (k, libelle, n, aide) => <button key={k} className={'tuile tuile-filtre' + (filtre === k ? ' on' : '')} onClick={() => setFiltre(filtre === k ? 'tous' : k)}
    aria-pressed={filtre === k} title={aide}>
    <div className="muted">{libelle}</div><div className="tuile-n">{n || 0}</div></button>;
  const enGestion = PHASES.reduce((t, [k]) => t + (c[k] || 0), 0);
  return <>
    <div className="entete"><div><h1>Biens</h1>
      <p className="sub">Chaque lot sur sa frise : entrée en gestion, mise en location, bail en cours, sortie. Tout est déduit de Rivage ; un clic ouvre la fiche.</p></div></div>
    {err && <div className="banner">{err}</div>}
    <div className="tuiles">
      {tuile('tous', 'En gestion', enGestion, 'Tous les lots gérés')}
      {PHASES.map(([k, l]) => tuile(k, l, c[k]))}
      {tuile('a_moi', 'À moi', c.a_moi, 'Lots dont je suis le commercial, ou avec une alerte qui m’est adressée')}
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
      : <div className="stack" style={{ gap: 8 }}>{lots.map((l) => <LigneBien key={l.id} l={l} ouvrir={() => setOuvert(l)} />)}</div>}
    {ouvert && <Fiche titre={'Lot ' + (ouvert.lot || '') + ' · ' + (ouvert.adresse || '')} fermer={() => setOuvert(null)}>
      <FicheBien l={ouvert} peut={d.peut} moi={moi} apres={charger} />
    </Fiche>}
  </>;
}

function LigneBien({ l, ouvrir }) {
  const etape = l.etape != null ? (l.etapes || [])[l.etape] : null;
  const alerte = (l.etapes || []).some((e) => e.etat === 'alerte');
  return <div className={'kcarte bien ' + (alerte ? 'haute' : 'normale')} role="button" tabIndex={0} onClick={ouvrir}
    onKeyDown={(e) => { if (e.key === 'Enter') ouvrir(); }}>
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
      <div style={{ minWidth: 0 }}>
        <div className="kcarte-titre" style={{ marginTop: 0 }}>Lot {l.lot || '?'} · {l.adresse || 'adresse ?'}</div>
        <div className="muted">{nature(l.nature)} · {l.bailleur || 'bailleur ?'}{l.locataires ? ' · ' + l.locataires : ''}{l.commercial ? ' · ' + l.commercial : ''}</div>
      </div>
      <div className="row" style={{ gap: 6 }}>
        {l.alertes_moi > 0 && <span className="etq rose">{l.alertes_moi} alerte{l.alertes_moi > 1 ? 's' : ''} pour moi</span>}
        {l.fin_gestion && <span className="etq violet">Fin de gestion le {date(l.fin_gestion)}</span>}
        {l.relocation && <span className="etq ok">{l.relocation}</span>}
        {l.a_cloturer > 0 && <span className="etq rose" title="Bail resté en sortie dans Rivage plus de 2 mois après le départ">{l.a_cloturer} bail à clôturer</span>}
      </div>
    </div>
    <Frise phase={l.phase} />
    {l.phase !== 'hors' && <Etapes etapes={l.etapes} courante={l.etape} />}
    {etape?.info && <div className="muted" style={{ marginTop: 4 }}>{etape.libelle} : {etape.info}</div>}
  </div>;
}

// Les quatre phases, la phase en cours marquée
export function Frise({ phase }) {
  if (phase === 'hors') return <div className="frise"><span className="frise-phase hors">Hors gestion</span></div>;
  const i = PHASES.findIndex(([k]) => k === phase);
  return <ol className="frise" aria-label={'Phase : ' + LIBELLE[phase]}>
    {PHASES.map(([k, lib], n) => <li key={k} className={'frise-phase ' + (n < i ? 'passee' : n === i ? 'courante' : 'a-venir')}
      aria-current={n === i ? 'step' : undefined}><span className="long">{lib}</span><span className="court" aria-hidden="true">{COURT[k]}</span></li>)}
  </ol>;
}

// Détail de la phase en cours : chaque étape avec son état (fait, en cours, à venir, alerte)
const MARQUE = { fait: '✓', en_cours: '●', alerte: '!', a_venir: '○' };
export function Etapes({ etapes, courante }) {
  if (!etapes?.length) return null;
  return <ol className="etapes">
    {etapes.map((e, n) => <li key={n} className={'etape e-' + e.etat + (n === courante ? ' courante' : '')} title={e.info || ''}>
      <span className="etape-marque" aria-hidden="true">{MARQUE[e.etat] || '○'}</span>
      <span>{e.libelle}{e.date ? ' · ' + date(e.date) : ''}</span>
      <span className="sr">{{ fait: ' (fait)', en_cours: ' (en cours)', alerte: ' (à traiter)', a_venir: ' (à venir)' }[e.etat]}</span>
    </li>)}
  </ol>;
}

function FicheBien({ l, peut, moi, apres }) {
  return <>
    <Frise phase={l.phase} />
    {l.phase !== 'hors' && <Etapes etapes={l.etapes} courante={l.etape} />}
    {(l.etapes || []).filter((e) => e.info).length > 0 && <ul className="muted" style={{ margin: '8px 0 12px', paddingLeft: 18 }}>
      {l.etapes.filter((e) => e.info).map((e, n) => <li key={n}>{e.libelle} : {e.info}</li>)}
    </ul>}
    {l.bail_id
      ? <DossierBail b={{ bail_id: l.bail_id, reference: l.bail, locataires: l.locataires, adresse: l.adresse, bailleur: l.bailleur, mandat: l.mandat ? 'Mandat n°' + l.mandat : null, mandat_id: l.mandat_id }}
          peut={peut} moi={moi} apres={apres} />
      : l.mandat_id ? <DossierMandat m={{ id: l.mandat_id }} apres={apres} />
      : <p className="muted">Aucun mandat ni bail rattaché à ce lot dans Rivage.</p>}
  </>;
}
