// Liste « À louer » (038) : lots mis en location par la gestion (proposés d'office quand un congé arrive à sa fin ou qu'un lot n'a pas
// de bail), indicateur « prêt à louer » (DPE, état des risques de moins de 6 mois, permis de louer), sortie automatique à la création
// d'un bail dans Rivage. En dessous : la table des communes du permis de louer, à confirmer par la gestion.
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';
import { REGIME } from './Permis.jsx';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');
const euro = (n) => (n == null ? '—' : Number(n).toLocaleString('fr-FR', { maximumFractionDigits: 0 }) + ' €');
const NATURE = { flat: 'Appartement', room: 'Chambre', house: 'Maison', commercial: 'Local commercial', office: 'Bureau', parking: 'Parking', box: 'Box', basement: 'Cave' };

export default function ALouer() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_a_louer').then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const agir = async (args) => { setErr(''); try { await rpc('pilotage_a_louer_maj', args); await charger(); } catch (e) { setErr(e.message); } };
  const prets = d.lots.filter((l) => l.pret.dpe && l.pret.erp && l.pret.permis).length;
  return <>
    <div className="entete"><div><h1>À louer</h1>
      <p className="sub">Lots en recherche de locataire. Un lot sort de la liste dès qu’un bail est créé dans Rivage.</p></div></div>
    {err && <div className="banner">{err}</div>}
    <div className="tuiles">
      <div className="tuile"><div className="muted">Lots à louer</div><div className="tuile-n">{d.lots.length}</div></div>
      <div className="tuile"><div className="muted">Prêts à louer</div><div className="tuile-n">{prets}</div></div>
      {d.peut && <div className="tuile"><div className="muted">Propositions à confirmer</div><div className="tuile-n" style={{ color: d.propositions.length ? 'var(--amber)' : undefined }}>{d.propositions.length}</div></div>}
    </div>
    {d.peut && d.propositions.length > 0 && <details className="replie" open style={{ margin: '10px 0' }}>
      <summary style={{ cursor: 'pointer', fontWeight: 700 }}>À mettre en location ? ({d.propositions.length})</summary>
      <div className="muted" style={{ fontSize: 12, margin: '4px 0' }}>Congé qui arrive à sa fin ou lot d’un mandat sans bail : confirmer d’un clic.</div>
      <div className="stack" style={{ gap: 6 }}>{d.propositions.map((p) => <Proposition key={p.asset_id} p={p} agir={agir} />)}</div>
    </details>}
    {!d.lots.length ? <div className="card">Aucun lot en recherche de locataire.</div>
      : <div className="stack" style={{ gap: 8 }}>{d.lots.map((l) => <LotALouer key={l.asset_id} l={l} peut={d.peut} agir={agir} />)}</div>}
    <Communes />
  </>;
}

