import { nature, Parties, Carte, texteRecherche, correspond, normaliser } from './cartes.jsx';
import React, { useEffect, useMemo, useState } from 'react';
import { supabase, rpc, ecouterRivage } from './supabase.js';
import { lireExportMonday } from './importMonday.js';
import SuiviBaux, { EditeurMail, NATURES, DossierBail } from './SuiviBaux.jsx';
import { preparer, MODELES } from './mails.js';
import DossierMandat, { NATURES_MANDAT } from './SuiviMandat.jsx';
import Commissions from './Commissions.jsx';
import MesDossiers, { RecapRemuneration } from './Circuit.jsx';
import ModelesMessages from './ModelesMessages.jsx';
import MessagesDossier, { MessagesAEnvoyer, etapesDesAlertes } from './MessagesDossier.jsx';
import Fiche from './Fiche.jsx';
import FicheConge from './FicheConge.jsx';
import ALouer from './ALouer.jsx';
import Reprise from './Reprise.jsx';
import ImpayesMois, { Extrait, ORGANISMES } from './ImpayesMois.jsx';

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

// Menu de navigation : rubriques regroupées, page courante gardée dans l'adresse (#regles) pour le retour arrière et le rechargement
const MENU = [
  ['Au quotidien', [['jour', 'Ma journée', '☀'], ['agence', 'Toute l’agence', '◉'], ['alouer', 'À louer', '⌂']]],
  ['Gestion', [['baux', 'Baux et obligations', '▤'], ['mandats', 'Mandats', '✎'], ['dg', 'Sorties et DG', '⇥'], ['sinistres', 'Sinistres', '⚠'], ['impayes', 'Impayés', '€'], ['compta', 'Comptabilité', '∑']]],
  ['Commercial', [['commissions', 'Commissions', '%'], ['reprise', 'Reprise', '↻']]],
  ['Réglages', [['messages', 'Modèles de messages', '✉'], ['obligations', 'Obligations suivies', '☑'], ['regles', 'Règles de relance', '⏱'], ['equipe', 'Équipe', '☺']]],
];
const lireHash = () => (typeof window !== 'undefined' ? window.location.hash.replace('#', '') : '') || 'jour';

function Espace() {
  const [moi, setMoi] = useState(undefined);
  const [onglet, setOngletEtat] = useState(lireHash);
  const [menuOuvert, setMenuOuvert] = useState(false);
  const [err, setErr] = useState('');
  const [tableaux, setTableaux] = useState([]);
  useEffect(() => {
    rpc('pilotage_moi').then(setMoi).catch((e) => setErr(e.message));
    rpc('pilotage_tableaux_visibles').then((t) => setTableaux(t || [])).catch(() => {});
    const surHash = () => setOngletEtat(lireHash());
    window.addEventListener('hashchange', surHash);
    return () => window.removeEventListener('hashchange', surHash);
  }, []);
  useEffect(() => {
    if (!menuOuvert) return undefined;
    const echap = (e) => { if (e.key === 'Escape') setMenuOuvert(false); };
    window.addEventListener('keydown', echap);
    document.body.style.overflow = 'hidden';
    return () => { window.removeEventListener('keydown', echap); document.body.style.overflow = ''; };
  }, [menuOuvert]);
  const setOnglet = (k) => { if (window.location.hash !== '#' + k) window.location.hash = k; setOngletEtat(k); setMenuOuvert(false); window.scrollTo(0, 0); };
  const voit = (t) => tableaux.includes(t);
  if (err) return <main><div className="banner">{err}</div></main>;
  if (moi === undefined) return <main><p className="sub">Chargement…</p></main>;
  if (moi === null) return (
    <main><div className="card"><h1>Accès non ouvert</h1><p className="sub">Votre compte existe mais n’a pas encore accès au pilotage. Demandez à Nicolas de vous ajouter dans l’onglet Équipe.</p>
      <button className="btn gris" onClick={() => supabase.auth.signOut()}>Se déconnecter</button></div></main>
  );
  const droit = { jour: true, agence: voit('agence'), sinistres: voit('sinistres'), dg: voit('dg'), compta: voit('compta'), impayes: voit('impayes'), alouer: true,
    mandats: moi.voit_commissions || ['gestionnaire', 'comptable'].includes(moi.role), baux: voit('baux'), commissions: moi.voit_commissions, reprise: moi.voit_equipe,
    obligations: moi.voit_reglages, regles: moi.voit_reglages, equipe: moi.voit_reglages, messages: true };
  const menu = MENU.map(([g, items]) => [g, items.filter(([k]) => droit[k])]).filter(([, items]) => items.length);
  const page = droit[onglet] ? onglet : 'jour';
  const titre = MENU.flatMap(([, items]) => items).find(([k]) => k === page)?.[1] || '';
  return (
    <div className="appli">
      <header className="barre-mobile">
        <button className="burger" aria-label="Ouvrir le menu" aria-expanded={menuOuvert} onClick={() => setMenuOuvert(true)}><span /><span /><span /></button>
        <img className="barre-logo" src="/logo-udi.png" alt="UDI" /><span className="barre-titre">{titre}</span>
      </header>
      {menuOuvert && <div className="voile" onClick={() => setMenuOuvert(false)} />}
      <aside className={'menu' + (menuOuvert ? ' ouvert' : '')} aria-label="Navigation">
        <div className="menu-tete">
          <span className="menu-marque"><span className="menu-logo"><img src="/logo-udi.png" alt="UDI, l’immobilier sécurisé" /></span><span className="brand">Pilotage<br />UDI Gestion</span></span>
          <button className="menu-fermer" aria-label="Fermer le menu" onClick={() => setMenuOuvert(false)}>×</button>
        </div>
        <nav className="menu-liste">
          {menu.map(([g, items]) => <div key={g} className="menu-groupe">
            <div className="menu-groupe-titre">{g}</div>
            {items.map(([k, l, ic]) => <button key={k} className={'menu-item' + (page === k ? ' on' : '')} aria-current={page === k ? 'page' : undefined} onClick={() => setOnglet(k)}>
              <span className="menu-ic" aria-hidden="true">{ic}</span>{l}</button>)}
          </div>)}
        </nav>
        <div className="menu-pied">
          <div><strong>{moi.prenom}</strong><div className="menu-role">{ROLES[moi.role]}</div></div>
          <button onClick={() => supabase.auth.signOut()}>Déconnexion</button>
        </div>
      </aside>
      <main>
        <Synchro direction={moi.role === 'direction'} />
        {page === 'jour' && <Journee moi={moi} />}
        {page === 'agence' && <Agence />}
        {page === 'sinistres' && <Sinistres />}
        {page === 'dg' && <SortiesDG />}
        {page === 'compta' && <Compta />}
        {page === 'impayes' && <Impayes />}
        {page === 'alouer' && <ALouer />}
        {page === 'reprise' && <Reprise moi={moi} />}
        {page === 'baux' && <SuiviBaux moi={moi} />}
        {page === 'mandats' && <Mandats />}
        {page === 'commissions' && <Commissions />}
        {page === 'obligations' && <Obligations />}
        {page === 'regles' && <Regles />}
        {page === 'equipe' && <Equipe moi={moi} />}
        {page === 'messages' && <ModelesMessages />}
      </main>
    </div>
  );
}

