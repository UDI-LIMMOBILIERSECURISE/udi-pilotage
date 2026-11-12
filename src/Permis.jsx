// Permis de louer (038) : régime de chaque logement (table des communes, à l'adresse), demandes déposées et leur suivi,
// mail préparé à la mairie pour l'attestation d'accord tacite, liste des pièces par régime.
import { useBiens } from './Biens.jsx';
import React, { useEffect, useState } from 'react';
import { supabase, rpc } from './supabase.js';
import { lienGmail } from './mails.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const auj = () => new Date().toISOString().slice(0, 10);
export const REGIME = { autorisation: 'Autorisation préalable', declaration: 'Déclaration de mise en location', aucun: 'Pas de permis de louer',
  non_concerne: 'Non concerné', inconnu: 'Commune non vérifiée', a_verifier: 'Adresse à vérifier' };
const COUL = { autorisation: 'haute', declaration: 'normale', aucun: 'normale', non_concerne: 'normale', inconnu: 'haute', a_verifier: 'haute' };

// Pièces demandées par la mairie de Corbeil-Essonnes (liste fournie par Nicolas) : reprises pour toutes les communes
export const PIECES = {
  autorisation: ['Cerfa n° 15652 : demande d’autorisation préalable de mise en location', 'Acte de propriété du logement', 'Projet de bail', 'Plan du logement',
    'DPE (valable 10 ans)', 'Surface habitable (loi Boutin)', 'Amiante (logements construits avant 1997)', 'Plomb (CREP, logements construits avant 1949)',
    'Installation électrique (plus de 15 ans, valable 6 ans)', 'Installation gaz (plus de 15 ans, valable 6 ans)', 'État des risques (moins de 6 mois)'],
  declaration: ['Cerfa n° 15651 : déclaration de mise en location (dans les 15 jours de la signature)', 'Acte de propriété du logement', 'Bail signé', 'Plan du logement et photos',
    'DPE (valable 10 ans)', 'Surface habitable (loi Boutin)', 'Amiante (logements construits avant 1997)', 'Plomb (CREP, logements construits avant 1949)',
    'Installation électrique (plus de 15 ans, valable 6 ans)', 'Installation gaz (plus de 15 ans, valable 6 ans)', 'État des risques (moins de 6 mois)'],
};

function mailAttestation(l, dem, prenom) {
  const p = l.permis || {};
  return {
    to: p.email_depot ? [p.email_depot] : [],
    objet: `Demande d’attestation d’autorisation tacite de mise en location — ${l.adresse}`,
    corps: `Madame, Monsieur,\n\nNous avons déposé le ${date(dem.depot_le)}${dem.numero ? ` (dossier n° ${dem.numero})` : ''}, pour le compte du propriétaire, une demande d’autorisation préalable de mise en location pour le logement situé ${l.adresse}.\n\nSauf erreur de notre part, aucune décision ne nous a été notifiée dans le délai d’un mois prévu par le code de la construction et de l’habitation (articles L635-1 et suivants) : l’autorisation est donc réputée accordée.\n\nEn application de l’article L232-3 du code des relations entre le public et l’administration, nous vous remercions de bien vouloir nous délivrer l’attestation de cette décision implicite d’acceptation.\n\nNous vous prions d’agréer, Madame, Monsieur, l’expression de nos salutations distinguées.\n\n${prenom || ''}\nUDI Gestion`,
  };
}

export default function PermisMandat({ m, onErreur }) {
  const [liste, setListe] = useState(null);
  const [email, setEmail] = useState('');
  const [prenom, setPrenom] = useState('');
  const charger = () => rpc('pilotage_mandat_permis', { p_mandat: m.id }).then(setListe).catch(() => setListe([]));
  useEffect(() => {
    charger();
    supabase.auth.getSession().then(({ data }) => setEmail(data?.session?.user?.email || ''));
    rpc('pilotage_moi').then((x) => setPrenom(x?.prenom || '')).catch(() => {});
  }, [m.id]);
  if (!liste?.length) return null;
  const agir = async (args) => { try { await rpc('pilotage_permis_action', args); await charger(); } catch (e) { onErreur(e.message); } };
  return <>
    <div className="groupe-tete" style={{ marginTop: 14 }}><b>Permis de louer</b></div>
    {liste.map((l) => <LotPermis key={l.asset_id} l={l} agir={agir} email={email} prenom={prenom} recharger={charger} onErreur={onErreur} />)}
  </>;
}

