// Permis de louer (038) : régime de chaque logement (table des communes, à l'adresse), demandes déposées et leur suivi,
// mail préparé à la mairie pour l'attestation d'accord tacite, liste des pièces par régime.
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
    {liste.map((l) => <LotPermis key={l.asset_id} l={l} agir={agir} email={email} prenom={prenom} recharger={charger} />)}
  </>;
}

export function LotPermis({ l, agir, email, prenom, recharger }) {
  const p = l.permis || {};
  const [depot, setDepot] = useState({ ouvert: false, le: auj(), numero: '' });
  const [pieces, setPieces] = useState(false);
  const enCours = (l.demandes || []).find((d) => !d.close_le);
  const soumis = ['autorisation', 'declaration', 'a_verifier'].includes(p.regime);
  return <div style={{ borderTop: '1px solid var(--line)', padding: '8px 0', fontSize: 13 }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <div><b>Lot {l.lot}</b><span className="muted"> · {l.adresse}</span></div>
      <span className={'sev ' + (COUL[p.regime] || 'normale')}>{REGIME[p.regime] || p.regime}{p.a_confirmer ? ' · à confirmer' : ''}</span>
    </div>
    {p.detail && <div className="muted" style={{ fontSize: 12 }}>{p.detail}{p.source ? ' · source : ' + p.source : ''}</div>}
    {p.regime === 'inconnu' && <div className="muted" style={{ fontSize: 12 }}>La recherche automatique de la commune est lancée dans l’heure ; le résultat sera à confirmer par la gestion (onglet À louer).</div>}
    {(l.demandes || []).map((d) => <Demande key={d.id} l={l} d={d} agir={agir} email={email} prenom={prenom} />)}
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
  </div>;
}

function Demande({ l, d, agir, email, prenom }) {
  const [rep, setRep] = useState({ action: '', le: auj() });
  const jours = Math.round((new Date(auj()) - new Date(d.depot_le)) / 86400000);
  const act = (action, extra = {}) => agir({ p_asset: l.asset_id, p_demande: d.id, p_action: action, p_le: extra.le || null, p_numero: null, p_notes: null });
  const mail = mailAttestation(l, d, prenom);
  return <div className="mini-alerte normale" style={{ margin: '4px 0' }}>
    <div><b>{d.regime === 'declaration' ? 'Déclaration' : 'Demande d’autorisation'}</b> déposée le {date(d.depot_le)}{d.numero ? ` · n° ${d.numero}` : ''}
      {d.close_le ? ` · close le ${date(d.close_le)}` : ''}</div>
    {d.reponse ? <div>{d.reponse === 'accord' ? `Accordée le ${date(d.reponse_le)}` : d.reponse === 'tacite' ? `Accord tacite le ${date(d.reponse_le)}` : `Refusée le ${date(d.reponse_le)}`}
      {d.reponse !== 'refus' && ` · caduc le ${date(new Date(new Date(d.reponse_le).setFullYear(new Date(d.reponse_le).getFullYear() + 2)))} sans bail signé`}</div>
      : d.regime === 'autorisation' && <div className="muted">Sans réponse depuis {jours} jour(s){jours >= 30 ? ' : l’accord est tacite' : jours >= 21 ? ' : relancer la mairie' : ''}.</div>}
    {d.reponse === 'tacite' && <div>{d.attestation_recue_le ? `Attestation reçue le ${date(d.attestation_recue_le)}` : d.attestation_demandee_le ? `Attestation demandée le ${date(d.attestation_demandee_le)}` : 'Attestation à demander à la mairie'}</div>}
    {!d.close_le && <div className="row" style={{ marginTop: 4 }}>
      {d.regime === 'autorisation' && !d.reponse && <>
        <select value={rep.action} onChange={(e) => setRep({ ...rep, action: e.target.value })} aria-label="Réponse de la mairie">
          <option value="">Réponse de la mairie…</option><option value="accord">Accordée</option><option value="refus">Refusée</option>
          {jours >= 30 && <option value="tacite">Pas de réponse en un mois : accord tacite</option>}</select>
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