function Journee({ moi }) {
  const [membres, setMembres] = useState([]);
  const [cible, setCible] = useState(moi.user_id);
  const [alertes, setAlertes] = useState(null);
  const [cat, setCat] = useState('toutes');
  const [type, setType] = useState('tous'); // 102 : filtre par type d'alerte (règle), ex. « Facture fournisseur à traiter »
  const [ouvert, setOuvert] = useState(null);
  const [fiche, setFiche] = useState(null);
  const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_journee', { p_user: cible }).then(setAlertes).catch((e) => setErr(e.message));
  useEffect(() => { if (moi.voit_equipe) rpc('pilotage_membres').then(setMembres).catch(() => {}); }, []);
  useEffect(() => { setAlertes(null); charger(); }, [cible]);
  const traiter = async (a, oui) => { try { await rpc('pilotage_traiter', { p_alerte: a.id, p_traitee: oui }); setOuvert(null); charger(); } catch (e) { setErr(e.message); } };

  const ouvertes = (alertes || []).filter((a) => a.statut === 'ouverte');
  const traitees = (alertes || []).filter((a) => a.statut === 'traitee');
  const dansCat = ouvertes.filter((a) => cat === 'toutes' || a.categorie === cat);
  // Types d'alerte présents dans la catégorie choisie, du plus fréquent au moins fréquent
  const types = Object.values(dansCat.reduce((m, a) => { (m[a.regle] = m[a.regle] || { regle: a.regle, libelle: a.libelle || a.regle, n: 0 }).n += 1; return m; }, {}))
    .sort((x, y) => y.n - x.n || x.libelle.localeCompare(y.libelle));
  const typeActif = types.some((t) => t.regle === type) ? type : 'tous';
  const visibles = dansCat.filter((a) => typeActif === 'tous' || a.regle === typeActif);
  const dossiers = useMemo(() => {
    const m = new Map();
    visibles.forEach((a) => {
      const k = a.dossier?.type === 'bail' || a.dossier?.type === 'lot' ? a.dossier.type + a.dossier.ref : 'm' + (a.mandat_id || a.id);
      if (!m.has(k)) m.set(k, { cle: k, dossier: a.dossier, mandat: a.mandat, bailleur: a.bailleur, mandat_id: a.mandat_id, alertes: [] });
      m.get(k).alertes.push(a);
      if (a.objet_type === 'LeasingContract') m.get(k).bail_id = a.objet_id;
    });
    const rang = { critique: 0, haute: 1, normale: 2 };
    return [...m.values()].map((d) => ({ ...d, pire: d.alertes.reduce((p, a) => Math.min(p, rang[a.gravite]), 2) }))
      .sort((x, y) => x.pire - y.pire || y.alertes.length - x.alertes.length);
  }, [alertes, cat, typeActif]);
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
      {cible === moi.user_id && ['direction', 'superviseur', 'gestionnaire', 'comptable', 'negociateur'].includes(moi.role) && <MesDossiers moi={moi} />}
      {cible === moi.user_id && ['gestionnaire', 'negociateur'].includes(moi.role) && <MessagesAEnvoyer />}
      {cible === moi.user_id && moi.role === 'direction' && <RecapRemuneration />}
      {cible === moi.user_id && ['direction', 'superviseur'].includes(moi.role) && <Supervision voir={setCible} />}
      {['direction', 'superviseur'].includes(moi.role) && cible === moi.user_id && <div className="info">Ici, seulement les alertes réservées à la direction. Les autres vont à la gestionnaire ou à la comptable : cliquer sur un nom ci-dessus pour voir sa journée.</div>}
      <div className="row" style={{ marginBottom: 14 }}>
        {[['toutes', 'Toutes']].concat(Object.entries(CAT)).map(([k, l]) => (
          <button key={k} className={'chip' + (cat === k ? ' on' : '')} onClick={() => { setCat(k); setType('tous'); }}>{l}<span className="n">{k === 'toutes' ? ouvertes.length : ouvertes.filter((a) => a.categorie === k).length}</span></button>
        ))}
      </div>
      {types.length > 1 && <div className="row" role="group" aria-label="Type d’alerte" style={{ marginTop: -6, marginBottom: 14, gap: 6 }}>
        <span className="muted" style={{ fontSize: 12 }}>Type :</span>
        <button className={'chip' + (typeActif === 'tous' ? ' on' : '')} onClick={() => setType('tous')}>Tous<span className="n">{dansCat.length}</span></button>
        {types.map((t) => <button key={t.regle} className={'chip' + (typeActif === t.regle ? ' on' : '')} onClick={() => setType(t.regle)}>{t.libelle}<span className="n">{t.n}</span></button>)}
      </div>}
      {alertes === null ? <p className="sub">Chargement…</p> : dossiers.length === 0 ? <div className="card">Rien à traiter pour {nomCible}.</div> : (
        <div className="stack">
          {dossiers.map((d) => (
            <article key={d.cle} className={'card ' + gravNom[d.pire]}>
              <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <span className={'sev ' + gravNom[d.pire]}>{SEV[gravNom[d.pire]]}</span>
                  <h2 style={{ fontSize: 17, margin: '4px 0 2px' }}>{d.dossier?.type === 'bail' ? `Bail ${d.dossier.ref}` : d.dossier?.type === 'lot' ? `Lot ${d.dossier.ref}` : d.dossier?.type === 'organisme' ? `Impayés · ${ORGANISMES[d.dossier.ref] || d.dossier.ref}` : d.dossier?.type === 'invoice' ? 'Facture fournisseur' : d.mandat || 'Dossier'}{d.dossier?.adresse ? ` · ${d.dossier.adresse}` : ''}</h2>
                  <div className="grid2">
                    {d.bailleur && <><span>Bailleur</span><span>{d.bailleur}</span></>}
                    {d.dossier?.locataires && <><span>Locataire</span><span>{d.dossier.locataires}</span></>}
                    {d.mandat && <><span>Mandat</span><span>{d.mandat}</span></>}
                  </div>
                </div>
                <div className="row" style={{ gap: 6, justifyContent: 'flex-end' }}>
                  {(d.bail_id || d.mandat_id || d.dossier?.type === 'organisme') && <button className={'btn' + (fiche === d.cle ? ' plein' : '')} aria-expanded={fiche === d.cle}
                    onClick={() => setFiche(fiche === d.cle ? null : d.cle)}>{fiche === d.cle ? 'Fermer la fiche' : 'Ouvrir la fiche'}</button>}
                  {d.dossier?.lien && <a className="btn gris" href={d.dossier.lien} target="_blank" rel="noopener">Ouvrir dans Rivage</a>}
                </div>
              </div>
              <div className="stack" style={{ gap: 6, marginTop: 10 }}>
                {d.alertes.map((a) => (
                  <div key={a.id} className={'alerte ' + a.gravite}>
                    <button className="head" aria-expanded={ouvert === a.id} onClick={() => setOuvert(ouvert === a.id ? null : a.id)}>
                      <span className="row"><span className={'tag ' + a.categorie}>{CAT[a.categorie]}</span><strong style={{ fontSize: 14 }}>{a.titre}</strong></span>
                      <span className="muted">depuis le {date(a.depuis)}</span>
                    </button>
                    {/* 103 : facture fournisseur, à qui elle incombe et notes Rivage qui en parlent, visibles sans ouvrir l'alerte */}
                    {a.regle === 'facture_a_traiter' && a.detail?.includes('\n') && <div style={{ padding: '0 12px 8px', fontSize: 13, fontWeight: 600, color: 'var(--ink)' }}>{a.detail.split('\n')[0]}</div>}
                    {ouvert === a.id && (
                      <div className="detail">
                        {a.detail && <p style={{ margin: '0 0 6px' }}>{a.regle === 'facture_a_traiter' && a.detail.includes('\n') ? a.detail.split('\n').slice(1).join(' ') : a.detail}</p>}
                        {a.regle !== 'facture_a_traiter' && <p style={{ margin: '0 0 6px' }}><strong>Règle :</strong> {a.explication}</p>}
                        <div className="row">
                          {a.lien && <a className="btn" href={a.lien} target="_blank" rel="noopener">Voir dans Rivage</a>}
                          <button className="btn plein" onClick={() => traiter(a, true)}>Traité</button>
                        </div>
                        {MAILS_ALERTE[a.regle] && a.objet_id && <MailAlerte a={a} />}
                      </div>
                    )}
                  </div>
                ))}
              </div>
              {fiche === d.cle && <Fiche fermer={() => setFiche(null)}
                titre={(d.dossier?.type === 'bail' ? `Bail ${d.dossier.ref}` : d.dossier?.type === 'organisme' ? 'Impayés' : d.mandat || 'Dossier') + (d.dossier?.adresse ? ` · ${d.dossier.adresse}` : '')}>
                {d.dossier?.type === 'organisme' || d.alertes.some((a) => a.regle.startsWith('impaye_'))
                  ? <FicheImpayes organisme={d.dossier?.type === 'organisme' ? d.dossier.ref : null} bail={d.bail_id} apres={charger} />
                  : d.bail_id
                  ? <DossierBail b={{ bail_id: d.bail_id, reference: d.dossier?.ref, locataires: d.dossier?.locataires, adresse: d.dossier?.adresse, bailleur: d.bailleur, mandat: d.mandat }}
                      peut={['direction', 'superviseur', 'gestionnaire'].includes(moi.role)} moi={moi} apres={charger}
                      etapesMessages={etapesDesAlertes(d.alertes.map((a) => a.regle))} />
                  : <DossierMandat m={{ id: d.mandat_id }} apres={charger} etapesMessages={etapesDesAlertes(d.alertes.map((a) => a.regle))} />}
              </Fiche>}
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

// Mails proposés depuis une alerte de Ma journée (053) : brouillon Gmail à relire, rien n'est envoyé seul.
const MAILS_ALERTE = {
  colocataire_sorti: [['coloc_sortant', 'Mail aux colocataires'], ['coloc_bailleur', 'Mail au bailleur']],
  garant_sorti: [['garant_fin', 'Mail au bailleur']],
  loyer_modifie: [['revision_bailleur', 'Mail au bailleur']],
};
const dateTitre = (t) => { const x = (t || '').match(/(\d{2})\/(\d{2})\/(\d{4})/); return x ? `${x[3]}-${x[2]}-${x[1]}` : null; };

// Supervision (061) : charge de chaque membre de l'équipe, clic pour ouvrir sa journée
function Supervision({ voir }) {
  const [l, setL] = useState(null);
  useEffect(() => { rpc('pilotage_supervision').then(setL).catch(() => setL([])); }, []);
  if (!l || !l.length) return null;
  const ROLE = { gestionnaire: 'Gestion', comptable: 'Comptabilité', negociateur: 'Commercial' };
  return <section className="card" style={{ marginBottom: 16 }}>
    <h2 style={{ fontSize: 17, margin: '0 0 8px' }}>Supervision de l’équipe</h2>
    <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>{l.map((m) => <button key={m.user_id} className="tuile" style={{ cursor: 'pointer', textAlign: 'left', borderColor: m.critiques ? 'var(--red)' : undefined }} onClick={() => voir(m.user_id)}>
      <div className="muted">{ROLE[m.role] || m.role}</div>
      <div style={{ fontWeight: 700, fontSize: 16 }}>{m.prenom}</div>
      <div>{m.ouvertes} alerte{m.ouvertes > 1 ? 's' : ''}{m.critiques ? <span style={{ color: 'var(--red)', fontWeight: 700 }}> · {m.critiques} critique{m.critiques > 1 ? 's' : ''}</span> : ''}</div>
      {m.plus_ancienne && <div className="muted">la plus ancienne depuis le {date(m.plus_ancienne)}</div>}
    </button>)}</div>
  </section>;
}

function useMoiMail() {
  const [moi, setMoi] = useState({ prenom: '', email: '' });
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setMoi((m) => ({ ...m, email: data?.session?.user?.email || '' })));
    rpc('pilotage_moi').then((x) => setMoi((m) => ({ ...m, prenom: x?.prenom || '' }))).catch(() => {});
  }, []);
  return moi;
}

function MailAlerte({ a }) {
  const moi = useMoiMail();
  const [mail, setMail] = useState(null);
  const [err, setErr] = useState('');
  const ouvrir = async (code) => {
    setErr('');
    try {
      const c = await rpc('pilotage_contacts_bail', { p_bail: a.objet_id });
      const nom = a.regle === 'colocataire_sorti' ? ((a.titre || '').match(/colocataire : (.+) le \d{2}\//) || [])[1] : null;
      const revision = a.regle === 'loyer_modifie' ? await rpc('pilotage_loyer_changement', { p_bail: a.objet_id }) : null;
      const m = preparer(code, { bail: { adresse: c.adresse || a.dossier?.adresse }, contacts: c, moi,
        coloc: { nom, sortie: dateTitre(a.titre) }, garant: { fin: dateTitre(a.titre) }, revision });
      if (m) setMail({ m });
    } catch (e) { setErr(e.message); }
  };
  return <div style={{ marginTop: 8 }}>
    <div className="row">{MAILS_ALERTE[a.regle].map(([code, lib]) => <button key={code} className="btn" onClick={() => ouvrir(code)}>{lib}</button>)}</div>
    {err && <div className="err">{err}</div>}
    {mail && <EditeurMail mail={mail} email={moi.email} fermer={() => setMail(null)} marquer={() => setMail(null)} peut={false} />}
  </div>;
}

// ===== Mandats et commissions (direction, superviseur) =====

const COL_MANDAT = [['En cours', 'En cours · GO à donner'], ['Dossier complet validé', 'Dossier complet à louer'], ['Loué', 'Loué / retiré']];

function etapesMandat(m) {
  const ko = m.statut === 'Retiré sans location';
  return [
    ['Mandat signé', !!m.signe_le],
    ['Négociateur attribué', !!m.negociateur],
    ['GO dossier complet', !!m.go_le],
    ['Bien loué', !!m.bail, ko],
    ['Bail validé · loué par', !!(m.bail?.valide_le && m.bail?.loue_par)],
  ];
}

function Mandats() {
  const [d, setD] = useState(null);
  const [baux, setBaux] = useState([]);
  const [err, setErr] = useState('');
  const [vue, setVue] = useState('pipeline');
  const [sel, setSel] = useState(null);
  const [nego, setNego] = useState(null);
  const [anciens, setAnciens] = useState(false);
  const [cherche, setCherche] = useState('');
  // Sur mobile, colonnes « Dossier complet à louer » et « Loué / retiré » repliées au départ ; un toucher sur l'en-tête les ouvre
  const [replie, setReplie] = useState(() => (typeof window !== 'undefined' && window.innerWidth < 700 ? { 'Dossier complet validé': true, Loué: true } : {}));
  const [infos, setInfos] = useState({});
  const charger = () => { rpc('pilotage_infos_cartes').then((x) => setInfos(x?.mandats || {})).catch(() => {}); return Promise.all([rpc('pilotage_mandats'), rpc('pilotage_baux_a_valider')]).then(([m, b]) => { setD(m); setBaux(b || []); }).catch((e) => setErr(e.message)); };
  useEffect(() => { charger(); }, []);
  if (err && !d) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const majMandat = async (id, champ, valeur) => { setErr(''); try { await rpc('pilotage_mandat_maj', { p_mandat: id, p_champ: champ, p_valeur: valeur ?? '' }); await charger(); } catch (e) { setErr(e.message); } };
  const majBail = async (id, champ, valeur) => { setErr(''); try { await rpc('pilotage_bail_maj', { p_bail: id, p_champ: champ, p_valeur: valeur ?? '' }); await charger(); } catch (e) { setErr(e.message); } };
  const facturer = async (mid, v, facture, montant) => { setErr(''); try { await rpc('pilotage_commission_facturer', { p_mandat: mid, p_versement: v, p_facture: facture, p_montant: montant }); await charger(); } catch (e) { setErr(e.message); } };
  const suivis = d.mandats.filter((m) => m.suivi_commission);
  // Par défaut on ne montre que les mandats rentrés depuis 2026 (ceux qui donnent lieu à commission)
  const q = normaliser(cherche);
  // Recherche sur tout : n°, bailleurs, négociateur, locataire, adresses et types des lots, téléphones, e-mails ; elle porte sur tous les mandats, 2026 ou non
  const mandats = q ? d.mandats.filter((m) => correspond(texteRecherche(m.reference, m.nom, m.bailleur, m.negociateur_prenom, m.bail?.locataires, m.bail?.reference,
      (infos[m.id]?.lots || []).map((l) => [l.adresse, nature(l.nature)]), infos[m.id]?.parties), q))
    : anciens ? d.mandats : suivis;
  const negos = d.negociateurs;
  const aValider = suivis.filter((m) => m.statut !== 'Retiré sans location' && (!m.go_le || !m.negociateur)).length + baux.filter((b) => !b.valide_le || !b.loue_par).length;
  const sansGo = mandats.filter((m) => m.bail && !m.go_le && m.suivi_commission);
  // Lignes de commission : versements mandat au négociateur du mandat, versement location à celui qui a loué
  const lignes = [];
  suivis.forEach((m) => (m.versements || []).forEach((v) => {
    const benef = v.cle === 'loc' ? v.beneficiaire : m.negociateur;
    if (!benef || v.montant == null) return;
    lignes.push({ m, v, benef, facture: m.factures?.[v.cle] });
  }));
  const parNego = negos.map((n) => ({ ...n, lignes: lignes.filter((l) => l.benef === n.user_id) })).filter((n) => n.lignes.length || n.role === 'negociateur');
  const s = d.mandats.find((m) => m.id === sel);
  return <>
    <div className="entete"><div><h1>Mandats</h1>
      <p className="sub">Avancement de chaque mandat, contrôle d’entrée et GO « dossier complet ». Les commissions des commerciaux sont dans l’onglet Commissions.</p></div></div>
    {err && <div className="banner">{err}</div>}
    {sansGo.length > 0 && <div className="banner">⚠ {sansGo.length} mandat{sansGo.length > 1 ? 's' : ''} loué{sansGo.length > 1 ? 's' : ''} sans GO : {sansGo.map((m) => 'n°' + m.reference).join(', ')}</div>}
    <Tuiles items={[[suivis.length, 'Mandats depuis 2026'], [suivis.filter((m) => !m.go_le && m.statut !== 'Retiré sans location').length, 'GO à donner', true],
      [suivis.filter((m) => m.statut === 'Loué').length, 'Loués'], [d.mandats.length, 'Mandats au total']]} />
    <div className="row" style={{ justifyContent: 'space-between', marginTop: 6, gap: 8, flexWrap: 'wrap' }}>
      <input className="recherche" placeholder="Rechercher : nom, adresse, téléphone, e-mail, n° de mandat" value={cherche} onChange={(e) => setCherche(e.target.value)} aria-label="Rechercher un mandat" />
      <label className="switch"><input type="checkbox" checked={anciens} onChange={(e) => setAnciens(e.target.checked)} /> Afficher aussi les mandats antérieurs à 2026 ({d.mandats.length - suivis.length})</label>
    </div>
    {q && <div className="muted" style={{ margin: '6px 0' }}>{mandats.length} mandat(s) trouvé(s) sur tous les mandats.</div>}
    <div style={{ height: 8 }} />
    {vue === 'pipeline' && s && <section className="panneau" style={{ marginTop: 8 }}>
      <button className="btn" onClick={() => setSel(null)}>← Retour au pipeline</button>
      <div style={{ maxWidth: 980, marginTop: 10 }}><FicheMandat m={s} negos={negos} role={d.mon_role} majMandat={majMandat} majBail={majBail} apres={charger} /></div>
    </section>}
    {vue === 'pipeline' && !s && <AvecDetail cle={sel} fermer={() => setSel(null)} vide="Clique sur un mandat pour voir le détail, ce qui manque, les versements et le contrôle d’entrée."
      detail={null}>
      <div className="kanban">{COL_MANDAT.map(([k, l]) => { const items = mandats.filter((m) => k === 'Loué' ? ['Loué', 'Retiré sans location'].includes(m.statut) : m.statut === k);
        const ferme = !!replie[k] && !q;
        return <div key={k} className="kcol"><button type="button" className="kcol-tete kcol-bouton" aria-expanded={!ferme} onClick={() => setReplie({ ...replie, [k]: !replie[k] })}>
            <b>{ferme ? '▸' : '▾'} {l}</b><span className="pastille">{items.length}</span></button>
          {!ferme && !items.length && <div className="muted" style={{ padding: '8px 4px' }}>Aucun.</div>}
          {!ferme && items.map((m) => { const et = etapesMandat(m); const alerte = m.suivi_commission && m.bail && !m.go_le;
            return <Carte key={m.id} className={'kcarte ' + (sel === m.id ? 'sel ' : '') + (alerte ? 'critique' : m.manques.length ? 'haute' : 'normale')} onClick={() => setSel(m.id)}>
              {alerte && <div className="carte-alerte">⚠ Loué sans GO</div>}
              <div className="row" style={{ justifyContent: 'space-between' }}><span className="mono muted">Mandat n°{m.reference}{m.nom ? ' · ' + m.nom : ''}</span>
                {!m.suivi_commission && <span className="muted" style={{ fontSize: 11 }}>avant 2026</span>}</div>
              <div className="kcarte-titre">{m.bailleur || '—'}</div>
              {(infos[m.id]?.lots || []).slice(0, 2).map((l, i) => <div key={i} className="muted" style={{ fontSize: 12 }}>{nature(l.nature)}{l.surface ? ` · ${l.surface} m²` : ''} · {l.adresse || 'adresse ?'}</div>)}
              {(infos[m.id]?.lots || []).length > 2 && <div className="muted" style={{ fontSize: 12 }}>+ {infos[m.id].lots.length - 2} autre(s) lot(s)</div>}
              <Parties titre="Bailleurs" liste={infos[m.id]?.parties?.bailleurs} />
              <div className="grid2" style={{ marginTop: 6 }}><span className="muted">Négo</span><span>{m.negociateur_prenom || <span style={{ color: 'var(--red)' }}>à attribuer</span>}</span>
                <span className="muted">Locataire</span><span>{m.bail?.locataires || 'pas encore loué'}</span>
                <span className="muted">Loyer</span><span>{m.loyer_reel != null ? euro(m.loyer_reel) + ' CC' : m.loyer_prev != null ? euro(m.loyer_prev) + ' prévu' : 'à saisir'}</span></div>
              <div className="barres">{et.map(([l2, ok, ko]) => <span key={l2} title={l2} className={ok ? 'fait' : ko ? 'retard' : ''} />)}</div>
              <div className="row" style={{ justifyContent: 'space-between', fontSize: 12 }}>
                <span className={m.manques.length ? '' : 'muted'} style={{ color: m.manques.length ? 'var(--amber)' : undefined }}>{m.manques.length ? m.manques.length + ' point(s) à compléter' : 'Complet'}</span>
              </div>
            </Carte>; })}
        </div>; })}</div>
    </AvecDetail>}

  </>;
}

function FicheMandat({ m, negos, role, majMandat, majBail, apres }) {
  const et = etapesMandat(m);
  return <>
    <div className="muted">Mandat n°{m.reference}{m.nom ? ' · ' + m.nom : ''} · {m.statut === 'Dossier complet validé' ? 'Dossier complet à louer' : m.statut}{m.apport_direction ? ' · apport direction' : ''}</div>
    <h2>{m.bailleur || 'Bailleur'}</h2>
    <div className="muted">Locataire : {m.bail?.locataires || 'pas encore loué'}</div>
    {m.suivi_commission && m.bail && !m.go_le && <div className="mini-alerte critique"><b>Anomalie : bien loué sans GO.</b> Le bail a été signé le {date(m.bail.signe_le || m.bail.debut)} alors que le dossier complet n’a pas été validé.</div>}
    <ResumeIA type="mandat" id={m.id} />
    <h3>Ce qui manque</h3>
    {m.manques.length ? <ul className="manques">{m.manques.map((x) => <li key={x}>{x}</li>)}</ul> : <p className="muted">Rien : dossier complet.</p>}
    <h3>Étapes</h3>
    <ol className="etapes">{et.map(([l, ok, ko]) => <li key={l} className={ok ? 'fait' : ko ? 'retard' : ''}><span className="puce">{ok ? '✓' : ''}</span><span>{l}</span></li>)}</ol>
    <Champs items={[['Négociateur', m.negociateur_prenom || 'à attribuer'], ['Mandat signé le', date(m.signe_le)], ['Début', date(m.debut)], ['Lots', String(m.lots)],
      ['Taux de gestion TTC', m.taux_ttc != null ? m.taux_ttc + ' %' : '—'], ['Loyer prévu', euro(m.loyer_prev)], ['Loyer réel', euro(m.loyer_reel)],
      ['GO', m.go_le ? date(m.go_le) + (m.go_par ? ' · ' + m.go_par : '') : 'non donné'],
      ['Bail', m.bail ? `${m.bail.reference} · ${date(m.bail.signe_le || m.bail.debut)} · ${euro(m.bail.loyer_cc)} CC` : '—']]} />
    {m.suivi_commission && <p className="muted" style={{ fontSize: 12 }}>Commissions de ce mandat : onglet Commissions.</p>}
    <div className="row" style={{ marginTop: 14, gap: 8 }}>
      <select value={m.negociateur || ''} onChange={(e) => majMandat(m.id, 'negociateur', e.target.value)}><option value="">Négociateur…</option>{negos.map((n) => <option key={n.user_id} value={n.user_id}>{n.prenom}</option>)}</select>
      {!m.go_le && m.statut !== 'Retiré sans location' && <button className="btn plein" onClick={() => majMandat(m.id, 'go', auj())}>Valider le dossier complet (GO)</button>}
      {!m.bail && m.statut !== 'Retiré sans location' && <button className="btn gris" onClick={() => majMandat(m.id, 'retire', auj())}>Retiré sans location</button>}
      {m.retire_le && <button className="btn gris" onClick={() => majMandat(m.id, 'retire', '')}>Annuler « retiré »</button>}
      <a className="btn" href={m.lien} target="_blank" rel="noreferrer">Propriétaire dans Rivage</a>
      {m.bail && <a className="btn" href={m.bail.lien} target="_blank" rel="noreferrer">Bail dans Rivage</a>}
    </div>
    {role === 'superviseur' && !m.go_le && <p className="muted">Romain : GO possible seulement si plus rien ne manque.</p>}
    <DossierMandat m={m} apres={apres} />
  </>;
}

function useReglages() {
  const [r, setR] = useState(null); const [err, setErr] = useState('');
  const charger = () => rpc('pilotage_reglages').then(setR).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  return [r, err, charger, setErr];
}

const STL = { auto: 'Automatisable', partiel: 'Rivage + saisie', saisie: 'À saisir', humain: 'Contrôle humain', regles: 'Règles à remplir' };
const CHAMPS_OB = [['obligation', 'Obligation', true], ['domaine', 'Domaine'], ['moment', 'Moment'], ['types', 'Types de baux'], ['texte', 'Texte de référence', true],
  ['declencheur', 'Déclencheur', true], ['donnee', 'Donnée utilisée', true], ['alerte', 'Alerte', true], ['manque', 'Ce qui manque', true]];

function FicheObligation({ o, doms, fermer, apres, setErr }) {
  const [f, setF] = useState({ ...o });
  const maj = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const envoyer = async (supprimer) => {
    if (supprimer && !window.confirm('Supprimer cette obligation du référentiel ?')) return;
    try {
      await rpc('pilotage_obligation_enregistrer', { p_id: f.id ?? null, p_domaine: f.domaine || '', p_moment: f.moment || '', p_types: f.types || '', p_obligation: f.obligation || '',
        p_texte: f.texte || '', p_declencheur: f.declencheur || '', p_donnee: f.donnee || '', p_alerte: f.alerte || '', p_statut: f.statut || '', p_manque: f.manque || '', p_supprimer: !!supprimer });
      apres(); fermer();
    } catch (e) { setErr(e.message); }
  };
  return <div className="card" style={{ margin: '6px 0' }}>
    <datalist id="doms-ob">{doms.map((d) => <option key={d} value={d} />)}</datalist>
    {CHAMPS_OB.map(([k, l, long]) => <label key={k} style={{ display: 'block', marginBottom: 6 }}><span className="muted">{l}</span><br />
      {long ? <textarea rows={k === 'obligation' ? 2 : 3} style={{ width: '100%' }} value={f[k] || ''} onChange={maj(k)} />
        : <input style={{ width: '100%' }} list={k === 'domaine' ? 'doms-ob' : undefined} value={f[k] || ''} onChange={maj(k)} />}</label>)}
    <label style={{ display: 'block', marginBottom: 8 }}><span className="muted">Statut</span><br />
      <select value={f.statut || ''} onChange={maj('statut')}><option value="">—</option>{Object.entries(STL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
    <div className="row"><button className="btn plein" onClick={() => envoyer(false)}>Enregistrer</button><button className="btn gris" onClick={fermer}>Annuler</button>
      {f.id != null && <button className="btn gris" style={{ marginLeft: 'auto' }} onClick={() => envoyer(true)}>Supprimer</button>}</div>
  </div>;
}

function Obligations() {
  const [r, err, charger, setErr] = useReglages();
  const [dom, setDom] = useState('Toutes'); const [st, setSt] = useState('tous'); const [q, setQ] = useState('');
  const [edit, setEdit] = useState(null);
  if (!r) return err ? <div className="banner">{err}</div> : <p className="sub">Chargement…</p>;
  const ob = r.obligations || [];
  const domsTous = [...new Set(ob.map((o) => o.domaine).filter(Boolean))];
  const doms = ['Toutes', ...domsTous];
  const qq = q.trim().toLowerCase();
  const rows = ob.filter((o) => (dom === 'Toutes' || o.domaine === dom) && (st === 'tous' || o.statut === st)
    && (!qq || [o.obligation, o.texte, o.declencheur, o.alerte, o.manque].some((x) => (x || '').toLowerCase().includes(qq))));
  return (
    <>
      <h1>Obligations suivies</h1>
      <p className="sub">{ob.length} obligations. Réservé à Nicolas. Cliquer sur une ligne pour la modifier.</p>
      {err && <div className="banner">{err}</div>}
      <div className="row" style={{ marginBottom: 8 }}>{doms.map((d) => <button key={d} className={'chip' + (dom === d ? ' on' : '')} onClick={() => setDom(d)}>{d}</button>)}</div>
      <div className="row" style={{ marginBottom: 8 }}>{[['tous', 'Tous']].concat(Object.entries(STL)).map(([k, l]) => <button key={k} className={'chip' + (st === k ? ' on' : '')} onClick={() => setSt(k)}>{l}<span className="n">{k === 'tous' ? ob.length : ob.filter((o) => o.statut === k).length}</span></button>)}</div>
      <div className="row" style={{ marginBottom: 14 }}><input placeholder="Rechercher…" value={q} onChange={(e) => setQ(e.target.value)} style={{ minWidth: 240 }} />
        <button className="btn plein" onClick={() => setEdit({ id: null, domaine: dom === 'Toutes' ? '' : dom })}>+ Nouvelle obligation</button></div>
      {edit && edit.id == null && <FicheObligation o={edit} doms={domsTous} fermer={() => setEdit(null)} apres={charger} setErr={setErr} />}
      <div className="table-wrap"><table>
        <thead><tr><th>Obligation</th><th>Texte</th><th>Déclencheur</th><th>Alerte</th><th>Statut</th><th>Ce qui manque</th></tr></thead>
        <tbody>{rows.map((o) => edit && edit.id === o.id
          ? <tr key={o.id}><td colSpan={6}><FicheObligation o={o} doms={domsTous} fermer={() => setEdit(null)} apres={charger} setErr={setErr} /></td></tr>
          : <tr key={o.id} style={{ cursor: 'pointer' }} onClick={() => setEdit(o)}><td><strong>{o.obligation}</strong><div className="muted">{o.domaine} · {o.moment}{o.types ? ' · ' + o.types : ''}</div></td><td>{o.texte}</td><td>{o.declencheur}</td><td>{o.alerte}</td><td>{STL[o.statut] || o.statut}</td><td>{o.manque}</td></tr>)}</tbody>
      </table></div>
    </>
  );
}

const CANAUX = { mail_locataire: 'Mail au locataire', mail_bailleur: 'Mail au bailleur', sms: 'SMS (envoyé par l’agence)', sms_rivage: 'SMS (ancien : Rivage)', lrar: 'Recommandé', tache: 'Tâche' };
const NOM_NATURE = (n) => ({ ...NATURES_MANDAT, ...NATURES })[n] || n;
const delai = (j) => (j === 0 ? 'À l’échéance' : j < 0 ? `J${j}` : `J+${j}`);

function EtapeEditable({ e, nature, apres, setErr }) {
  const neuve = e.ordre == null;
  const [ouvert, setOuvert] = useState(neuve);
  const [f, setF] = useState({ jours: e.jours ?? 0, libelle: e.libelle || '', canal: e.canal || 'tache', modele: e.modele || '' });
  const envoyer = async (supprimer) => {
    if (supprimer && !window.confirm('Supprimer cette étape du calendrier ?')) return;
    try {
      await rpc('pilotage_calendrier_etape', { p_nature: nature, p_ordre: e.ordre ?? null, p_jours: Number(f.jours), p_libelle: f.libelle, p_canal: f.canal, p_modele: f.modele, p_supprimer: !!supprimer });
      setOuvert(false); apres();
    } catch (x) { setErr(x.message); }
  };
  if (!ouvert) return <tr style={{ cursor: 'pointer' }} onClick={() => setOuvert(true)}><td>{delai(e.jours)}</td><td>{CANAUX[e.canal] || e.canal}</td><td>{e.libelle}</td><td className="muted">{e.modele || '—'}</td></tr>;
  return <tr><td><input type="number" style={{ width: 70 }} value={f.jours} onChange={(x) => setF({ ...f, jours: x.target.value })} /><div className="muted" style={{ fontSize: 11 }}>négatif = avant</div></td>
    <td><select value={f.canal} onChange={(x) => setF({ ...f, canal: x.target.value })}>{Object.entries(CANAUX).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></td>
    <td><textarea rows={2} style={{ width: '100%' }} value={f.libelle} onChange={(x) => setF({ ...f, libelle: x.target.value })} /></td>
    <td><input list="modeles-mails" value={f.modele} onChange={(x) => setF({ ...f, modele: x.target.value })} placeholder="aucun" />
      <div className="row" style={{ marginTop: 4 }}><button className="btn plein" onClick={() => envoyer(false)}>Enregistrer</button>
        <button className="btn gris" onClick={() => (neuve ? apres() : setOuvert(false))}>Annuler</button>
        {!neuve && <button className="btn gris" onClick={() => envoyer(true)}>Supprimer</button>}</div></td></tr>;
}

// Calendriers rattachés aux règles « Suivi du bail » et « Suivi du mandat » : chaque nature de suivi et ses étapes
const NATURES_DE_REGLE = { bail_suivi: Object.keys(NATURES), bail_suivi_retard: [], mandat_suivi: Object.keys(NATURES_MANDAT), mandat_suivi_retard: [] };
function CalendriersRegle({ r, cle, charger, setErr }) {
  const [ajout, setAjout] = useState(null);
  const parNature = {};
  (r.calendriers || []).forEach((c) => { (parNature[c.nature] = parNature[c.nature] || []).push(c); });
  const natures = (NATURES_DE_REGLE[cle] || []).filter((n) => parNature[n]).sort((x, y) => NOM_NATURE(x).localeCompare(NOM_NATURE(y), 'fr'));
  if (!natures.length) return null;
  const apres = () => { setAjout(null); charger(); };
  return <div style={{ marginTop: 10 }}>
    <div className="muted" style={{ marginBottom: 4 }}>Rythme des relances de chaque suivi (délais comptés depuis l’échéance du suivi ; négatif = avant). Cliquer sur une étape pour la modifier.</div>
    <datalist id="modeles-mails">{MODELES.map((m) => <option key={m} value={m} />)}</datalist>
    {natures.map((n) => <details key={n} style={{ marginBottom: 6 }}>
      <summary style={{ cursor: 'pointer' }}><strong>{NOM_NATURE(n)}</strong> <span className="muted">· {parNature[n].map((e) => delai(e.jours)).join(', ')}</span>
        {NATURES[n] && NATURES_MANDAT[n] && <span className="muted"> · commun aux baux et aux mandats</span>}</summary>
      <div className="table-wrap" style={{ marginTop: 6 }}><table>
        <thead><tr><th>Délai</th><th>Canal</th><th>Étape</th><th>Modèle</th></tr></thead>
        <tbody>{parNature[n].map((e) => <EtapeEditable key={e.ordre + ':' + e.jours + ':' + e.libelle + ':' + e.canal} e={e} nature={n} apres={apres} setErr={setErr} />)}
          {ajout === n && <EtapeEditable e={{ ordre: null, jours: 0, canal: 'tache' }} nature={n} apres={apres} setErr={setErr} />}</tbody>
      </table></div>
      {ajout !== n && <button className="lien" onClick={() => setAjout(n)}>+ Ajouter une étape</button>}
    </details>)}
  </div>;
}

// Un délai d'une règle : modifié et enregistré tout de suite
function DelaiRegle({ cle, p, apres, setErr }) {
  const [v, setV] = useState(String(p.valeur));
  const [etat, setEtat] = useState('');
  const change = String(v) !== String(p.valeur);
  const enregistrer = async () => {
    try { await rpc('pilotage_regle_parametre', { p_cle: cle, p_nom: p.nom, p_valeur: Number(String(v).replace(',', '.')) }); setEtat('Enregistré'); apres(); }
    catch (e) { setErr(e.message); setEtat(''); }
  };
  return <div className="row" style={{ alignItems: 'center', marginBottom: 4 }}>
    <span style={{ flex: 1 }}>{p.libelle}</span>
    <input type="text" inputMode="decimal" style={{ width: 70, textAlign: 'right' }} value={v} onChange={(e) => { setV(e.target.value); setEtat(''); }} />
    <span className="muted" style={{ width: 90 }}>{p.unite}</span>
    {change ? <button className="btn plein" onClick={enregistrer}>Enregistrer</button> : <span className="muted" style={{ fontSize: 12, width: 80 }}>{etat}</span>}
  </div>;
}

function RegleEditable({ g, r, apres, setErr }) {
  const [ouvert, setOuvert] = useState(false);
  const [texte, setTexte] = useState(false);
  const [f, setF] = useState({ libelle: g.libelle, explication: g.explication || '', domaine: g.domaine || '', gravite: g.gravite });
  const envoyer = async (actif) => {
    try { await rpc('pilotage_regle_modifier', { p_cle: g.cle, p_libelle: f.libelle, p_explication: f.explication, p_domaine: f.domaine, p_gravite: f.gravite, p_actif: actif ?? g.actif }); setTexte(false); apres(); }
    catch (e) { setErr(e.message); }
  };
  const delais = g.parametres || [];
  const aCal = (NATURES_DE_REGLE[g.cle] || []).length > 0;
  const resume = delais.length ? delais.map((p) => `${p.valeur} ${p.unite === 'jour du mois' ? '(jour)' : p.unite}`).join(' · ') : aCal ? 'Rythmes des suivis' : 'Aucun délai réglable';
  return <>
    <tr style={{ cursor: 'pointer' }} onClick={() => setOuvert(!ouvert)}>
      <td><strong>{g.libelle}</strong><div className="muted">{g.explication}</div></td><td>{g.domaine}</td>
      <td><span className={'sev ' + g.gravite}>{SEV[g.gravite]}</span></td>
      <td><select value={g.destinataire || 'gestion'} onClick={(e) => e.stopPropagation()} aria-label="Destinataire des alertes"
        onChange={async (e) => { try { await rpc('pilotage_regle_destinataire', { p_cle: g.cle, p_destinataire: e.target.value }); apres(); } catch (x) { setErr(x.message); } }}>
        <option value="gestion">Gestion</option><option value="compta">Comptabilité</option><option value="direction">Direction</option><option value="commercial">Commercial du dossier</option></select></td>
      <td className="muted" style={{ fontSize: 12 }}>{resume}</td><td>{g.ouvertes}</td>
      <td><label className="switch" onClick={(e) => e.stopPropagation()}><input type="checkbox" checked={g.actif} onChange={() => envoyer(!g.actif)} /> {g.actif ? 'Oui' : 'Non'}</label></td></tr>
    {ouvert && <tr><td colSpan={7} style={{ background: 'var(--fond-2, rgba(0,0,0,0.03))' }}>
      {delais.length > 0 && <div style={{ marginBottom: 8 }}>
        <div className="muted" style={{ marginBottom: 4 }}>Délais de la règle (pris en compte au contrôle suivant, toutes les 30 minutes)</div>
        {delais.map((p) => <DelaiRegle key={p.nom + p.valeur} cle={g.cle} p={p} apres={apres} setErr={setErr} />)}
      </div>}
      {!delais.length && !aCal && <div className="muted" style={{ marginBottom: 8 }}>Cette règle n’a pas de délai réglable : elle se déclenche sur une incohérence ou sur un délai fixé par la loi.</div>}
      {aCal && <CalendriersRegle r={r} cle={g.cle} charger={apres} setErr={setErr} />}
      {!texte ? <button className="lien" style={{ marginTop: 6 }} onClick={() => setTexte(true)}>Modifier le libellé, l’explication, le domaine ou la gravité</button>
        : <div style={{ marginTop: 8 }}>
          <input style={{ width: '100%' }} value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} />
          <textarea rows={3} style={{ width: '100%', marginTop: 4 }} value={f.explication} onChange={(e) => setF({ ...f, explication: e.target.value })} />
          <div className="row" style={{ marginTop: 4 }}>
            <input value={f.domaine} onChange={(e) => setF({ ...f, domaine: e.target.value })} placeholder="Domaine" />
            <select value={f.gravite} onChange={(e) => setF({ ...f, gravite: e.target.value })}>{Object.entries(SEV).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
            <button className="btn plein" onClick={() => envoyer()}>Enregistrer</button><button className="btn gris" onClick={() => setTexte(false)}>Annuler</button></div>
        </div>}
    </td></tr>}
  </>;
}

function Regles() {
  const [r, err, charger, setErr] = useReglages();
  if (!r) return err ? <div className="banner">{err}</div> : <p className="sub">Chargement…</p>;
  return (
    <>
      <h1>Règles de relance</h1>
      <p className="sub">Contrôles exécutés automatiquement toutes les 30 minutes. Cliquer sur une règle pour régler ses délais et, pour les suivis de bail et de mandat, le rythme des relances. Les délais fixés par la loi (date limite d’un congé, restitution du dépôt de garantie…) ne sont pas modifiables. Une règle désactivée ne crée plus d’alerte.</p>
      {err && <div className="banner" onClick={() => setErr('')}>{err}</div>}
      <div className="table-wrap"><table>
        <thead><tr><th>Règle</th><th>Domaine</th><th>Gravité</th><th>Pour</th><th>Délais</th><th>Alertes ouvertes</th><th>Active</th></tr></thead>
        <tbody>{(r.regles || []).map((g) => <RegleEditable key={g.cle} g={g} r={r} apres={charger} setErr={setErr} />)}</tbody>
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

// types : types d'objets Rivage dont la modification déclenche une relecture (signal envoyé à chaque webhook, 050).
// Relecture aussi au retour sur l'onglet. Aucune lecture périodique, et la page ne lit que la base du pilotage, jamais l'API Rivage.
function useCharge(fn, types) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const relire = React.useRef(() => {});
  useEffect(() => {
    let t = null;
    const lire = () => rpc(fn).then((x) => { setD(x); setErr(''); }).catch((e) => setErr(e.message));
    relire.current = lire;
    lire();
    if (!types) return undefined;
    // plusieurs webhooks arrivent souvent à la suite : une seule relecture 1,5 s après le dernier
    const plusTard = () => { clearTimeout(t); t = setTimeout(() => { if (document.visibilityState === 'visible') lire(); }, 1500); };
    const fin = ecouterRivage((type) => { if (types.includes(type)) plusTard(); });
    const vu = () => { if (document.visibilityState === 'visible') lire(); };
    document.addEventListener('visibilitychange', vu);
    return () => { clearTimeout(t); fin(); document.removeEventListener('visibilitychange', vu); };
  }, []);
  return [d, err, () => relire.current()];
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
// Liste de cartes en pleine largeur ; le détail de la carte choisie s'ouvre en grand par-dessus (096, avant : colonne de droite)
function AvecDetail({ children, detail, fermer, vide, titre }) {
  return <>
    {vide && <p className="muted" style={{ margin: '0 0 8px', fontSize: 13 }}>{vide}</p>}
    {children}
    {detail && <Fiche titre={titre} fermer={fermer}>{detail}</Fiche>}
  </>;
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
      : <><p>{etat.texte}</p><div className="muted">Généré le {dateHeure(etat.genere_le)} à partir des seules données du dossier{type === 'impaye' ? ' et de ses échanges' : ''}. À vérifier avant toute décision.</div></>}
  </div>;
}

function Champs({ items }) {
  return <dl className="champs">{items.filter((x) => x).map(([k, v]) => <React.Fragment key={k}><dt>{k}</dt><dd>{v ?? '—'}</dd></React.Fragment>)}</dl>;
}

// Champs Rivage modifiés d'un envoi à l'autre (049)
const CHAMPS_RIVAGE = { status: 'statut', contractor_ids: 'prestataires', urgency: 'urgence', estimated_amount_in_cents: 'montant estimé',
  charged_to: 'prise en charge', title: 'titre', description: 'description', assignee_id: 'personne assignée', resolved_at: 'date de résolution',
  archived_at: 'archivage', incident_type: 'type', declared_at: 'date de déclaration', tenant_id: 'locataire', leasing_contract_id: 'bail',
  asset_id: 'lot', landlord_id: 'bailleur', asset_group_id: 'immeuble' };
function Historique({ items, libStatut }) {
  if (!items?.length) return null;
  return <><h3>Reçu de Rivage</h3><ol className="histo">{items.map((e, i) =>
    <li key={i}><span className="muted">{dateHeure(e.le)}</span><span>{EVT[e.evenement] || e.evenement}{e.statut ? ' · ' + (libStatut?.[e.statut] || e.statut) : ''}
      {Array.isArray(e.champs) && <span className="muted">{e.champs.length ? ' · ' + e.champs.map((c) => CHAMPS_RIVAGE[c] || c).join(', ')
        : ' · changement non transmis par Rivage (ex. statut d’un artisan)'}</span>}</span></li>)}</ol></>;
}

function AlertesLiees({ items }) {
  if (!items?.length) return null;
  return <><h3>Contrôles en alerte sur ce bail</h3>{items.map((a, i) =>
    <div key={i} className={'mini-alerte ' + a.gravite}><b>{SEV[a.gravite]}</b> · {a.libelle}<div className="muted">{a.detail}</div></div>)}</>;
}

// Texte d'une mise à jour avec liens cliquables ; les liens Gmail sont abrégés en « mail envoyé / reçu » (085)
const URL_RE = /(https?:\/\/[^\s<>"]+[^\s<>".,;:!?)\]])/g;
function libelleLien(u) {
  if (u.includes('mail.google.com')) return u.includes('#sent') ? '✉ mail envoyé' : u.includes('#inbox') ? '✉ mail reçu' : '✉ mail';
  if (u.includes('monday.com/protected_static')) return '📎 pièce jointe Monday';
  try { return new URL(u).hostname.replace(/^www\./, ''); } catch { return u; }
}
function TexteLiens({ texte }) {
  const morceaux = String(texte || '').split(URL_RE);
  return <>{morceaux.map((m, i) => (i % 2 ? <a key={i} href={m} target="_blank" rel="noreferrer" title={m} onClick={(e) => e.stopPropagation()}>{libelleLien(m)}</a> : m))}</>;
}

// Outil d'origine d'un dossier repris (081 Monday, 086 WeRoof)
const ORIGINE = (x) => (x?.origine === 'weroof' ? 'WeRoof' : 'Monday');

// Fil des mises à jour d'un sinistre : dossiers repris de Monday ou WeRoof (081, 086 ; clôture / réouverture) et incidents Rivage (084)
function SuiviSinistre({ dossier, recharger }) {
  const [notes, setNotes] = useState(null);
  const [texte, setTexte] = useState('');
  const [err, setErr] = useState('');
  const [tout, setTout] = useState(false);
  const monday = dossier.source === 'monday';
  const id = monday ? dossier.monday_id : dossier.id;
  const lire = () => rpc(monday ? 'pilotage_travaux_notes' : 'pilotage_sinistre_notes', monday ? { p_monday: id } : { p_incident: id })
    .then(setNotes).catch((e) => setErr(e.message));
  useEffect(() => { lire(); }, [id]);
  const agir = async (f) => { try { setErr(''); await f(); lire(); recharger(); } catch (e) { setErr(e.message); } };
  const envoyer = () => texte.trim() && agir(async () => {
    await rpc(monday ? 'pilotage_travaux_note' : 'pilotage_sinistre_note', monday ? { p_monday: id, p_contenu: texte } : { p_incident: id, p_contenu: texte }); setTexte(''); });
  if (!notes) return <p className="muted">Chargement des mises à jour…</p>;
  const racines = notes.filter((n) => !n.parent_id);
  const vues = tout ? racines : racines.slice(0, 3);
  const reponses = (n) => notes.filter((r) => r.parent_id === n.id).sort((a, b) => a.le.localeCompare(b.le));
  const an = (d) => (new Date(d).getFullYear() !== new Date().getFullYear() ? ' ' + new Date(d).getFullYear() : '');
  return <>
    <h3>Mises à jour ({notes.length})</h3>
    {err && <div className="err">{err}</div>}
    <div style={{ marginBottom: 10 }}><textarea className="saisie-note" rows="3" placeholder="Écrire une mise à jour…" value={texte} onChange={(e) => setTexte(e.target.value)} />
      <div className="row" style={{ marginTop: 6, gap: 8 }}><button className="btn plein" onClick={envoyer}>Publier</button>
        {monday && <button className="btn gris" onClick={() => agir(() => rpc('pilotage_travaux_clore', { p_monday: id, p_clos: !dossier.clos }))}>{dossier.clos ? 'Rouvrir le dossier' : 'Clore le dossier'}</button>}</div>
      {!monday && <div className="muted" style={{ marginTop: 4 }}>Commentaires internes au pilotage : le statut et les prestataires se gèrent dans Rivage.</div>}</div>
    {vues.map((n) => <div key={n.id} className="note">
      <div className="muted"><b>{n.auteur || '—'}</b> · {dateHeure(n.le)}{an(n.le)}{n.origine ? ' · ' + n.origine : n.monday ? ' · Monday' : ''}</div>
      <div className="note-texte"><TexteLiens texte={n.contenu} /></div>
      {n.tronque && <div className="muted">Message coupé à 2 000 caractères à la reprise : texte complet dans Monday.</div>}
      {reponses(n).map((r) => <div key={r.id} className="note reponse"><div className="muted"><b>{r.auteur || '—'}</b> · {dateHeure(r.le)}{an(r.le)}</div><div className="note-texte"><TexteLiens texte={r.contenu} /></div></div>)}
    </div>)}
    {racines.length > 3 && <button className="btn gris" style={{ marginTop: 8 }} onClick={() => setTout(!tout)}>{tout ? 'Ne garder que les 3 dernières' : `Voir les ${racines.length - 3} mises à jour plus anciennes`}</button>}
    {!notes.length && <p className="muted">Aucune mise à jour.</p>}
    {monday && <p className="muted" style={{ marginTop: 8 }}>Pièces jointes et photos restées dans {ORIGINE(dossier)}.</p>}
    {dossier.repris && <p className="muted" style={{ marginTop: 8 }}>Historique repris de {ORIGINE(dossier.repris)}{dossier.repris.reference ? ' (' + dossier.repris.reference + ')' : ''} :
      pièces jointes et photos restées dans {ORIGINE(dossier.repris)}{dossier.repris.lien ? <> · <a href={dossier.repris.lien} target="_blank" rel="noreferrer">ouvrir le dossier d'origine</a></> : ''}.</p>}
  </>;
}

// ----- Sinistres : colonnes par statut -----

const TYPE_INC = { plumbing: 'Plomberie', roofing: 'Toiture', painting: 'Peinture', electricity: 'Électricité', electrical: 'Électricité', heating: 'Chauffage', locksmith: 'Serrurerie', locksmithing: 'Serrurerie', other: 'Autre' };
const URG = { urgent: ['Urgent', 'critique'], high: ['Haute', 'haute'], normal: ['Normale', 'normale'], low: ['Basse', 'normale'] };
// Libellés de Rivage (liste des incidents : Nouveau, En cours, En attente)
const ST_INC = { open: 'Nouveau', in_progress: 'En cours', on_hold: 'En attente', closed: 'Clos', resolved: 'Résolu', cancelled: 'Annulé' };
const CHARGE = { tenant: 'Locataire', landlord: 'Propriétaire', agency: 'Agence' };

function Sinistres() {
  const [d, err, recharger] = useCharge('pilotage_sinistres', ['Incident', 'Profile', 'LeasingContract', 'Asset']);
  const [filtre, setFiltre] = useState('tous');
  const [statut, setStatut] = useState('tous');
  const [sel, setSel] = useState(null);
  const [cherche, setCherche] = useState('');
  // Colonne « Clos » repliée au départ (plus de 200 dossiers repris de Monday et WeRoof) ; un clic sur l'en-tête replie ou ouvre une colonne
  const [replie, setReplie] = useState({ clos: true });
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const ouverts = d.filter((x) => !x.clos);
  const q = normaliser(cherche);
  // Recherche sur tout : titre, adresse, lot, bail, locataires, bailleur, mandat, entreprises, téléphones, e-mails, bail Monday
  const trouve = (x) => !q || correspond(texteRecherche(x.titre, x.numero, x.adresse, x.lot, x.bail, x.locataires, x.bailleur, x.mandat,
    x.prestataires_noms, x.monday_bail, x.statut_monday, x.reference, x.description, x.parties, x.repris?.reference), q);
  // Colonne (et filtre) de statut d'un incident, avec les libellés de Rivage
  const colonneDe = (x) => (x.clos ? 'clos' : ['in_progress', 'on_hold'].includes(x.statut) ? x.statut : 'open');
  const STATUTS = [['open', 'Nouveau'], ['in_progress', 'En cours'], ['on_hold', 'En attente'], ['clos', 'Clos']];
  const aJour = ouverts.filter((x) => x.jours <= 15).length;
  const tests = {
    tous: () => true,
    urgents: (x) => x.urgence === 'urgent' || x.urgence === 'high',
    vieux: (x) => !x.clos && x.jours > 15,
    sans: (x) => !x.clos && !x.prestataires,
  };
  const vus = d.filter(tests[filtre]).filter((x) => statut === 'tous' || colonneDe(x) === statut).filter(trouve);
  const colonnes = STATUTS.filter(([k]) => statut === 'tous' || k === statut).map(([k, l]) => [k, l, vus.filter((x) => colonneDe(x) === k)]);
  const s = d.find((x) => x.id === sel);
  return <>
    <div className="entete">
      <div><h1>Sinistres et incidents techniques</h1><p className="sub">Au {date(auj())} · {d.filter((x) => x.source !== 'monday').length} incidents reçus de Rivage
        · {d.filter((x) => x.source === 'monday' && x.origine !== 'weroof').length} repris de Monday · {d.filter((x) => x.origine === 'weroof').length} repris de WeRoof
        · {d.filter((x) => x.repris).length} dossiers repris devenus incidents Rivage</p></div>
      <div className="objectif"><div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Objectif : aucun incident ouvert depuis plus de 15 jours</span><b>{aJour}/{ouverts.length}</b></div>
        <div className="jauge"><div style={{ width: (ouverts.length ? (aJour / ouverts.length) * 100 : 100) + '%' }} /></div></div>
    </div>
    <Tuiles items={[[ouverts.length, 'Ouverts'], [ouverts.filter(tests.urgents).length, 'Urgents ou prioritaires', true],
      [ouverts.filter((x) => x.jours > 15).length, 'Ouverts depuis plus de 15 j', true], [ouverts.filter((x) => !x.prestataires).length, 'Sans prestataire', true],
      [d.filter((x) => x.clos).length, 'Clos']]} />
    <Filtres val={filtre} set={setFiltre} items={[['tous', 'Tous', d.length], ['urgents', 'Urgents', d.filter(tests.urgents).length],
      ['vieux', '+ de 15 jours', d.filter(tests.vieux).length], ['sans', 'Sans prestataire', d.filter(tests.sans).length]]} />
    <Filtres val={statut} set={setStatut} items={[['tous', 'Tous les statuts', d.filter(tests[filtre]).length],
      ...STATUTS.map(([k, l]) => [k, l, d.filter(tests[filtre]).filter((x) => colonneDe(x) === k).length])]} />
    <input className="recherche" placeholder="Rechercher : titre, adresse, locataire, bailleur, entreprise, téléphone, e-mail, n° de bail" value={cherche}
      onChange={(e) => setCherche(e.target.value)} aria-label="Rechercher un sinistre" />
    {q && <div className="muted" style={{ margin: '6px 0' }}>{vus.length} dossier(s) trouvé(s) avec les filtres choisis.</div>}
    <div style={{ height: 8 }} />
    <AvecDetail cle={sel} fermer={() => setSel(null)} vide="Clique sur un incident pour voir le détail." detail={s && <>
      <div className="muted">{s.source === 'monday' ? `Repris de ${ORIGINE(s)}${s.reference ? ' · ' + s.reference : ''} · ${s.clos ? 'Clos' : 'En cours'}${s.statut_monday ? ' (' + ORIGINE(s) + ' : ' + s.statut_monday + ')' : ''}`
        : `Incident n°${s.numero} · ${ST_INC[s.statut] || s.statut}${s.repris ? ` · repris de ${ORIGINE(s.repris)}${s.repris.reference ? ' ' + s.repris.reference : ''} (ouvert le ${date(s.repris.ouvert_le)})` : ''}`}</div>
      <h2>{s.titre}</h2>
      {s.situation && <div className={'mini-alerte ' + s.situation.gravite}><b>Situation du bien : {s.situation.libelle}</b>
        <div>{s.situation.detail}{s.situation.bail ? ' Bail ' + s.situation.bail + '.' : ''}</div>
        {s.mandat_statut && <div className="muted">{s.mandat_statut}</div>}</div>}
      {(s.source !== 'monday' || !s.clos) && <ResumeIA key={s.id + ':' + (s.nb_notes || 0)} type="sinistre" id={s.id} />}
      {s.source === 'monday' && !s.bail && <div className="mini-alerte haute">{s.lot ? `Rattaché au lot seulement : pas de bail Rivage retrouvé pour le locataire du dossier ${ORIGINE(s)}.`
        : s.mandat ? 'Rattaché au mandat seulement : ni bail ni lot précis retrouvé dans Rivage.' : `Non rattaché : aucun bail, lot ou mandat Rivage retrouvé pour ce dossier ${ORIGINE(s)}.`}</div>}
      {s.description && <p style={{ whiteSpace: 'pre-line' }}>{s.description}</p>}
      <Champs items={[['Type', TYPE_INC[s.type] || s.type], ['Urgence', (URG[s.urgence] || [s.urgence])[0]], ['Lot', s.adresse ? `${s.adresse} (${s.lot})` : 'Immeuble, pas de lot précis'],
        ['Bailleur', s.bailleur], ['Locataire', s.locataires], ['Bail', s.bail], ['Mandat', s.mandat], ['Déclaré le', date(s.declare_le)],
        ['Ancienneté', s.jours + ' jours'], ['Résolu le', s.resolu_le ? date(s.resolu_le) : null], ['À la charge de', CHARGE[s.a_charge] || s.a_charge],
        ['Montant estimé', euro(s.montant_estime)], ['Prestataires', s.prestataires ? ((s.prestataires_noms || []).join(', ') || String(s.prestataires)) : 'Aucun désigné'],
        s.source === 'monday' && s.monday_bail && ['Bail dans Monday', s.monday_bail], s.source === 'monday' && ['Rattachement', s.rattachement],
        s.source === 'monday' && ['Gestionnaire (' + ORIGINE(s) + ')', s.gestionnaire]]} />
      <Parties titre="Entreprises" liste={s.parties?.entreprises} max={9} />
      <Parties titre="Locataires" liste={s.parties?.locataires} max={9} />
      <Parties titre="Bailleurs" liste={s.parties?.bailleurs} max={9} />
      {!s.clos && !s.prestataires && <div className="mini-alerte haute">{s.source === 'monday' ? 'Aucune entreprise renseignée sur le dossier.' : 'Aucun prestataire désigné dans Rivage.'}</div>}
      {!s.clos && s.jours > 15 && <div className="mini-alerte critique">Ouvert depuis plus de 15 jours.</div>}
      <Historique items={s.historique} libStatut={ST_INC} />
      <SuiviSinistre key={s.id} dossier={s} recharger={recharger} />
      {s.lien && <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={s.lien} target="_blank" rel="noreferrer">{s.source === 'monday' ? 'Ouvrir dans Monday' : 'Ouvrir dans Rivage'}</a></div>}
    </>}>
      <div className="kanban">{colonnes.map(([k, l, items]) => { const ferme = !!replie[k] && !q && statut !== k; return <div key={k} className="kcol">
        <button type="button" className="kcol-tete kcol-bouton" aria-expanded={!ferme} onClick={() => setReplie({ ...replie, [k]: !ferme })}>
          <b>{ferme ? '▸' : '▾'} {l}</b><span className="pastille">{items.length}</span></button>
        {!ferme && !items.length && <div className="muted" style={{ padding: '8px 4px' }}>Rien ici avec ce filtre.</div>}
        {!ferme && items.map((x) => { const u = URG[x.urgence] || [x.urgence, 'normale'];
          return <Carte key={x.id} className={'kcarte ' + (sel === x.id ? 'sel ' : '') + (!x.clos && x.jours > 15 ? 'critique' : u[1])} onClick={() => setSel(x.id)}>
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="mono muted">{(x.source === 'monday' ? ORIGINE(x) + (x.reference ? ' · ' + x.reference : '') : '#' + x.numero + ' · ' + (TYPE_INC[x.type] || x.type)) + (x.nb_notes ? ' · 💬 ' + x.nb_notes : '')}</span>
              <span className="row" style={{ gap: 4 }}><span className={'statut-inc ' + colonneDe(x)}>{x.clos ? (ST_INC[x.statut] || 'Clos') : x.statut_monday || ST_INC[x.statut] || x.statut}</span>{u[0] && <span className={'sev ' + u[1]}>{u[0]}</span>}</span></div>
            <div className="kcarte-titre">{x.titre}</div>
            <div className="muted">{x.adresse || 'Immeuble, pas de lot précis'}</div>
            {x.situation && <div style={{ marginTop: 6 }}><span className={'situ ' + x.situation.code + ' ' + x.situation.gravite}>{x.situation.libelle}</span>
              {x.mandat_statut && x.mandat_statut !== 'Mandat actif' && <span className="situ critique" style={{ marginLeft: 6 }}>{x.mandat_statut}</span>}</div>}
            <div className="grid2" style={{ marginTop: 6 }}><span className="muted">Bailleur</span><span>{x.bailleur || '—'}</span><span className="muted">Locataire</span><span>{x.locataires || '—'}</span><span className="muted">Mandat</span><span>{x.mandat || '—'}</span></div>
            <div className="row" style={{ justifyContent: 'space-between', marginTop: 8 }}>
              <span style={{ fontSize: 12, color: x.prestataires || x.clos ? 'var(--ink2)' : 'var(--red)' }}>{x.prestataires ? ((x.prestataires_noms || []).join(', ') || x.prestataires + ' prestataire(s)') : x.clos ? 'Clos le ' + date(x.resolu_le) : 'Sans prestataire'}</span>
              <span className="mono" style={{ fontSize: 12 }}>{x.clos ? 'clos' : x.jours + ' j'}</span></div>
            <Parties titre="Entreprises" liste={x.parties?.entreprises} />
            <Parties titre="Locataires" liste={x.parties?.locataires} />
            <Parties titre="Bailleurs" liste={x.parties?.bailleurs} max={1} />
          </Carte>; })}
      </div>; })}</div>
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
  const [d, err] = useCharge('pilotage_dg', ['LeasingContract', 'BailSituation', 'AccountingEventGroup', 'Incident']);
  const [filtre, setFiltre] = useState('tous');
  const [sel, setSel] = useState(null);
  const [cherche, setCherche] = useState('');
  const [rev, setRev] = useState(0);
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const a = auj();
  const partis = d.filter((x) => x.parti && !x.remboursee);
  const tests = { tous: () => true, preavis: (x) => !x.parti, partis: (x) => x.parti && !x.remboursee, retard: (x) => x.parti && !x.remboursee && a > x.limite_1_mois };
  // Recherche (096) : n° de bail, locataires, bailleur, adresse, lot, mandat, téléphones et e-mails ; elle porte sur tous les dossiers, quel que soit le filtre
  const q = normaliser(cherche);
  const vus = (q ? d : d.filter(tests[filtre])).filter((x) => !q || correspond(texteRecherche(x.reference, x.locataires, x.bailleur, x.adresse, x.lot, x.mandat, x.parties), q));
  const s = d.find((x) => x.bail_id === sel);
  const jours = (x) => Math.round((new Date(x.limite_1_mois) - new Date(a)) / 86400000);
  return <>
    <div className="entete"><div><h1>Congés et restitution des dépôts de garantie</h1>
      <p className="sub">Au {date(a)} · baux en sortie dans Rivage, suivis de la fin du bail jusqu’au remboursement du dépôt.</p></div></div>
    <Tuiles items={[[d.filter(tests.preavis).length, 'Préavis en cours'], [partis.length, 'Partis, DG non restitué', true],
      [d.filter(tests.retard).length, 'Au-delà d’un mois', true], [partis.filter((x) => !x.restitution_creee).length, 'Restitution non créée', true]]} />
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <Filtres val={filtre} set={setFiltre} items={[['tous', 'Tous', d.length], ['preavis', 'Préavis', d.filter(tests.preavis).length],
        ['partis', 'À restituer', partis.length], ['retard', 'En retard', d.filter(tests.retard).length]]} />
      <input className="recherche" placeholder="Rechercher : nom, adresse, téléphone, e-mail, n° de bail" value={cherche} onChange={(e) => setCherche(e.target.value)} aria-label="Rechercher un congé" />
    </div>
    {q && <div className="muted" style={{ margin: '6px 0' }}>{vus.length} dossier(s) trouvé(s) sur tous les congés.</div>}
    <AvecDetail cle={sel} fermer={() => setSel(null)} titre={s ? `Bail ${s.reference} · ${s.adresse || ''}` : ''} vide="Clique sur un dossier pour ouvrir sa fiche." detail={s && (() => {
      const e = etatDG(s); const aCharge = s.incidents.filter((i) => i.a_charge === 'tenant' && i.statut !== 'cancelled');
      return <>
        <div className="muted">Bail {s.reference} · <span className={'sev ' + e[1]}>{e[0]}</span></div>
        <h2>{s.locataires}</h2>
        <div className="muted">{s.adresse} ({s.lot}) · {s.mandat}</div>
        <div className="muted">Bailleur : {s.bailleur || '—'}</div>
        <Parties titre="Locataires" liste={s.parties?.locataires} max={9} />
        <Parties titre="Bailleurs" liste={s.parties?.bailleurs} max={9} />
        <ResumeIA type="dg" id={s.bail_id} />
        <div className="echeance"><div><b>{s.parti ? 'Restitution au plus tard' : 'Départ prévu'}</b>
          <div className="muted">{s.parti ? 'le ' + date(s.limite_1_mois) + ' si EDL conforme, le ' + date(s.limite_2_mois) + ' sinon' : 'fin du bail'}</div></div>
          <div className="echeance-n">{s.parti ? (jours(s) >= 0 ? 'J-' + jours(s) : 'J+' + -jours(s)) : date(s.fin)}</div></div>
        {s.situation && <div className="mini-alerte normale"><b>Situation lue dans Rivage</b> <span className="muted">(le {dateHeure(s.situation.lu_le)})</span>
          <div>{s.situation.edl_sortie ? 'État des lieux de sortie le ' + date(s.situation.edl_sortie) + ' : les délais de restitution partent de cette date.' : 'Pas d’état des lieux de sortie enregistré dans Rivage : délais calculés depuis la fin du bail.'}</div>
          {s.situation.trop_percu > 0 && <div><b>Trop-perçu du locataire : {euro(s.situation.trop_percu)}</b>, à lui rendre avec le dépôt.</div>}
          {s.situation.impaye > 0 && <div><b>Impayé du locataire : {euro(s.situation.impaye)}</b>, à retenir sur le dépôt avec justificatif.</div>}
          {s.situation.arriere_statut === 'open' && <div>Arriéré ouvert depuis le {date(s.situation.arriere_depuis)} ({s.situation.arriere_jours} jours).</div>}
          {s.situation.restitution_presente === false && <div>Aucune restitution du dépôt préparée dans Rivage.</div>}</div>}
        <AlertesLiees items={s.alertes} />
        {aCharge.length > 0 && <div className="mini-alerte haute"><b>À regarder avant restitution</b> · {aCharge.length} incident(s) à la charge du locataire :
          {aCharge.map((i) => <div key={i.numero}><a href={i.lien} target="_blank" rel="noreferrer">n°{i.numero} {i.titre}</a> · {ST_INC[i.statut] || i.statut} · estimé {euro(i.montant_estime)}</div>)}</div>}
        <SuiviReversement s={s} />
        {s.statut === 'move_out' && <>
          <FicheConge bail={s.bail_id} apres={() => setRev((n) => n + 1)} />
          <MessagesDossier key={s.bail_id + rev} objet="bail" id={s.bail_id} />
        </>}
        <h3>Étapes</h3>
        <ol className="etapes">{etapesDG(s).map((st) => <li key={st.l} className={st.fait ? 'fait' : st.retard ? 'retard' : ''}>
          <span className="puce">{st.fait ? '✓' : ''}</span><span>{st.l}{st.info ? <span className="muted"> · {st.info}</span> : null}</span></li>)}</ol>
        <Champs items={[['Dépôt', euro(s.depot)], ['Loyer HC', euro(s.loyer_hc)], ['Charges', euro(s.charges)], ['Impayé', euro(s.impaye)],
          ['Début du bail', date(s.debut)], ['Fin du bail', date(s.fin)], ['Pénalité si retard', euro(Math.round(s.loyer_hc * 10) / 100) + ' par mois commencé']]} />
        <Historique items={s.historique} libStatut={{ move_out: 'sortie', in_progress: 'en cours', created: 'créé', move_in: 'entrée' }} />
        <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={s.lien} target="_blank" rel="noreferrer">Ouvrir le bail dans Rivage</a></div>
      </>; })()}>
      <div className="grille-cartes">{vus.map((x) => { const e = etatDG(x); const et = etapesDG(x);
        return <Carte key={x.bail_id} className={'kcarte ' + (sel === x.bail_id ? 'sel ' : '') + e[1]} onClick={() => setSel(x.bail_id)}>
          <div className="row" style={{ justifyContent: 'space-between' }}><span className="mono muted">Bail {x.reference}</span><span className={'sev ' + e[1]}>{e[0]}</span></div>
          <div className="kcarte-titre">{x.locataires}</div>
          <div className="muted">{x.adresse}</div>
          <div className="grid2" style={{ marginTop: 6 }}><span className="muted">Bailleur</span><span>{x.bailleur || '—'}</span><span className="muted">Mandat</span><span>{x.mandat || '—'}</span><span className="muted">Fin</span><span>{date(x.fin)}</span></div>
          <div className="barres" aria-label={`${et.filter((s) => s.fait).length} étapes sur ${et.length}`}>{et.map((s) => <span key={s.l} className={s.fait ? 'fait' : s.retard ? 'retard' : ''} />)}</div>
          <div className="row" style={{ justifyContent: 'space-between', fontSize: 12 }}><span>DG {euro(x.depot)}</span><span className="mono">{x.parti ? 'limite ' + date(x.limite_1_mois) : 'préavis'}</span></div>
          {(x.alertes.length > 0 || x.incidents.some((i) => i.a_charge === 'tenant')) && <div className="muted" style={{ color: 'var(--amber)', marginTop: 4 }}>
            {[x.alertes.length && x.alertes.length + ' contrôle(s) en alerte', x.incidents.filter((i) => i.a_charge === 'tenant').length && 'incident à la charge du locataire'].filter(Boolean).join(' · ')}</div>}
          <Parties titre="Locataires" liste={x.parties?.locataires} />
          <Parties titre="Bailleurs" liste={x.parties?.bailleurs} max={1} />
        </Carte>; })}</div>
      {!vus.length && <div className="card">Aucun dossier avec ce filtre.</div>}
    </AvecDetail>
    <p className="muted" style={{ marginTop: 16 }}>Délais : restitution sous 1 mois après la remise des clés si l’état des lieux de sortie est conforme à celui d’entrée, 2 mois sinon (loi du 6 juillet 1989, art. 22) ; au-delà, majoration de 10 % du loyer mensuel hors charges par mois de retard commencé. Rivage n’expose ni la date de remise des clés ni la conformité de l’EDL : le calcul part de la date de fin du bail.</p>
  </>;
}

const plusMoisDG = (x, n) => { if (!x) return null; const t = new Date(x); t.setMonth(t.getMonth() + n); return t.toISOString().slice(0, 10); };

// Détenteur du dépôt, reversement du bailleur et mails (054). Rivage ne donne ni l'un ni l'autre : saisie de la gestion.
function SuiviReversement({ s }) {
  const moi = useMoiMail();
  const [suivi, setSuivi] = useState(s.suivi || {});
  const [mail, setMail] = useState(null);
  const [err, setErr] = useState('');
  const [iban, setIban] = useState(null);
  useEffect(() => { rpc('pilotage_iban_agence').then(setIban).catch(() => setIban(null)); }, []);
  useEffect(() => { setSuivi(s.suivi || {}); setMail(null); setErr(''); }, [s.bail_id]);
  const maj = async (champ, valeur) => {
    setErr('');
    try { await rpc('pilotage_dg_maj', { p_bail: s.bail_id, p_champ: champ, p_valeur: valeur ?? '' }); setSuivi((x) => ({ ...x, [champ]: valeur || null })); }
    catch (e) { setErr(e.message); }
  };
  // Départ : sortie réelle, sinon dernière sortie annoncée dans Rivage, sinon fin du bail (même règle que le 055)
  const sortie = s.sortie_reelle || (s.sortie_locataires?.tous_sortis ? s.sortie_locataires.derniere_sortie : null) || s.fin;
  const ouvrir = async (code, champ) => {
    setErr('');
    try {
      const c = await rpc('pilotage_contacts_bail', { p_bail: s.bail_id });
      const m = preparer(code, { bail: { adresse: c.adresse || s.adresse }, contacts: c, moi, iban,
        dg: { depot: s.depot, loyer_hc: s.loyer_hc, sortie, limite_1_mois: plusMoisDG(sortie, 1), limite_2_mois: plusMoisDG(sortie, 2), demande_le: suivi.demande_le } });
      if (m) setMail({ m, champ });
    } catch (e) { setErr(e.message); }
  };
  // Détenteur : saisie de la gestion, sinon champ deposit_retained_by du bail lu dans Rivage (055)
  const detenu = suivi.detenu_par || s.detenu_rivage || null;
  const bailleur = detenu === 'bailleur';
  // Dépôt chez le bailleur : demande de reversement dès le congé (bail en sortie dans Rivage ou sortie saisie pour tous les locataires)
  const conge = s.statut === 'move_out' || !!s.sortie_locataires?.tous_sortis;
  if (s.remboursee || !(s.parti || conge)) return null;
  return <div className="mini-alerte normale" style={{ margin: '10px 0' }}>
    <div className="row">
      <b>Dépôt détenu par</b>
      <select value={suivi.detenu_par || ''} onChange={(e) => maj('detenu_par', e.target.value)} aria-label="Détenteur du dépôt">
        <option value="">{s.detenu_rivage ? `Selon Rivage : ${s.detenu_rivage === 'bailleur' ? 'le bailleur' : 'l’agence'}` : 'À préciser'}</option>
        <option value="bailleur">le bailleur</option><option value="agence">l’agence</option></select>
      {s.detenu_rivage && suivi.detenu_par && suivi.detenu_par !== s.detenu_rivage && <span className="muted" style={{ color: 'var(--amber)' }}>différent de Rivage ({s.detenu_rivage === 'bailleur' ? 'bailleur' : 'agence'}) : corriger l’un ou l’autre</span>}
    </div>
    {bailleur && <div style={{ marginTop: 6 }}>
      <div className="muted">{suivi.recu_le ? `Reversement reçu le ${date(suivi.recu_le)} : restituer au locataire.` : suivi.demande_le ? `Reversement demandé le ${date(suivi.demande_le)}${suivi.relance_le ? `, relancé le ${date(suivi.relance_le)}` : ''}.` : 'Reversement à demander au bailleur.'}</div>
      {!suivi.recu_le && <div className="row" style={{ marginTop: 4 }}>
        <button className="btn" onClick={() => ouvrir(suivi.demande_le ? 'dg_reversement_relance' : 'dg_reversement_demande', suivi.demande_le ? 'relance_le' : 'demande_le')}>{suivi.demande_le ? 'Relancer le bailleur' : 'Demander le reversement au bailleur'}</button>
        <label className="muted">Reçu le <input type="date" onBlur={(e) => e.target.value && maj('recu_le', e.target.value)} /></label>
      </div>}
    </div>}
    {(detenu === 'agence' || suivi.recu_le) && <div className="row" style={{ marginTop: 6 }}>
      <button className="btn" onClick={() => ouvrir('dg_restitution', 'restitution_mail_le')}>Mail de restitution au locataire</button>
      {suivi.restitution_mail_le && <span className="muted">envoyé le {date(suivi.restitution_mail_le)}</span>}
    </div>}
    {err && <div className="err">{err}</div>}
    {mail && <EditeurMail mail={mail} email={moi.email} fermer={() => setMail(null)} peut
      marquer={async () => { await maj(mail.champ, auj()); setMail(null); }} />}
  </div>;
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
        <div className="muted">Bailleur : {s.bailleur || '—'}</div>
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
          <div className="grid2" style={{ marginTop: 6 }}><span className="muted">Bailleur</span><span>{x.bailleur || '—'}</span><span className="muted">Dû</span><span>{euro(x.du)}</span><span className="muted">Reçu</span><span>{euro(x.recu)}</span></div>
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
      <Champs items={[['Bailleur', s.bailleur], ['Mandat', s.mandat], ['Qui', s.qui], ['Détectée le', dateHeure(s.depuis)]]} />
      {s.lien && <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={s.lien} target="_blank" rel="noreferrer">Ouvrir dans Rivage</a></div>}
    </>}>
      <div className="grille-cartes">{vus.map((x) => <button key={x.id} className={'kcarte ' + (sel === x.id ? 'sel ' : '') + x.gravite} onClick={() => setSel(x.id)}>
        <div className="row" style={{ justifyContent: 'space-between' }}><span className="mono muted">{x.domaine}</span><span className={'sev ' + x.gravite}>{SEV[x.gravite]}</span></div>
        <div className="kcarte-titre">{x.libelle}</div>
        <div className="muted">{x.titre}</div>
        <div className="grid2" style={{ marginTop: 6 }}><span className="muted">Bailleur</span><span>{x.bailleur || '—'}</span><span className="muted">Mandat</span><span>{x.mandat || '—'}</span><span className="muted">Qui</span><span>{x.qui}</span></div>
      </button>)}</div>
    </AvecDetail>
  </>;
}


// ===== Mise à jour depuis Rivage =====

function Synchro({ direction }) {
  const [d, setD] = useState(null);
  const [encours, setEncours] = useState(false);
  const [msg, setMsg] = useState('');
  const lire = () => rpc('pilotage_derniere_sync').then(setD).catch(() => {});
  useEffect(() => { lire(); }, []);
  const lancer = async () => {
    setEncours(true); setMsg('');
    const { data, error } = await supabase.functions.invoke('pilotage-sync-rivage', { body: {} });
    if (error) {
      let texte = 'La mise à jour a échoué.';
      try { const j = await error.context.json(); if (j?.error) texte += ' ' + j.error; } catch { /* réponse illisible */ }
      setMsg(texte);
    } else setMsg('Mise à jour terminée : ' + Object.entries(data.compteurs || {}).map(([k, v]) => v + ' ' + k).join(', ') + '. Rechargez la page pour voir les données.');
    setEncours(false); lire();
  };
  return <div className="synchro">
    <span>{d ? <>Dernière mise à jour depuis Rivage : {dateHeure(d.fin || d.debut)}{d.erreur ? <span style={{ color: 'var(--red)' }}> · échec : {d.erreur}</span> : ''}</> : 'Mise à jour nocturne depuis Rivage : pas encore de passage.'} Les webhooks mettent à jour en continu.</span>
    {direction && <button className="lien" disabled={encours} onClick={lancer}>{encours ? 'Mise à jour en cours…' : 'Mettre à jour maintenant'}</button>}
    {msg && <span className="muted">{msg}</span>}
  </div>;
}

// ===== Suivi des impayés (repris du tableau Monday « UDI Gestion - Suivi IMPAYES ») =====

const GROUPES_IMP = [
  ['GLI ZELOK', 'Dossiers suivi impayés · GLI Zelok', '#579BFC'],
  ['TRANSFERT MILA', 'Transfert Mila · penser à envoyer les décomptes mensuels', '#037F4C'],
  ['SMARTGARANT', 'SmartGarant', '#FDAB3D'],
  ['HUISSIER', 'Huissier · commandement de payer', '#A25DDC'],
  ['AVOCAT', 'Dossier en cours chez l’avocat (procédure d’expulsion)', '#E2445C'],
  ['VISALE', 'Dossiers suivi impayés · garantie Visale', '#0086C0'],
  ['SANS GARANTIE', 'Sans garantie · relances amiables puis huissier', '#6B7280'],
  ['LIQUIDATION', 'Liquidation judiciaire', '#784BD1'],
  ['Clôturé', 'Dossier clôturé', '#9DA3AE'],
];
// Valeurs reprises telles qu'utilisées dans Monday
const LISTES_IMP = {
  notif_bailleur: ['Infos Impayé', 'Prise en charge', 'Régularisé'],
  garantie: ['GLI ZELOK', 'TRANSFERT MILA', 'CAUTION SMARTGARANT', 'CAUTION GARANTME', 'VISALE', 'CDT VIA HUISSIER', 'AVOCAT', 'PAS DE GARANTIE'],
  procedure: ['CDT DE PAYER', 'ASSIGNATION AVOCAT PAR MILA'],
  prise_en_charge: ['OUI', 'En cours', 'DECOMPTE MAJ OK', 'VOIE HUISSIER', 'LOC REGUL DETTE', 'NON REFUS', 'DOSSIER CLOS'],
  indemnisation_recue: ['OK RECUE', 'En cours', 'QUITTANCE SUBRO FINALE', 'LOC REGUL DETTE', 'ECHEANCIER EN COURS', 'Bloqué'],
  indemnite_versee_bailleur: ['OK FAIT', 'OUI AVEC LE DECOMPTE DU MOIS EN COURS', 'A REMBOURSER A ZELOK'],
  dette_remb_loc: ['OUI', 'PARTIEL', 'NON'],
  indemnisation_a_rembourser: ['OK FAIT', 'OK PARTIEL', 'En cours', 'REMBOURSEMENT DIRECT PAR LE LOCATAIRE A ZELOK'],
};
const CAUSES_IMP = ['IMPAYE LOYER', 'LOYER NON REGLE', 'REJET PRLVT', 'PAS DE REGLT', 'TEOM NON REGLEE', 'DEGRADATIONS', 'PREAVIS EN COURS', 'COMMANDEMENT DE PAYER'];
const COULEUR_VAL = {
  'OUI': 'ok', 'OK RECUE': 'ok', 'OK FAIT': 'ok', 'Prise en charge': 'ok', 'Régularisé': 'ok', 'DECOMPTE MAJ OK': 'ok', 'LOC REGUL DETTE': 'ok',
  'En cours': 'encours', 'PARTIEL': 'encours', 'OK PARTIEL': 'encours', 'ECHEANCIER EN COURS': 'encours',
  'Infos Impayé': 'info', 'QUITTANCE SUBRO FINALE': 'info', 'OUI AVEC LE DECOMPTE DU MOIS EN COURS': 'info', 'REMBOURSEMENT DIRECT PAR LE LOCATAIRE A ZELOK': 'info',
  'VOIE HUISSIER': 'violet', 'A REMBOURSER A ZELOK': 'rose', 'NON REFUS': 'ko', 'NON': 'ko', 'Bloqué': 'ko', 'DOSSIER CLOS': 'gris',
  'GLI ZELOK': 'rose', 'TRANSFERT MILA': 'vert', 'CAUTION SMARTGARANT': 'encours', 'CAUTION GARANTME': 'encours', 'VISALE': 'info', 'CDT VIA HUISSIER': 'violet', 'AVOCAT': 'ko', 'PAS DE GARANTIE': 'gris',
};
const civ = (c) => ({ mr: 'M.', mrs: 'Mme', other: '' }[c] ?? c ?? '');
const NATURE_LOT = { flat: 'Appartement', house: 'Maison', commercial: 'Local commercial', office: 'Bureaux', parking: 'Parking', box: 'Box', cellar: 'Cave' };

function Etiquette({ v }) { return v ? <span className={'etq ' + (COULEUR_VAL[v] || 'neutre')} title={v}>{v}</span> : <span className="muted">—</span>; }

// Noms et coordonnées : Rivage si le dossier est rattaché à un bail, sinon ceux saisis dans le dossier (repris de Monday)
function parties(x) {
  const r = x.rivage;
  const bailleur = r?.bailleurs?.length ? r.bailleurs.map((b) => b.nom).join(', ') : x.bailleur_nom;
  const locataire = r?.locataires?.length ? r.locataires.map((l) => l.nom).join(', ') : x.locataire_nom;
  return { bailleur, locataire, adresse: r?.adresse || x.adresse, titre: x.titre || [bailleur, locataire].filter(Boolean).join(' à ') };
}

function Impayes() {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [sel, setSel] = useState(null);
  const [ouverts, setOuverts] = useState({ 'Clôturé': false });
  const [recherche, setRecherche] = useState('');
  const [section, setSection] = useState('en_cours');
  const [moi, setMoi] = useState(null);
  const [vue, setVue] = useState(() => { try { return localStorage.getItem('vue-impayes') || 'cartes'; } catch { return 'cartes'; } });
  const changerVue = (v) => { setVue(v); try { localStorage.setItem('vue-impayes', v); } catch { /* stockage indisponible */ } };
  const charger = () => rpc('pilotage_impayes').then(setD).catch((e) => setErr(e.message));
  useEffect(() => { charger(); rpc('pilotage_moi').then(setMoi).catch(() => {}); }, []);
  if (err) return <div className="banner">{err}</div>;
  if (!d) return <p className="sub">Chargement…</p>;
  const ouvrir = async (bail) => { try { const id = await rpc('pilotage_impaye_ouvrir', { p_bail: bail, p_groupe: 'GLI ZELOK' }); await charger(); setSel(id); } catch (e) { setErr(e.message); } };
  const q = recherche.trim().toLowerCase();
  const filtre = (x) => !q || JSON.stringify([x.titre, x.bailleur_nom, x.locataire_nom, x.adresse, x.cause, x.observations, x.rivage?.locataires, x.rivage?.bailleurs, x.rivage?.adresse]).toLowerCase().includes(q);
  const dossiers = d.dossiers.filter(filtre);
  const s = d.dossiers.find((x) => x.id === sel);
  const actifs = d.dossiers.filter((x) => x.groupe !== 'Clôturé');
  const somme = (k) => actifs.reduce((t, x) => t + (Number(x[k]) || 0), 0);
  const groupesConnus = GROUPES_IMP.map((g) => g[0]);
  const autres = [...new Set(d.dossiers.map((x) => x.groupe).filter((g) => !groupesConnus.includes(g)))].map((g) => [g, g, '#666']);
  return <>
    <div className="entete"><div><h1>Suivi des impayés</h1>
      <p className="sub">Un dossier par impayé : garantie, prise en charge, procédure, indemnisation et remboursements, avec le fil des échanges.</p></div>
      <input className="recherche" placeholder="Rechercher un locataire, un bailleur, une adresse…" value={recherche} onChange={(e) => setRecherche(e.target.value)} /></div>
    <Tuiles items={[[actifs.length, 'Dossiers en cours'], [euro(somme('montant_impaye')), `Montant saisi · ${actifs.filter((x) => x.montant_impaye != null).length} dossier(s) sur ${actifs.length} renseigné(s)`],
      [actifs.filter((x) => !x.declaration_le).length, 'Sans date de déclaration', true],
      [actifs.filter((x) => x.audience_le && x.audience_le >= auj()).length, 'Audiences à venir'],
      [euro(somme('solde_a_rembourser_assureur')), 'Solde à rembourser à l’assureur']]} />
    <ImpayesMois peut={d.peut_saisir} apres={charger} />
    <div className="row" style={{ justifyContent: 'space-between', marginBottom: 12 }}>
      <div className="bascule">{[['cartes', 'Cartes'], ['tableau', 'Tableau']].map(([k, l]) => <button key={k} className={vue === k ? 'on' : ''} onClick={() => changerVue(k)}>{l}</button>)}</div>
      {moi?.role === 'direction' && <ImportMonday membres={d.membres} apres={charger} />}
    </div>
    <div className="filtres-imp">
      {[['en_cours', 'En cours', actifs.length], ...[...GROUPES_IMP, ...autres].map(([g, titre, c]) => [g, g === 'Clôturé' ? 'Clôturés' : (GROUPES_IMP.find((x) => x[0] === g) ? g : titre), d.dossiers.filter((x) => x.groupe === g).length, c]), ['tous', 'Tous', d.dossiers.length]]
        .filter(([k, , n]) => n > 0 || ['en_cours', 'tous'].includes(k))
        .map(([k, l, n, c]) => <button key={k} className={'chip' + (section === k ? ' on' : '')} style={c && section !== k ? { borderColor: c, color: c } : c ? { background: c, borderColor: c } : undefined} onClick={() => setSection(k)}>{l}<span className="n">{n}</span></button>)}
    </div>
    {d.peut_saisir && <Rapprochement apres={charger} />}
    {d.candidats.length > 0 && <div className="mini-alerte haute" style={{ marginBottom: 14 }}>
      <b>{d.candidats.length} bail{d.candidats.length > 1 ? 'x' : ''} en impayé dans Rivage sans dossier de suivi</b>
      <div className="muted">Un dossier s'ouvre tout seul chaque matin dès que Rivage ouvre un cycle d'impayé ; ici, les baux en dette sans cycle ouvert.</div>
      {d.candidats.map((c) => <div key={c.bail_id} className="row" style={{ justifyContent: 'space-between', marginTop: 6 }}>
        <span>{(c.locataires || []).map((l) => l.nom).join(', ')} · {c.adresse} · impayé {euro(c.impaye)}{c.assureur_gli ? ' · GLI ' + c.assureur_gli : ''}</span>
        {d.peut_saisir && <button className="btn" onClick={() => ouvrir(c.bail_id)}>Ouvrir un dossier</button>}</div>)}
    </div>}
    {d.dossiers.some((x) => x.ecart_garantie) && <details className="mini-alerte haute" style={{ marginBottom: 14 }}>
      <summary style={{ cursor: 'pointer' }}><b>{d.dossiers.filter((x) => x.ecart_garantie).length} dossier(s) dont la garantie ne concorde pas avec la GLI du bail dans Rivage</b>
        {' '}({d.dossiers.filter((x) => x.ecart_garantie && x.groupe !== 'Clôturé').length} en cours)</summary>
      {d.dossiers.filter((x) => x.ecart_garantie).map((x) => <div key={x.id} className="row" style={{ justifyContent: 'space-between', marginTop: 6 }}>
        <span>{parties(x).titre}{x.groupe === 'Clôturé' ? ' (clôturé)' : ''} · {x.ecart_garantie}</span>
        <button className="btn" onClick={() => setSel(x.id)}>Ouvrir</button></div>)}
    </details>}
    <AvecDetail cle={sel} fermer={() => setSel(null)} vide="Clique sur un dossier pour voir et modifier le suivi." detail={s && <DossierImpaye key={s.id} d={s} membres={d.membres} peut={d.peut_saisir} recharger={charger} />}>
      {[...GROUPES_IMP, ...autres].map(([g, titre, couleur]) => {
        if (section === 'en_cours' ? g === 'Clôturé' : section !== 'tous' && section !== g) return null;
        const items = dossiers.filter((x) => x.groupe === g);
        if (!items.length && (q || section !== 'tous')) return null;
        const ouvert = section === g ? true : (ouverts[g] ?? items.length > 0);
        return <section key={g} className="groupe-imp">
          <button className="groupe-tete" style={{ color: couleur }} onClick={() => setOuverts({ ...ouverts, [g]: !ouvert })}>
            {ouvert ? '▾' : '▸'} {titre} <span className="muted">{items.length} dossier{items.length > 1 ? 's' : ''}</span></button>
          {ouvert && vue === 'cartes' && <div className="grille-imp">
            {items.map((x) => <CarteImpaye key={x.id} x={x} couleur={couleur} sel={sel === x.id} choisir={() => setSel(x.id)} />)}
            {!items.length && <div className="muted" style={{ padding: 8 }}>Aucun dossier.</div>}</div>}
          {ouvert && vue === 'tableau' && <div className="table-wrap" style={{ borderLeft: '4px solid ' + couleur, borderRadius: 8 }}><table className="table-imp">
            <thead><tr><th>Dossier</th><th>Cause</th><th>Personne</th><th>Notif. bailleur</th><th>Déclaré le</th><th>Garantie</th><th>Prise en charge</th><th>Montant</th><th>Indemnisation</th><th>Indemnité bailleur</th><th>Procédure</th><th>Audience</th><th>Échanges</th></tr></thead>
            <tbody>{items.map((x) => { const p = parties(x);
              return <tr key={x.id} className={'clic' + (sel === x.id ? ' sel' : '')} onClick={() => setSel(x.id)}>
                <td><b>{p.titre}</b><div className="muted">{p.adresse || ''}{x.bail_id ? ' · lié à Rivage' : ''}</div></td>
                <td>{x.cause || '—'}</td>
                <td>{x.intervenants || x.responsable_prenom || '—'}</td>
                <td><Etiquette v={x.notif_bailleur} /></td>
                <td>{date(x.declaration_le)}</td>
                <td><Etiquette v={x.garantie} /></td>
                <td><Etiquette v={x.prise_en_charge} /></td>
                <td>{euro(x.montant_impaye)}</td>
                <td><Etiquette v={x.indemnisation_recue} /></td>
                <td><Etiquette v={x.indemnite_versee_bailleur} /></td>
                <td>{x.procedure || '—'}</td>
                <td>{date(x.audience_le)}</td>
                <td className="muted">{x.nb_notes ? `${x.nb_notes} · ${date(x.derniere_note)}` : '—'}</td>
              </tr>; })}
            {!items.length && <tr><td colSpan="13" className="muted">Aucun dossier.</td></tr>}</tbody></table></div>}
        </section>;
      })}
    </AvecDetail>
  </>;
}

function ImportMonday({ membres, apres }) {
  const [etat, setEtat] = useState(null);
  const [lu, setLu] = useState(null);
  const lire = async (e) => {
    const f = e.target.files?.[0]; if (!f) return;
    setEtat({ msg: 'Lecture du fichier…' });
    try { const r = await lireExportMonday(f, membres); setLu(r); setEtat(null); }
    catch (x) { setEtat({ err: 'Fichier illisible : ' + x.message }); }
    e.target.value = '';
  };
  const importer = async () => {
    setEtat({ msg: 'Import en cours…' });
    try {
      const r1 = await rpc('pilotage_import_monday', { p_items: lu.items, p_notes: [] });
      // Commentaires : messages puis réponses, par paquets
      const tri = [...lu.notes].sort((a, b) => (a.parent_post_id ? 1 : 0) - (b.parent_post_id ? 1 : 0) || a.le.localeCompare(b.le));
      let nc = 0;
      for (let i = 0; i < tri.length; i += 150) { const r = await rpc('pilotage_import_monday', { p_items: [], p_notes: tri.slice(i, i + 150) }); nc += r.commentaires; }
      setEtat({ ok: `${r1.dossiers} dossier(s) et ${nc} commentaire(s) importés. Les éléments déjà présents ont été ignorés.` });
      setLu(null); apres();
    } catch (x) { setEtat({ err: 'Import interrompu : ' + x.message }); }
  };
  return <div className="import-monday">
    <label className="btn gris">Importer un export Monday (.xlsx)<input type="file" accept=".xlsx" onChange={lire} hidden /></label>
    {lu && <span>{lu.items.length} dossiers, {lu.items.reduce((t, i) => t + i.actions.length, 0)} sous-éléments, {lu.notes.length} commentaires trouvés.
      <button className="btn plein" style={{ marginLeft: 8 }} onClick={importer}>Importer</button> <button className="lien" onClick={() => setLu(null)}>Annuler</button></span>}
    {etat?.msg && <span className="muted">{etat.msg}</span>}
    {etat?.ok && <span style={{ color: 'var(--teal)' }}>{etat.ok}</span>}
    {etat?.err && <span className="err">{etat.err}</span>}
  </div>;
}

function Commentaires({ id, peut, recharger }) {
  const [notes, setNotes] = useState(null);
  const [texte, setTexte] = useState('');
  const [err, setErr] = useState('');
  const [tout, setTout] = useState(false);
  const lire = () => rpc('pilotage_impaye_notes', { p_impaye: id }).then(setNotes).catch((e) => setErr(e.message));
  useEffect(() => { lire(); }, [id]);
  const envoyer = async () => { if (!texte.trim()) return; try { await rpc('pilotage_impaye_note', { p_impaye: id, p_contenu: texte }); setTexte(''); lire(); recharger(); } catch (e) { setErr(e.message); } };
  if (!notes) return <p className="muted">Chargement des échanges…</p>;
  const toutes = notes.filter((n) => !n.parent_id);
  const racines = tout ? toutes : toutes.slice(0, 3);
  const reponses = (n) => notes.filter((r) => r.parent_id === n.id).sort((a, b) => a.le.localeCompare(b.le));
  return <>
    <h3>Échanges ({notes.length}) <span className="muted" style={{ fontWeight: 400 }}>· les 3 derniers, le résumé IA en haut de la fiche couvre tout le fil</span></h3>
    {err && <div className="err">{err}</div>}
    {peut && <div style={{ marginBottom: 10 }}><textarea className="saisie-note" rows="3" placeholder="Écrire une mise à jour…" value={texte} onChange={(e) => setTexte(e.target.value)} />
      <button className="btn plein" onClick={envoyer} style={{ marginTop: 6 }}>Publier</button></div>}
    {racines.map((n) => <div key={n.id} className="note">
      <div className="muted"><b>{n.auteur || '—'}</b> · {dateHeure(n.le)} {new Date(n.le).getFullYear() !== new Date().getFullYear() ? new Date(n.le).getFullYear() : ''}{n.pieces_jointes ? ` · ${n.pieces_jointes} pièce(s) jointe(s) restée(s) dans Monday` : ''}</div>
      <div className="note-texte">{n.contenu}</div>
      {reponses(n).map((r) => <div key={r.id} className="note reponse"><div className="muted"><b>{r.auteur || '—'}</b> · {dateHeure(r.le)}</div><div className="note-texte">{r.contenu}</div></div>)}
    </div>)}
    {toutes.length > 3 && <button className="btn gris" style={{ marginTop: 8 }} onClick={() => setTout(!tout)}>{tout ? 'Ne garder que les 3 derniers' : `Voir les ${toutes.length - 3} échanges plus anciens`}</button>}
    {!notes.length && <p className="muted">Aucun échange.</p>}
  </>;
}

// Fiche des dossiers d'impayé ouverte depuis la journée : ceux d'un organisme (actualisation du mois) ou celui d'un bail
function FicheImpayes({ organisme, bail, apres }) {
  const [d, setD] = useState(null);
  const [mois, setMois] = useState(null);
  const [sel, setSel] = useState(null);
  const [extrait, setExtrait] = useState(null);
  const [err, setErr] = useState('');
  const charger = () => Promise.all([rpc('pilotage_impayes'), rpc('pilotage_impayes_mois')])
    .then(([a, b]) => { setD(a); setMois(b); }).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, [organisme, bail]);
  if (err) return <div className="banner">{err}</div>;
  if (!d || !mois) return <p className="muted">Chargement des dossiers…</p>;
  const actu = organisme ? mois.actualisations.find((a) => a.organisme === organisme) : null;
  const ids = actu ? actu.dossiers.map((x) => x.id) : [];
  const liste = d.dossiers.filter((x) => (organisme ? ids.includes(x.id) : x.bail_id === bail && x.groupe !== 'Clôturé'));
  const choisi = d.dossiers.find((x) => x.id === (sel ?? (liste.length === 1 ? liste[0].id : null)));
  const recharger = () => { charger(); apres && apres(); };
  const actualiser = async (fait) => { try { await rpc('pilotage_impayes_actualisation', { p_organisme: organisme, p_fait: fait, p_note: null }); recharger(); } catch (e) { setErr(e.message); } };
  return <div>
    <div className="row" style={{ justifyContent: 'space-between', marginBottom: 8, paddingRight: 32 }}>
      <h3 style={{ margin: 0 }}>{organisme ? `Dossiers ${ORGANISMES[organisme] || organisme} à actualiser` : 'Dossier d’impayé'}</h3>
      {actu && d.peut_saisir && (actu.fait_le
        ? <span className="muted">Actualisation faite le {date(actu.fait_le)} <button className="lien" onClick={() => actualiser(false)}>Rouvrir</button></span>
        : <button className="btn plein" onClick={() => actualiser(true)}>Actualisation faite pour tous</button>)}
    </div>
    {!liste.length && <p className="muted">{bail ? 'Aucun dossier d’impayé ouvert pour ce bail : à ouvrir depuis l’onglet Impayés.' : 'Aucun dossier à actualiser.'}</p>}
    {liste.length > 1 && <div className="stack" style={{ gap: 4, marginBottom: 10 }}>
      {liste.map((x) => { const p = parties(x);
        return <div key={x.id} className={'row ligne-imp' + (choisi?.id === x.id ? ' sel' : '')} style={{ justifyContent: 'space-between', borderBottom: '1px solid var(--line)', padding: '6px 0' }}>
          <span><b>{p.titre}</b>{p.adresse ? <span className="muted"> · {p.adresse}</span> : null}{x.montant_impaye != null ? ' · ' + euro(x.montant_impaye) : ''}</span>
          <span className="row" style={{ gap: 6 }}>
            {x.bail_id && <button className="btn gris" onClick={() => setExtrait(extrait === x.bail_id ? null : x.bail_id)}>Extrait de compte</button>}
            <button className={'btn' + (choisi?.id === x.id ? ' plein' : '')} onClick={() => setSel(choisi?.id === x.id ? -1 : x.id)}>{choisi?.id === x.id ? 'Fermer la fiche' : 'Ouvrir la fiche'}</button>
          </span></div>; })}
    </div>}
    {extrait && <Extrait bail={extrait} fermer={() => setExtrait(null)} />}
    {choisi && <div className="panneau" style={{ marginTop: 8 }}><DossierImpaye key={choisi.id} d={choisi} membres={d.membres} peut={d.peut_saisir} recharger={recharger} /></div>}
  </div>;
}

function DossierImpaye({ d, membres, peut, recharger }) {
  const [err, setErr] = useState('');
  const [extrait, setExtrait] = useState(false);
  const [action, setAction] = useState('');
  const [actionLe, setActionLe] = useState('');
  const r = d.rivage || null;
  const p = parties(d);
  const maj = async (champ, valeur) => { setErr(''); try { await rpc('pilotage_impaye_maj', { p_id: d.id, p_champ: champ, p_valeur: valeur ?? '' }); recharger(); } catch (e) { setErr(e.message); } };
  const champ = (cle, libelle, type = 'texte') => {
    const v = d[cle];
    let input;
    if (!peut) input = <span>{type === 'date' ? date(v) : type === 'montant' ? euro(v) : v || '—'}</span>;
    else if (LISTES_IMP[cle]) input = <select defaultValue={v || ''} onChange={(e) => maj(cle, e.target.value)}><option value="">—</option>{[...new Set([...LISTES_IMP[cle], ...(v ? [v] : [])])].map((o) => <option key={o}>{o}</option>)}</select>;
    else if (type === 'date') input = <input type="date" defaultValue={v || ''} onBlur={(e) => e.target.value !== (v || '') && maj(cle, e.target.value)} />;
    else if (type === 'montant') input = <input inputMode="decimal" defaultValue={v ?? ''} placeholder="0,00" onBlur={(e) => e.target.value !== String(v ?? '') && maj(cle, e.target.value)} />;
    else input = <input defaultValue={v || ''} list={cle === 'cause' ? 'causes-imp' : undefined} onBlur={(e) => e.target.value !== (v || '') && maj(cle, e.target.value)} />;
    return <label key={cle + d.maj_le} className="champ-imp"><span>{libelle}</span>{input}</label>;
  };
  const ajouterAction = async () => { if (!action.trim()) return; try { await rpc('pilotage_impaye_action', { p_impaye: d.id, p_libelle: action, p_le: actionLe || null }); setAction(''); setActionLe(''); recharger(); } catch (e) { setErr(e.message); } };
  const statutAction = async (a, st) => { try { await rpc('pilotage_impaye_action_statut', { p_action: a.id, p_statut: st }); recharger(); } catch (e) { setErr(e.message); } };
  return <>
    <datalist id="causes-imp">{CAUSES_IMP.map((c) => <option key={c} value={c} />)}</datalist>
    <div className="muted">{r ? `Bail ${r.reference} · ${r.mandat} · ` : d.monday_id ? 'Repris de Monday · ' : ''}dossier du {date(d.cree_le)}{d.maj_par ? ' · modifié par ' + d.maj_par + ' le ' + dateHeure(d.maj_le) : ''}</div>
    <h2>{p.titre}</h2>
    <div className="muted">{p.adresse}{r ? ` (${r.lot}) · ${NATURE_LOT[r.nature_lot] || r.nature_lot || ''}` : d.nature_bien ? ' · ' + d.nature_bien : ''}</div>
    {err && <div className="err">{err}</div>}
    <ResumeIA type="impaye" id={d.id} />
    <SuggestionsBail d={d} peut={peut} recharger={recharger} />
    <div className="row" style={{ margin: '6px 0' }}>
      {/* Organisme déduit de la garantie (089) : plus de double saisie */}
      <span className="etq">Organisme : {ORGANISMES[d.organisme] || (d.garantie ? d.garantie : 'garantie à renseigner')}</span>
      {d.ecart_garantie && <span className="mini-alerte haute" style={{ margin: 0 }}>Garantie à vérifier : {d.ecart_garantie}</span>}
      {d.cycle?.libelle && <span className="etq" title={d.cycle.jours != null ? `Ouvert depuis ${d.cycle.jours} jour(s)` : ''}>Rivage : {d.cycle.libelle}</span>}
      {d.bail_id && <button className="btn" onClick={() => setExtrait(!extrait)}>Extrait de compte</button>}
    </div>
    {extrait && d.bail_id && <Extrait bail={d.bail_id} fermer={() => setExtrait(false)} />}
    {r && <div className="echeance"><div><b>Impayé selon Rivage</b><div className="muted">loyer {euro((r.loyer_hc || 0) + (r.charges || 0))} CC · dernier encaissement {euro(r.dernier_encaissement_montant)} le {date(r.dernier_encaissement)}</div></div>
      <div className="echeance-n" style={{ color: r.impaye > 0 ? 'var(--red)' : 'var(--teal)' }}>{euro(r.impaye)}</div></div>}
    <h3>Contacts {r ? '(Rivage)' : ''}</h3>
    {r ? <Champs items={[...(r.bailleurs || []).map((b, i) => ['Bailleur' + ((r.bailleurs || []).length > 1 ? ' ' + (i + 1) : ''), [civ(b.civilite), b.nom].filter(Boolean).join(' ') + (b.email ? ' · ' + b.email : '') + (b.tel ? ' · ' + b.tel : '')]),
      ...(r.locataires || []).map((l, i) => ['Locataire' + ((r.locataires || []).length > 1 ? ' ' + (i + 1) : ''), [civ(l.civilite), l.nom].filter(Boolean).join(' ') + (l.tel ? ' · ' + l.tel : '') + (l.email ? ' · ' + l.email : '')]),
      ['Assureur GLI (Rivage)', r.assureur_gli || 'aucun indiqué'], ['Dépôt de garantie', euro(r.depot)]]} />
      : <div className="grille-champs">
        {champ('bailleur_civilite', 'Civilité bailleur')}{champ('bailleur_nom', 'Bailleur')}
        {champ('mail_bailleur_1', 'Mail bailleur 1')}{champ('mail_bailleur_2', 'Mail bailleur 2')}
        {champ('locataire_civilite', 'Civilité locataire')}{champ('locataire_nom', 'Locataire')}
        {champ('tel_locataire', 'Tél. locataire')}{champ('nature_bien', 'Nature du bien')}
        {champ('adresse', 'Adresse')}{champ('garantie_bail', 'Garantie inscrite au bail')}
      </div>}
    <h3>Suivi</h3>
    <div className="grille-champs">
      {peut ? <label className="champ-imp"><span>Section</span><select defaultValue={d.groupe} key={'g' + d.maj_le} onChange={(e) => maj('groupe', e.target.value)}>
        {[...GROUPES_IMP.map((g) => g[0]), ...(GROUPES_IMP.some((g) => g[0] === d.groupe) ? [] : [d.groupe])].map((g) => <option key={g} value={g}>{(GROUPES_IMP.find((x) => x[0] === g) || [g, g])[1]}</option>)}</select></label>
        : <label className="champ-imp"><span>Section</span><span>{d.groupe}</span></label>}
      {champ('cause', 'Cause du sinistre')}
      {champ('intervenants', 'Personnes (Monday)')}
      {peut ? <label className="champ-imp"><span>Responsable</span><select defaultValue={d.responsable || ''} key={'r' + d.maj_le} onChange={(e) => maj('responsable', e.target.value)}><option value="">—</option>{membres.map((m) => <option key={m.user_id} value={m.user_id}>{m.prenom}</option>)}</select></label>
        : <label className="champ-imp"><span>Responsable</span><span>{d.responsable_prenom || '—'}</span></label>}
      {champ('notif_bailleur', 'Notification bailleur')}
      {champ('declaration_le', 'Déclaré le', 'date')}
      {champ('garantie', 'Garantie (donne l’organisme)')}
      {champ('maj_assureur_le', 'MAJ dossier chez l’assureur', 'date')}
      {champ('prise_en_charge', 'Prise en charge')}
      {champ('montant_impaye', 'Montant de l’impayé', 'montant')}
      {champ('indemnisation_recue', 'Indemnisation reçue')}
      {champ('indemnite_versee_bailleur', 'Indemnité versée au bailleur')}
      {champ('dette_remb_loc', 'Dette remboursée par le locataire')}
      {champ('solde_a_rembourser_assureur', 'Solde à rembourser à l’assureur', 'montant')}
      {champ('indemnisation_a_rembourser', 'Indemnisation à rembourser à l’assureur')}
      {champ('procedure', 'Procédure')}
      {champ('commandement_le', 'Commandement de payer délivré le', 'date')}
      {champ('audience_le', 'Date de l’audience au tribunal', 'date')}
    </div>
    {peut ? <label className="champ-imp" style={{ marginTop: 8 }}><span>Observations</span><textarea rows="3" defaultValue={d.observations || ''} key={'o' + d.maj_le} onBlur={(e) => e.target.value !== (d.observations || '') && maj('observations', e.target.value)} /></label>
      : d.observations && <p>{d.observations}</p>}
    <h3>Sous-éléments / actions</h3>
    <ol className="histo">{d.actions.map((a) => <li key={a.id}><span className="muted">{date(a.le)}</span><span style={{ flex: 1 }}>{a.libelle}{a.par ? <span className="muted"> · {a.par}</span> : ''}</span>
      {peut ? <select value={a.statut} onChange={(e) => statutAction(a, e.target.value)}>{[...new Set(['À faire', 'En cours', 'Fait', a.statut])].map((o) => <option key={o}>{o}</option>)}</select> : <span>{a.statut}</span>}</li>)}
      {!d.actions.length && <li className="muted">Aucune action notée.</li>}</ol>
    {peut && <div className="form" style={{ marginTop: 8 }}>
      <label style={{ flex: 1 }}>Nouvelle action<input value={action} onChange={(e) => setAction(e.target.value)} placeholder="Ex. envoyer le décompte mensuel à l’assureur" /></label>
      <label>Pour le<input type="date" value={actionLe} onChange={(e) => setActionLe(e.target.value)} /></label>
      <button className="btn plein" onClick={ajouterAction}>Ajouter</button></div>}
    {r && <MailsImpaye d={d} r={r} p={p} />}
    {r && <div className="row" style={{ marginTop: 14 }}><a className="btn plein" href={r.lien} target="_blank" rel="noreferrer">Ouvrir le bail dans Rivage</a></div>}
    <Commentaires id={d.id} peut={peut} recharger={recharger} />
  </>;
}


// Mails au bailleur proposés depuis le dossier impayé (053) : déclaration à la GLI, dette régularisée
function MailsImpaye({ d, r, p }) {
  const moi = useMoiMail();
  const [mail, setMail] = useState(null);
  const nomComplet = (x) => [civ(x.civilite), x.nom].filter(Boolean).join(' ');
  const contacts = { bailleurs: (r.bailleurs || []).map((b) => ({ nom: nomComplet(b), email: b.email })), locataires: (r.locataires || []).map((l) => ({ nom: nomComplet(l), email: l.email })) };
  const ouvrir = (code) => {
    const m = preparer(code, { bail: { adresse: p.adresse }, contacts, moi, impaye: { declaration_le: d.declaration_le, organisme: ORGANISMES[d.organisme] || d.organisme } });
    if (m) setMail({ m });
  };
  const declare = !!d.declaration_le && d.organisme && d.organisme !== 'aucun';
  const solde = r.impaye != null && r.impaye <= 0;
  if (!declare && !solde) return null;
  return <div style={{ marginTop: 14 }}>
    <h3>Mails au bailleur</h3>
    <div className="row">
      {declare && <button className="btn" onClick={() => ouvrir('gli_declaree')}>Impayé déclaré à l’assurance</button>}
      {solde && <button className="btn" onClick={() => ouvrir('impaye_regularise')}>Dette régularisée</button>}
    </div>
    {mail && <EditeurMail mail={mail} email={moi.email} fermer={() => setMail(null)} marquer={() => setMail(null)} peut={false} />}
  </div>;
}

function CarteImpaye({ x, couleur, sel, choisir }) {
  const p = parties(x);
  const statuts = [['Garantie', x.garantie], ['Prise en charge', x.prise_en_charge], ['Indemnisation', x.indemnisation_recue], ['Indemnité bailleur', x.indemnite_versee_bailleur]];
  return <button className={'carte-imp' + (sel ? ' sel' : '')} style={{ borderLeftColor: couleur }} onClick={choisir}>
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start', gap: 6 }}>
      <span className="carte-imp-titre">{p.titre}</span>
      {x.montant_impaye != null && <span className="carte-imp-montant">{euro(x.montant_impaye)}</span>}
    </div>
    <div className="muted">{[p.adresse, x.cause].filter(Boolean).join(' · ') || '—'}</div>
    {x.ecart_garantie && <div style={{ color: 'var(--red)', fontSize: 12, marginTop: 4 }}>⚠ Garantie différente de Rivage</div>}
    <div className="carte-imp-statuts">{statuts.map(([l, v]) => <div key={l}><span className="muted">{l}</span><Etiquette v={v} /></div>)}</div>
    <div className="carte-imp-pied">
      <span>{x.intervenants || x.responsable_prenom || 'Personne'}</span>
      <span>{x.declaration_le ? 'Déclaré ' + date(x.declaration_le) : 'Non déclaré'}</span>
      {x.audience_le && <span className="carte-imp-audience">Audience {date(x.audience_le)}</span>}
      {x.procedure && <span>{x.procedure}</span>}
      <span>{x.nb_notes ? `💬 ${x.nb_notes} · ${date(x.derniere_note)}` : '💬 0'}</span>
      {x.bail_id ? <span className="lie">Rivage ✓</span> : null}
    </div>
  </button>;
}

// Rapprochement des dossiers non rattachés avec les baux Rivage (propositions à valider)
function Rapprochement({ apres }) {
  const [liste, setListe] = useState(null);
  const [ouvert, setOuvert] = useState(false);
  const lire = () => rpc('pilotage_impayes_rapprochement').then(setListe).catch(() => setListe([]));
  useEffect(() => { lire(); }, []);
  if (!liste || !liste.length) return null;
  const rattacher = async (id, bail) => { await rpc('pilotage_impaye_maj', { p_id: id, p_champ: 'bail_id', p_valeur: bail }); lire(); apres(); };
  const sures = liste.filter((x) => x.score >= 0.8);
  return <div className="mini-alerte" style={{ marginBottom: 14 }}>
    <div className="row" style={{ justifyContent: 'space-between' }}>
      <b>{liste.length} dossier{liste.length > 1 ? 's' : ''} correspond{liste.length > 1 ? 'ent' : ''} probablement à un bail Rivage</b>
      <span>{sures.length > 0 && <button className="btn" onClick={async () => { for (const x of sures) await rpc('pilotage_impaye_maj', { p_id: x.id, p_champ: 'bail_id', p_valeur: x.bail_id }); lire(); apres(); }}>Rattacher les {sures.length} sûrs (≥ 80 %)</button>}
        <button className="lien" onClick={() => setOuvert(!ouvert)}>{ouvert ? 'Masquer' : 'Voir les propositions'}</button></span>
    </div>
    {ouvert && liste.map((x) => <div key={x.id} className="row" style={{ justifyContent: 'space-between', marginTop: 6, gap: 8 }}>
      <span><b>{x.titre}</b> → bail {x.reference} · {x.bailleurs} à {x.locataires} · {x.adresse} <span className="muted">({Math.round(x.score * 100)} %)</span></span>
      <button className="btn" onClick={() => rattacher(x.id, x.bail_id)}>Rattacher</button></div>)}
  </div>;
}

function SuggestionsBail({ d, peut, recharger }) {
  const [sug, setSug] = useState(null);
  useEffect(() => { if (!d.bail_id) rpc('pilotage_impaye_suggestions', { p_impaye: d.id }).then(setSug).catch(() => setSug([])); }, [d.id, d.bail_id]);
  const maj = async (v) => { await rpc('pilotage_impaye_maj', { p_id: d.id, p_champ: 'bail_id', p_valeur: v }); recharger(); };
  if (d.bail_id) return peut ? <div className="muted" style={{ marginTop: 4 }}>Rattaché au bail Rivage {d.rivage?.reference} · <button className="lien" onClick={() => maj('')}>détacher</button></div> : null;
  return <div className="mini-alerte" style={{ marginTop: 10 }}>
    <b>Pas encore rattaché à un bail Rivage</b>
    {sug === null ? <div className="muted">Recherche…</div> : !sug.length ? <div className="muted">Aucun bail Rivage ressemblant (normal tant que vos baux réels ne sont pas dans Rivage).</div>
      : sug.map((x) => <div key={x.bail_id} className="row" style={{ justifyContent: 'space-between', marginTop: 6, gap: 8 }}>
        <span>Bail {x.reference} · {x.bailleurs} à {x.locataires} · {x.adresse} <span className="muted">({Math.round(x.score * 100)} %)</span></span>
        {peut && <button className="btn" onClick={() => maj(x.bail_id)}>Rattacher</button>}</div>)}
  </div>;
}

export { AvecDetail, ResumeIA, Tuiles, Filtres };
