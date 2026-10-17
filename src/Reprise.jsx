// Audit du stock repris dans Rivage (040) : dossiers aveugles d'abord (bail ou mandat signé absent de la GED), avancement des lectures IA,
// pièces manquantes par nature. À lancer par Nicolas une fois la reprise Rivage terminée. Rien n'est envoyé aux équipes.
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const NATURE_ECHEC = { bail: 'Bail', mandat: 'Mandat', edl: 'État des lieux', justificatif: 'Justificatif', commune: 'Commune' };
const TYPES = { commercial: 'Commercial', derogatoire: 'Dérogatoire', professionnel: 'Professionnel', vide: 'Habitation vide', meuble: 'Meublé', mobilite: 'Mobilité', etudiant: 'Étudiant' };

export default function Reprise({ moi }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_audit').then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const agir = async (fn, args) => { setErr(''); try { await rpc(fn, args); await charger(); } catch (e) { setErr(e.message); } };
  const pc = (a, b) => (b ? Math.round((a / b) * 100) : 0);
  return <>
    <div className="entete"><div><h1>Reprise du stock</h1>
      <p className="sub">Audit des baux et mandats repris dans Rivage : d’abord les dossiers sans acte signé, puis la lecture IA de tous les actes et le croisement avec Rivage. Aucune notification aux équipes pendant l’audit.</p></div>
      {moi.role === 'direction' && <button className={'btn ' + (d.actif ? 'gris' : 'plein')} onClick={() => agir('pilotage_audit_lancer', { p_actif: !d.actif })}>
        {d.actif ? 'Mettre l’audit en pause' : 'Lancer l’audit du stock'}</button>}
    </div>
    {err && <div className="banner">{err}</div>}
    {!d.actif && <div className="info">À lancer une fois la reprise Rivage terminée (données Wipimo et GED). Les lectures IA tournent ensuite toutes les 10 minutes (environ 20 actes par heure).</div>}
    {d.actif && <div className="info">Audit en cours depuis le {date(d.lance_le)} · {d.lectures_jour ?? 0} lecture(s) aujourd’hui sur un plafond de {d.plafond ?? 150} par jour (2 dossiers toutes les 5 minutes, reprise automatique le lendemain).</div>}
    {moi.role === 'direction' && d.plafond != null && <Plafond valeur={d.plafond} agir={agir} />}
    <div className="tuiles">
      <div className="tuile"><div className="muted">Baux lus par l’IA</div><div className="tuile-n">{d.baux.lus}/{d.baux.total}</div><div className="jauge"><div style={{ width: pc(d.baux.lus, d.baux.total) + '%' }} /></div></div>
      <div className="tuile"><div className="muted">Mandats lus par l’IA</div><div className="tuile-n">{d.mandats.lus}/{d.mandats.total}</div><div className="jauge"><div style={{ width: pc(d.mandats.lus, d.mandats.total) + '%' }} /></div></div>
      <div className="tuile"><div className="muted">Baux avec écarts Rivage</div><div className="tuile-n" style={{ color: d.baux.avec_ecarts ? 'var(--red)' : undefined }}>{d.baux.avec_ecarts}</div></div>
      <div className="tuile"><div className="muted">Mandats avec écarts Rivage</div><div className="tuile-n" style={{ color: d.mandats.avec_ecarts ? 'var(--red)' : undefined }}>{d.mandats.avec_ecarts}</div></div>
      <div className="tuile"><div className="muted">États des lieux lus · propositions à confirmer</div><div className="tuile-n">{d.edl.lus} · {d.edl.propositions}</div></div>
    </div>

    <h3>1. Dossiers aveugles : acte signé absent de la GED</h3>
    <p className="muted" style={{ fontSize: 13 }}>Sans l’acte, aucune condition ne peut être vérifiée dans Rivage : ce sont les dossiers à reconstituer en priorité. « Introuvable » (Nicolas ou Romain) les sort de la liste avec une justification.</p>
    <Aveugles titre={`Baux en cours sans bail signé (${d.baux.aveugles.length})`} items={d.baux.aveugles} cle={(x) => (['commercial', 'derogatoire', 'professionnel'].includes(x.type) ? 'c_doc_bail' : 'h_doc_bail')}
      ligne={(x) => <><b>{x.locataires || '—'}</b> · {x.adresse} · {TYPES[x.type] || 'type à préciser'}<span className="muted"> · bailleur : {x.bailleur || '—'}</span></>} agir={agir} />
    <Aveugles titre={`Mandats actifs sans mandat signé (${d.mandats.aveugles.length})`} items={d.mandats.aveugles} cle={() => 'm_doc_mandat'}
      ligne={(x) => <><b>{x.bailleur || '—'}</b> · mandat n° {x.reference}{x.nom ? ' · ' + x.nom : ''}</>} agir={agir} />

    {d.echecs?.length > 0 && <>
      <h3>Lectures impossibles ({d.echecs.length})</h3>
      <p className="muted" style={{ fontSize: 13 }}>Documents en échec deux fois de suite (scan illisible, lien Rivage expiré…) : ils ne sont plus retentés automatiquement pour ne pas payer la lecture en boucle. Vérifier le document dans Rivage, le remplacer si besoin, puis relancer.</p>
      <div className="stack" style={{ gap: 4, marginBottom: 12 }}>{d.echecs.map((e) => <div key={e.cle} className="row" style={{ justifyContent: 'space-between', fontSize: 13, borderTop: '1px solid var(--line)', padding: '4px 0' }}>
        <span><b>{NATURE_ECHEC[e.nature] || e.nature}</b> · {e.libelle || e.cle}<span className="muted"> · {e.erreur} · {e.nb} essai(s), dernier le {date(e.le)}</span></span>
        <button className="lien" onClick={() => agir('pilotage_lecture_relancer', { p_cle: e.cle })}>Relancer</button>
      </div>)}</div>
    </>}

    <h3>2. Pièces manquantes par nature</h3>
    <p className="muted" style={{ fontSize: 13 }}>Compte des pièces exigées absentes de Rivage, sur les baux en cours et les mandats actifs (date d’exigibilité légale prise en compte).{d.mandats_calcule_le ? ` Mandats recalculés le ${new Date(d.mandats_calcule_le).toLocaleString('fr-FR')}.` : ''}</p>
    {!d.pieces.length ? <p className="muted">Aucune pièce manquante.</p>
      : <div className="table-wrap"><table className="table-imp"><thead><tr><th>Pièce</th><th>Dossiers</th><th>Nombre</th></tr></thead>
        <tbody>{d.pieces.map((p) => <tr key={p.cle}><td>{p.libelle}</td><td>{p.portee === 'mandat' ? 'Mandats' : p.portee === 'commercial' ? 'Baux commerciaux' : 'Baux d’habitation'}</td><td><b>{p.n}</b></td></tr>)}</tbody></table></div>}
  </>;
}

