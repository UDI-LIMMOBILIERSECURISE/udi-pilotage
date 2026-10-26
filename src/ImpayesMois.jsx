// Le mois des impayés (039) : déclarations Zelok du 16 au 19 avec leurs pièces, actualisation mensuelle par organisme,
// règlements reçus sur des dossiers déclarés. Extrait de compte généré à la date du jour depuis les écritures Rivage.
import React, { useEffect, useState } from 'react';
import { supabase, rpc } from './supabase.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const euro = (n) => (n == null ? '—' : Number(n).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €');
const auj = () => new Date().toISOString().slice(0, 10);
export const ORGANISMES = { zelok: 'Zelok', mila: 'Mila', smartgarant: 'Smart Garant', garantme: 'Garantme', visale: 'Visale', avocats: 'Avocats', aucun: 'Sans garantie' };

export default function ImpayesMois({ peut, apres }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [extrait, setExtrait] = useState(null);
  const charger = () => rpc('pilotage_impayes_mois').then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  if (!d) return err ? <div className="banner">{err}</div> : null;
  const agir = async (fn, args) => { setErr(''); try { await rpc(fn, args); await charger(); apres && apres(); } catch (e) { setErr(e.message); } };
  const declarer = async (x) => {
    setErr('');
    try {
      const id = x.dossier_id || await rpc('pilotage_impaye_ouvrir', { p_bail: x.bail_id, p_groupe: 'GLI ZELOK' });
      await rpc('pilotage_impaye_maj', { p_id: id, p_champ: 'declaration_le', p_valeur: auj() });
      await rpc('pilotage_impaye_organisme', { p_dossier: id, p_organisme: 'zelok' });
      await charger(); apres && apres();
    } catch (e) { setErr(e.message); }
  };
  const fenetre = d.jour >= 16 && d.jour <= 19;
  const rien = !d.a_declarer.length && !d.reglements.length && !d.actualisations.length;
  return <section className="card" style={{ marginBottom: 14 }}>
    <h2 style={{ fontSize: 17, margin: '0 0 6px' }}>Ce mois-ci</h2>
    {err && <div className="banner">{err}</div>}
    {rien && <p className="muted">Rien à déclarer ni à actualiser pour l’instant.</p>}
    {d.sans_organisme > 0 && <div className="muted" style={{ fontSize: 12 }}>{d.sans_organisme} dossier(s) en cours sans organisme (garantie « CDT via huissier », « avocat » ou non renseignée) : à compléter dans le dossier.</div>}

    {d.a_declarer.length > 0 && <div className={'mini-alerte ' + (fenetre ? (d.jour >= 18 ? 'critique' : 'haute') : 'normale')} style={{ marginTop: 8 }}>
      <b>Impayés à déclarer à Zelok ({d.a_declarer.length})</b>{fenetre ? ` · date limite le 19, ${d.jour >= 18 ? 'dernier délai' : 'encore ' + (19 - d.jour + 1) + ' jour(s)'}` : d.jour < 16 ? ' · déclarations du 16 au 19' : ' · délai du mois dépassé : voir avec Zelok'}
      {d.a_declarer.map((x) => <div key={x.bail_id} style={{ borderTop: '1px solid rgba(0,0,0,.08)', padding: '6px 0', color: 'var(--ink)' }}>
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <div><b>{x.locataires || x.bail_id}</b> · {x.adresse} · dette {euro(x.dette)}{x.cycle?.libelle ? ` · Rivage : ${x.cycle.libelle}` : ''}
            <div className="muted" style={{ fontSize: 12 }}>Bailleur : {x.bailleur || '—'}{x.ouvert_le ? ' · impayé ouvert le ' + date(x.ouvert_le) : ''}</div></div>
          <div className="row">
            <button className="btn" onClick={() => setExtrait(x.bail_id)}>Extrait de compte</button>
            {peut && <button className="btn plein" onClick={() => declarer(x)}>Déclaré à Zelok aujourd’hui</button>}
          </div>
        </div>
        <div style={{ fontSize: 12, marginTop: 4 }}>{(x.pieces || []).map((p) => <span key={p.piece} className={'etq ' + (p.ok ? 'ok' : 'rose')} title={p.detail} style={{ marginRight: 4 }}>{p.ok ? '✓' : '✗'} {p.piece}</span>)}</div>
      </div>)}
    </div>}

    {d.reglements.length > 0 && <div className="mini-alerte haute" style={{ marginTop: 8 }}>
      <b>Règlements à signaler ({d.reglements.length})</b>
      {d.reglements.map((r) => <div key={r.dossier_id} className="row" style={{ justifyContent: 'space-between', borderTop: '1px solid rgba(0,0,0,.08)', padding: '6px 0', color: 'var(--ink)' }}>
        <div>{r.locataires || r.bail_id} · {euro(r.montant)} reçu le {date(r.recu_le)} · {ORGANISMES[r.organisme] || r.organisme}
          {Number(r.indemnisation_compte || 0) !== 0 && <div style={{ fontSize: 12, color: 'var(--red)' }}>Indemnisation déjà enregistrée (compte GLI du bail : {euro(r.indemnisation_compte)}) : calculer la somme à reverser à l’organisme pour éviter une double indemnisation.</div>}</div>
        <div className="row"><button className="btn" onClick={() => setExtrait(r.bail_id)}>Extrait de compte</button>
          {peut && <button className="btn plein" onClick={() => agir('pilotage_impaye_reglement_signale', { p_dossier: r.dossier_id })}>Signalé à l’organisme</button>}</div>
      </div>)}
    </div>}

    {d.actualisations.length > 0 && <details className="replie" open={d.jour >= 16 && d.actualisations.some((a) => !a.fait_le)} style={{ marginTop: 8 }}>
      <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Actualisation mensuelle par organisme ({d.actualisations.filter((a) => a.fait_le).length}/{d.actualisations.length} faite(s))</summary>
      {d.actualisations.map((a) => <div key={a.organisme} style={{ borderTop: '1px solid var(--line)', padding: '6px 0' }}>
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <b>{ORGANISMES[a.organisme] || a.organisme} · {a.dossiers.length} dossier(s)</b>
          {a.fait_le ? <span className="muted">Fait le {date(a.fait_le)} par {a.fait_par || '—'} {peut && <button className="lien" onClick={() => agir('pilotage_impayes_actualisation', { p_organisme: a.organisme, p_fait: false, p_note: null })}>Rouvrir</button>}</span>
            : peut && <button className="btn" onClick={() => agir('pilotage_impayes_actualisation', { p_organisme: a.organisme, p_fait: true, p_note: null })}>Actualisation faite</button>}
        </div>
        <div style={{ fontSize: 13 }}>{a.dossiers.map((x) => <span key={x.id} style={{ marginRight: 10 }}>{x.titre || 'dossier ' + x.id}
          {x.bail_id ? <button className="lien" onClick={() => setExtrait(x.bail_id)}>extrait</button> : <span className="muted"> (non relié à Rivage)</span>}</span>)}</div>
      </div>)}
    </details>}
    {extrait && <Extrait bail={extrait} fermer={() => setExtrait(null)} />}
  </section>;
}