// Fiche du bail : permis de louer du lot du bail (suivi d'ensemble 052, filtré sur ce bail). Rien si le lot n'est pas soumis.
// Fiche d'un ticket tagué PL ou DMEL : même bloc, retrouvé par le n° du lot (lot), avec un message si le lot n'est pas suivi.
export function PermisBail({ bail, lot, onErreur, statut }) {
  const biens = useBiens();
  const [x, setX] = useState(undefined);
  const [email, setEmail] = useState('');
  const [prenom, setPrenom] = useState('');
  const charger = () => rpc('pilotage_permis_suivi').then((liste) => setX((liste || []).find((y) => (bail ? y.bail?.id === bail : String(y.lot) === String(lot))) || null)).catch(() => setX(null));
  useEffect(() => {
    charger();
    supabase.auth.getSession().then(({ data }) => setEmail(data?.session?.user?.email || ''));
    rpc('pilotage_moi').then((r) => setPrenom(r?.prenom || '')).catch(() => {});
  }, [bail, lot]);
  if (x === null && lot) return <div className="mini-alerte haute" style={{ marginTop: 10 }}>Permis de louer : le lot {lot} n’est pas suivi. Le suivi s’ouvre quand un ticket Rivage du lot porte le tag PL ou DMEL (le tag apparaît ici à la modification suivante de l’incident).</div>;
  if (!x) return null;
  const agir = async (args) => { try { await rpc('pilotage_permis_action', args); await charger(); } catch (e) { onErreur ? onErreur(e.message) : alert(e.message); } };
  const loue = /prochaine location/i.test(x.etat || '') && statut !== 'move_out' && biens.parId[x.asset_id]?.phase !== 'sortie';
  // 12/11 : logement loué, rien à faire avant la prochaine location : une ligne, le détail (démarches, tâches, notes) replié
  if (loue) {
    const d = (x.demandes || []).filter((y) => y.reponse).sort((u, v) => (u.reponse_le < v.reponse_le ? 1 : -1))[0];
    return <details className="replie" style={{ marginTop: 10 }}>
      <summary style={{ cursor: 'pointer', fontSize: 13 }}><b>Permis de louer</b> · {d ? `${d.reponse} le ${date(d.reponse_le)} · ` : ''}à redemander à la prochaine location</summary>
      {x.peut && <LotPermis l={x} agir={agir} email={email} prenom={prenom} recharger={charger} onErreur={onErreur} loue />}
    </details>;
  }
  return <div style={{ marginTop: 10 }}>
    <div className="groupe-tete"><b>Permis de louer</b> <span className={'sev ' + (x.gravite || 'normale')} style={{ marginLeft: 6 }}>{x.etat}</span>
      {x.echeance && <span className="mono" style={{ marginLeft: 6, fontSize: 12 }}>échéance {date(x.echeance)}</span>}</div>
    {x.action && <div style={{ fontSize: 13, marginTop: 4 }}>{x.action}</div>}
    {x.peut ? <LotPermis l={x} agir={agir} email={email} prenom={prenom} recharger={charger} onErreur={onErreur}
        loue={loue} />
      : <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>{(x.demandes || []).length ? x.demandes.map((d) => `${d.regime === 'declaration' ? 'Déclaration' : 'Demande'} déposée le ${date(d.depot_le)}${d.reponse ? ' · ' + d.reponse + ' le ' + date(d.reponse_le) : ''}`).join(' ; ') : 'Aucune démarche enregistrée.'} Seule la gestion enregistre les démarches.</div>}
  </div>;
}

