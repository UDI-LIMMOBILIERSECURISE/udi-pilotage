// Ordures ménagères par lot (092) : taxe incluse dans la taxe foncière, ou organisme externe (redevance), choisi dans une liste
// reprise de WeRoof et extensible. Question du contrôle d'entrée du mandat, validée quand chaque lot a sa réponse.
// Ce que WeRoof sait d'un lot rapproché est proposé, à confirmer : rien n'est repris sans clic.
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
export const MODE_ORDURES = { taxe_fonciere: 'Taxe incluse dans la taxe foncière', organisme_externe: 'Organisme externe (redevance)' };

export function useOrdures(assets) {
  const [d, setD] = useState(null);
  const cle = (assets || []).join(',');
  const lire = () => (assets?.length ? rpc('pilotage_lots_ordures', { p_assets: assets }).then(setD).catch(() => setD({ lots: {}, organismes: [] })) : Promise.resolve());
  useEffect(() => { lire(); }, [cle]);
  return [d, lire];
}

// Question m_cl_ordures du contrôle d'entrée
export default function OrduresLots({ i, lots, repondre, onErreur, regle }) {
  const [d, lire] = useOrdures(lots.map((l) => l.id));
  const [ajout, setAjout] = useState(false);
  if (!d) return null;
  const restants = lots.filter((l) => !d.lots[l.id]?.reponse);
  const enregistrer = async (l, mode, organisme, source) => {
    try { await rpc('pilotage_lot_ordures', { p_asset: l.id, p_mode: mode, p_organisme: organisme ?? null, p_source: source || 'saisie' }); await lire(); }
    catch (e) { onErreur(e.message); }
  };
  return <div style={{ borderTop: '1px solid var(--line)', padding: '8px 0' }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <div><span style={{ color: regle ? 'var(--teal)' : 'var(--amber)', fontWeight: 700 }}>{i.statut === 'ok' ? '✓' : '○'}</span> <b>{i.libelle}</b>
        <div className="muted" style={{ fontSize: 12 }}>{i.aide}</div></div>
      <div className="row">
        {i.repondu ? <><span className="muted" style={{ fontSize: 12 }}>Validé ({i.par}, {date(i.le)})</span><button className="lien" onClick={() => repondre(i, null)}>Revenir</button></>
          : <button className="btn" disabled={restants.length > 0} onClick={() => repondre(i, 'ok')}>
              Valider la saisie{restants.length ? ` (${restants.length} lot${restants.length > 1 ? 's' : ''} à renseigner)` : ''}</button>}
      </div>
    </div>
    {lots.map((l) => <LotOrdures key={l.id} l={l} x={d.lots[l.id] || {}} organismes={d.organismes} enregistrer={enregistrer} fige={i.repondu} />)}
    {!i.repondu && (ajout
      ? <Organisme fermer={() => setAjout(false)} apres={async () => { setAjout(false); await lire(); }} onErreur={onErreur} />
      : <button className="lien" style={{ marginLeft: 18 }} onClick={() => setAjout(true)}>+ Ajouter un organisme à la liste</button>)}
  </div>;
}

function LotOrdures({ l, x, organismes, enregistrer, fige }) {
  const r = x.reponse; const w = x.weroof;
  const [org, setOrg] = useState('');
  return <div style={{ margin: '6px 0 6px 18px', fontSize: 13 }}>
    <b>Lot {l.reference || l.id}</b><span className="muted"> · {l.adresse}</span>
    {r ? <div className="row" style={{ gap: 8 }}>
        <span className="etq ok">✓ {MODE_ORDURES[r.mode]}{r.organisme ? ' : ' + r.organisme.nom : ''}</span>
        <span className="muted">{r.source === 'weroof' ? 'repris de WeRoof' : 'saisi'} par {r.par || '—'} le {date(r.le)}</span>
        {r.organisme && !r.organisme.email && <span style={{ color: 'var(--amber)' }}>e-mail de l’organisme à compléter</span>}
        {!fige && <button className="lien" onClick={() => enregistrer(l, null)}>Modifier</button>}
      </div>
      : <>
        {w && <div style={{ background: 'var(--blue-bg)', borderRadius: 6, padding: '4px 8px', margin: '4px 0' }}>
          <b>WeRoof indique :</b> {MODE_ORDURES[w.mode]}{w.organisme_nom ? ' : ' + w.organisme_nom : ''}{' '}
          {(w.mode === 'taxe_fonciere' || w.organisme_id)
            ? <button className="btn" onClick={() => enregistrer(l, w.mode, w.organisme_id, 'weroof')}>Confirmer</button>
            : <span className="muted">(organisme absent de la liste : à ajouter)</span>}
        </div>}
        <div className="row" style={{ gap: 6, marginTop: 4 }}>
          <button className="btn" onClick={() => enregistrer(l, 'taxe_fonciere')}>Taxe foncière</button>
          <select value={org} onChange={(e) => setOrg(e.target.value)}>
            <option value="">Organisme externe…</option>
            {organismes.map((o) => <option key={o.id} value={o.id}>{o.nom}{o.ville ? ' (' + o.ville + ')' : ''}</option>)}
          </select>
          {org && <button className="btn plein" onClick={() => enregistrer(l, 'organisme_externe', Number(org))}>Enregistrer</button>}
        </div>
      </>}
  </div>;
}

// Ajouter un organisme (nom obligatoire ; l'e-mail sert aux déclarations d'entrée et de départ des locataires)
export function Organisme({ o = {}, fermer, apres, onErreur }) {
  const [f, setF] = useState({ nom: o.nom || '', email: o.email || '', telephone: o.telephone || '', adresse: o.adresse || '', code_postal: o.code_postal || '', ville: o.ville || '', site_web: o.site_web || '', notes: o.notes || '' });
  const ch = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const ok = async () => {
    try {
      await rpc('pilotage_organisme_ordures_maj', { p_id: o.id || null, p_nom: f.nom, p_email: f.email, p_telephone: f.telephone, p_adresse: f.adresse,
        p_code_postal: f.code_postal, p_ville: f.ville, p_site_web: f.site_web, p_notes: f.notes });
      await apres();
    } catch (e) { onErreur(e.message); }
  };
  return <div className="card" style={{ margin: '8px 0 8px 18px', fontSize: 13 }}>
    <div className="row" style={{ gap: 6 }}>
      <label>Nom <input value={f.nom} onChange={ch('nom')} /></label>
      <label>E-mail <input value={f.email} onChange={ch('email')} /></label>
      <label>Téléphone <input value={f.telephone} onChange={ch('telephone')} /></label>
    </div>
    <div className="row" style={{ gap: 6, marginTop: 6 }}>
      <label>Adresse <input value={f.adresse} onChange={ch('adresse')} /></label>
      <label>Code postal <input style={{ width: 80 }} value={f.code_postal} onChange={ch('code_postal')} /></label>
      <label>Ville <input value={f.ville} onChange={ch('ville')} /></label>
      <label>Site <input value={f.site_web} onChange={ch('site_web')} /></label>
    </div>
    <div className="row" style={{ marginTop: 6 }}>
      <button className="btn plein" disabled={!f.nom.trim()} onClick={ok}>Enregistrer l’organisme</button>
      <button className="btn gris" onClick={fermer}>Annuler</button>
    </div>
  </div>;
}
