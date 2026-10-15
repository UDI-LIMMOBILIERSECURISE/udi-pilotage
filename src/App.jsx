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
  useEffect(() => { rpc(fn).then(setD).catch((e) => setErr(e.message)); }, []);
  return [d, err];
}

const auj = () => new Date().toISOString().slice(0, 10);
const dateHeure = (d) => (d ? new Date(d).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—');
const EVT = { created: 'Création', updated: 'Modification', deleted: 'Suppression' };

function Tuiles({ items }) {
  return <div className="tuiles">{items.map(([n, l, rouge]) =>
    <div key={l} className="tuile"><div className="muted">{l}</div><div className="tuile-n" style={{ color: rouge && n > 0 ? 'var(--red)' : 'var(--ink)' }}>{n}</div></div>)}</div>;
}

function Filtres({ items, val, set }) {
  return <div className="row" style={{ marginBottom: 14 }}>{items.map(([k, l, n]) =>
    <button key={k} className={'chip' + (val === k ? ' on' : '')} onClick={() => set(k)}>{l}<span className="n">{n}</span></button>)}</div>;
}

// Mise en page : cartes à gauche, panneau de détail à droite (sous les cartes sur téléphone)
function AvecDetail({ children, detail, fermer, vide, cle }) {
  const ref = React.useRef(null);
  const ouvert = !!detail;
  useEffect(() => { if (ouvert && window.innerWidth < 900 && ref.current) ref.current.scrollIntoView({ behavior: 'smooth', block: 'start' }); }, [cle]);
  return <div className="avec-detail">
    <div className="zone-cartes">{children}</div>
    <aside className="zone-detail" ref={ref}>
      {detail ? <section className="panneau">
        <button className="fermer" onClick={fermer} aria-label="Fermer le détail">×</button>
        {detail}
      </section> : <div className="panneau vide">{vide}</div>}
    </aside>
  </div>;
}

function ResumeIA({ type, id }) {
  const [etat, setEtat] = useState({ charge: true });
  const demander = (forcer) => {
    setEtat((e) => ({ ...e, charge: true, err: '' }));
    supabase.functions.invoke('pilotage-resume', { body: { type, id, forcer } })
      .then(({ data, error }) => {
        if (error || !data?.texte) setEtat({ err: 'Résumé indisponible pour le moment.' });
        else setEtat({ ...data });
      })
      .catch(() => setEtat({ err: 'Résumé indisponible pour le moment.' }));
  };
  useEffect(() => { demander(false); }, [type, id]);
  return <div className="resume-ia">
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <span className="resume-ia-titre">✦ Résumé IA</span>
      {!etat.charge && <button className="lien" onClick={() => demander(true)}>Actualiser</button>}
    </div>
    {etat.charge ? <p className="muted">Analyse du dossier en cours…</p>
      : etat.err ? <p className="muted">{etat.err}</p>
      : <><p>{etat.texte}</p><div className="muted">Généré le {dateHeure(etat.genere_le)} à partir des seules données Rivage du dossier. À vérifier avant toute décision.</div></>}
  </div>;
}

function Champs({ items }) {
  return <dl className="champs">{items.filter((x) => x).map(([k, v]) => <React.Fragment key={k}><dt>{k}</dt><dd>{v ?? '—'}</dd></React.Fragment>)}</dl>;
}

function Historique({ items, libStatut }) {
  if (!items?.length) return null;
  return <><h3>Reçu de Rivage</h3><ol className="histo">{items.map((e, i) =>
    <li key={i}><span className="muted">{dateHeure(e.le)}</span><span>{EVT[e.evenement] || e.evenement}{e.statut ? ' · ' + (libStatut?.[e.statut] || e.statut) : ''}</span></li>)}</ol></>;
}

function AlertesLiees({ items }) {
  if (!items?.length) return null;
  return <><h3>Contrôles en alerte sur ce bail</h3>{items.map((a, i) =>
    <div key={i} className={'mini-alerte ' + a.gravite}><b>{SEV[a.gravite]}</b> · {a.libelle}<div className="muted">{a.detail}</div></div>)}</>;
}

// ----- Sinistres : colonnes par statut -----

const TYPE_INC = { plumbing: 'Plomberie', roofing: 'Toiture', painting: 'Peinture', electricity: 'Électricité', electrical: 'Électricité', heating: 'Chauffage', locksmith: 'Serrurerie', other: 'Autre' };
const URG = { urgent: ['Urgent', 'critique'], high: ['Haute', 'haute'], normal: ['Normale', 'normale'], low: ['Basse', 'normale'] };
const ST_INC = { open: 'Ouvert', in_progress: 'En cours', closed: 'Clos', resolved: 'Résolu', cancelled: 'Annulé' };
const CHARGE = { tenant: 'Locataire', landlord: 'Propriétaire', agency: 'Agence' };

function Sinistres() {
  const [d, err] = useCharge('pilotage_sinistres');
  const [filtre, setFiltre] = useState('tous');
  const [sel, setSel] = useState(null);
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const ouverts = d.filter((x) => !x.clos);
  const aJour = ouverts.filter((x) => x.jours <= 15).length;
  const tests = {
    tous: () => true,
    urgents: (x) => x.urgence === 'urgent' || x.urgence === 'high',
    vieux: (x) => !x.clos && x.jours > 15,
    sans: (x) => !x.clos && !x.prestataires,
  };
  const vus = d.filter(tests[filtre]);
  const colonnes = [['open', 'Ouvert'], ['in_progress', 'En cours'], ['clos', 'Clos']].map(([k, l]) =>
    [k, l, vus.filter((x) => (k === 'clos' ? x.clos : !x.clos && (x.statut === k || (k === 'open' && !['in_progress'].includes(x.statut)))))]);
  const s = d.find((x) => x.id === sel);
  return <>
    <div className="entete">
      <div><h1>Sinistres et incidents techniques</h1><p className="sub">Au {date(auj())} · {d.length} incidents reçus de Rivage</p></div>
      <div className="objectif"><div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Objectif : aucun incident ouvert depuis plus de 15 jours</span><b>{aJour}/{ouverts.length}</b></div>
        <div className="jauge"><div style={{ width: (ouverts.length ? (aJour / ouverts.length) * 100 : 100) + '%' }} /></div></div>
    </div>
    <Tuiles items={[[ouverts.length, 'Ouverts'], [ouverts.filter(tests.urgents).length, 'Urgents ou prioritaires', true],
      [ouverts.filter((x) => x.jours > 15).length, 'Ouverts depuis plus de 15 j', true], [ouverts.filter((x) => !x.prestataires).length, 'Sans prestataire', true],
      [d.filter((x) => x.clos).length, 'Clos']]} />
    <Filtres val={filtre} set={setFiltre} items={[['tous', 'Tous', d.length], ['urgents', 'Urgents', d.filter(tests.urgents).length],
      ['vieux', '+ de 15 jours', d.filter(tests.vieux).length], ['sans', 'Sans prestataire', d.filter(tests.sans).length]]} />
    <AvecDetail cle={sel} fermer={() => setSel(null)} vide="Clique sur un incident pour voir le détail." detail={s && <>
      <div className="muted">Incident n°{s.numero} · {ST_INC[s.statut] || s.statut}</div>
      <h2>{s.titre}</h2>
      <ResumeIA type="sinistre" id={s.id} />
      {s.description && <p>{s.description}</p>}
      <Champs items={[['Type', TYPE_INC[s.type] || s.type], ['Urgence', (URG[s.urgence] || [s.urgence])[0]], ['Lot', s.adresse ? `${s.adresse} (${s.lot})` : 'Immeuble, pas de lot précis'],
        ['Locataire', s.locataires], ['Bail', s.bail], ['Mandat', s.mandat], s.bailleur && ['Bailleur', s.bailleur], ['Déclaré le', date(s.declare_le)],
        ['Ancienneté', s.jours + ' jours'], ['Résolu le', s.resolu_le ? date(s.resolu_le) : null], ['À la charge de', CHARGE[s.a_charge] || s.a_charge],
        ['Montant estimé', euro(s.montant_estime)], ['Prestataires', s.prestataires ? String(s.prestataires) : 'Aucun désigné']]} />
      {!s.clos && !s.prestataires && <div className="mini-alerte haute">Aucun prestataire désigné dans Rivage.</div>}
      {!s.clos && s.jours > 15 && <div className="mini-alerte critique">Ouvert depuis plus de 15 jours.</div>}
      <Historique items={s.historique} libStatut={ST_INC} />
      <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={s.lien} target="_blank" rel="noreferrer">Ouvrir dans Rivage</a></div>
    </>}>
      <div className="kanban">{colonnes.map(([k, l, items]) => <div key={k} className="kcol">
        <div className="kcol-tete"><b>{l}</b><span className="pastille">{items.length}</span></div>
        {!items.length && <div className="muted" style={{ padding: '8px 4px' }}>Rien ici avec ce filtre.</div>}
        {items.map((x) => { const u = URG[x.urgence] || [x.urgence, 'normale'];
          return <button key={x.id} className={'kcarte ' + (sel === x.id ? 'sel ' : '') + (!x.clos && x.jours > 15 ? 'critique' : u[1])} onClick={() => setSel(x.id)}>
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="mono muted">#{x.numero} · {TYPE_INC[x.type] || x.type}</span><span className={'sev ' + u[1]}>{u[0]}</span></div>
            <div className="kcarte-titre">{x.titre}</div>
            <div className="muted">{x.adresse || 'Immeuble, pas de lot précis'}</div>
            <div className="grid2" style={{ marginTop: 6 }}><span className="muted">Locataire</span><span>{x.locataires || '—'}</span><span className="muted">Mandat</span><span>{x.mandat || '—'}</span></div>
            <div className="row" style={{ justifyContent: 'space-between', marginTop: 8 }}>
              <span style={{ fontSize: 12, color: x.prestataires || x.clos ? 'var(--ink2)' : 'var(--red)' }}>{x.prestataires ? x.prestataires + ' prestataire(s)' : x.clos ? 'Clos le ' + date(x.resolu_le) : 'Sans prestataire'}</span>
              <span className="mono" style={{ fontSize: 12 }}>{x.clos ? 'clos' : x.jours + ' j'}</span></div>
          </button>; })}
      </div>)}</div>
    </AvecDetail>
  </>;
}

// ----- Sorties et dépôts de garantie -----

function etapesDG(x) {
  const a = auj();
  return [
    ['Bail passé en sortie dans Rivage', x.statut === 'move_out', null],
    ['Fin du bail', x.parti, date(x.fin)],
    ['Restitution créée dans Rivage', x.restitution_creee, x.restitution_creee_le ? date(x.restitution_creee_le) : null],
    ['Restitution validée', x.validee, null],
    ['Dépôt remboursé', x.remboursee, null],
  ].map(([l, fait, info]) => ({ l, fait, info, retard: !fait && x.parti && a > x.limite_1_mois }));
}

function etatDG(x) {
  const a = auj();
  if (x.remboursee) return ['Restitué', 'normale'];
  if (!x.parti) return ['Préavis en cours', 'normale'];
  if (a > x.limite_2_mois) return ['Hors délai (2 mois)', 'critique'];
  if (a > x.limite_1_mois) return ['Délai 1 mois dépassé', 'haute'];
  return [x.validee ? 'Validé, à virer' : 'À préparer', 'normale'];
}

function SortiesDG() {
  const [d, err] = useCharge('pilotage_dg');
  const [filtre, setFiltre] = useState('tous');
  const [sel, setSel] = useState(null);
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const a = auj();
  const partis = d.filter((x) => x.parti && !x.remboursee);
  const tests = { tous: () => true, preavis: (x) => !x.parti, partis: (x) => x.parti && !x.remboursee, retard: (x) => x.parti && !x.remboursee && a > x.limite_1_mois };
  const vus = d.filter(tests[filtre]);
  const s = d.find((x) => x.bail_id === sel);
  const jours = (x) => Math.round((new Date(x.limite_1_mois) - new Date(a)) / 86400000);
  return <>
    <div className="entete"><div><h1>Congés et restitution des dépôts de garantie</h1>
      <p className="sub">Au {date(a)} · baux en sortie dans Rivage, suivis de la fin du bail jusqu’au remboursement du dépôt.</p></div></div>
    <Tuiles items={[[d.filter(tests.preavis).length, 'Préavis en cours'], [partis.length, 'Partis, DG non restitué', true],
      [d.filter(tests.retard).length, 'Au-delà d’un mois', true], [partis.filter((x) => !x.restitution_creee).length, 'Restitution non créée', true]]} />
    <Filtres val={filtre} set={setFiltre} items={[['tous', 'Tous', d.length], ['preavis', 'Préavis', d.filter(tests.preavis).length],
      ['partis', 'À restituer', partis.length], ['retard', 'En retard', d.filter(tests.retard).length]]} />
    <AvecDetail cle={sel} fermer={() => setSel(null)} vide="Clique sur un dossier pour voir le détail." detail={s && (() => {
      const e = etatDG(s); const aCharge = s.incidents.filter((i) => i.a_charge === 'tenant' && i.statut !== 'cancelled');
      return <>
        <div className="muted">Bail {s.reference} · <span className={'sev ' + e[1]}>{e[0]}</span></div>
        <h2>{s.locataires}</h2>
        <div className="muted">{s.adresse} ({s.lot}) · {s.mandat}</div>
        <ResumeIA type="dg" id={s.bail_id} />
        <div className="echeance"><div><b>{s.parti ? 'Restitution au plus tard' : 'Départ prévu'}</b>
          <div className="muted">{s.parti ? 'le ' + date(s.limite_1_mois) + ' si EDL conforme, le ' + date(s.limite_2_mois) + ' sinon' : 'fin du bail'}</div></div>
          <div className="echeance-n">{s.parti ? (jours(s) >= 0 ? 'J-' + jours(s) : 'J+' + -jours(s)) : date(s.fin)}</div></div>
        <AlertesLiees items={s.alertes} />
        {aCharge.length > 0 && <div className="mini-alerte haute"><b>À regarder avant restitution</b> · {aCharge.length} incident(s) à la charge du locataire :
          {aCharge.map((i) => <div key={i.numero}><a href={i.lien} target="_blank" rel="noreferrer">n°{i.numero} {i.titre}</a> · {ST_INC[i.statut] || i.statut} · estimé {euro(i.montant_estime)}</div>)}</div>}
        <h3>Étapes</h3>
        <ol className="etapes">{etapesDG(s).map((st) => <li key={st.l} className={st.fait ? 'fait' : st.retard ? 'retard' : ''}>
          <span className="puce">{st.fait ? '✓' : ''}</span><span>{st.l}{st.info ? <span className="muted"> · {st.info}</span> : null}</span></li>)}</ol>
        <Champs items={[['Dépôt', euro(s.depot)], ['Loyer HC', euro(s.loyer_hc)], ['Charges', euro(s.charges)], ['Impayé', euro(s.impaye)],
          ['Début du bail', date(s.debut)], ['Fin du bail', date(s.fin)], ['Pénalité si retard', euro(Math.round(s.loyer_hc * 10) / 100) + ' par mois commencé']]} />
        <Historique items={s.historique} libStatut={{ move_out: 'sortie', in_progress: 'en cours', created: 'créé', move_in: 'entrée' }} />
        <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={s.lien} target="_blank" rel="noreferrer">Ouvrir le bail dans Rivage</a></div>
      </>; })()}>
      <div className="grille-cartes">{vus.map((x) => { const e = etatDG(x); const et = etapesDG(x);
        return <button key={x.bail_id} className={'kcarte ' + (sel === x.bail_id ? 'sel ' : '') + e[1]} onClick={() => setSel(x.bail_id)}>
          <div className="row" style={{ justifyContent: 'space-between' }}><span className="mono muted">Bail {x.reference}</span><span className={'sev ' + e[1]}>{e[0]}</span></div>
          <div className="kcarte-titre">{x.locataires}</div>
          <div className="muted">{x.adresse}</div>
          <div className="grid2" style={{ marginTop: 6 }}><span className="muted">Mandat</span><span>{x.mandat || '—'}</span><span className="muted">Fin</span><span>{date(x.fin)}</span></div>
          <div className="barres" aria-label={`${et.filter((s) => s.fait).length} étapes sur ${et.length}`}>{et.map((s) => <span key={s.l} className={s.fait ? 'fait' : s.retard ? 'retard' : ''} />)}</div>
          <div className="row" style={{ justifyContent: 'space-between', fontSize: 12 }}><span>DG {euro(x.depot)}</span><span className="mono">{x.parti ? 'limite ' + date(x.limite_1_mois) : 'préavis'}</span></div>
          {(x.alertes.length > 0 || x.incidents.some((i) => i.a_charge === 'tenant')) && <div className="muted" style={{ color: 'var(--amber)', marginTop: 4 }}>
            {[x.alertes.length && x.alertes.length + ' contrôle(s) en alerte', x.incidents.filter((i) => i.a_charge === 'tenant').length && 'incident à la charge du locataire'].filter(Boolean).join(' · ')}</div>}
        </button>; })}</div>
      {!vus.length && <div className="card">Aucun dossier avec ce filtre.</div>}
    </AvecDetail>
    <p className="muted" style={{ marginTop: 16 }}>Délais : restitution sous 1 mois après la remise des clés si l’état des lieux de sortie est conforme à celui d’entrée, 2 mois sinon (loi du 6 juillet 1989, art. 22) ; au-delà, majoration de 10 % du loyer mensuel hors charges par mois de retard commencé. Rivage n’expose ni la date de remise des clés ni la conformité de l’EDL : le calcul part de la date de fin du bail.</p>
  </>;
}

// ----- Comptabilité -----

const EV_COMPTA = { tenant_payin: 'paiement du locataire', call_rent: 'appel de loyer', rent_received: 'loyer encaissé', call_refund_deposit: 'appel de restitution du DG' };

function Compta() {
  const [d, err] = useCharge('pilotage_compta');
  const [filtre, setFiltre] = useState('ecarts');
  const [sel, setSel] = useState(null);
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const tests = { ecarts: (x) => x.solde !== 0, imp: (x) => x.solde < 0, trop: (x) => x.solde > 0, nonrev: (x) => x.recu > 0 && !x.reverse_proprio, tous: () => true };
  const vus = d.periodes.filter(tests[filtre]);
  const s = d.periodes.find((x) => x.id === sel);
  const ok = d.periodes.filter((x) => x.solde === 0).length;
  return <>
    <div className="entete"><div><h1>Contrôle comptable</h1>
      <p className="sub">Loyers appelés et encaissés par période, d’après les écritures envoyées par Rivage depuis la mise en place.</p></div>
      <div className="row"><div className="tuile"><div className="muted">Périodes soldées</div><div className="tuile-n" style={{ color: 'var(--teal)' }}>{ok}</div></div>
        <div className="tuile"><div className="muted">Points à vérifier</div><div className="tuile-n" style={{ color: 'var(--red)' }}>{d.periodes.length - ok + d.impayes_baux.length}</div></div></div></div>
    <Filtres val={filtre} set={setFiltre} items={[['ecarts', 'Écarts', d.periodes.filter(tests.ecarts).length], ['imp', 'Impayés', d.periodes.filter(tests.imp).length],
      ['trop', 'Trop-perçus', d.periodes.filter(tests.trop).length], ['nonrev', 'Encaissés non reversés', d.periodes.filter(tests.nonrev).length], ['tous', 'Toutes', d.periodes.length]]} />
    <AvecDetail cle={sel} fermer={() => setSel(null)} vide="Clique sur une carte pour voir le détail du compte." detail={s && (() => {
      const cpt = d.comptes.filter((c) => c.bail_id === s.bail_id);
      return <>
        <div className="muted">Bail {s.reference} · période du {date(s.periode)} au {date(s.periode_fin)}</div>
        <h2>{s.locataires}</h2>
        <div className="muted">{s.adresse} ({s.lot}) · {s.mandat}</div>
        <ResumeIA type="compta" id={s.id} />
        <div className="echeance"><div><b>{s.solde < 0 ? 'Reste dû par le locataire' : s.solde > 0 ? 'Trop-perçu à régulariser' : 'Période soldée'}</b>
          <div className="muted">reçu − dû sur la période</div></div><div className="echeance-n" style={{ color: s.solde < 0 ? 'var(--red)' : s.solde > 0 ? 'var(--amber)' : 'var(--teal)' }}>{s.solde > 0 ? '+' : ''}{euro(s.solde)}</div></div>
        {s.solde > 0 && s.statut_bail === 'move_out' && s.appele < s.loyer_hc + s.charges &&
          <div className="mini-alerte haute">L’appel de la période ({euro(s.appele)}) est inférieur au loyer charges comprises ({euro(s.loyer_hc + s.charges)}) : appel au prorata de la sortie alors que le locataire a payé le mois entier. Le trop-perçu est à rembourser ou à imputer sur le solde de sortie.</div>}
        <AlertesLiees items={s.alertes} />
        <Champs items={[['Loyer HC + charges', euro(s.loyer_hc + s.charges)], ['Appelé', euro(s.appele)], ['Total dû', euro(s.du)], ['Reçu', euro(s.recu)], ['Reçu le', date(s.recu_le)],
          ['Report locataire', euro(s.report_locataire)], ['Reversé au propriétaire', euro(s.reverse_proprio)], ['Dernier virement', date(s.dernier_virement_proprio)],
          ['Report propriétaire', euro(s.report_proprio)], ['Opérations', s.evenements.map((e) => EV_COMPTA[e] || e).join(', ')],
          ['Documents', [s.avis_echeance && 'avis d’échéance', s.quittance && 'quittance', s.compte_rendu && 'compte rendu de gestion'].filter(Boolean).join(', ') || 'aucun généré']]} />
        {cpt.length > 0 && <><h3>Compte locataire</h3>{cpt.map((c, i) => <Champs key={i} items={[['Compte', c.compte + ' · ' + c.libelle], ['Débit', euro(c.debit)], ['Crédit', euro(c.credit)], ['Solde', euro(c.solde)]]} />)}</>}
        <Historique items={s.historique} />
        <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={s.lien} target="_blank" rel="noreferrer">Ouvrir le bail dans Rivage</a></div>
      </>; })()}>
      <div className="grille-cartes">{vus.map((x) => { const g = x.solde < 0 ? 'critique' : x.solde > 0 ? 'haute' : 'normale';
        return <button key={x.id} className={'kcarte ' + (sel === x.id ? 'sel ' : '') + g} onClick={() => setSel(x.id)}>
          <div className="row" style={{ justifyContent: 'space-between' }}><span className="mono muted">Bail {x.reference} · {new Date(x.periode).toLocaleDateString('fr-FR', { month: 'long', year: 'numeric' })}</span>
            <span className={'sev ' + g}>{x.solde < 0 ? 'Impayé' : x.solde > 0 ? 'Trop-perçu' : 'Soldé'}</span></div>
          <div className="kcarte-titre">{x.locataires}</div>
          <div className="muted">{x.adresse}</div>
          <div className="grid2" style={{ marginTop: 6 }}><span className="muted">Dû</span><span>{euro(x.du)}</span><span className="muted">Reçu</span><span>{euro(x.recu)}</span></div>
          <div className="row" style={{ justifyContent: 'space-between', marginTop: 8 }}><span style={{ fontSize: 12 }}>Reversé {euro(x.reverse_proprio)}</span>
            <b style={{ color: x.solde < 0 ? 'var(--red)' : x.solde > 0 ? 'var(--amber)' : 'var(--teal)' }}>{x.solde > 0 ? '+' : ''}{euro(x.solde)}</b></div>
        </button>; })}
        {d.impayes_baux.map((x) => <a key={x.bail_id} className="kcarte critique" href={x.lien} target="_blank" rel="noreferrer">
          <div className="row" style={{ justifyContent: 'space-between' }}><span className="mono muted">Bail {x.reference}</span><span className="sev critique">Impayé déclaré</span></div>
          <div className="kcarte-titre">{x.locataires}</div><div className="muted">{x.adresse}</div><b style={{ color: 'var(--red)' }}>{euro(x.impaye)}</b></a>)}
      </div>
      {!vus.length && !d.impayes_baux.length && <div className="card">Rien avec ce filtre.</div>}
    </AvecDetail>
    <p className="muted" style={{ marginTop: 16 }}>Seules les périodes dont Rivage a envoyé les écritures depuis la mise en place apparaissent ; pas d’historique antérieur. Les ordres de virement aux propriétaires ne sont pas encore suivis.</p>
  </>;
}

// ----- Toute l’agence -----

function Agence() {
  const [d, err] = useCharge('pilotage_agence');
  const [qui, setQui] = useState('Tous');
  const [dom, setDom] = useState('Tous');
  const [sel, setSel] = useState(null);
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const compte = (arr, k) => arr.reduce((m, x) => { m[x[k]] = (m[x[k]] || 0) + 1; return m; }, {});
  const parQui = compte(d, 'qui');
  const base = d.filter((x) => qui === 'Tous' || x.qui === qui);
  const parDom = compte(base, 'domaine');
  const vus = base.filter((x) => dom === 'Tous' || x.domaine === dom);
  const s = d.find((x) => x.id === sel);
  return <>
    <div className="entete"><div><h1>Toute l’agence</h1><p className="sub">Toutes les alertes ouvertes, quelle que soit la personne. {d.length} au total.</p></div></div>
    <Tuiles items={[[d.filter((x) => x.gravite === 'critique').length, 'Critiques', true], [d.filter((x) => x.gravite === 'haute').length, 'Hautes', true],
      [d.filter((x) => x.gravite === 'normale').length, 'Normales'], [parQui['Non attribué'] || 0, 'Sur des mandats non attribués', true]]} />
    <Filtres val={qui} set={(k) => { setQui(k); setDom('Tous'); }} items={[['Tous', 'Tout le monde', d.length], ...Object.keys(parQui).sort().map((k) => [k, k, parQui[k]])]} />
    <Filtres val={dom} set={setDom} items={[['Tous', 'Tous domaines', base.length], ...Object.keys(parDom).sort().map((k) => [k, k, parDom[k]])]} />
    <AvecDetail cle={sel} fermer={() => setSel(null)} vide="Clique sur une alerte pour voir le détail." detail={s && <>
      <div className="muted">{s.domaine} · {CAT[s.categorie] || s.categorie} · <span className={'sev ' + s.gravite}>{SEV[s.gravite]}</span></div>
      <h2>{s.libelle}</h2>
      <p><b>{s.titre}</b></p>
      <ResumeIA type="alerte" id={s.id} />
      {s.detail && <p>{s.detail}</p>}
      {s.explication && <div className="info">{s.explication}</div>}
      <Champs items={[['Mandat', s.mandat], ['Qui', s.qui], ['Détectée le', dateHeure(s.depuis)]]} />
      {s.lien && <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={s.lien} target="_blank" rel="noreferrer">Ouvrir dans Rivage</a></div>}
    </>}>
      <div className="grille-cartes">{vus.map((x) => <button key={x.id} className={'kcarte ' + (sel === x.id ? 'sel ' : '') + x.gravite} onClick={() => setSel(x.id)}>
        <div className="row" style={{ justifyContent: 'space-between' }}><span className="mono muted">{x.domaine}</span><span className={'sev ' + x.gravite}>{SEV[x.gravite]}</span></div>
        <div className="kcarte-titre">{x.libelle}</div>
        <div className="muted">{x.titre}</div>
        <div className="grid2" style={{ marginTop: 6 }}><span className="muted">Mandat</span><span>{x.mandat || '—'}</span><span className="muted">Qui</span><span>{x.qui}</span></div>
      </button>)}</div>
    </AvecDetail>
  </>;
}