// 12/11 : loue = logement loué avec un permis déjà utilisé pour ce bail, sans congé : la prochaine démarche se fera à la relocation,
// les boutons « Qui dépose ? », « Permis déjà obtenu » et « Demande déposée » ne sont pas proposés d'ici là. Dès le congé reçu
// (bail en sortie dans Rivage, frise en « Sortie »), les questions reviennent pour redéposer avant la relocation (règle de Nicolas).
export function LotPermis({ l, agir, email, prenom, recharger, onErreur, loue }) {
  const p = l.permis || {};
  const [modif, setModif] = useState(false);
  const modifiable = p.regime !== 'non_concerne' && !p.tag; // 132 : avec un tag PL ou DMEL, c'est le tag qui décide
  // Régime choisi pour ce lot (062) : prime sur la table des communes
  const agirRegime = async (regime) => {
    try { await rpc('pilotage_permis_lot_regime', { p_asset: l.asset_id, p_regime: regime }); recharger && await recharger(); }
    catch (e) { onErreur ? onErreur(e.message) : alert(e.message); }
  };
  const [depot, setDepot] = useState({ ouvert: false, le: auj(), numero: '' });
  const [pieces, setPieces] = useState(false);
  const [obtenu, setObtenu] = useState({ ouvert: false, le: '', numero: '' }); // permis déjà obtenu par le bailleur (095)
  const enCours = (l.demandes || []).find((d) => !d.close_le);
  const soumis = ['autorisation', 'declaration', 'a_verifier'].includes(p.regime) && !loue;
  return <div style={{ borderTop: '1px solid var(--line)', padding: '8px 0', fontSize: 13 }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <div><b>Lot {l.lot}</b><span className="muted"> · {l.adresse}</span></div>
      <span className="row" style={{ gap: 6 }}>
        {modif ? <select autoFocus value={p.force ? p.regime : ''} aria-label="Régime du permis de louer pour ce lot"
            onChange={async (e) => { await agirRegime(e.target.value || null); setModif(false); }} onBlur={() => setModif(false)}>
            <option value="">{p.force ? 'Revenir au régime de la commune' : 'Choisir pour ce lot…'}</option>
            <option value="autorisation">Autorisation préalable (permis de louer)</option>
            <option value="declaration">Déclaration de mise en location</option>
            <option value="aucun">Pas de permis de louer</option>
          </select>
          : <><span className={'sev ' + (COUL[p.regime] || 'normale')}>{REGIME[p.regime] || p.regime}{p.a_confirmer ? ' · à confirmer' : ''}{p.force ? ' · choisi pour ce lot' : ''}</span>
            {modifiable && <button className="lien" onClick={() => setModif(true)}>Modifier</button>}</>}
      </span>
    </div>
    {p.detail && <div className="muted" style={{ fontSize: 12 }}>{p.detail}{p.source ? ' · source : ' + p.source : ''}</div>}
    {p.regime === 'inconnu' && <div className="muted" style={{ fontSize: 12 }}>La recherche automatique de la commune est lancée dans l’heure ; le résultat sera à confirmer par la gestion (onglet À louer).</div>}
    {(l.demandes || []).map((d) => <Demande key={d.id} l={l} d={d} agir={agir} email={email} prenom={prenom} recharger={recharger} onErreur={onErreur} />)}
    {/* 132 : « Qui dépose ? » aussi pour la déclaration (DMEL), sans montant ; 90 € TTC pour l'autorisation (PL) */}
    {soumis && !enCours && <div className="row" style={{ marginTop: 4 }}>
      <span className="muted">{l.choix === 'agence' ? 'Dépôt par l’agence' + (p.regime === 'declaration' ? '' : ' (90 € TTC à facturer)') : l.choix === 'bailleur' ? 'Dépôt par le bailleur (récépissé à obtenir)' : l.choix_a_demander ? 'Choix du bailleur à obtenir :' : 'Qui dépose ?'}</span>
      {l.choix !== 'agence' && <button className="btn" onClick={() => agir({ p_asset: l.asset_id, p_demande: null, p_action: 'choix_agence', p_le: null, p_numero: null, p_notes: null })}>{p.regime === 'declaration' ? 'L’agence dépose' : 'L’agence dépose (90 € TTC)'}</button>}
      {l.choix !== 'bailleur' && <button className="btn" onClick={() => agir({ p_asset: l.asset_id, p_demande: null, p_action: 'choix_bailleur', p_le: null, p_numero: null, p_notes: null })}>Le bailleur dépose</button>}
    </div>}
    {loue && <div className="muted" style={{ marginTop: 4 }}>Rien à faire tant que le logement est loué : la démarche se fera à la prochaine mise en location.</div>}
    {['autorisation', 'a_verifier'].includes(p.regime) && !enCours && !loue && (obtenu.ouvert
      ? <div className="row" style={{ marginTop: 4 }}>
          <label className="muted">Permis obtenu le <input type="date" value={obtenu.le} max={auj()} onChange={(e) => setObtenu({ ...obtenu, le: e.target.value })} /></label>
          <input placeholder="N° du permis (facultatif)" value={obtenu.numero} onChange={(e) => setObtenu({ ...obtenu, numero: e.target.value })} style={{ width: 170 }} />
          <button className="btn plein" disabled={!obtenu.le} onClick={async () => { await agir({ p_asset: l.asset_id, p_demande: null, p_action: 'deja_obtenu', p_le: obtenu.le, p_numero: obtenu.numero, p_notes: null }); setObtenu({ ouvert: false, le: '', numero: '' }); }}>Enregistrer</button>
          <button className="lien" onClick={() => setObtenu({ ouvert: false, le: '', numero: '' })}>Annuler</button>
        </div>
      : <div className="row" style={{ marginTop: 4 }}><button className="btn" onClick={() => setObtenu({ ...obtenu, ouvert: true })}>Permis déjà obtenu</button></div>)}
    {soumis && !enCours && (depot.ouvert ? <div className="row" style={{ marginTop: 4 }}>
      <label className="muted">Déposée le <input type="date" value={depot.le} onChange={(e) => setDepot({ ...depot, le: e.target.value })} /></label>
      <input placeholder="N° de dossier (facultatif)" value={depot.numero} onChange={(e) => setDepot({ ...depot, numero: e.target.value })} style={{ width: 170 }} />
      <button className="btn plein" onClick={async () => { await agir({ p_asset: l.asset_id, p_demande: null, p_action: 'deposer', p_le: depot.le, p_numero: depot.numero, p_notes: null }); setDepot({ ...depot, ouvert: false }); }}>Enregistrer le dépôt</button>
      <button className="lien" onClick={() => setDepot({ ...depot, ouvert: false })}>Annuler</button>
    </div> : <div className="row" style={{ marginTop: 4 }}>
      <button className="btn" onClick={() => setDepot({ ...depot, ouvert: true })}>{p.regime === 'declaration' ? 'Déclaration déposée' : 'Demande déposée en mairie'}</button>
      <button className="lien" onClick={() => setPieces(!pieces)}>{pieces ? 'Masquer les pièces' : 'Pièces à fournir'}</button>
    </div>)}
    {pieces && <ul style={{ margin: '4px 0', paddingLeft: 18, fontSize: 12 }}>{(PIECES[p.regime === 'declaration' ? 'declaration' : 'autorisation']).map((x) => <li key={x}>{x}</li>)}
      {p.email_depot && <li>Dossier complet à transmettre à : {p.email_depot}{p.adresse_depot ? ' (' + p.adresse_depot + ')' : ''}</li>}</ul>}
    {['autorisation', 'declaration', 'a_verifier'].includes(p.regime) && <FilPermis l={l} enCours={enCours} onErreur={onErreur} />}
  </div>;
}

// Tâches et mises à jour du permis de louer d'un lot (126). Une tâche arrive dans Ma journée de la personne choisie le jour de son échéance.
// 157 : aussi pour la sortie d'un locataire (contexte « sortie ») : notes et tâches du lot, partagées
export function FilLot({ asset, contexte, onErreur, titreNotes }) { return <FilPermis l={{ asset_id: asset }} contexte={contexte} onErreur={onErreur} titreNotes={titreNotes} />; }
function FilPermis({ l, enCours, onErreur, contexte, titreNotes }) {
  const [f, setF] = useState(null);
  const [tache, setTache] = useState(null); // formulaire de nouvelle tâche
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const dans = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  const charger = () => rpc('pilotage_permis_fil', { p_asset: l.asset_id }).then(setF).catch(() => setF(null));
  useEffect(() => { charger(); }, [l.asset_id]);
  if (!f) return null;
  const erreur = (e) => (onErreur ? onErreur(e.message) : alert(e.message));
  const tacheAction = async (action, t, extra = {}) => {
    try {
      if (contexte) await rpc('pilotage_lot_tache', { p_action: action, p_id: t?.id || null, p_asset: l.asset_id,
        p_libelle: extra.libelle || null, p_echeance: extra.echeance || null, p_assigne: extra.assigne || null, p_contexte: contexte });
      else await rpc('pilotage_permis_tache', { p_action: action, p_id: t?.id || null, p_asset: l.asset_id, p_demande: extra.demande || null,
        p_libelle: extra.libelle || null, p_echeance: extra.echeance || null, p_assigne: extra.assigne || null });
      await charger(); return true; }
    catch (e) { erreur(e); return false; }
  };
  const ouvertes = f.taches.filter((t) => !t.faite_le);
  const faites = f.taches.filter((t) => t.faite_le);
  return <div style={{ marginTop: 8 }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <b>Tâches{ouvertes.length ? ` (${ouvertes.length})` : ''}</b>
      {!tache && <button className="lien" onClick={() => setTache({ libelle: '', echeance: dans(7), assigne: f.moi, demande: enCours?.id || null })}>+ Ajouter une tâche</button>}
    </div>
    {tache && <div className="row" style={{ marginTop: 4, alignItems: 'flex-end' }}>
      <label className="muted" style={{ flex: 1, minWidth: 200 }}>Tâche<br /><input value={tache.libelle} onChange={(e) => setTache({ ...tache, libelle: e.target.value })}
        placeholder={contexte === 'sortie' ? 'Ex. rappeler le bailleur, récupérer les clés chez le locataire' : 'Ex. relancer la mairie, transmettre le récépissé au locataire'} style={{ width: '100%' }} autoFocus /></label>
      <label className="muted">Pour<br /><select value={tache.assigne} onChange={(e) => setTache({ ...tache, assigne: e.target.value })}>
        {f.membres.map((m) => <option key={m.id} value={m.id}>{m.prenom}</option>)}</select></label>
      <label className="muted">Échéance<br /><input type="date" value={tache.echeance} onChange={(e) => setTache({ ...tache, echeance: e.target.value })} /></label>
      <button className="btn plein" disabled={!tache.libelle.trim() || !tache.echeance} onClick={async () => { if (await tacheAction('creer', null, tache)) setTache(null); }}>Enregistrer</button>
      <button className="lien" onClick={() => setTache(null)}>Annuler</button>
    </div>}
    {!f.taches.length && !tache && <div className="muted" style={{ fontSize: 12 }}>Aucune tâche.</div>}
    {[...ouvertes, ...faites].map((t) => <div key={t.id} className="row" style={{ gap: 8, padding: '3px 0', fontSize: 13, opacity: t.faite_le ? 0.6 : 1 }}>
      <input type="checkbox" checked={!!t.faite_le} aria-label={t.faite_le ? 'Rouvrir la tâche' : 'Marquer la tâche faite'} onChange={() => tacheAction(t.faite_le ? 'rouvrir' : 'faite', t)} />
      <span style={{ flex: 1, minWidth: 180, textDecoration: t.faite_le ? 'line-through' : 'none' }}>{t.libelle}</span>
      <span className="muted">{t.assigne_prenom} · {t.faite_le ? `faite le ${date(t.faite_le)}${t.faite_par ? ' par ' + t.faite_par : ''}`
        : <span style={{ color: t.echeance < auj() ? 'var(--red)' : t.echeance === auj() ? 'var(--amber)' : undefined }}>échéance {date(t.echeance)}</span>}</span>
      {!t.faite_le && <button className="lien" onClick={() => window.confirm('Supprimer cette tâche ?') && tacheAction('supprimer', t)}>Supprimer</button>}
    </div>)}

    <div style={{ marginTop: 10 }}><b>{titreNotes || 'Mises à jour'}{f.notes.length ? ` (${f.notes.length})` : ''}</b></div>
    <div className="row" style={{ marginTop: 4, alignItems: 'flex-end' }}>
      <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2} placeholder={contexte === 'sortie' ? 'Note de suivi (appel du bailleur, réponse du locataire, clés…)' : 'Ajouter une mise à jour (appel à la mairie, pièce envoyée, réponse du bailleur…)'} style={{ flex: 1, minWidth: 220 }} />
      <button className="btn" disabled={busy || !note.trim()} onClick={async () => { setBusy(true); try { await (contexte ? rpc('pilotage_lot_note', { p_asset: l.asset_id, p_contenu: note, p_supprimer: null, p_contexte: contexte }) : rpc('pilotage_permis_note', { p_asset: l.asset_id, p_contenu: note, p_supprimer: null })); setNote(''); await charger(); } catch (e) { erreur(e); } setBusy(false); }}>Publier</button>
    </div>
    {f.notes.map((n) => <div key={n.id} style={{ borderLeft: '3px solid var(--line)', padding: '4px 8px', margin: '6px 0', fontSize: 13 }}>
      <div className="muted" style={{ fontSize: 12 }}>{n.auteur || '—'} · {new Date(n.le).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })}
        {n.auteur_id === f.moi && <button className="lien" style={{ marginLeft: 8 }} onClick={async () => { if (!window.confirm('Retirer ce message ?')) return; try { await rpc('pilotage_permis_note', { p_asset: l.asset_id, p_contenu: null, p_supprimer: n.id }); await charger(); } catch (e) { erreur(e); } }}>Retirer</button>}</div>
      <div style={{ whiteSpace: 'pre-wrap' }}>{n.contenu}</div>
    </div>)}
  </div>;
}