function Proposition({ p, agir }) {
  const [f, setF] = useState({ dispo: p.disponible_le || '', loyer: p.loyer_dernier ?? '' });
  return <div className="card haute" style={{ padding: 10 }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <div><b>Lot {p.lot}</b> · {NATURE[p.nature] || p.nature} · {p.adresse}<div className="muted" style={{ fontSize: 12 }}>{p.motif} · bailleur : {p.bailleur || '—'}</div></div>
      <div className="row">
        <label className="muted">Disponible le <input type="date" value={f.dispo} onChange={(e) => setF({ ...f, dispo: e.target.value })} /></label>
        <label className="muted">Loyer CC <input type="number" value={f.loyer} onChange={(e) => setF({ ...f, loyer: e.target.value })} style={{ width: 90 }} /></label>
        <button className="btn plein" onClick={() => agir({ p_asset: p.asset_id, p_action: 'ajouter', p_disponible: f.dispo || null, p_loyer: f.loyer === '' ? null : Number(f.loyer), p_motif: p.motif, p_note: null })}>Mettre en location</button>
      </div>
    </div>
  </div>;
}

function Pastille({ ok, oui, non }) {
  return <span className={'etq ' + (ok ? 'ok' : 'rose')} style={{ marginRight: 4 }}>{ok ? '✓ ' + oui : '✗ ' + non}</span>;
}

function LotALouer({ l, peut, agir }) {
  const [edit, setEdit] = useState(false);
  const [f, setF] = useState({ dispo: l.disponible_le || '', loyer: l.loyer_prevu ?? '', note: l.note || '' });
  const pret = l.pret || {};
  const soumisPermis = l.permis?.regime === 'autorisation';
  return <article className={'card ' + (pret.dpe && pret.erp && pret.permis ? 'normale' : 'haute')} style={{ padding: 12 }}>
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
      <div>
        <div className="kcarte-titre">Lot {l.lot} · {NATURE[l.nature] || l.nature}{l.surface ? ` · ${l.surface} m²` : ''}</div>
        <div className="muted">{l.adresse} · bailleur : {l.bailleur || '—'}</div>
        <div style={{ fontSize: 13, marginTop: 4 }}>Disponible le {date(l.disponible_le)} · loyer prévu {euro(l.loyer_prevu)} · en liste depuis le {date(l.depuis)}{l.motif ? ' · ' + l.motif : ''}</div>
        <div style={{ marginTop: 6 }}>
          <Pastille ok={pret.dpe} oui={'DPE' + (pret.dpe_classe ? ' ' + pret.dpe_classe : '')} non="DPE manquant ou expiré" />
          <Pastille ok={pret.erp} oui="État des risques" non="État des risques de plus de 6 mois" />
          {soumisPermis && <Pastille ok={pret.permis} oui="Permis de louer" non="Permis de louer à obtenir" />}
          {!soumisPermis && l.permis?.regime && l.permis.regime !== 'non_concerne' && l.permis.regime !== 'aucun' &&
            <span className="etq">{REGIME[l.permis.regime]}</span>}
        </div>
        {['commercial', 'office'].includes(l.nature) || !['F', 'G'].includes(pret.dpe_classe) ? null
          : <div style={{ color: 'var(--red)', fontSize: 12, marginTop: 4 }}>DPE classé {pret.dpe_classe} : vérifier les interdictions de location applicables aux logements énergivores.</div>}
        {l.note && <div className="muted" style={{ fontSize: 12 }}>{l.note}</div>}
      </div>
      {peut && <div className="row">
        <button className="btn" onClick={() => setEdit(!edit)}>Modifier</button>
        <button className="btn gris" onClick={() => agir({ p_asset: l.asset_id, p_action: 'retirer', p_disponible: null, p_loyer: null, p_motif: 'Retiré par la gestion', p_note: null })}>Retirer</button>
      </div>}
    </div>
    {edit && <div className="row" style={{ marginTop: 6 }}>
      <label className="muted">Disponible le <input type="date" value={f.dispo} onChange={(e) => setF({ ...f, dispo: e.target.value })} /></label>
      <label className="muted">Loyer CC <input type="number" value={f.loyer} onChange={(e) => setF({ ...f, loyer: e.target.value })} style={{ width: 90 }} /></label>
      <input placeholder="Note pour les commerciaux" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} style={{ width: 240 }} />
      <button className="btn plein" onClick={async () => { await agir({ p_asset: l.asset_id, p_action: 'modifier', p_disponible: f.dispo || null, p_loyer: f.loyer === '' ? null : Number(f.loyer), p_motif: null, p_note: f.note || null }); setEdit(false); }}>Enregistrer</button>
    </div>}
  </article>;
}

// ----- Table des communes du permis de louer -----
function Communes() {
  const [c, setC] = useState(null);
  const [err, setErr] = useState('');
  const [sel, setSel] = useState(null);
  const charger = () => rpc('pilotage_permis_communes').then(setC).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  if (!c) return null;
  const aConfirmer = c.filter((x) => x.statut === 'a_confirmer');
  return <details className="replie" open={aConfirmer.length > 0} style={{ marginTop: 18 }}>
    <summary style={{ cursor: 'pointer', fontWeight: 700 }}>Permis de louer : communes ({c.length}){aConfirmer.length ? ` · ${aConfirmer.length} à confirmer` : ''}</summary>
    <div className="muted" style={{ fontSize: 12, margin: '4px 0' }}>Les communes des logements gérés absentes de la table sont recherchées automatiquement sur le web ; le résultat reste « à confirmer » jusqu’à validation par la gestion. Un arrêté peut évoluer : revérifier régulièrement.</div>
    {err && <div className="banner">{err}</div>}
    <div className="table-wrap"><table className="table-imp"><thead><tr><th>Commune</th><th>Régime</th><th>Périmètre</th><th>Source</th><th>Vérifiée</th><th /></tr></thead>
      <tbody>{c.map((x) => <React.Fragment key={x.commune}>
        <tr style={{ background: x.statut === 'a_confirmer' ? 'var(--amber-bg, #fff6e5)' : undefined }}>
          <td><b>{x.libelle}</b>{x.statut === 'a_confirmer' && <div className="etq rose">à confirmer</div>}</td>
          <td>{REGIME[x.regime]}{x.regime_hors_perimetre ? ` (ailleurs : ${REGIME[x.regime_hors_perimetre].toLowerCase()})` : ''}</td>
          <td>{x.perimetre === 'rues' ? `${x.rues} voie(s)` : 'Toute la commune'}</td>
          <td style={{ maxWidth: 280, fontSize: 12 }}>{x.notes ? x.notes + ' · ' : ''}{x.source && /^https?:/.test(x.source) ? <a href={x.source} target="_blank" rel="noreferrer">source</a> : x.source}</td>
          <td style={{ fontSize: 12 }}>{x.verifie_le ? date(x.verifie_le) + (x.verifie_par ? ' · ' + x.verifie_par : '') : x.recherche_le ? 'recherche IA du ' + date(x.recherche_le) : '—'}</td>
          <td><button className="lien" onClick={() => setSel(sel === x.commune ? null : x.commune)}>{x.statut === 'a_confirmer' ? 'Confirmer' : 'Modifier'}</button></td>
        </tr>
        {sel === x.commune && <tr><td colSpan={6}><EditCommune x={x} fini={async () => { setSel(null); await charger(); }} onErreur={setErr} /></td></tr>}
      </React.Fragment>)}</tbody></table></div>
    {sel === '__nouvelle' ? <EditCommune x={{ libelle: '', regime: 'autorisation', perimetre: 'commune' }} fini={async () => { setSel(null); await charger(); }} onErreur={setErr} />
      : <button className="lien" onClick={() => setSel('__nouvelle')}>+ Ajouter une commune</button>}
  </details>;
}

