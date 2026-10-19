// Liste « À louer » (038) : lots mis en location par la gestion (proposés d'office quand un congé arrive à sa fin ou qu'un lot n'a pas
// de bail), indicateur « prêt à louer » (DPE, état des risques de moins de 6 mois, permis de louer), sortie automatique à la création
// d'un bail dans Rivage. En dessous : la table des communes du permis de louer, à confirmer par la gestion.
import React, { useEffect, useState } from 'react';
import { supabase, rpc } from './supabase.js';
import { REGIME, LotPermis } from './Permis.jsx';

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
    <SuiviPermis />
    <Communes peut={d.peut} />
  </>;
}

// ----- Suivi d'ensemble du permis de louer (052) : tous les logements gérés soumis, état de la démarche, prochaine action -----
const FILTRES_PERMIS = [['traiter', 'À traiter', (x) => x.ordre <= 2], ['attente', 'En attente', (x) => x.ordre === 3], ['faits', 'À jour', (x) => x.ordre === 4], ['tous', 'Tous', () => true]];
function SuiviPermis() {
  const [liste, setListe] = useState(null);
  const [err, setErr] = useState('');
  const [filtre, setFiltre] = useState('traiter');
  const [ouvert, setOuvert] = useState(null);
  const [email, setEmail] = useState('');
  const [prenom, setPrenom] = useState('');
  const charger = () => rpc('pilotage_permis_suivi').then(setListe).catch((e) => setErr(e.message));
  useEffect(() => {
    charger();
    supabase.auth.getSession().then(({ data }) => setEmail(data?.session?.user?.email || ''));
    rpc('pilotage_moi').then((x) => setPrenom(x?.prenom || '')).catch(() => {});
  }, []);
  const agir = async (args) => { setErr(''); try { await rpc('pilotage_permis_action', args); await charger(); } catch (e) { setErr(e.message); } };
  if (!liste) return err ? <div className="banner" style={{ marginTop: 16 }}>Suivi du permis de louer indisponible : {err}</div> : null;
  const f = FILTRES_PERMIS.find((x) => x[0] === filtre);
  const vus = liste.filter(f[2]);
  return <section style={{ marginTop: 20 }}>
    <div className="groupe-tete"><b>Permis de louer : suivi des démarches</b></div>
    <div className="muted" style={{ fontSize: 12, margin: '4px 0 8px' }}>Tous les logements gérés soumis à autorisation préalable ou à déclaration de mise en location, d’après la table des communes.</div>
    {err && <div className="banner">{err}</div>}
    <div className="row" style={{ marginBottom: 10 }}>{FILTRES_PERMIS.map(([k, l, t]) =>
      <button key={k} className={'chip' + (filtre === k ? ' on' : '')} onClick={() => setFiltre(k)}>{l}<span className="n">{liste.filter(t).length}</span></button>)}</div>
    {!liste.length ? <div className="card">Aucun logement géré n’est soumis au permis de louer d’après la table des communes.</div>
      : !vus.length ? <div className="card">Rien avec ce filtre.</div>
      : <div className="stack" style={{ gap: 8 }}>{vus.map((x) => <article key={x.asset_id} className={'card ' + x.gravite} style={{ padding: 12 }}>
        <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div style={{ flex: 1, minWidth: 220 }}>
            <div className="kcarte-titre">Lot {x.lot} · {NATURE[x.nature] || x.nature}{x.a_louer ? ' · à louer' : ''}</div>
            <div className="muted">{x.adresse} · bailleur : {x.bailleur || '—'} · {x.mandat || '—'}</div>
            <div style={{ marginTop: 6 }}><span className={'sev ' + x.gravite}>{x.etat}</span>
              <span className="etq" style={{ marginLeft: 6 }}>{REGIME[x.permis?.regime] || x.permis?.regime}</span>
              {x.echeance && <span className="mono" style={{ marginLeft: 6, fontSize: 12 }}>échéance {date(x.echeance)}</span>}</div>
            {x.action && <div style={{ fontSize: 13, marginTop: 4 }}>{x.action}</div>}
            {x.bail && <div className="muted" style={{ fontSize: 12 }}>Bail {x.bail.reference} · {x.bail.locataires || '—'} · signé le {date(x.bail.signe_le)}</div>}
          </div>
          <button className="btn" onClick={() => setOuvert(ouvert === x.asset_id ? null : x.asset_id)}>{ouvert === x.asset_id ? 'Fermer' : x.peut ? 'Traiter' : 'Détail'}</button>
        </div>
        {ouvert === x.asset_id && (x.peut ? <LotPermis l={x} agir={agir} email={email} prenom={prenom} recharger={charger} />
          : <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>{(x.demandes || []).length ? x.demandes.map((dm) => `Dépôt le ${date(dm.depot_le)}${dm.reponse ? ' · ' + dm.reponse + ' le ' + date(dm.reponse_le) : ''}`).join(' ; ') : 'Aucune demande enregistrée.'} Seule la gestion peut enregistrer les démarches.</div>)}
      </article>)}</div>}
  </section>;
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
const perimetre = (x) => (x.perimetre !== 'rues' ? 'toute la commune' : x.rues ? `${x.rues} voie(s) concernée(s)` : 'certaines voies (liste à fournir)');

function Communes({ peut }) {
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
    <div className="stack" style={{ gap: 6 }}>{c.map((x) => <div key={x.commune} className="card" style={{ padding: '10px 12px', background: x.statut === 'a_confirmer' ? 'var(--amber-bg)' : undefined }}>
      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: 8 }}>
        <div style={{ minWidth: 0, flex: '1 1 320px' }}>
          <div><b>{x.libelle}</b>{x.statut === 'a_confirmer' && <span className="etq rose" style={{ marginLeft: 6 }}>à confirmer</span>}</div>
          <div style={{ fontSize: 13, marginTop: 2 }}>{REGIME[x.regime]}
            {x.regime === 'aucun' ? '' : <span className="muted"> · {perimetre(x)}{x.perimetre === 'rues' && x.regime_hors_perimetre && x.regime_hors_perimetre !== 'aucun' ? ` ; ailleurs : ${REGIME[x.regime_hors_perimetre].toLowerCase()}` : ''}</span>}</div>
          {(x.notes || x.source) && <div className="muted" style={{ fontSize: 12, marginTop: 2, overflowWrap: 'anywhere' }}>{x.notes}{x.notes && x.source ? ' · ' : ''}
            {x.source && /^https?:/.test(x.source) ? <a href={x.source} target="_blank" rel="noreferrer">source</a> : x.source}</div>}
        </div>
        <div className="row" style={{ gap: 8, flex: '0 0 auto' }}>
          <span className="muted" style={{ fontSize: 12 }}>{x.verifie_le ? 'Vérifiée le ' + date(x.verifie_le) + (x.verifie_par ? ' · ' + x.verifie_par : '') : x.recherche_le ? 'Recherche IA du ' + date(x.recherche_le) : ''}</span>
          {peut && <button className="btn" onClick={() => setSel(sel === x.commune ? null : x.commune)}>{sel === x.commune ? 'Fermer' : x.statut === 'a_confirmer' ? 'Confirmer' : 'Modifier'}</button>}
        </div>
      </div>
      {sel === x.commune && <div style={{ marginTop: 8 }}><EditCommune x={x} fini={async () => { setSel(null); await charger(); }} onErreur={setErr} /></div>}
    </div>)}</div>
    {!peut ? null : sel === '__nouvelle' ? <EditCommune x={{ libelle: '', regime: 'autorisation', perimetre: 'commune' }} fini={async () => { setSel(null); await charger(); }} onErreur={setErr} />
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