function Demande({ l, d, agir, email, prenom, recharger, onErreur }) {
  const [rep, setRep] = useState({ action: '', le: auj() });
  // déclaration (126) : accusé de réception de la mairie, correction de la date de dépôt et du n° de dossier
  const [edit, setEdit] = useState(null);
  const enregistrer = async () => {
    try {
      await rpc('pilotage_permis_demande_maj', { p_demande: d.id, p_depot_le: edit.depot, p_numero: edit.numero, p_recepisse_le: edit.recepisse || null });
      setEdit(null); recharger && await recharger();
    } catch (e) { onErreur ? onErreur(e.message) : alert(e.message); }
  };
  const jours = Math.round((new Date(auj()) - new Date(d.depot_le)) / 86400000);
  const act = (action, extra = {}) => agir({ p_asset: l.asset_id, p_demande: d.id, p_action: action, p_le: extra.le || null, p_numero: null, p_notes: null });
  const mail = mailAttestation(l, d, prenom);
  return <div className="mini-alerte normale" style={{ margin: '4px 0' }}>
    <div><b>{d.regime === 'declaration' ? 'Déclaration' : 'Demande d’autorisation'}</b> déposée le {date(d.depot_le)}{d.numero ? ` · n° ${d.numero}` : ''}
      {d.close_le ? ` · close le ${date(d.close_le)}` : ''}</div>
    {d.regime === 'declaration' && <div>{d.recepisse_le ? `Accusé de réception de la mairie du ${date(d.recepisse_le)}` : <span className="muted">Accusé de réception de la mairie : date non renseignée</span>}</div>}
    {d.reponse ? <div>{d.reponse === 'accord' ? `Accordée le ${date(d.reponse_le)}` : d.reponse === 'tacite' ? `Accord tacite le ${date(d.reponse_le)}` : `Refusée le ${date(d.reponse_le)}`}
      {d.reponse !== 'refus' && ` · caduc le ${date(new Date(new Date(d.reponse_le).setFullYear(new Date(d.reponse_le).getFullYear() + 2)))} sans bail signé`}</div>
      : d.regime === 'declaration' ? <div className="muted">Déclaration : pas de décision à attendre de la mairie.{l.bail?.signe_le ? ` Bail signé le ${date(l.bail.signe_le)} : déposée ${Math.round((new Date(d.depot_le) - new Date(l.bail.signe_le)) / 86400000)} jour(s) après la signature (délai : 15 jours).` : ''}</div>
      : d.regime === 'autorisation' && <div className="muted">Sans réponse depuis {jours} jour(s){jours >= 35 ? ' : l’accord est tacite (acquis à 30 jours), à constater' : jours >= 30 ? ' : accord acquis à 30 jours, mais une décision peut encore arriver par courrier : attendre 35 jours avant de signer' : jours >= 21 ? ' : relancer la mairie' : ''}.</div>}
    {d.reponse === 'tacite' && <div>{d.attestation_recue_le ? `Attestation reçue le ${date(d.attestation_recue_le)}` : d.attestation_demandee_le ? `Attestation demandée le ${date(d.attestation_demandee_le)}` : 'Attestation à demander à la mairie'}</div>}
    {edit && <div className="row" style={{ marginTop: 4, alignItems: 'flex-end' }}>
      <label className="muted">Déposée le<br /><input type="date" value={edit.depot} max={auj()} onChange={(e) => setEdit({ ...edit, depot: e.target.value })} /></label>
      <label className="muted">N° de dossier<br /><input value={edit.numero} onChange={(e) => setEdit({ ...edit, numero: e.target.value })} style={{ width: 150 }} /></label>
      <label className="muted">Accusé de réception du<br /><input type="date" value={edit.recepisse} min={edit.depot} max={auj()} onChange={(e) => setEdit({ ...edit, recepisse: e.target.value })} /></label>
      <button className="btn plein" disabled={!edit.depot} onClick={enregistrer}>Enregistrer</button>
      <button className="lien" onClick={() => setEdit(null)}>Annuler</button>
    </div>}
    {!d.close_le && <div className="row" style={{ marginTop: 4 }}>
      {d.regime === 'declaration' && !edit && <button className="btn" onClick={() => setEdit({ depot: d.depot_le || '', numero: d.numero || '', recepisse: d.recepisse_le || '' })}>
        {d.recepisse_le ? 'Modifier la déclaration' : 'Noter l’accusé de réception'}</button>}
      {d.regime === 'autorisation' && !d.reponse && <>
        <select value={rep.action} onChange={(e) => setRep({ ...rep, action: e.target.value })} aria-label="Réponse de la mairie">
          <option value="">Réponse de la mairie…</option><option value="accord">Accordée</option><option value="refus">Refusée</option>
          {jours >= 35 && <option value="tacite">Pas de réponse en un mois (+ 5 jours de marge) : accord tacite</option>}</select>
        {rep.action && rep.action !== 'tacite' && <input type="date" value={rep.le} onChange={(e) => setRep({ ...rep, le: e.target.value })} />}
        {rep.action && <button className="btn plein" onClick={() => act(rep.action, { le: rep.le })}>Enregistrer</button>}</>}
      {d.reponse === 'tacite' && !d.attestation_recue_le && <>
        <a className="btn plein" href={lienGmail(mail, email)} target="_blank" rel="noreferrer" onClick={() => act('attestation_demandee')}>Préparer le mail à la mairie (attestation)</a>
        {!mail.to.length && <span className="muted" style={{ fontSize: 12 }}>Adresse de la mairie à compléter dans la table des communes.</span>}
        {d.attestation_demandee_le && <button className="btn" onClick={() => act('attestation_recue')}>Attestation reçue</button>}</>}
      <button className="lien" onClick={() => act('annuler')}>Clore cette demande</button>
    </div>}
  </div>;
}
