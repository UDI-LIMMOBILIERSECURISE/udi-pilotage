// Tableau des clés (125), repris de WeRoof : n° de trousseau et agence dépositaire par lot Rivage, journal des prises et retours,
// état courant calculé sur le dernier mouvement. Un lot peut avoir plusieurs trousseaux (un par agence, par exemple).
// Page « Clés » (vue d'ensemble) et bloc « Clés » dans les fiches du mandat et du bail (ClesLots).
// Contrairement à WeRoof, la page ne liste que les lots qui ont des clés. « + Ajouter des clés » : sur un lot Rivage, ou sous un nom saisi
// à la main (clés d'un local, d'un bien hors Rivage), rattachables plus tard à un lot.
// Droits : toute l'équipe voit et note les prises et retours ; la gestion et la direction créent et modifient les trousseaux
// et rattachent les clés restées dans WeRoof.
import React, { useEffect, useMemo, useState } from 'react';
import { rpc } from './supabase.js';
import { nature, normaliser, correspond } from './cartes.jsx';
import Fiche from './Fiche.jsx';

export const MOTIFS = { edl_entree: 'EDL d’entrée', edl_sortie: 'EDL de sortie', visite: 'Visite', diagnostic: 'Diagnostic', travaux: 'Travaux',
  remise_locataire: 'Remise au locataire', restitution_locataire: 'Restitution par le locataire', autre: 'Autre' };
const QUI = { membre: 'Membre de l’équipe', prestataire: 'Prestataire', locataire: 'Locataire', proprietaire: 'Propriétaire', autre: 'Autre personne' };
const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const dateHeure = (d) => (d ? new Date(d).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—');
const jours = (d) => (d ? Math.floor((Date.now() - new Date(d).getTime()) / 86400000) : 0);
const maintenantLocal = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };

// État d'un lot : sorti si au moins un trousseau (ou des clés sans trousseau) est dehors ; jamais sorti s'il n'y a aucun mouvement
export const etatLot = (l) => (l.sorties > 0 ? 'sortie' : !l.dernier ? 'jamais' : 'agence');
const ETAT = { sortie: ['Sorties', 'encours'], agence: ['À l’agence', 'ok'], jamais: ['Jamais sorties', 'gris'] };
const trousseauTxt = (t) => [t.numero ? 'n° ' + t.numero : 'sans n°', t.agence_nom].filter(Boolean).join(' · ');
const detenteurs = (l) => [...(l.trousseaux || []).map((t) => t.etat), l.etat_lot].filter((e) => e && e.type === 'prise');