// ----- Extrait de compte à la date du jour -----
export function Extrait({ bail, fermer }) {
  const [x, setX] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    supabase.functions.invoke('pilotage-sync-rivage', { body: { extrait: bail } }).then(({ data, error }) => {
      if (error || data?.error) setErr(data?.error || 'Extrait indisponible pour le moment.'); else setX(data);
    });
  }, [bail]);
  let solde = 0;
  const lignes = (x?.lignes || []).map((l) => { solde += l.debit - l.credit; return { ...l, solde }; });
  const imprimer = () => {
    const w = window.open('', '_blank');
    if (!w) return;
    const esc = (t) => String(t ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]);
    w.document.write(`<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Extrait de compte ${esc(x.locataires)}</title>
      <style>body{font:13px system-ui,sans-serif;margin:32px;color:#111}table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #ddd;padding:4px 6px;text-align:left}td.n,th.n{text-align:right}h1{font-size:18px}</style></head><body>
      <h1>Extrait de compte locataire</h1><p>${esc(x.locataires)}<br>${esc(x.adresse)}${x.reference ? '<br>Bail ' + esc(x.reference) : ''}<br>Édité le ${date(x.edite_le)} par UDI Gestion, d’après la comptabilité Rivage</p>
      <table><thead><tr><th>Date</th><th>Libellé</th><th class="n">Débit</th><th class="n">Crédit</th><th class="n">Solde</th></tr></thead><tbody>
      ${lignes.map((l) => `<tr><td>${date(l.date)}</td><td>${esc(l.libelle)}</td><td class="n">${l.debit ? euro(l.debit) : ''}</td><td class="n">${l.credit ? euro(l.credit) : ''}</td><td class="n">${euro(l.solde)}</td></tr>`).join('')}
      </tbody></table><p><b>Solde dû : ${euro(solde)}</b></p>
      ${x.depot?.length ? `<p>Dépôt de garantie encaissé : ${x.depot.map((dp) => euro(dp.credit) + ' le ' + date(dp.date)).join(', ')}</p>` : ''}
      </body></html>`);
    w.document.close(); w.focus(); w.print();
  };
  return <div className="panneau" style={{ marginTop: 10 }}>
    <button className="fermer" onClick={fermer} aria-label="Fermer l’extrait">×</button>
    <h3 style={{ marginTop: 0 }}>Extrait de compte</h3>
    {err ? <div className="banner">{err}</div> : !x ? <p className="muted">Lecture des écritures dans Rivage…</p> : <>
      <div className="muted">{x.locataires} · {x.adresse} · édité le {date(x.edite_le)}</div>
      <div className="table-wrap" style={{ maxHeight: 340, overflow: 'auto' }}><table className="table-imp"><thead><tr><th>Date</th><th>Libellé</th><th>Débit</th><th>Crédit</th><th>Solde</th></tr></thead>
        <tbody>{lignes.map((l, i) => <tr key={i}><td>{date(l.date)}</td><td>{l.libelle}</td><td>{l.debit ? euro(l.debit) : ''}</td><td>{l.credit ? euro(l.credit) : ''}</td><td>{euro(l.solde)}</td></tr>)}
          {!lignes.length && <tr><td colSpan={5} className="muted">Aucune écriture.</td></tr>}</tbody></table></div>
      <div className="row" style={{ justifyContent: 'space-between', marginTop: 6 }}>
        <b>Solde dû : {euro(solde)}</b>
        <span className="muted">{x.depot?.length ? 'Dépôt de garantie encaissé : ' + x.depot.map((dp) => euro(dp.credit) + ' le ' + date(dp.date)).join(', ') : 'Encaissement du dépôt de garantie non trouvé dans Rivage'}</span>
      </div>
      <button className="btn plein" style={{ marginTop: 6 }} onClick={imprimer}>Imprimer ou enregistrer en PDF</button>
    </>}
  </div>;
}