function Aveugles({ titre, items, ligne, cle, agir }) {
  const [sel, setSel] = useState(null);
  const [justif, setJustif] = useState('');
  const restants = items.filter((x) => !x.introuvable);
  return <details className="replie" open={restants.length > 0 && restants.length <= 30} style={{ marginBottom: 10 }}>
    <summary style={{ cursor: 'pointer', fontWeight: 700 }}>{titre}{items.length - restants.length ? ` · ${items.length - restants.length} introuvable(s)` : ''}</summary>
    {!items.length && <p className="muted">Aucun.</p>}
    <div className="stack" style={{ gap: 4, marginTop: 6 }}>{items.map((x) => <div key={x.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13, borderTop: '1px solid var(--line)', padding: '4px 0', opacity: x.introuvable ? 0.6 : 1 }}>
      <span>{ligne(x)}{x.introuvable && <span className="etq"> introuvable</span>}</span>
      <span className="row">
        {x.lien && <a className="lien" href={x.lien} target="_blank" rel="noreferrer">Rivage</a>}
        {!x.introuvable && (sel === x.id ? <>
          <input placeholder="Justification (démarches faites, raison)" value={justif} onChange={(e) => setJustif(e.target.value)} style={{ width: 260 }} />
          <button className="btn plein" disabled={justif.trim().length < 10} onClick={async () => { await agir('pilotage_piece_introuvable', { p_dossier: x.id, p_cle: cle(x), p_justification: justif }); setSel(null); setJustif(''); }}>Confirmer</button>
          <button className="lien" onClick={() => setSel(null)}>Annuler</button></>
          : <button className="lien" onClick={() => { setSel(x.id); setJustif(''); }}>Introuvable</button>)}
      </span>
    </div>)}</div>
  </details>;
}

function Plafond({ valeur, agir }) {
  const [v, setV] = useState(String(valeur));
  return <div className="row" style={{ fontSize: 13, margin: '6px 0' }}>
    <span className="muted">Plafond de lectures IA par jour pendant l’audit</span>
    <input type="number" min={0} max={1000} value={v} onChange={(e) => setV(e.target.value)} style={{ width: 80 }} />
    <button className="btn" disabled={v === String(valeur) || v === ''} onClick={() => agir('pilotage_audit_plafond', { p_max: Number(v) })}>Enregistrer</button>
  </div>;
}