export default function Cles() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [q, setQ] = useState('');
  const [etat, setEtat] = useState('tous');
  const [agence, setAgence] = useState('');
  const [motif, setMotif] = useState('');
  const [tri, setTri] = useState('lot');
  const [ouvert, setOuvert] = useState(null); // clé de l'entrée ouverte : asset_id du lot, ou « t<id> » pour des clés sans lot
  const [ajout, setAjout] = useState(false);
  const charger = () => rpc('pilotage_cles_liste').then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);

  const lots = useMemo(() => (d?.lots || []).map((l) => ({ ...l, _etat: etatLot(l),
    _txt: normaliser([l.lot, l.libelle, l.adresse, l.mandat, nature(l.nature), ...(l.trousseaux || []).flatMap((t) => [t.numero, t.agence_nom, t.composition, t.note]),
      ...detenteurs(l).map((e) => e.detenteur)].filter(Boolean).join(' ')) })), [d]);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;

  const aVerifier = (l) => (l.trousseaux || []).some((t) => t.a_verifier || (t.aussi_sur || []).length);
  const FILTRES = [['tous', 'Toutes', () => true], ['sortie', 'Sorties', (l) => l._etat === 'sortie'], ['agence', 'À l’agence', (l) => l._etat === 'agence'],
    ['jamais', 'Jamais sorties', (l) => l._etat === 'jamais'], ['verifier', 'À vérifier', aVerifier]];
  const f = FILTRES.find((x) => x[0] === etat) || FILTRES[0];
  const vus = lots.filter(f[2])
    .filter((l) => !agence || (l.trousseaux || []).some((t) => t.agence === agence))
    .filter((l) => !motif || l.dernier?.motif === motif)
    .filter((l) => !q || correspond(l._txt, q))
    .sort(tri === 'date' ? (a, b) => new Date(b.dernier?.date || 0) - new Date(a.dernier?.date || 0)
      : tri === 'numero' ? (a, b) => String(a.trousseaux?.[0]?.numero || '~').localeCompare(String(b.trousseaux?.[0]?.numero || '~'), 'fr', { numeric: true })
      : (a, b) => String(a.lot).localeCompare(String(b.lot), 'fr', { numeric: true }));
  const sorties = lots.filter((l) => l._etat === 'sortie');
  const longues = sorties.filter((l) => detenteurs(l).some((e) => jours(e.date) > 30));

  return <>
    <div className="entete"><div><h1>Clés</h1>
      <p className="sub">Trousseaux rangés à l’agence et clés sorties, lot par lot. Une prise ou un retour se note depuis la fiche du lot, du mandat ou du bail.</p></div>
      {d.peut && <button className="btn plein" onClick={() => setAjout(!ajout)}>{ajout ? 'Fermer' : '+ Ajouter des clés'}</button>}</div>
    {err && <div className="banner">{err}</div>}
    {ajout && <AjoutTrousseau d={d} fini={async (cle) => { setAjout(false); await charger(); if (cle) setOuvert(cle); }} />}
    <div className="tuiles">
      <div className="tuile"><div className="muted">Lots et clés suivis</div><div className="tuile-n">{lots.length}</div></div>
      <div className="tuile"><div className="muted">Clés sorties</div><div className="tuile-n" style={{ color: sorties.length ? 'var(--amber)' : undefined }}>{sorties.length}</div></div>
      <div className="tuile"><div className="muted">Sorties depuis plus de 30 jours</div><div className="tuile-n" style={{ color: longues.length ? 'var(--red)' : undefined }}>{longues.length}</div></div>
      {d.peut && d.weroof.length > 0 && <div className="tuile"><div className="muted">Clés WeRoof à rattacher</div><div className="tuile-n">{d.weroof.length}</div></div>}
    </div>
    <input className="recherche" placeholder="Rechercher : n° de trousseau, nom des clés, lot, adresse, mandat, détenteur" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Rechercher des clés" />
    <div className="row" style={{ margin: '10px 0' }}>
      {FILTRES.map(([k, l, t]) => <button key={k} className={'chip' + (etat === k ? ' on' : '')} onClick={() => setEtat(k)}>{l}<span className="n">{lots.filter(t).length}</span></button>)}
    </div>
    <div className="row" style={{ marginBottom: 12 }}>
      <select value={agence} onChange={(e) => setAgence(e.target.value)} aria-label="Agence dépositaire">
        <option value="">Toutes les agences</option>{d.agences.map((a) => <option key={a.code} value={a.code}>{a.nom}</option>)}</select>
      <select value={motif} onChange={(e) => setMotif(e.target.value)} aria-label="Motif du dernier mouvement">
        <option value="">Tous les motifs</option>{Object.entries(MOTIFS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
      <select value={tri} onChange={(e) => setTri(e.target.value)} aria-label="Trier">
        <option value="lot">Tri par lot</option><option value="numero">Tri par n° de trousseau</option><option value="date">Dernier mouvement d’abord</option></select>
    </div>
    {!lots.length ? <div className="card">Aucune clé enregistrée.{d.peut ? ' « + Ajouter des clés » pour commencer.' : ''}</div>
      : !vus.length ? <div className="card">Rien avec ces filtres.</div>
      : <div className="stack" style={{ gap: 8 }}>{vus.map((l) => <CarteLot key={l.cle} l={l} ouvrir={() => setOuvert(l.cle)} />)}</div>}
    {d.peut && d.weroof.length > 0 && <ClesWeroof d={d} apres={charger} onErreur={setErr} />}
    {ouvert && <Fiche titre={titreEntree(lots.find((l) => l.cle === ouvert))} fermer={() => { setOuvert(null); charger(); }}>
      {ouvert.startsWith('t') ? <ClesLots trousseau={Number(ouvert.slice(1))} ouvert /> : <ClesLots assets={[ouvert]} ouvert />}</Fiche>}
  </>;
}

const titreEntree = (l) => (!l ? 'Clés' : l.libre ? 'Clés · ' + l.libelle : 'Clés · lot ' + l.lot);

function CarteLot({ l, ouvrir }) {
  const [lib, cls] = ETAT[l._etat];
  const dehors = detenteurs(l);
  return <article className={'card ' + (dehors.some((e) => jours(e.date) > 30) ? 'haute' : 'normale')} style={{ padding: 12, cursor: 'pointer' }} onClick={ouvrir}>
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
      <div style={{ flex: 1, minWidth: 220 }}>
        {l.libre ? <><div className="kcarte-titre" style={{ marginTop: 0 }}>{l.libelle}</div><div className="muted">Clés sans lot Rivage (nom saisi à la main)</div></>
          : <><div className="kcarte-titre" style={{ marginTop: 0 }}>Lot {l.lot} · {nature(l.nature)}{l.mandat ? ' · mandat ' + l.mandat : ''}</div>
            <div className="muted">{l.adresse}</div></>}
        <div className="row" style={{ marginTop: 6, gap: 6 }}>
          {(l.trousseaux || []).map((t) => <span key={t.id} className="etq info" style={{ maxWidth: 'none' }}>{trousseauTxt(t)}</span>)}
          {!(l.trousseaux || []).length && <span className="muted">Aucun trousseau enregistré</span>}
          {(l.trousseaux || []).some((t) => t.a_verifier) && <span className="sev haute">Reprise WeRoof à vérifier</span>}
          {(l.trousseaux || []).some((t) => (t.aussi_sur || []).length) && <span className="sev haute">N° aussi sur un autre lot</span>}
        </div>
      </div>
      <div style={{ textAlign: 'right', minWidth: 160 }}>
        <span className={'etq ' + cls}>{lib}</span>
        {dehors.map((e, i) => <div key={i} style={{ fontSize: 13, marginTop: 4 }}>Chez <b>{e.detenteur}</b> depuis le {date(e.date)}{e.motif ? ' · ' + MOTIFS[e.motif] : ''}
          {jours(e.date) > 30 && <span className="muted"> ({jours(e.date)} j)</span>}</div>)}
        {!dehors.length && l.dernier && <div className="muted" style={{ marginTop: 4 }}>Rendues le {date(l.dernier.date)}</div>}
      </div>
    </div>
  </article>;
}

// Bloc des clés pour une liste de lots (fiche du mandat) ou pour le lot d'un bail ; replié par défaut, ouvert dans la page Clés
export function ClesLots({ assets, bail, trousseau, ouvert = false }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const cle = JSON.stringify([assets || [], bail || null, trousseau || null]);
  const charger = () => rpc('pilotage_cles_lots', { p_assets: assets || null, p_bail: bail || null, p_trousseau: trousseau || null }).then(setD).catch((e) => setErr(e.message));
  useEffect(() => { setD(null); charger(); }, [cle]);
  if (!d) return err ? <div className="err">Clés : {err}</div> : null;
  const contenu = <>
    {err && <div className="err">{err}</div>}
    {!d.lots.length && <p className="muted">{trousseau ? 'Clés introuvables (supprimées ou rattachées à un lot entre-temps).' : 'Lot inconnu dans Rivage.'}</p>}
    {d.lots.map((l) => <LotCles key={l.cle} l={l} d={d} seul={d.lots.length === 1} apres={charger} onErreur={setErr} />)}
  </>;
  if (ouvert) return contenu;
  const resume = d.lots.map((l) => {
    const t = (l.trousseaux || []).map((x) => (x.numero ? 'n° ' + x.numero : 'sans n°')).join(', ');
    return (d.lots.length > 1 ? 'lot ' + l.lot + ' : ' : '') + (t || 'aucun trousseau') + (l.sorties > 0 ? ' (sorties)' : '');
  }).join(' · ');
  return <details className="replie" style={{ marginTop: 10 }} open={d.lots.some((l) => l.sorties > 0)}>
    <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Clés · {resume || '—'}</summary>
    {contenu}
  </details>;
}

function LotCles({ l, d, seul, apres, onErreur }) {
  const [forme, setForme] = useState(null); // { type: 'prise' | 'retour', trousseau } ou { trousseau: objet | 'nouveau' }
  const [tout, setTout] = useState(false);
  const agir = async (fn, args) => { onErreur(''); try { await rpc(fn, args); setForme(null); await apres(); } catch (e) { onErreur(e.message); } };
  const trs = l.trousseaux || [];
  const mvts = l.mouvements || [];
  const vus = tout ? mvts : mvts.slice(0, 10);
  const peutSupprimer = (m) => ['direction', 'superviseur'].includes(d.role) || (m.par_id === d.moi && jours(m.saisi_le) < 1);
  return <div style={{ borderTop: seul ? 0 : '1px solid var(--line)', padding: '8px 0' }}>
    {!seul && <div style={{ fontWeight: 700, fontSize: 14 }}>Lot {l.lot} · {nature(l.nature)} <span className="muted">· {l.adresse}</span></div>}
    {seul && <div className="muted" style={{ marginBottom: 6 }}>{l.libre ? 'Clés sans lot Rivage, enregistrées sous le nom « ' + l.libelle + ' »'
      : <>Lot {l.lot} · {nature(l.nature)} · {l.adresse}{l.mandat ? ' · mandat ' + l.mandat : ''}</>}</div>}

    {trs.map((t) => <div key={t.id} className={'mini-alerte ' + (t.etat?.type === 'prise' ? 'haute' : 'normale')} style={{ background: t.etat?.type === 'prise' ? 'var(--amber-bg)' : 'var(--teal-bg)', color: 'var(--ink)' }}>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <div><b>Trousseau {t.numero ? 'n° ' + t.numero : 'sans numéro'}</b>{t.agence_nom ? ' · ' + t.agence_nom : ' · agence non renseignée'}
          {t.composition && <span className="muted"> · {t.composition}</span>}
          <div style={{ fontSize: 13, marginTop: 2 }}>{!t.etat ? 'Jamais sorti' : t.etat.type === 'prise'
            ? <>Sorti : chez <b>{t.etat.detenteur}</b> depuis le {date(t.etat.date)}{t.etat.motif ? ' · ' + MOTIFS[t.etat.motif] : ''}</>
            : <>À l’agence depuis le {date(t.etat.date)}</>}</div>
          {t.note && <div className="muted">{t.note}</div>}
          {t.a_verifier && <div className="muted" style={{ color: 'var(--amber)' }}>{t.a_verifier}</div>}
          {(t.aussi_sur || []).length > 0 && <div className="muted" style={{ color: 'var(--amber)' }}>Même n° dans la même agence : {t.aussi_sur.join(', ')}. Trousseau commun ou erreur à corriger.</div>}
        </div>
        <div className="row">
          <button className="btn plein" onClick={() => setForme({ type: t.etat?.type === 'prise' ? 'retour' : 'prise', trousseau: t.id })}>{t.etat?.type === 'prise' ? 'Noter le retour' : 'Noter une prise'}</button>
          {d.peut && <button className="btn gris" onClick={() => setForme({ trousseau: t })}>Modifier</button>}
        </div>
      </div>
      {forme?.trousseau === t && <FormTrousseau t={t} asset={l.asset_id} libre={l.libre} d={d} agir={agir} annuler={() => setForme(null)} />}
      {forme?.type && forme.trousseau === t.id && <FormMouvement l={l} d={d} type={forme.type} trousseau={t.id} agir={agir} annuler={() => setForme(null)} />}
    </div>)}

    {/* Clés notées sans trousseau (lot sans trousseau enregistré) */}
    {!l.libre && (!trs.length || l.etat_lot) && <div className="mini-alerte normale" style={{ color: 'var(--ink)' }}>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <div>{!trs.length && <b>Aucun trousseau enregistré. </b>}
          {l.etat_lot ? (l.etat_lot.type === 'prise' ? <>Clés sorties : chez <b>{l.etat_lot.detenteur}</b> depuis le {date(l.etat_lot.date)}</> : <>Clés rendues le {date(l.etat_lot.date)}</>)
            : <span className="muted">Une prise peut être notée sans trousseau.</span>}</div>
        {!trs.length && <button className="btn" onClick={() => setForme({ type: l.etat_lot?.type === 'prise' ? 'retour' : 'prise', trousseau: null })}>{l.etat_lot?.type === 'prise' ? 'Noter le retour' : 'Noter une prise'}</button>}
      </div>
      {forme?.type && forme.trousseau === null && <FormMouvement l={l} d={d} type={forme.type} trousseau={null} agir={agir} annuler={() => setForme(null)} />}
    </div>}

    {d.peut && !l.libre && (forme?.trousseau === 'nouveau'
      ? <FormTrousseau t={null} asset={l.asset_id} d={d} agir={agir} annuler={() => setForme(null)} />
      : <button className="lien" onClick={() => setForme({ trousseau: 'nouveau' })}>+ Ajouter un trousseau à ce lot</button>)}

    {mvts.length > 0 && <>
      <div style={{ fontWeight: 700, fontSize: 13, marginTop: 10 }}>Historique ({mvts.length})</div>
      <ol className="histo">{vus.map((m) => <li key={m.id}>
        <span className="muted" style={{ minWidth: 92 }}>{dateHeure(m.date)}</span>
        <span style={{ flex: 1 }}><b>{m.type === 'prise' ? 'Prise' : 'Retour'}</b>{m.trousseau ? ' (n° ' + m.trousseau + ')' : ''} · {m.detenteur}
          {m.qui !== 'membre' ? <span className="muted"> ({QUI[m.qui].toLowerCase()})</span> : null}
          {m.motif ? ' · ' + MOTIFS[m.motif] : ''}{m.commentaire ? ' · ' + m.commentaire : ''}
          <span className="muted"> · {m.source === 'weroof' ? 'repris de WeRoof' : 'noté par ' + (m.saisi_par || '—')}</span></span>
        {m.source !== 'weroof' && peutSupprimer(m) && <button className="lien" onClick={() => window.confirm('Retirer ce mouvement saisi par erreur ?') && agir('pilotage_cles_mouvement_supprimer', { p_id: m.id })}>Retirer</button>}
      </li>)}</ol>
      {mvts.length > 10 && !tout && <button className="lien" onClick={() => setTout(true)}>Voir les {mvts.length - 10} mouvements plus anciens</button>}
    </>}
  </div>;
}

function FormTrousseau({ t, asset, libre = false, d, agir, annuler }) {
  const [rattacher, setRattacher] = useState(null); // clés sans lot : lot Rivage choisi pour les y rattacher
  const [f, setF] = useState({ libelle: t?.libelle || '', numero: t?.numero || '', agence: t?.agence || (d.agences[0]?.code || ''), composition: t?.composition || '', note: t?.note || '' });
  const ch = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const valide = (f.numero.trim() || f.composition.trim()) && (!libre || f.libelle.trim() || rattacher);
  const args = (supprimer) => ({ p_id: t?.id || null, p_asset: rattacher?.id || asset || null, p_libelle: libre ? f.libelle : null, p_numero: f.numero,
    p_agence: f.agence || null, p_composition: f.composition, p_note: f.note, p_supprimer: supprimer });
  return <div className="card" style={{ marginTop: 8, padding: 12 }}>
    {libre && <label className="muted" style={{ display: 'block', marginBottom: 6 }}>Nom des clés<br /><input value={f.libelle} onChange={ch('libelle')}
      placeholder="Ex. Local vélos, 10 rue de Villoison" style={{ width: '100%' }} /></label>}
    <div className="row" style={{ alignItems: 'flex-end' }}>
      <label className="muted">N° du trousseau<br /><input value={f.numero} onChange={ch('numero')} placeholder="Ex. 37" style={{ width: 110 }} /></label>
      <label className="muted">Agence où il est rangé<br /><select value={f.agence} onChange={ch('agence')}><option value="">Non renseignée</option>
        {d.agences.map((a) => <option key={a.code} value={a.code}>{a.nom}</option>)}</select></label>
      <label className="muted" style={{ flex: 1, minWidth: 200 }}>Contenu<br /><input value={f.composition} onChange={ch('composition')} placeholder="Ex. 3 clés, 1 bip, 1 badge" style={{ width: '100%' }} /></label>
    </div>
    <label className="muted" style={{ display: 'block', marginTop: 6 }}>Note<br /><input value={f.note} onChange={ch('note')} style={{ width: '100%' }} /></label>
    {t?.a_verifier && <div className="muted" style={{ marginTop: 4 }}>Enregistrer valide la reprise WeRoof : la mention « à vérifier » disparaît.</div>}
    {libre && t && <div style={{ marginTop: 8 }}>{rattacher
      ? <div className="muted">Rattachées au lot {rattacher.lot} · {rattacher.adresse} à l’enregistrement, avec leur historique. <button className="lien" onClick={() => setRattacher(null)}>Annuler</button></div>
      : <ChoixLot d={d} libelle="Rattacher ces clés à un lot Rivage (facultatif)" choisir={setRattacher} />}</div>}
    <div className="row" style={{ marginTop: 8 }}>
      <button className="btn plein" disabled={!valide} onClick={() => agir('pilotage_cles_trousseau', args(false))}>Enregistrer</button>
      <button className="btn gris" onClick={annuler}>Annuler</button>
      {t && <button className="lien" onClick={() => window.confirm('Supprimer ce trousseau ? Son historique reste dans le journal du lot.') && agir('pilotage_cles_trousseau', { ...args(true), p_asset: null })}>Supprimer le trousseau</button>}
    </div>
  </div>;
}

function FormMouvement({ l, d, type, trousseau, agir, annuler }) {
  const [f, setF] = useState({ type, qui: 'membre', membre: d.moi || '', nom: '', motif: '', date: maintenantLocal(), commentaire: '' });
  const ch = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const noms = (d.noms || []).filter((n) => n.qui === f.qui).map((n) => n.nom);
  const valide = f.qui === 'membre' ? !!f.membre : !!f.nom.trim();
  const idListe = 'noms-cles-' + l.cle;
  return <div className="card" style={{ marginTop: 8, padding: 12 }}>
    <div className="row">
      {['prise', 'retour'].map((x) => <button key={x} className={'chip' + (f.type === x ? ' on' : '')} onClick={() => setF({ ...f, type: x })}>{x === 'prise' ? 'Prise des clés' : 'Retour à l’agence'}</button>)}
    </div>
    <div className="row" style={{ marginTop: 8 }}>
      {Object.entries(QUI).map(([k, lib]) => <button key={k} className={'chip' + (f.qui === k ? ' on' : '')} onClick={() => setF({ ...f, qui: k })}>{lib}</button>)}
    </div>
    <div className="row" style={{ marginTop: 8, alignItems: 'flex-end' }}>
      {f.qui === 'membre'
        ? <label className="muted">Qui<br /><select value={f.membre} onChange={ch('membre')}>{d.membres.map((m) => <option key={m.id} value={m.id}>{m.prenom}</option>)}</select></label>
        : <label className="muted" style={{ flex: 1, minWidth: 200 }}>Nom<br /><input list={idListe} value={f.nom} onChange={ch('nom')} placeholder={f.qui === 'prestataire' ? 'Entreprise' : 'Nom et prénom'} style={{ width: '100%' }} />
          <datalist id={idListe}>{noms.map((n) => <option key={n} value={n} />)}</datalist></label>}
      <label className="muted">Motif<br /><select value={f.motif} onChange={ch('motif')}><option value="">—</option>
        {Object.entries(MOTIFS).map(([k, lib]) => <option key={k} value={k}>{lib}</option>)}</select></label>
      <label className="muted">Date et heure<br /><input type="datetime-local" value={f.date} max={maintenantLocal()} onChange={ch('date')} /></label>
    </div>
    <label className="muted" style={{ display: 'block', marginTop: 6 }}>Commentaire<br /><input value={f.commentaire} onChange={ch('commentaire')} style={{ width: '100%' }} /></label>
    <div className="row" style={{ marginTop: 8 }}>
      <button className="btn plein" disabled={!valide} onClick={() => agir('pilotage_cles_mouvement', { p_asset: l.asset_id, p_trousseau: trousseau, p_type: f.type,
        p_date: f.date ? new Date(f.date).toISOString() : null, p_qui: f.qui, p_membre: f.qui === 'membre' ? f.membre : null, p_nom: f.nom, p_motif: f.motif || null, p_commentaire: f.commentaire })}>Enregistrer</button>
      <button className="btn gris" onClick={annuler}>Annuler</button>
    </div>
  </div>;
}

// Nouvelles clés depuis la page Clés : sur un lot Rivage (recherche par n° ou adresse), ou sous un nom saisi à la main
function ChoixLot({ d, libelle, choisir }) {
  const [q, setQ] = useState('');
  const choix = useMemo(() => (q.trim().length < 2 ? [] : (d.tous_lots || []).filter((l) => correspond(normaliser(l.lot + ' ' + l.adresse), q)).slice(0, 8)), [q, d]);
  return <>
    <label className="muted">{libelle}<br /><input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Ex. 14 ou rue du Père Legris" style={{ width: '100%' }} /></label>
    <div className="stack" style={{ gap: 4, marginTop: 6 }}>{choix.map((l) =>
      <button key={l.id} className="btn gris" style={{ justifyContent: 'flex-start' }} onClick={() => choisir(l)}>Lot {l.lot} · {l.adresse}</button>)}</div>
    {q.trim().length >= 2 && !choix.length && <div className="muted">Aucun lot trouvé.</div>}
  </>;
}

function AjoutTrousseau({ d, fini }) {
  const [mode, setMode] = useState('lot');
  const [lot, setLot] = useState(null);
  const [err, setErr] = useState('');
  const enregistrer = async (fn, args) => {
    setErr('');
    try { const id = await rpc(fn, args); fini(args.p_asset || 't' + id); } catch (e) { setErr(e.message); }
  };
  return <div className="card" style={{ marginBottom: 12 }}>
    <div className="row" style={{ marginBottom: 8 }}>
      <button className={'chip' + (mode === 'lot' ? ' on' : '')} onClick={() => setMode('lot')}>Sur un lot Rivage</button>
      <button className={'chip' + (mode === 'libre' ? ' on' : '')} onClick={() => { setMode('libre'); setLot(null); }}>Sous un nom saisi à la main</button>
    </div>
    {err && <div className="err">{err}</div>}
    {mode === 'libre'
      ? <><div className="muted">Clés d’un local, d’un bien hors Rivage… Elles pourront être rattachées plus tard à un lot.</div>
        <FormTrousseau t={null} asset={null} libre d={d} annuler={() => fini(null)} agir={enregistrer} /></>
      : lot ? <><b>Lot {lot.lot}</b> <span className="muted">· {lot.adresse}</span> <button className="lien" onClick={() => setLot(null)}>Changer de lot</button>
        <FormTrousseau t={null} asset={lot.id} d={d} annuler={() => fini(null)} agir={enregistrer} /></>
      : <ChoixLot d={d} libelle="Lot (n° Rivage ou adresse)" choisir={setLot} />}
  </div>;
}

// Clés restées dans WeRoof : rapprochement seulement proposé, plusieurs lots validés ou aucun lot. La gestion choisit le lot ou écarte.
function ClesWeroof({ d, apres, onErreur }) {
  const [choix, setChoix] = useState({});
  const [q, setQ] = useState({});
  const agir = async (args) => { onErreur(''); try { await rpc('pilotage_cles_weroof', args); await apres(); } catch (e) { onErreur(e.message); } };
  return <details className="replie" style={{ marginTop: 20 }} open>
    <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Clés WeRoof à rattacher à un lot ({d.weroof.length})</summary>
    <div className="muted" style={{ margin: '4px 0 8px' }}>Biens WeRoof qui ont un trousseau ou des mouvements de clés, sans lot Rivage sûr. Choisir le lot reprend le trousseau et tout l’historique.</div>
    <div className="stack" style={{ gap: 8 }}>{d.weroof.map((w) => {
      const recherche = q[w.bien_id] || '';
      const trouves = recherche.trim().length < 2 ? [] : d.tous_lots.filter((l) => correspond(normaliser(l.lot + ' ' + l.adresse), recherche)).slice(0, 6);
      const options = [...(w.candidats || []).map((c) => ({ id: c.asset_id, lot: c.lot, adresse: c.adresse, statut: c.statut })), ...trouves.filter((t) => !(w.candidats || []).some((c) => c.asset_id === t.id))];
      return <div key={w.bien_id} className="card" style={{ padding: 12 }}>
        <b>{w.adresse}</b>
        <div className="muted">WeRoof : trousseau {w.trousseau || '—'}{w.cles_numero && w.cles_numero !== w.trousseau ? ' · n° clés « ' + w.cles_numero + ' »' : ''}{w.agence ? ' · ' + w.agence : ''} · {w.mouvements} mouvement(s)</div>
        <div className="row" style={{ marginTop: 6 }}>
          {options.map((o) => <button key={o.id} className={'chip' + (choix[w.bien_id] === o.id ? ' on' : '')} onClick={() => setChoix({ ...choix, [w.bien_id]: o.id })}>
            Lot {o.lot} · {o.adresse}{o.statut ? ' · ' + (o.statut === 'valide' ? 'rapprochement validé' : 'proposé') : ''}</button>)}
        </div>
        <div className="row" style={{ marginTop: 6 }}>
          <input placeholder="Autre lot : n° ou adresse" value={recherche} onChange={(e) => setQ({ ...q, [w.bien_id]: e.target.value })} style={{ minWidth: 220 }} />
          <button className="btn plein" disabled={!choix[w.bien_id]} onClick={() => agir({ p_bien: w.bien_id, p_asset: choix[w.bien_id], p_ecarter: false })}>Rattacher</button>
          <button className="btn gris" onClick={() => window.confirm('Ne pas reprendre ces clés WeRoof dans le pilotage ?') && agir({ p_bien: w.bien_id, p_asset: null, p_ecarter: true })}>Ne pas reprendre</button>
        </div>
      </div>;
    })}</div>
  </details>;
}
