// Fiche du congé (096) : ce que Rivage ne donne pas pour la sortie d'un locataire, saisi par la gestionnaire.
// Réception du congé, nouvelle adresse, pré-visite (décidée à la réception), état des lieux de sortie (interne ou prestataire,
// commandé le, date, heure), suite voulue par le bailleur. La date de l'EDL remplit les messages de confirmation et de rappel.
// 097-098 : date du congé, fin du bail et date de l'EDL de sortie lues dans Rivage, sans ressaisie ; un champ n'apparaît que si
// Rivage ne donne pas la date. Pour l'EDL, seule l'heure du rendez-vous est à saisir.
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const SUITE = { relouer: 'Relouer', reprise: 'Reprendre le bien', vente: 'Vendre' };
const VIDE = { recu_le: '', nouvelle_adresse: '', previsite: null, previsite_le: '', previsite_heure: '', edl_par: '', edl_commande_le: '',
  edl_le: '', edl_heure: '', edl_intervenant: '', suite: '', notes: '' };

export default function FicheConge({ bail, apres }) {
  const [d, setD] = useState(null);
  const [f, setF] = useState(VIDE);
  const [err, setErr] = useState('');
  const [ok, setOk] = useState('');
  const appliquer = (x) => {
    setD(x); const v = { ...VIDE }; Object.keys(VIDE).forEach((k) => { if (x?.fiche && x.fiche[k] != null) v[k] = x.fiche[k]; });
    setF(v);
  };
  useEffect(() => { setD(null); setErr(''); setOk(''); rpc('pilotage_fiche_conge', { p_bail: bail }).then(appliquer).catch(() => setD(false)); }, [bail]);
  if (!d || (d.statut !== 'move_out' && !d.fiche)) return null;
  const ch = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const enregistrer = async (valeurs = f) => {
    setErr(''); setOk('');
    try { appliquer(await rpc('pilotage_fiche_conge_maj', { p_bail: bail, p_valeurs: valeurs })); setOk('Enregistré'); apres && apres(); }
    catch (e) { setErr(e.message); }
  };
  const lecture = !d.peut;
  const dg = d.dg || {};
  const rv = d.rivage || {};
  return (
    <div className="card" style={{ margin: '12px 0', borderLeft: '4px solid var(--teal)' }}>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h3 style={{ margin: 0 }}>Fiche du congé</h3>
        <span className="muted">Départ le {date(d.sortie)}{d.fiche?.maj_le ? ` · mise à jour le ${date(d.fiche.maj_le)}${d.fiche.maj_par_prenom ? ' par ' + d.fiche.maj_par_prenom : ''}` : ''}</span>
      </div>
      <div className="grid2" style={{ fontSize: 13, margin: '6px 0 4px', gridTemplateColumns: 'minmax(120px, 170px) 1fr' }}>
        <span className="muted">Congé reçu le</span>
        <span>{rv.date_conge ? date(rv.date_conge) + (rv.source_conge === 'preavis' ? ' (préavis Rivage)' : ' (passage en sortie dans Rivage)')
          : <input type="date" disabled={lecture} value={f.recu_le} onChange={ch('recu_le')} aria-label="Congé reçu le (absent de Rivage)" />}</span>
        <span className="muted">Fin du bail</span>
        <span>{date(rv.fin_bail)} (Rivage){rv.sortie_locataires && rv.sortie_locataires !== rv.fin_bail ? ` · sortie des locataires saisie au ${date(rv.sortie_locataires)}` : ''}</span>
        <span className="muted">État des lieux de sortie</span>
        <span>{rv.edl_rivage ? date(rv.edl_rivage) + ' (Rivage)'
          : <input type="date" disabled={lecture} value={f.edl_le} onChange={ch('edl_le')} aria-label="Date de l’EDL de sortie (absente de Rivage)" />}
          {' '}à <input style={{ width: 80 }} disabled={lecture} value={f.edl_heure} onChange={ch('edl_heure')} placeholder="9h30" aria-label="Heure de l’EDL de sortie" /></span>
      </div>
      <div className="muted" style={{ fontSize: 13, margin: '4px 0 8px' }}>
        Dépôt de garantie : {dg.detenteur === 'bailleur' ? 'détenu par le bailleur' : dg.detenteur === 'agence' ? 'détenu par l’agence' : 'détenteur à préciser (Sorties et DG)'}
        {dg.detenteur === 'bailleur' && (dg.demande_le ? ` · reversement demandé le ${date(dg.demande_le)}` : ' · reversement demandé avec le mail au bailleur (étape « Congé reçu »)')}
      </div>
      <fieldset disabled={lecture} style={{ border: 0, padding: 0, margin: 0 }}>
        <div className="grille-champs">
          <label>Nouvelle adresse du locataire <input value={f.nouvelle_adresse} onChange={ch('nouvelle_adresse')} placeholder="pour le solde du dépôt" /></label>
        </div>
        <div className="row" style={{ marginTop: 8, gap: 10 }}>
          <b>Pré-visite</b>
          {[[true, 'Oui'], [false, 'Non']].map(([v, l]) => <label key={l}><input type="radio" name={'pv' + bail} checked={f.previsite === v} onChange={() => setF({ ...f, previsite: v })} /> {l}</label>)}
          {f.previsite === null && <span className="muted">à décider à la réception du congé</span>}
          {f.previsite === true && <>
            <label>le <input type="date" value={f.previsite_le} onChange={ch('previsite_le')} /></label>
            <label>à <input style={{ width: 80 }} value={f.previsite_heure} onChange={ch('previsite_heure')} placeholder="14h30" /></label>
          </>}
        </div>
        <div className="row" style={{ marginTop: 8, gap: 10 }}>
          <b>EDL fait par</b>
          <select value={f.edl_par} onChange={ch('edl_par')} aria-label="État des lieux fait par">
            <option value="">fait par…</option><option value="prestataire">le prestataire{d.prestataire?.nom ? ` (${d.prestataire.nom})` : ''}</option><option value="interne">l’agence (interne)</option>
          </select>
          {f.edl_par !== 'interne' && <label>commandé le <input type="date" value={f.edl_commande_le} onChange={ch('edl_commande_le')} /></label>}
        </div>
        <div className="row" style={{ marginTop: 6, gap: 10 }}>
          <label>Intervenant <input value={f.edl_intervenant} onChange={ch('edl_intervenant')} placeholder="nom de l’expert ou du collaborateur" /></label>
        </div>
        <div className="row" style={{ marginTop: 8, gap: 10 }}>
          <label>Suite voulue par le bailleur <select value={f.suite} onChange={ch('suite')}>
            <option value="">pas encore de réponse</option>{Object.entries(SUITE).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
        </div>
        <label style={{ display: 'block', marginTop: 8 }}>Notes <textarea rows={2} style={{ width: '100%', fontFamily: 'inherit' }} value={f.notes} onChange={ch('notes')} /></label>
        {!lecture && <div className="row" style={{ marginTop: 8 }}>
          <button className="btn plein" onClick={() => enregistrer()}>Enregistrer la fiche</button>
          {ok && <span className="muted">✓ {ok}</span>}
        </div>}
      </fieldset>
      {err && <div className="err">{err}</div>}
      <p className="muted" style={{ fontSize: 12, marginBottom: 0 }}>Une fois l’heure de l’état des lieux enregistrée, la confirmation (mail) et le rappel (SMS) au locataire sont prêts dans les messages « État des lieux de sortie ».</p>
    </div>
  );
}
