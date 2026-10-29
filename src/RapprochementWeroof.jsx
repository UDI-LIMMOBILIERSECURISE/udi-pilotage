// Rapprochement WeRoof ↔ Rivage (092) : pour chaque lot Rivage, le bien WeRoof le plus probable (adresse, bailleur, locataire,
// n° de lot). Le pilotage propose, la gestion valide ou rejette ; rien n'est écrit dans Rivage ni dans WeRoof.
// Une fois rapprochés, les lots reprennent ce que WeRoof sait (ordures ménagères aujourd'hui), toujours à confirmer.
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';
import { MODE_ORDURES } from './Ordures.jsx';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const CRIT = (c) => [c.adresse === 'identique' ? 'adresse identique' : c.adresse === 'proche' ? 'adresse proche' : null,
  c.bailleur ? 'même bailleur' : null, c.locataire ? 'même locataire' : null, c.lot ? 'même n° de lot' : null].filter(Boolean).join(' · ');

export default function RapprochementWeroof() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [ok, setOk] = useState('');
  const [vue, setVue] = useState('a_trancher');
  const [occupe, setOccupe] = useState(false);
  const charger = () => rpc('pilotage_rapprochements_weroof').then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  const agir = async (fn, args, msg) => {
    setErr(''); setOk(''); setOccupe(true);
    try { const n = await rpc(fn, args); if (msg) setOk(msg(n)); await charger(); } catch (e) { setErr(e.message); }
    setOccupe(false);
  };
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const propositions = d.lignes.filter((l) => l.statut === 'propose');
  const surs = propositions.filter((l) => l.score >= 75 && !l.ambigu);
  const liste = vue === 'valides' ? d.lignes.filter((l) => l.statut === 'valide')
    : vue === 'surs' ? surs : propositions.filter((l) => !(l.score >= 75 && !l.ambigu));
  return <div className="stack">
    <div>
      <h1>Rapprochement WeRoof</h1>
      <p className="sub">Chaque lot Rivage est rapproché du bien WeRoof le plus probable (même code postal, adresse, bailleur, locataire, n° de lot). Rien n’est écrit dans Rivage ni dans WeRoof : un lot rapproché permet seulement de proposer ce que WeRoof sait déjà (ordures ménagères, syndic…), à confirmer.</p>
    </div>
    <div className="row">
      <div className="tuile"><div className="muted">Lots Rivage</div><div className="tuile-n">{d.lots}</div></div>
      <div className="tuile"><div className="muted">Rapprochés</div><div className="tuile-n">{d.valides}</div></div>
      <div className="tuile"><div className="muted">Propositions sûres</div><div className="tuile-n">{d.surs}</div></div>
    </div>
    {err && <div className="banner">{err}</div>}
    {ok && <div className="info">{ok}</div>}
    <div className="row">
      {surs.length > 0 && <button className="btn plein" disabled={occupe} onClick={() => agir('pilotage_rapprochements_weroof_valider_surs', {}, (n) => `${n} rapprochement(s) validé(s).`)}>
        Valider les {surs.length} propositions sûres</button>}
      <button className="btn" disabled={occupe} onClick={() => agir('pilotage_lots_ordures_reprendre_weroof', {}, (n) => `${n} lot(s) : ordures ménagères reprises de WeRoof.`)}>
        Reprendre les ordures ménagères de WeRoof (lots rapprochés sans réponse)</button>
      <button className="btn gris" disabled={occupe} onClick={() => agir('pilotage_rapprochements_weroof_recalculer', {}, (n) => `${n} proposition(s) recalculée(s).`)}>Recalculer les propositions</button>
    </div>
    <div className="row">
      {[['a_trancher', 'À trancher', propositions.length - surs.length], ['surs', 'Sûres', surs.length], ['valides', 'Validés', d.valides]].map(([k, l, n]) =>
        <button key={k} className={'chip' + (vue === k ? ' on' : '')} onClick={() => setVue(k)}>{l}<span className="n">{n}</span></button>)}
    </div>
    <div className="stack" style={{ gap: 6 }}>
      {liste.slice(0, 200).map((l) => <div key={l.asset_id + l.bien_id} className="card" style={{ padding: '8px 12px', fontSize: 13 }}>
        <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div style={{ flex: 1, minWidth: 260 }}>
            <div><b>Rivage · lot {l.lot.reference || '—'}</b> · {l.lot.adresse} <span className="muted">· {l.lot.bailleur || '—'}</span></div>
            <div><b>WeRoof{l.bien.lot ? ' · lot ' + l.bien.lot : ''}</b> · {l.bien.adresse} <span className="muted">· {l.bien.bailleur || '—'}</span></div>
            <div className="muted">{l.statut === 'valide' ? `Validé par ${l.par || '—'} le ${date(l.le)}` : `${CRIT(l.criteres)} · score ${l.score}${l.ambigu ? ' · plusieurs candidats possibles' : ''}`}
              {l.bien.ordures ? ` · WeRoof : ${MODE_ORDURES[l.bien.ordures] || l.bien.ordures}${l.bien.organisme ? ' (' + l.bien.organisme + ')' : ''}` : ''}{l.bien.syndic ? ` · syndic : ${l.bien.syndic}` : ''}</div>
          </div>
          <div className="row">
            {l.statut === 'propose' && <>
              <button className="btn plein" disabled={occupe} onClick={() => agir('pilotage_rapprochement_weroof_decider', { p_asset: l.asset_id, p_bien: l.bien_id, p_accepter: true })}>Valider</button>
              <button className="btn gris" disabled={occupe} onClick={() => agir('pilotage_rapprochement_weroof_decider', { p_asset: l.asset_id, p_bien: l.bien_id, p_accepter: false })}>Rejeter</button></>}
            {l.statut === 'valide' && <button className="lien" disabled={occupe} onClick={() => agir('pilotage_rapprochement_weroof_annuler', { p_asset: l.asset_id })}>Annuler</button>}
          </div>
        </div>
      </div>)}
      {liste.length > 200 && <p className="muted">200 premiers affichés sur {liste.length}.</p>}
      {!liste.length && <p className="muted">Rien ici.</p>}
    </div>
  </div>;
}
