import React, { useEffect, useMemo, useState } from 'react';
import { supabase, rpc } from './supabase.js';

const CAT = { oblig: 'Obligation', tache: 'Tâche', controle: 'Contrôle', courrier: 'Courrier' };
const SEV = { critique: 'Critique', haute: 'Haute', normale: 'Normale' };
const ROLES = { direction: 'Direction', superviseur: 'Superviseur', gestionnaire: 'Gestionnaire', comptable: 'Comptable', negociateur: 'Négociateur' };
const euro = (n) => (n == null ? '—' : Number(n).toLocaleString('fr-FR', { style: 'currency', currency: 'EUR' }));
const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '—');

export default function App() {
  const [session, setSession] = useState(null);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); setReady(true); });
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);
  if (!ready) return null;
  return session ? <Espace /> : <Connexion />;
}

function Connexion() {
  const [email, setEmail] = useState('');
  const [mdp, setMdp] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const go = async (e) => {
    e.preventDefault(); setBusy(true); setErr('');
    const { error } = await supabase.auth.signInWithPassword({ email, password: mdp });
    if (error) setErr('Connexion refusée : vérifiez l’e-mail et le mot de passe (les mêmes que sur UDIGESTION).');
    setBusy(false);
  };
  return (
    <form className="card login" onSubmit={go}>
      <h1>Pilotage UDI Gestion</h1>
      <p className="sub">Connectez-vous avec votre compte UDIGESTION.</p>
      <label className="muted" htmlFor="em">E-mail</label>
      <input id="em" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required />
      <label className="muted" htmlFor="pw">Mot de passe</label>
      <input id="pw" type="password" autoComplete="current-password" value={mdp} onChange={(e) => setMdp(e.target.value)} required />
      {err && <div className="err">{err}</div>}
      <button className="btn plein" disabled={busy} type="submit">{busy ? 'Connexion…' : 'Se connecter'}</button>
    </form>
  );
}

function Espace() {
  const [moi, setMoi] = useState(undefined);
  const [onglet, setOnglet] = useState('jour');
  const [err, setErr] = useState('');
  const [tableaux, setTableaux] = useState([]);
  useEffect(() => {
    rpc('pilotage_moi').then(setMoi).catch((e) => setErr(e.message));
    rpc('pilotage_tableaux_visibles').then((t) => setTableaux(t || [])).catch(() => {});
  }, []);
  const voit = (t) => tableaux.includes(t);
  if (err) return <main><div className="banner">{err}</div></main>;
  if (moi === undefined) return <main><p className="sub">Chargement…</p></main>;
  if (moi === null) return (
    <main><div className="card"><h1>Accès non ouvert</h1><p className="sub">Votre compte existe mais n’a pas encore accès au pilotage. Demandez à Nicolas de vous ajouter dans l’onglet Équipe.</p>
      <button className="btn gris" onClick={() => supabase.auth.signOut()}>Se déconnecter</button></div></main>
  );
  const tabs = [['jour', 'Ma journée', true], ['agence', 'Toute l’agence', voit('agence')], ['sinistres', 'Sinistres', voit('sinistres')],
    ['dg', 'Sorties et DG', voit('dg')], ['compta', 'Comptabilité', voit('compta')], ['mandats', 'Mandats et commissions', moi.voit_commissions], ['obligations', 'Obligations suivies', moi.voit_reglages],
    ['regles', 'Règles de relance', moi.voit_reglages], ['equipe', 'Équipe', moi.voit_reglages]].filter((t) => t[2]);
  return (
    <>
      <header className="top">
        <span className="brand">Pilotage UDI Gestion</span>
        <nav className="tabs">{tabs.map(([k, l]) => <button key={k} className={'tab' + (onglet === k ? ' on' : '')} onClick={() => setOnglet(k)}>{l}</button>)}</nav>
        <span className="me">{moi.prenom} · {ROLES[moi.role]} <button onClick={() => supabase.auth.signOut()}>Déconnexion</button></span>
      </header>
      <main>
        {onglet === 'jour' && <Journee moi={moi} />}
        {onglet === 'agence' && voit('agence') && <Agence />}
        {onglet === 'sinistres' && voit('sinistres') && <Sinistres />}
        {onglet === 'dg' && voit('dg') && <SortiesDG />}
        {onglet === 'compta' && voit('compta') && <Compta />}
        {onglet === 'mandats' && moi.voit_commissions && <Mandats />}
        {onglet === 'obligations' && moi.voit_reglages && <Obligations />}
        {onglet === 'regles' && moi.voit_reglages && <Regles />}
        {onglet === 'equipe' && moi.voit_reglages && <Equipe moi={moi} />}
      </main>
    </>
  );
}