function EditCommune({ x, fini, onErreur }) {
  const [f, setF] = useState({ libelle: x.libelle || '', regime: x.regime || 'autorisation', perimetre: x.perimetre || 'commune', hors: x.regime_hors_perimetre || '',
    email: x.email_depot || '', adresse: x.adresse_depot || '', source: x.source || '', notes: x.notes || '' });
  const m = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const enregistrer = async () => {
    try { await rpc('pilotage_permis_commune_maj', { p_commune: f.libelle, p_libelle: f.libelle, p_regime: f.regime, p_perimetre: f.perimetre, p_hors: f.hors || null,
      p_email: f.email, p_adresse: f.adresse, p_source: f.source, p_notes: f.notes }); await fini(); } catch (e) { onErreur(e.message); }
  };
  return <div className="grille-champs" style={{ padding: 8, background: 'var(--bg)', borderRadius: 8 }}>
    {x.recherche?.detail && <div style={{ gridColumn: '1 / -1', fontSize: 13 }}>✦ Recherche IA : {x.recherche.detail} {(x.recherche.sources || []).map((u, i) => <a key={u} href={u} target="_blank" rel="noreferrer" style={{ marginLeft: 6 }}>[{i + 1}]</a>)}</div>}
    <label className="champ-imp"><span>Commune</span><input value={f.libelle} onChange={m('libelle')} disabled={!!x.commune} /></label>
    <label className="champ-imp"><span>Régime</span><select value={f.regime} onChange={m('regime')}><option value="autorisation">Autorisation préalable</option><option value="declaration">Déclaration</option><option value="aucun">Pas de permis</option></select></label>
    <label className="champ-imp"><span>Périmètre</span><select value={f.perimetre} onChange={m('perimetre')}><option value="commune">Toute la commune</option><option value="rues">Certaines voies</option></select></label>
    {f.perimetre === 'rues' && <label className="champ-imp"><span>Hors périmètre</span><select value={f.hors} onChange={m('hors')}><option value="">Pas de permis</option><option value="declaration">Déclaration</option></select></label>}
    <label className="champ-imp"><span>Mail de dépôt</span><input value={f.email} onChange={m('email')} /></label>
    <label className="champ-imp"><span>Adresse de dépôt</span><input value={f.adresse} onChange={m('adresse')} /></label>
    <label className="champ-imp"><span>Source (arrêté, page officielle)</span><input value={f.source} onChange={m('source')} /></label>
    <label className="champ-imp"><span>Notes</span><input value={f.notes} onChange={m('notes')} /></label>
    {f.perimetre === 'rues' && !x.rues && <div className="muted" style={{ gridColumn: '1 / -1', fontSize: 12 }}>La liste des voies du périmètre s’ajoute par script (comme pour Corbeil-Essonnes) : envoyez-la à Claude.</div>}
    <div className="row" style={{ gridColumn: '1 / -1' }}><button className="btn plein" disabled={!f.libelle.trim()} onClick={enregistrer}>Enregistrer et confirmer</button><button className="lien" onClick={() => fini()}>Annuler</button></div>
  </div>;
}
