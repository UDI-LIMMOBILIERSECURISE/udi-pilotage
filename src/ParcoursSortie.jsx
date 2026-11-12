// 157 : parcours de sortie d'un locataire en étapes (décision de Nicolas du 12/11/2026). Une seule étape ouverte : la première qui reste à
// faire ; dès qu'elle est faite (message noté, réponse saisie…), la suivante s'ouvre dans la fiche. Chaque étape porte ses messages et ses
// champs. Les alertes suivent le même ordre (157) : la gestionnaire qui enchaîne dans la fiche ne voit pas l'alerte de l'étape suivante.
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';
import MessagesDossier from './MessagesDossier.jsx';
import { FilLot } from './Permis.jsx';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const auj = () => new Date().toISOString().slice(0, 10);
const SUITES = [['relouer', 'Relouer'], ['travaux', 'Travaux avant relocation'], ['reprise', 'Reprendre le bien'], ['vente', 'Vendre']];
const LIB_SUITE = Object.fromEntries(SUITES);

export default function ParcoursSortie({ s, reversement, aCharge = [], apres }) {
  const [p, setP] = useState(null);
  const [err, setErr] = useState('');
  const [ouverte, setOuverte] = useState(null); // étape ouverte à la main ; sinon la première à faire
  const [rev, setRev] = useState(0);
  const [f, setF] = useState({});
  const charger = () => rpc('pilotage_parcours_sortie', { p_bail: s.bail_id }).then((x) => {
    setP(x); const fi = x.fiche || {};
    setF({ previsite: fi.previsite ?? null, previsite_le: fi.previsite_le || '', previsite_heure: fi.previsite_heure || '', edl_par: fi.edl_par || '',
      edl_commande_le: fi.edl_commande_le || '', edl_le: fi.edl_le || '', edl_heure: fi.edl_heure || '', edl_intervenant: fi.edl_intervenant || '',
      nouvelle_adresse: fi.nouvelle_adresse || '' });
  }).catch((e) => setErr(e.message));
  useEffect(() => { setP(null); setOuverte(null); charger(); }, [s.bail_id]);
  if (err && !p) return <div className="err">{err}</div>;
  if (!p) return <p className="muted">Chargement du parcours…</p>;

  const fi = p.fiche || {};
  const j = p.journal || {};
  const dg = p.dg || {};
  const peut = p.peut;
  const recharger = async () => { await charger(); setRev((n) => n + 1); setOuverte(null); apres && apres(); };
  const action = async (a, v) => { setErr(''); try { setP(await rpc('pilotage_parcours_sortie_maj', { p_bail: s.bail_id, p_action: a, p_valeur: v ?? null })); setOuverte(null); apres && apres(); } catch (e) { setErr(e.message); } };
  const enregistrer = async (valeurs) => {
    setErr('');
    try { await rpc('pilotage_fiche_conge_maj', { p_bail: s.bail_id, p_valeurs: valeurs }); await recharger(); } catch (e) { setErr(e.message); }
  };
  const ch = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const fait = (code) => j[code];
  const prevenu = (codes) => codes.map(fait).filter(Boolean).sort((a, b) => (a.le < b.le ? 1 : -1))[0];
  const relocation = ['relouer', 'travaux'].includes(fi.suite);
  const edlPasse = p.edl_le && p.edl_le <= auj();
  const parti = !!p.sortie_reelle || (p.sortie && p.sortie <= auj());
  const dgFini = s.remboursee || !!dg.clos_le || !(Number(p.depot) > 0);

  const etapes = [
    { cle: 'conge', titre: 'Congé reçu : prévenir le locataire et le bailleur', fait: !!p.accuse_le,
      resume: p.accuse_le ? `Fait le ${date(p.accuse_le)}` : 'Accusé de réception au locataire, information du bailleur (et demande du dépôt s’il le détient)' },
    { cle: 'suite', titre: 'Décision du bailleur', fait: !!fi.suite,
      resume: fi.suite ? `${LIB_SUITE[fi.suite]}${fi.suite_le ? ' · noté le ' + date(fi.suite_le) : ''}${fi.suite_par_prenom ? ' par ' + fi.suite_par_prenom : ''}${fi.suite_source === 'ia_confirmee' ? ' (lu dans son mail)' : ''}`
        : fi.suite_proposee ? `Proposé d’après son mail : ${LIB_SUITE[fi.suite_proposee]} (à confirmer)` : 'Relouer, travaux, reprendre ou vendre' },
    { cle: 'previsite', titre: 'Pré-visite', sansObjet: !!fi.suite && !relocation, fait: fi.previsite === false || (fi.previsite === true && !!fi.previsite_le),
      resume: fi.suite && !relocation ? 'Sans objet (pas de relocation)' : fi.previsite === false ? 'Pas de pré-visite'
        : fi.previsite ? `Le ${date(fi.previsite_le)}${fi.previsite_heure ? ' à ' + fi.previsite_heure : ''}` : 'Oui ou non, date et heure' },
    { cle: 'edl', titre: 'État des lieux de sortie', fait: edlPasse || (!!p.edl_le && !!fi.edl_heure && !!fait('es_locataire_email')),
      resume: p.edl_le ? `Le ${date(p.edl_le)}${fi.edl_heure ? ' à ' + fi.edl_heure : ''}${fi.edl_par ? ' · ' + (fi.edl_par === 'interne' ? 'en interne' : 'prestataire') : ''}` : 'À commander, date et heure, confirmation au locataire' },
    { cle: 'depart', titre: 'Départ et clés', fait: parti,
      resume: `${p.sortie_reelle ? 'Parti le ' + date(p.sortie_reelle) : 'Départ prévu le ' + date(p.sortie)} · ${p.cles ? p.cles + ' trousseau(x) à l’agence' : 'aucun trousseau enregistré'}` },
    { cle: 'compare', titre: 'Comparer les états des lieux d’entrée et de sortie', sansObjet: false, attente: !edlPasse, fait: !!fi.edl_compare_le,
      resume: fi.edl_compare_le ? `Faite le ${date(fi.edl_compare_le)}${fi.edl_compare_par_prenom ? ' par ' + fi.edl_compare_par_prenom : ''}` : edlPasse ? 'À faire (retenues sur le dépôt)' : 'Après l’état des lieux de sortie' },
    { cle: 'dg', titre: 'Dépôt de garantie', fait: dgFini,
      resume: s.remboursee ? 'Remboursé (Rivage)' : dg.clos_le ? 'Dossier clôturé dans le pilotage' : !(Number(p.depot) > 0) ? 'Pas de dépôt'
        : dg.recu_le ? `Reversé par le bailleur le ${date(dg.recu_le)} : restituer au locataire` : dg.demande_le ? `Reversement demandé au bailleur le ${date(dg.demande_le)}` : 'Reversement, restitution au locataire' },
  ];
  const courante = etapes.find((e) => !e.fait && !e.sansObjet && !e.attente) || etapes.find((e) => !e.fait && !e.sansObjet);
  const ouv = ouverte || courante?.cle;

  const corps = (e) => {
    if (e.cle === 'conge') return <>
      <p className="muted" style={{ margin: '0 0 6px' }}>Rivage a déclaré le congé : accuser réception au locataire, informer le bailleur{p.dg_detenu_rivage === 'bailleur' || dg.detenu_par === 'bailleur' ? ' et lui demander de reverser le dépôt (le mail au bailleur le contient)' : ''}. Un message envoyé depuis Gmail et rangé sur le dossier compte aussi.</p>
      {['cg_locataire_email', 'cg_locataire_sms', 'cg_bailleur_email', 'cg_bailleur_sms'].filter(fait).length > 0 && <div className="muted" style={{ fontSize: 12, marginBottom: 6 }}>
        Locataire : {prevenu(['cg_locataire_email', 'cg_locataire_sms']) ? 'prévenu le ' + date(prevenu(['cg_locataire_email', 'cg_locataire_sms']).le) : 'à prévenir'} ·
        Bailleur : {prevenu(['cg_bailleur_email', 'cg_bailleur_sms']) ? 'prévenu le ' + date(prevenu(['cg_bailleur_email', 'cg_bailleur_sms']).le) : 'à prévenir'}</div>}
      <MessagesDossier key={'cg' + rev} objet="bail" id={s.bail_id} etapes={['conge']} titre={false} statut={s.statut} apres={recharger} />
    </>;
    if (e.cle === 'suite') return <>
      {fi.suite_proposee && !fi.suite && <div className="mini-alerte normale" style={{ marginBottom: 6 }}>
        D’après le mail du bailleur{fi.suite_proposee_le ? ' du ' + date(fi.suite_proposee_le) : ''} : <b>{LIB_SUITE[fi.suite_proposee]}</b>
        {peut && <span className="row" style={{ marginTop: 4 }}><button className="btn plein" onClick={() => action('confirmer_suite')}>Confirmer</button>
          <button className="btn gris" onClick={() => action('ecarter_suite')}>Ce n’est pas ça</button></span>}</div>}
      <p className="muted" style={{ margin: '0 0 6px' }}>Réponse par mail ou par téléphone : la choisir ici et, pour un appel, ajouter une note de suivi ci-dessous.</p>
      {peut && <div className="row" style={{ gap: 6 }}>{SUITES.map(([k, l]) => <button key={k} className={'chip' + (fi.suite === k ? ' on' : '')} onClick={() => action('suite', fi.suite === k ? '' : k)}>{l}</button>)}</div>}
      {fi.suite === 'travaux' && <p className="muted" style={{ fontSize: 12 }}>Créer le ticket dans Rivage avec le tag « Travaux » : le chantier se suit sur la frise du bien.</p>}
    </>;
    if (e.cle === 'previsite') return <>
      <div className="row" style={{ gap: 10 }}>
        {[[true, 'Oui'], [false, 'Non']].map(([v, l]) => <label key={l}><input type="radio" disabled={!peut} name={'pv' + s.bail_id} checked={f.previsite === v}
          onChange={() => { setF({ ...f, previsite: v }); if (v === false) enregistrer({ previsite: false }); }} /> {l}</label>)}
        {f.previsite === true && <>
          <label>le <input type="date" value={f.previsite_le} onChange={ch('previsite_le')} /></label>
          <label>à <input style={{ width: 80 }} value={f.previsite_heure} onChange={ch('previsite_heure')} placeholder="14h30" /></label>
          <button className="btn plein" disabled={!f.previsite_le} onClick={() => enregistrer({ previsite: true, previsite_le: f.previsite_le, previsite_heure: f.previsite_heure })}>Enregistrer</button>
        </>}
      </div>
      {f.previsite === true && <p className="muted" style={{ fontSize: 12 }}>Le message au locataire pour la pré-visite est dans l’étape suivante (messages « État des lieux de sortie »).</p>}
    </>;
    if (e.cle === 'edl') return <>
      <fieldset disabled={!peut} style={{ border: 0, padding: 0, margin: 0 }}>
        <div className="row" style={{ gap: 10 }}>
          <b>Fait par</b>
          <select value={f.edl_par} onChange={ch('edl_par')} aria-label="État des lieux fait par">
            <option value="">…</option><option value="prestataire">le prestataire</option><option value="interne">l’agence (interne)</option></select>
          {f.edl_par !== 'interne' && <label>commandé le <input type="date" max={auj()} value={f.edl_commande_le} onChange={ch('edl_commande_le')} /></label>}
        </div>
        <div className="row" style={{ gap: 10, marginTop: 6 }}>
          <span>Date : {p.edl_le && !fi.edl_le ? date(p.edl_le) + ' (Rivage)' : <input type="date" value={f.edl_le} onChange={ch('edl_le')} aria-label="Date de l’état des lieux" />}</span>
          <label>à <input style={{ width: 80 }} value={f.edl_heure} onChange={ch('edl_heure')} placeholder="9h30" aria-label="Heure de l’état des lieux" /></label>
          <label>Intervenant <input value={f.edl_intervenant} onChange={ch('edl_intervenant')} placeholder="expert ou collaborateur" /></label>
          <label>Nouvelle adresse du locataire <input value={f.nouvelle_adresse} onChange={ch('nouvelle_adresse')} placeholder="pour le solde du dépôt" /></label>
          <button className="btn plein" onClick={() => enregistrer({ edl_par: f.edl_par, edl_commande_le: f.edl_commande_le, edl_le: f.edl_le, edl_heure: f.edl_heure,
            edl_intervenant: f.edl_intervenant, nouvelle_adresse: f.nouvelle_adresse })}>Enregistrer</button>
        </div>
      </fieldset>
      <MessagesDossier key={'es' + rev} objet="bail" id={s.bail_id} etapes={['edl_sortie']} titre={false} statut={s.statut} apres={recharger} />
    </>;
    if (e.cle === 'depart') return <p className="muted" style={{ margin: 0 }}>Date de sortie lue dans Rivage ; les clés rendues se notent dans le bloc Clés de la fiche du bien.</p>;
    if (e.cle === 'compare') return <>
      {aCharge.length > 0 && <div className="mini-alerte haute" style={{ marginBottom: 6 }}><b>À regarder</b> · {aCharge.length} incident(s) à la charge du locataire :
        {aCharge.map((i) => <div key={i.numero}><a href={i.lien} target="_blank" rel="noreferrer">n°{i.numero} {i.titre}</a></div>)}</div>}
      {!edlPasse && <p className="muted" style={{ margin: '0 0 6px' }}>À faire après l’état des lieux de sortie{p.edl_le ? ' du ' + date(p.edl_le) : ''} : une alerte arrive 10 jours après si ce n’est pas fait.</p>}
      {peut && <label className="row" style={{ gap: 6 }}><input type="checkbox" checked={!!fi.edl_compare_le} onChange={() => action(fi.edl_compare_le ? 'edl_compare_annuler' : 'edl_compare')} />
        Comparaison des EDL d’entrée et de sortie faite (retenues décidées, à noter ci-dessous si besoin)</label>}
    </>;
    if (e.cle === 'dg') return reversement || null;
    return null;
  };

  return <div style={{ margin: '12px 0' }}>
    <h3 style={{ margin: '0 0 6px' }}>Parcours de sortie</h3>
    {err && <div className="err">{err}</div>}
    <ol className="parcours">
      {etapes.map((e, n) => { const ouvert = ouv === e.cle; const etat = e.fait ? 'fait' : e.sansObjet ? 'sans' : courante?.cle === e.cle ? 'cours' : 'avenir';
        return <li key={e.cle} className={'parcours-etape ' + etat + (ouvert ? ' ouvert' : '')}>
          <button type="button" className="parcours-tete" aria-expanded={ouvert} onClick={() => setOuverte(ouvert ? '__aucune' : e.cle)}>
            <span className="parcours-n">{e.fait ? '✓' : n + 1}</span>
            <span className="parcours-titre"><b>{e.titre}</b><span className="muted"> · {e.resume}</span></span>
            {etat === 'cours' && <span className="etq rose">À faire</span>}
          </button>
          {ouvert && <div className="parcours-corps">{corps(e)}</div>}
        </li>; })}
    </ol>
    {p.lot_id && <details className="parcours-fil" open>
      <summary><b>Notes de suivi et tâches</b></summary>
      <FilLot asset={p.lot_id} contexte="sortie" titreNotes="Notes de suivi" onErreur={setErr} />
    </details>}
  </div>;
}