function Journee({ moi }) {
  const [membres, setMembres] = useState([]);
  const [cible, setCible] = useState(moi.user_id);
  const [alertes, setAlertes] = useState(null);
  const [cat, setCat] = useState('toutes');
  const [ouvert, setOuvert] = useState(null);
  const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_journee', { p_user: cible }).then(setAlertes).catch((e) => setErr(e.message));
  useEffect(() => { if (moi.voit_equipe) rpc('pilotage_membres').then(setMembres).catch(() => {}); }, []);
  useEffect(() => { setAlertes(null); charger(); }, [cible]);
  const traiter = async (a, oui) => { try { await rpc('pilotage_traiter', { p_alerte: a.id, p_traitee: oui }); setOuvert(null); charger(); } catch (e) { setErr(e.message); } };

  const ouvertes = (alertes || []).filter((a) => a.statut === 'ouverte');
  const traitees = (alertes || []).filter((a) => a.statut === 'traitee');
  const visibles = ouvertes.filter((a) => cat === 'toutes' || a.categorie === cat);
  const dossiers = useMemo(() => {
    const m = new Map();
    visibles.forEach((a) => {
      const k = a.dossier?.type === 'bail' || a.dossier?.type === 'lot' ? a.dossier.type + a.dossier.ref : 'm' + (a.mandat_id || a.id);
      if (!m.has(k)) m.set(k, { cle: k, dossier: a.dossier, mandat: a.mandat, alertes: [] });
      m.get(k).alertes.push(a);
    });
    const rang = { critique: 0, haute: 1, normale: 2 };
    return [...m.values()].map((d) => ({ ...d, pire: d.alertes.reduce((p, a) => Math.min(p, rang[a.gravite]), 2) }))
      .sort((x, y) => x.pire - y.pire || y.alertes.length - x.alertes.length);
  }, [alertes, cat]);
  const nomCible = cible === moi.user_id ? moi.prenom : (membres.find((m) => m.user_id === cible)?.prenom || '');
  const gravNom = ['critique', 'haute', 'normale'];

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-end', marginBottom: 12 }}>
        <div>
          <h1>{cible === moi.user_id ? `Bonjour ${moi.prenom}` : `Journée de ${nomCible}`}</h1>
          <p className="sub">{new Date().toLocaleDateString('fr-FR', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })} · {ouvertes.length} alerte{ouvertes.length > 1 ? 's' : ''} à traiter</p>
        </div>
        {moi.voit_equipe && membres.length > 1 && (
          <div className="row" role="group" aria-label="Voir la journée de">
            {membres.map((m) => <button key={m.user_id} className={'chip' + (cible === m.user_id ? ' on' : '')} onClick={() => setCible(m.user_id)}>{m.prenom}</button>)}
          </div>
        )}
      </div>
      {err && <div className="banner">{err}</div>}
      {moi.role === 'direction' && cible === moi.user_id && <div className="info">Vous voyez ici les alertes des mandats attribués à vous et celles des mandats qui ne sont encore attribués à personne.</div>}
      <div className="row" style={{ marginBottom: 14 }}>
        {[['toutes', 'Toutes']].concat(Object.entries(CAT)).map(([k, l]) => (
          <button key={k} className={'chip' + (cat === k ? ' on' : '')} onClick={() => setCat(k)}>{l}<span className="n">{k === 'toutes' ? ouvertes.length : ouvertes.filter((a) => a.categorie === k).length}</span></button>
        ))}
      </div>
      {alertes === null ? <p className="sub">Chargement…</p> : dossiers.length === 0 ? <div className="card">Rien à traiter pour {nomCible}.</div> : (
        <div className="stack">
          {dossiers.map((d) => (
            <article key={d.cle} className={'card ' + gravNom[d.pire]}>
              <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <span className={'sev ' + gravNom[d.pire]}>{SEV[gravNom[d.pire]]}</span>
                  <h2 style={{ fontSize: 17, margin: '4px 0 2px' }}>{d.dossier?.type === 'bail' ? `Bail ${d.dossier.ref}` : d.dossier?.type === 'lot' ? `Lot ${d.dossier.ref}` : d.mandat || 'Dossier'}{d.dossier?.adresse ? ` · ${d.dossier.adresse}` : ''}</h2>
                  <div className="grid2">
                    {d.dossier?.locataires && <><span>Locataire</span><span>{d.dossier.locataires}</span></>}
                    {d.mandat && <><span>Mandat</span><span>{d.mandat}</span></>}
                  </div>
                </div>
                {d.dossier?.lien && <a className="btn" href={d.dossier.lien} target="_blank" rel="noopener">Ouvrir dans Rivage</a>}
              </div>
              <div className="stack" style={{ gap: 6, marginTop: 10 }}>
                {d.alertes.map((a) => (
                  <div key={a.id} className={'alerte ' + a.gravite}>
                    <button className="head" aria-expanded={ouvert === a.id} onClick={() => setOuvert(ouvert === a.id ? null : a.id)}>
                      <span className="row"><span className={'tag ' + a.categorie}>{CAT[a.categorie]}</span><strong style={{ fontSize: 14 }}>{a.titre}</strong></span>
                      <span className="muted">depuis le {date(a.depuis)}</span>
                    </button>
                    {ouvert === a.id && (
                      <div className="detail">
                        {a.detail && <p style={{ margin: '0 0 6px' }}>{a.detail}</p>}
                        <p style={{ margin: '0 0 6px' }}><strong>Règle :</strong> {a.explication}</p>
                        <div className="row">
                          {a.lien && <a className="btn" href={a.lien} target="_blank" rel="noopener">Voir dans Rivage</a>}
                          <button className="btn plein" onClick={() => traiter(a, true)}>Traité</button>
                        </div>
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </article>
          ))}
        </div>
      )}
      {traitees.length > 0 && (
        <details style={{ marginTop: 18 }}><summary style={{ cursor: 'pointer', color: 'var(--teal)' }}>Traité ces 7 derniers jours ({traitees.length})</summary>
          <ul style={{ fontSize: 13, color: 'var(--ink2)' }}>{traitees.map((a) => <li key={a.id}>{a.titre} · par {a.traitee_par} le {date(a.traitee_le)} <button className="btn gris" style={{ minHeight: 28 }} onClick={() => traiter(a, false)}>Rouvrir</button></li>)}</ul>
          <p className="muted">Une alerte traitée revient si le problème est toujours présent dans Rivage au contrôle suivant.</p>
        </details>
      )}
    </>
  );
}

const SUIVI_DEPUIS = '2026-01-01'; // mandats concernés par la commission de rentrée
const suivi = (m) => (m.debut || '') >= SUIVI_DEPUIS;

function Mandats() {
  const [rows, setRows] = useState(null);
  const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_mandats').then(setRows).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  const saisir = async (m, cle, valeur) => { try { await rpc('pilotage_saisir_mandat', { p_mandat: m.id, p_cle: cle, p_valeur: valeur }); charger(); } catch (e) { setErr(e.message); } };
  if (!rows) return err ? <div className="banner">{err}</div> : <p className="sub">Chargement…</p>;
  const sansGo = rows.filter((m) => suivi(m) && m.loyer_cc > 0 && !(m.go && m.go.v));
  return (
    <>
      <h1>Mandats et commissions</h1>
      <p className="sub">Visible par Nicolas et Romain. Commission et GO suivis pour les mandats rentrés depuis le 01/01/2026. Commission estimée selon le nouveau barème : 8 mois d’honoraires de gestion HT (loyer CC × taux TTC ÷ 1,2 × 8).</p>
      {err && <div className="banner">{err}</div>}
      {sansGo.length > 0 && <div className="banner">{sansGo.length} mandat{sansGo.length > 1 ? 's' : ''} loué{sansGo.length > 1 ? 's' : ''} sans GO : {sansGo.map((m) => 'n°' + m.reference).join(', ')}</div>}
      <div className="table-wrap">
        <table>
          <thead><tr><th>Mandat</th><th>Statut</th><th>Début</th><th>Signé le</th><th>Taux TTC</th><th>Lots</th><th>Loyers CC en cours</th><th>Commission estimée</th><th>Négociateur</th><th>GO</th><th></th></tr></thead>
          <tbody>
            {rows.map((m) => {
              const anomalie = suivi(m) && m.loyer_cc > 0 && !(m.go && m.go.v);
              const commission = suivi(m) && m.loyer_cc && m.taux_ttc ? (m.loyer_cc * m.taux_ttc / 100 / 1.2) * 8 : null;
              return (
                <tr key={m.id} className={anomalie ? 'anomalie' : ''}>
                  <td><strong>n°{m.reference}</strong>{m.nom ? ` · ${m.nom}` : ''}</td>
                  <td>{m.statut === 'active' ? 'Actif' : m.statut === 'lost' ? 'Perdu' : m.statut}</td>
                  <td>{date(m.debut)}</td>
                  <td style={{ color: m.signe_le ? 'inherit' : 'var(--red)' }}>{m.signe_le ? date(m.signe_le) : 'non signé'}</td>
                  <td>{m.taux_ttc != null ? m.taux_ttc + ' %' : '—'}</td>
                  <td>{m.lots}</td>
                  <td>{euro(m.loyer_cc)}</td>
                  <td>{euro(commission)}</td>
                  <td><input aria-label={'Négociateur du mandat ' + m.reference} defaultValue={m.negociateur || ''} placeholder="à identifier" style={{ width: 110, padding: '4px 6px', border: '1px solid #C9D3DC', borderRadius: 6 }}
                    onBlur={(e) => { const v = e.target.value.trim(); if (v !== (m.negociateur || '')) saisir(m, 'negociateur', { v }); }} /></td>
                  <td>{!suivi(m) ? <span className="muted">avant 2026</span> : m.go && m.go.v ? <span>✓ {date(m.go.le)}</span> : <button className="btn" onClick={() => saisir(m, 'go', { v: true, le: new Date().toISOString().slice(0, 10) })}>Donner le GO</button>}</td>
                  <td><a className="btn gris" href={m.lien} target="_blank" rel="noopener">Rivage</a></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </>
  );
}

function useReglages() {
  const [r, setR] = useState(null); const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_reglages').then(setR).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  return [r, err, charger, setErr];
}

function Obligations() {
  const [r, err] = useReglages();
  const [dom, setDom] = useState('Toutes'); const [st, setSt] = useState('tous');
  if (!r) return err ? <div className="banner">{err}</div> : <p className="sub">Chargement…</p>;
  const ob = r.obligations || [];
  const doms = ['Toutes', ...new Set(ob.map((o) => o.domaine))];
  const STL = { auto: 'Automatisable', partiel: 'Rivage + saisie', saisie: 'À saisir', humain: 'Contrôle humain', regles: 'Règles à remplir' };
  const rows = ob.filter((o) => (dom === 'Toutes' || o.domaine === dom) && (st === 'tous' || o.statut === st));
  return (
    <>
      <h1>Obligations suivies</h1>
      <p className="sub">{ob.length} obligations. Réservé à Nicolas.</p>
      <div className="row" style={{ marginBottom: 8 }}>{doms.map((d) => <button key={d} className={'chip' + (dom === d ? ' on' : '')} onClick={() => setDom(d)}>{d}</button>)}</div>
      <div className="row" style={{ marginBottom: 14 }}>{[['tous', 'Tous']].concat(Object.entries(STL)).map(([k, l]) => <button key={k} className={'chip' + (st === k ? ' on' : '')} onClick={() => setSt(k)}>{l}<span className="n">{k === 'tous' ? ob.length : ob.filter((o) => o.statut === k).length}</span></button>)}</div>
      <div className="table-wrap"><table>
        <thead><tr><th>Obligation</th><th>Texte</th><th>Déclencheur</th><th>Alerte</th><th>Statut</th><th>Ce qui manque</th></tr></thead>
        <tbody>{rows.map((o) => <tr key={o.id}><td><strong>{o.obligation}</strong><div className="muted">{o.domaine} · {o.moment}{o.types ? ' · ' + o.types : ''}</div></td><td>{o.texte}</td><td>{o.declencheur}</td><td>{o.alerte}</td><td>{STL[o.statut] || o.statut}</td><td>{o.manque}</td></tr>)}</tbody>
      </table></div>
    </>
  );
}

function Regles() {
  const [r, err, charger, setErr] = useReglages();
  if (!r) return err ? <div className="banner">{err}</div> : <p className="sub">Chargement…</p>;
  const basculer = async (g) => { try { await rpc('pilotage_regle_activer', { p_cle: g.cle, p_actif: !g.actif }); charger(); } catch (e) { setErr(e.message); } };
  return (
    <>
      <h1>Règles de relance</h1>
      <p className="sub">Contrôles exécutés automatiquement toutes les 30 minutes. Une règle désactivée ne crée plus d’alerte ; les alertes déjà ouvertes se ferment au contrôle suivant.</p>
      {err && <div className="banner">{err}</div>}
      <div className="table-wrap"><table>
        <thead><tr><th>Règle</th><th>Domaine</th><th>Gravité</th><th>Alertes ouvertes</th><th>Active</th></tr></thead>
        <tbody>{(r.regles || []).map((g) => <tr key={g.cle}><td><strong>{g.libelle}</strong><div className="muted">{g.explication}</div></td><td>{g.domaine}</td><td><span className={'sev ' + g.gravite}>{SEV[g.gravite]}</span></td><td>{g.ouvertes}</td>
          <td><label className="switch"><input type="checkbox" checked={g.actif} onChange={() => basculer(g)} /> {g.actif ? 'Oui' : 'Non'}</label></td></tr>)}</tbody>
      </table></div>
    </>
  );
}

function Equipe({ moi }) {
  const [r, err, charger, setErr] = useReglages();
  const [f, setF] = useState({ email: '', prenom: '', role: 'gestionnaire' });
  const [sel, setSel] = useState(null);
  if (!r) return err ? <div className="banner">{err}</div> : <p className="sub">Chargement…</p>;
  const membres = r.membres || []; const mandats = r.mandats || [];
  const ajouter = async (e) => { e.preventDefault(); try { await rpc('pilotage_membre_enregistrer', { p_email: f.email, p_prenom: f.prenom, p_role: f.role, p_actif: true }); setF({ email: '', prenom: '', role: 'gestionnaire' }); charger(); } catch (x) { setErr(x.message); } };
  const modifier = async (m, patch) => { try { await rpc('pilotage_membre_enregistrer', { p_email: m.email, p_prenom: m.prenom, p_role: patch.role ?? m.role, p_actif: patch.actif ?? m.actif }); charger(); } catch (x) { setErr(x.message); } };
  const attribuer = async (mid, uid, oui) => { try { await rpc('pilotage_attribuer', { p_mandat: mid, p_user: uid, p_oui: oui }); charger(); } catch (x) { setErr(x.message); } };
  const choisi = membres.find((m) => m.user_id === sel);
  return (
    <>
      <h1>Équipe</h1>
      <p className="sub">Chaque membre ne voit que les alertes des mandats qui lui sont attribués. Romain (superviseur) voit en plus les journées de toute l’équipe et les commissions.</p>
      {err && <div className="banner">{err}</div>}
      <form className="form card" onSubmit={ajouter}>
        <label>E-mail du compte UDIGESTION<input type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} required /></label>
        <label>Prénom<input value={f.prenom} onChange={(e) => setF({ ...f, prenom: e.target.value })} required /></label>
        <label>Rôle<select value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}>{Object.entries(ROLES).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
        <button className="btn plein" type="submit">Ajouter</button>
      </form>
      <div className="table-wrap" style={{ marginBottom: 18 }}><table>
        <thead><tr><th>Membre</th><th>Rôle</th><th>Mandats attribués</th><th>Accès</th><th></th></tr></thead>
        <tbody>{membres.map((m) => <tr key={m.user_id}>
          <td><strong>{m.prenom}</strong><div className="muted">{m.email}</div></td>
          <td>{m.user_id === moi.user_id ? ROLES[m.role] : <select value={m.role} onChange={(e) => modifier(m, { role: e.target.value })}>{Object.entries(ROLES).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>}</td>
          <td>{m.mandats.length}</td>
          <td>{m.user_id === moi.user_id ? 'Oui' : <label className="switch"><input type="checkbox" checked={m.actif} onChange={() => modifier(m, { actif: !m.actif })} /> {m.actif ? 'Oui' : 'Non'}</label>}</td>
          <td><button className="btn gris" onClick={() => setSel(m.user_id)}>Attribuer des mandats</button></td>
        </tr>)}</tbody>
      </table></div>
      {choisi && (
        <div className="card">
          <h2 style={{ fontSize: 17, marginTop: 0 }}>Mandats de {choisi.prenom}</h2>
          <div className="row">{mandats.map((md) => { const oui = choisi.mandats.includes(md.id); return (
            <label key={md.id} className="chip" style={{ background: oui ? 'var(--teal-bg)' : '#fff' }}><input type="checkbox" checked={oui} onChange={() => attribuer(md.id, choisi.user_id, !oui)} /> n°{md.reference}{md.nom ? ' ' + md.nom : ''}</label>); })}</div>
        </div>
      )}
    </>
  );
}

// ===== Tableaux de suivi =====

function useCharge(fn) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const charger = () => rpc(fn).then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  return [d, err, charger];
}

function Chiffre({ n, l, alerte }) {
  return <div className="card" style={{ minWidth: 150, flex: '1 1 150px' }}>
    <div style={{ fontSize: 26, fontWeight: 700, color: alerte && n > 0 ? 'var(--red)' : 'var(--ink)' }}>{n}</div>
    <div className="muted">{l}</div></div>;
}

const TYPE_INC = { plumbing: 'Plomberie', roofing: 'Toiture', painting: 'Peinture', electricity: 'Électricité', electrical: 'Électricité', heating: 'Chauffage', locksmith: 'Serrurerie', other: 'Autre' };
const URG = { urgent: ['Urgent', 'critique'], high: ['Haute', 'haute'], normal: ['Normale', 'normale'], low: ['Basse', 'normale'] };
const ST_INC = { open: 'Ouvert', in_progress: 'En cours', closed: 'Clos', resolved: 'Résolu', cancelled: 'Annulé' };
const CHARGE = { tenant: 'Locataire', landlord: 'Propriétaire', agency: 'Agence' };

function Sinistres() {
  const [d, err] = useCharge('pilotage_sinistres');
  const [clos, setClos] = useState(false);
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const ouverts = d.filter((x) => !x.clos);
  const liste = clos ? d : ouverts;
  return <>
    <h1>Sinistres et incidents</h1>
    <p className="sub">Incidents déclarés dans Rivage, mis à jour à chaque modification.</p>
    <div className="row" style={{ marginBottom: 14 }}>
      <Chiffre n={ouverts.length} l="ouverts" />
      <Chiffre n={ouverts.filter((x) => x.urgence === 'urgent' || x.urgence === 'high').length} l="urgents ou prioritaires" alerte />
      <Chiffre n={ouverts.filter((x) => x.jours > 15).length} l="ouverts depuis plus de 15 jours" alerte />
      <Chiffre n={ouverts.filter((x) => !x.prestataires).length} l="sans prestataire" alerte />
    </div>
    <label className="switch" style={{ marginBottom: 10 }}><input type="checkbox" checked={clos} onChange={(e) => setClos(e.target.checked)} /> Afficher aussi les clos</label>
    <div className="table-wrap"><table>
      <thead><tr><th>N°</th><th>Incident</th><th>Lot et locataire</th><th>Urgence</th><th>Statut</th><th>Déclaré</th><th>Âge</th><th>À la charge</th><th>Estimé</th><th>Prestataire</th><th></th></tr></thead>
      <tbody>{liste.map((x) => {
        const u = URG[x.urgence] || [x.urgence, 'normale'];
        return <tr key={x.id} className={!x.clos && (x.jours > 15 || !x.prestataires) ? 'anomalie' : ''}>
          <td>{x.numero}</td>
          <td><b>{x.titre}</b><div className="muted">{TYPE_INC[x.type] || x.type}{x.description ? ' · ' + x.description : ''}</div></td>
          <td>{x.adresse || <span className="muted">Immeuble (pas de lot)</span>}<div className="muted">{[x.locataires, x.mandat].filter(Boolean).join(' · ')}</div></td>
          <td><span className={'sev ' + u[1]}>{u[0]}</span></td>
          <td>{ST_INC[x.statut] || x.statut}{x.resolu_le ? <div className="muted">le {date(x.resolu_le)}</div> : null}</td>
          <td>{date(x.declare_le)}</td>
          <td>{x.jours} j</td>
          <td>{CHARGE[x.a_charge] || x.a_charge || '—'}</td>
          <td>{euro(x.montant_estime)}</td>
          <td>{x.prestataires ? x.prestataires : <span style={{ color: 'var(--red)' }}>Aucun</span>}</td>
          <td><a className="btn gris" href={x.lien} target="_blank" rel="noreferrer">Rivage</a></td>
        </tr>;
      })}</tbody></table></div>
    {!liste.length && <p className="sub">Aucun incident.</p>}
  </>;
}

function SortiesDG() {
  const [d, err] = useCharge('pilotage_dg');
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const auj = new Date().toISOString().slice(0, 10);
  const etat = (x) => {
    if (x.remboursee) return ['Restitué', 'normale'];
    if (!x.parti) return ['Préavis en cours', 'normale'];
    if (auj > x.limite_2_mois) return ['Hors délai (2 mois dépassés)', 'critique'];
    if (auj > x.limite_1_mois) return ['Délai 1 mois dépassé', 'haute'];
    return [x.validee ? 'Validé, à virer' : 'À préparer', 'normale'];
  };
  const parti = d.filter((x) => x.parti && !x.remboursee);
  return <>
    <h1>Sorties et dépôts de garantie</h1>
    <p className="sub">Baux en sortie ou avec une date de fin. Délai légal de restitution : 1 mois après la remise des clés si l’état des lieux de sortie est conforme, 2 mois sinon (loi du 6 juillet 1989, art. 22). Au-delà, majoration de 10 % du loyer hors charges par mois de retard.</p>
    <div className="info">La date de fin affichée est celle du bail dans Rivage. La date réelle de remise des clés et la conformité de l’état des lieux ne sont pas exposées par Rivage : le délai applicable (1 ou 2 mois) reste à apprécier.</div>
    <div className="row" style={{ marginBottom: 14 }}>
      <Chiffre n={d.filter((x) => !x.parti).length} l="préavis en cours" />
      <Chiffre n={parti.length} l="partis, DG non restitué" alerte />
      <Chiffre n={parti.filter((x) => auj > x.limite_1_mois).length} l="au-delà d’un mois" alerte />
      <Chiffre n={parti.filter((x) => !x.restitution_creee).length} l="sans restitution créée dans Rivage" alerte />
    </div>
    <div className="table-wrap"><table>
      <thead><tr><th>Bail</th><th>Lot</th><th>Fin du bail</th><th>Dépôt</th><th>Limite 1 mois</th><th>Limite 2 mois</th><th>Restitution Rivage</th><th>État</th><th></th></tr></thead>
      <tbody>{d.map((x) => {
        const e = etat(x);
        return <tr key={x.bail_id} className={e[1] !== 'normale' ? 'anomalie' : ''}>
          <td><b>{x.locataires}</b><div className="muted">{x.reference}</div></td>
          <td>{x.adresse}<div className="muted">{x.mandat}</div></td>
          <td>{date(x.fin)}</td>
          <td>{euro(x.depot)}</td>
          <td>{date(x.limite_1_mois)}</td>
          <td>{date(x.limite_2_mois)}</td>
          <td>{!x.restitution_creee ? 'Non créée' : x.remboursee ? 'Remboursée' : x.validee ? 'Validée' : 'Créée, non validée'}</td>
          <td><span className={'sev ' + e[1]}>{e[0]}</span></td>
          <td><a className="btn gris" href={x.lien} target="_blank" rel="noreferrer">Rivage</a></td>
        </tr>;
      })}</tbody></table></div>
    {!d.length && <p className="sub">Aucune sortie en cours.</p>}
  </>;
}

function Compta() {
  const [d, err] = useCharge('pilotage_compta');
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const imp = d.periodes.filter((x) => x.solde < 0);
  const trop = d.periodes.filter((x) => x.solde > 0);
  return <>
    <h1>Comptabilité</h1>
    <p className="sub">Situation des locataires par période quittancée et comptes tiers, d’après les écritures reçues de Rivage.</p>
    <div className="info">Ne remontent ici que les périodes et comptes dont Rivage a envoyé les écritures depuis la mise en place (pas d’historique antérieur). Les ordres de virement aux propriétaires ne sont pas encore suivis.</div>
    <div className="row" style={{ marginBottom: 14 }}>
      <Chiffre n={imp.length + d.impayes_baux.length} l="impayés" alerte />
      <Chiffre n={trop.length} l="trop-perçus à régulariser" alerte />
      <Chiffre n={d.periodes.filter((x) => x.recu > 0 && !x.reverse_proprio).length} l="encaissés non reversés" />
    </div>
    <h2 style={{ fontSize: 18 }}>Loyers par période</h2>
    <div className="table-wrap"><table>
      <thead><tr><th>Bail</th><th>Lot</th><th>Période</th><th>Appelé</th><th>Reçu</th><th>Écart</th><th>Reçu le</th><th>Reversé proprio</th><th></th></tr></thead>
      <tbody>{d.periodes.map((x) => <tr key={x.bail_id + x.periode} className={x.solde !== 0 ? 'anomalie' : ''}>
        <td><b>{x.locataires}</b><div className="muted">{x.reference}</div></td>
        <td>{x.adresse}<div className="muted">{x.mandat}</div></td>
        <td>{date(x.periode)}</td>
        <td>{euro(x.du)}</td>
        <td>{euro(x.recu)}</td>
        <td style={{ fontWeight: 700, color: x.solde < 0 ? 'var(--red)' : x.solde > 0 ? 'var(--amber)' : 'inherit' }}>{x.solde > 0 ? '+' : ''}{euro(x.solde)}<div className="muted">{x.solde < 0 ? 'impayé' : x.solde > 0 ? 'trop-perçu' : 'soldé'}</div></td>
        <td>{date(x.recu_le)}</td>
        <td>{euro(x.reverse_proprio)}{x.dernier_virement_proprio ? <div className="muted">le {date(x.dernier_virement_proprio)}</div> : null}</td>
        <td><a className="btn gris" href={x.lien} target="_blank" rel="noreferrer">Rivage</a></td>
      </tr>)}</tbody></table></div>
    {!d.periodes.length && <p className="sub">Aucune période reçue.</p>}
    {d.impayes_baux.length > 0 && <>
      <h2 style={{ fontSize: 18 }}>Impayés déclarés sur les baux</h2>
      <div className="table-wrap"><table><thead><tr><th>Bail</th><th>Lot</th><th>Impayé</th><th></th></tr></thead>
        <tbody>{d.impayes_baux.map((x) => <tr key={x.bail_id} className="anomalie"><td><b>{x.locataires}</b><div className="muted">{x.reference}</div></td><td>{x.adresse}</td><td>{euro(x.impaye)}</td>
          <td><a className="btn gris" href={x.lien} target="_blank" rel="noreferrer">Rivage</a></td></tr>)}</tbody></table></div>
    </>}
    <h2 style={{ fontSize: 18 }}>Comptes tiers non soldés</h2>
    <p className="muted">Solde = crédit − débit. Un compte propriétaire négatif signifie que le propriétaire doit de l’argent à l’agence.</p>
    <div className="table-wrap"><table><thead><tr><th>Compte</th><th>Libellé</th><th>Débit</th><th>Crédit</th><th>Solde</th></tr></thead>
      <tbody>{d.comptes.map((x, i) => <tr key={i} className={x.titulaire === 'landlord' && x.solde < 0 ? 'anomalie' : ''}>
        <td>{x.compte} · {x.titulaire === 'tenant' ? 'Locataire' : 'Propriétaire'}</td><td>{x.libelle}</td><td>{euro(x.debit)}</td><td>{euro(x.credit)}</td>
        <td style={{ fontWeight: 700 }}>{euro(x.solde)}</td></tr>)}</tbody></table></div>
    {!d.comptes.length && <p className="sub">Tous les comptes tiers reçus sont soldés.</p>}
  </>;
}

function Agence() {
  const [d, err] = useCharge('pilotage_agence');
  const [qui, setQui] = useState('Tous');
  const [dom, setDom] = useState('Tous');
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const compte = (arr, k) => arr.reduce((m, x) => { m[x[k]] = (m[x[k]] || 0) + 1; return m; }, {});
  const parQui = compte(d, 'qui');
  const parDom = compte(d.filter((x) => qui === 'Tous' || x.qui === qui), 'domaine');
  const liste = d.filter((x) => (qui === 'Tous' || x.qui === qui) && (dom === 'Tous' || x.domaine === dom));
  return <>
    <h1>Toute l’agence</h1>
    <p className="sub">Toutes les alertes ouvertes, quelle que soit la personne. {d.length} au total.</p>
    <div className="row" style={{ marginBottom: 8 }}>
      {['Tous', ...Object.keys(parQui).sort()].map((k) => <button key={k} className={'chip' + (qui === k ? ' on' : '')} onClick={() => { setQui(k); setDom('Tous'); }}>{k}<span className="n">{k === 'Tous' ? d.length : parQui[k]}</span></button>)}
    </div>
    <div className="row" style={{ marginBottom: 14 }}>
      {['Tous', ...Object.keys(parDom).sort()].map((k) => <button key={k} className={'chip' + (dom === k ? ' on' : '')} onClick={() => setDom(k)}>{k === 'Tous' ? 'Tous domaines' : k}<span className="n">{k === 'Tous' ? Object.values(parDom).reduce((a, b) => a + b, 0) : parDom[k]}</span></button>)}
    </div>
    <div className="table-wrap"><table>
      <thead><tr><th>Gravité</th><th>Alerte</th><th>Dossier</th><th>Mandat</th><th>Qui</th><th>Depuis</th><th></th></tr></thead>
      <tbody>{liste.map((x) => <tr key={x.id}>
        <td><span className={'sev ' + x.gravite}>{SEV[x.gravite]}</span></td>
        <td><b>{x.libelle}</b><div className="muted">{x.domaine} · {CAT[x.categorie] || x.categorie}</div></td>
        <td>{x.titre}</td>
        <td>{x.mandat || '—'}</td>
        <td>{x.qui === 'Non attribué' ? <span className="muted">Non attribué</span> : x.qui}</td>
        <td>{date(x.depuis)}</td>
        <td>{x.lien ? <a className="btn gris" href={x.lien} target="_blank" rel="noreferrer">Rivage</a> : null}</td>
      </tr>)}</tbody></table></div>
  </>;
}
