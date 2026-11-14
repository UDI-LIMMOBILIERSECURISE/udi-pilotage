// Échanges par mail (145) : mails Gmail des boîtes branchées, rattachés à un lot / bail / ticket par la fonction pilotage-mails.
//  - EchangesLot : onglet de la fiche du bien, présenté comme une boîte Gmail (une ligne par conversation) ;
//  - EchangesTicket : mails d'un ticket, sous son fil de mises à jour ;
//  - MailsAVerifier : page des mails que le pilotage n'a pas pu rattacher avec certitude (un clic pour choisir le lot).
//  - 169 : niveau société (profil Rivage) ; « Mails à vérifier » en trois questions avec suggestion, raccourcis et compteur du jour.
//  - 168 : niveaux bailleur (tous ses biens) et mandat ; FicheBailleur : mandats, lots, tickets ouverts et tous les échanges d'un bailleur.
// Le texte est en base, les pièces jointes sur R2 (lien de 5 minutes demandé à la fonction pilotage-mails).
import React, { useEffect, useMemo, useState } from 'react';
import { supabase, rpc } from './supabase.js';

const dateHeure = (d) => (d ? new Date(d).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—');
const ROLES = { locataire: 'Locataire', bailleur: 'Bailleur', prestataire: 'Prestataire', syndic: 'Syndic', garant: 'Garant', organisme: 'Organisme' };
// Texte venu de mails HTML : entités affichées telles quelles (« &lt; ») corrigées à l'affichage (169)
const texteMail = (t) => (t || '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');
const qui = (m) => (m.parties || []).map((p) => `${p.nom || p.email} (${ROLES[p.role] || p.role})`).join(', ');

async function ouvrirPj(id, cle) {
  const w = window.open('', '_blank');
  const { data, error } = await supabase.functions.invoke('pilotage-mails', { body: { action: 'pj', id, cle } });
  if (error || !data?.url) { if (w) w.close(); alert('Pièce jointe indisponible'); return; }
  if (w) w.location = data.url; else window.location.href = data.url;
}

function Message({ m }) {
  const [plein, setPlein] = useState(null);
  const [err, setErr] = useState('');
  const lire = () => (plein ? setPlein(null) : rpc('pilotage_mail_lire', { p_id: m.id }).then(setPlein).catch((e) => setErr(e.message)));
  return <div className={'mail-msg ' + m.sens}>
    <div className="mail-tete">
      <span className="mail-sens" title={m.sens === 'envoye' ? 'Envoyé par l’agence' : 'Reçu'}>{m.sens === 'envoye' ? '↗' : '↘'}</span>
      <span className="mail-de">{m.sens === 'envoye' ? 'À ' + (m.a || []).join(', ') : m.de}</span>
      <span className="muted">{dateHeure(m.le)}</span>
    </div>
    <div className="mail-resume">{texteMail(m.resume || m.extrait)}</div>
    <div className="row" style={{ gap: 6, marginTop: 4 }}>
      <button className="lien" onClick={lire}>{plein ? 'Replier' : 'Lire le mail'}</button>
      {(m.pj || []).map((p) => p.cle
        ? <button key={p.cle} className="lien" onClick={() => ouvrirPj(m.id, p.cle)}>📎 {p.nom}</button>
        : <span key={p.nom} className="muted">📎 {p.nom} (dans Gmail)</span>)}
      {m.ticket && <span className="etq neutre">Ticket n°{m.ticket.numero}</span>}
      {m.niveau === 'bailleur' && <span className="etq violet" title="Mail rangé au niveau du bailleur : il concerne tous ses biens">Bailleur · tous ses biens</span>}
      {m.niveau === 'societe' && <span className="etq violet" title="Mail rangé au niveau de la société : il concerne tous ses biens">Société {m.societe?.nom}</span>}
      {m.niveau === 'mandat' && <span className="etq info" title="Mail rangé au niveau du mandat : il concerne tous les lots du mandat">Mandat {m.mandat?.reference}</span>}
    </div>
    {err && <div className="err">{err}</div>}
    {plein && <pre className="mail-corps">{texteMail(plein.corps) || '(mail sans texte)'}</pre>}
  </div>;
}

function Conversations({ mails }) {
  const [ouvert, setOuvert] = useState(null);
  const fils = useMemo(() => {
    const g = new Map();
    for (const m of mails) { const k = m.thread_id || 'm' + m.id; if (!g.has(k)) g.set(k, []); g.get(k).push(m); }
    return [...g.entries()].map(([k, l]) => ({ k, l: l.sort((a, b) => a.le.localeCompare(b.le)), dernier: l.reduce((a, b) => (a.le > b.le ? a : b)) }))
      .sort((a, b) => b.dernier.le.localeCompare(a.dernier.le));
  }, [mails]);
  return <div className="mail-liste">
    {fils.map(({ k, l, dernier }) => <div key={k} className={'mail-fil' + (ouvert === k ? ' ouvert' : '')}>
      <button className="mail-ligne" aria-expanded={ouvert === k} onClick={() => setOuvert(ouvert === k ? null : k)}>
        <span className="mail-qui">{qui(dernier) || dernier.de}</span>
        <span className="mail-objet"><b>{texteMail(dernier.objet) || '(sans objet)'}</b>{l.length > 1 ? <span className="muted"> ({l.length})</span> : null}
          <span className="muted"> — {texteMail(dernier.resume || dernier.extrait)}</span></span>
        <span className="mail-date">{l.some((m) => (m.pj || []).length) ? '📎 ' : ''}{dateHeure(dernier.le)}</span>
      </button>
      {ouvert === k && <div className="mail-detail">{l.map((m) => <Message key={m.id} m={m} />)}</div>}
    </div>)}
  </div>;
}

export function EchangesLot({ lotId }) {
  const [ouvert, setOuvert] = useState(false);
  const [mails, setMails] = useState(null);
  const [err, setErr] = useState('');
  const [role, setRole] = useState('tous');
  const [cherche, setCherche] = useState('');
  useEffect(() => { if (ouvert && !mails) rpc('pilotage_mails_lot', { p_asset: lotId }).then(setMails).catch((e) => setErr(e.message)); }, [ouvert]);
  const vus = (mails || []).filter((m) => (role === 'tous' || (m.parties || []).some((p) => p.role === role))
    && (!cherche || [m.objet, m.de, (m.a || []).join(' '), m.resume, m.extrait, qui(m)].join(' ').toLowerCase().includes(cherche.toLowerCase())));
  return <details className="fb-bloc fb-complet" onToggle={(e) => setOuvert(e.currentTarget.open)}>
    <summary>Échanges par mail{mails ? ` · ${mails.length}` : ''}</summary>
    {err && <div className="banner">{err}</div>}
    {ouvert && !mails && !err && <p className="muted">Chargement…</p>}
    {mails && !mails.length && <p className="muted">Aucun mail rattaché à ce lot pour l’instant (seuls les mails des boîtes branchées au pilotage remontent).</p>}
    {mails && mails.length > 0 && <>
      <div className="row" style={{ gap: 6, margin: '8px 0' }}>
        {['tous', ...Object.keys(ROLES)].filter((r) => r === 'tous' || mails.some((m) => (m.parties || []).some((p) => p.role === r))).map((r) =>
          <button key={r} className={'chip' + (role === r ? ' on' : '')} onClick={() => setRole(r)}>{r === 'tous' ? 'Tous' : ROLES[r]}</button>)}
        <input className="recherche" placeholder="Rechercher dans les mails…" value={cherche} onChange={(e) => setCherche(e.target.value)} style={{ flex: 1, minWidth: 160 }} />
      </div>
      <Conversations mails={vus} />
    </>}
  </details>;
}

export function EchangesTicket({ ticketId }) {
  const [mails, setMails] = useState(null);
  useEffect(() => { rpc('pilotage_mails_ticket', { p_ticket: ticketId }).then(setMails).catch(() => setMails([])); }, [ticketId]);
  if (!mails || !mails.length) return null;
  return <div style={{ marginTop: 12 }}><h3>Mails du ticket ({mails.length})</h3><Conversations mails={mails} /></div>;
}

// 169 : « Mails à vérifier » en trois questions — suggestion d'abord (Entrée), puis « ce mail concerne… » (société, mandat, lot, ticket),
// puis le choix, lots regroupés par société et par adresse avec une recherche. Compteur des mails triés dans la journée.
const sansAccent = (t) => (t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

// Suggestion déterministe : une seule société nommée dans le résumé ou l'objet, sinon un seul lot possible.
function suggestion(m) {
  const texte = ' ' + sansAccent([m.objet, m.resume, m.extrait].join(' ')).replace(/[^a-z0-9]+/g, ' ') + ' ';
  const nommees = (m.societes || []).filter((s) => {
    const nom = sansAccent(s.nom).replace(/[^a-z0-9]+/g, ' ').trim();
    return nom.length >= 3 && texte.includes(' ' + nom + ' ');
  });
  if (nommees.length === 1) return { type: 'societe', s: nommees[0], pourquoi: 'nommée dans le mail' };
  const cands = m.candidats || [];
  if (cands.length === 1) return { type: 'lot', c: cands[0], pourquoi: 'seul lot possible' };
  return null;
}
const libSuggestion = (sg) => (sg.type === 'societe'
  ? `${sg.s.nom} · ${sg.s.mandats} mandat${sg.s.mandats > 1 ? 's' : ''}, ${sg.s.lots} lot${sg.s.lots > 1 ? 's' : ''}`
  : `Lot ${sg.c.lot} · ${sg.c.adresse}${sg.c.locataires ? ' · ' + sg.c.locataires : ''}`);

export function MailsAVerifier() {
  const [liste, setListe] = useState(null);
  const [err, setErr] = useState('');
  const [jour, setJour] = useState(null);
  const charger = () => rpc('pilotage_mails_a_verifier').then(setListe).catch((e) => setErr(e.message));
  const compter = () => rpc('pilotage_mails_tri_jour').then(setJour).catch(() => setJour(null));
  useEffect(() => { charger(); compter(); }, []);
  const classer = async (m, action) => {
    setErr('');
    try {
      if (action.societe) await rpc('pilotage_mail_classer_societe', { p_id: m.id, p_profil: action.societe });
      else if (action.niveau) await rpc('pilotage_mail_classer_niveau', { p_id: m.id, p_mandat: action.niveau.niveau === 'mandat' ? action.niveau.mandat_id : null, p_bailleur: action.niveau.niveau === 'bailleur' ? action.niveau.email : null });
      else await rpc('pilotage_mail_classer', { p_id: m.id, p_lot_ref: action.lot || null, p_ticket_numero: action.ticket || null, p_ignorer: !!action.ignorer });
      supabase.functions.invoke('pilotage-mails', { body: { action: 'etiqueter', id: m.id } }).catch(() => {});
      setListe((l) => l.filter((x) => x.id !== m.id));
      setJour((j) => (j ? { ...j, moi: j.moi + 1, equipe: j.equipe + 1 } : j));
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } catch (e) { setErr(e.message); }
  };
  // Raccourcis sur le premier mail de la liste : Entrée = suggestion, N = pas un dossier (hors saisie)
  useEffect(() => {
    const touche = (e) => {
      if (!liste?.length || e.ctrlKey || e.metaKey || e.altKey || /^(INPUT|TEXTAREA|SELECT|BUTTON)$/.test(e.target.tagName)) return;
      const m = liste[0];
      if (e.key === 'Enter') { const sg = suggestion(m); if (sg) { e.preventDefault(); classer(m, sg.type === 'societe' ? { societe: sg.s.profil_id } : { lot: sg.c.lot }); } }
      if (e.key === 'n' || e.key === 'N') { e.preventDefault(); classer(m, { ignorer: true }); }
    };
    window.addEventListener('keydown', touche);
    return () => window.removeEventListener('keydown', touche);
  }, [liste]);
  const reste = liste ? liste.length : 0;
  const faits = jour ? jour.equipe : 0;
  return <>
    <div className="entete"><div><h1>Mails à vérifier</h1>
      <p className="sub">Mails échangés avec un contact Rivage que le pilotage n’a pas pu ranger seul. Le choix est retenu et le libellé Gmail passe à « Pilotage/Classé ».</p></div></div>
    {liste && <div className="tri-progres">
      <div className="jauge"><span style={{ width: (faits + reste ? Math.round(100 * faits / (faits + reste)) : 100) + '%' }} /></div>
      <span className="muted">{faits} trié{faits > 1 ? 's' : ''} aujourd’hui{jour && jour.moi ? ` (dont ${jour.moi} par vous)` : ''} · {reste} restant{reste > 1 ? 's' : ''}</span>
    </div>}
    {err && <div className="banner">{err}</div>}
    {!liste ? <p className="sub">Chargement…</p> : !liste.length
      ? <div className="tri-fini"><b>Tout est trié.</b> <span className="muted">Les nouveaux mails à vérifier arriveront ici.</span></div>
      : <div className="stack">{liste.map((m, i) => <CarteMail key={m.id} m={m} actif={i === 0} classer={classer} />)}</div>}
  </>;
}

function CarteMail({ m, actif, classer }) {
  const sg = useMemo(() => suggestion(m), [m]);
  const societes = m.societes || [];
  const adresses = (m.niveaux || []).filter((n) => n.niveau === 'bailleur');
  const mandats = (m.niveaux || []).filter((n) => n.niveau === 'mandat');
  const cands = m.candidats || [];
  const tickets = cands.flatMap((c) => (c.tickets || []).map((t) => ({ ...t, c })));
  const [niveau, setNiveau] = useState(sg ? sg.type : societes.length ? 'societe' : 'lot');
  const [q, setQ] = useState('');
  const [tk, setTk] = useState({ ticket: '', lot: '' });
  const [msg, setMsg] = useState('');
  const choix = [
    { k: 'societe', lib: 'Une société', sous: 'tous ses biens', n: societes.length, ok: societes.length > 0 },
    { k: 'mandat', lib: 'Un mandat', sous: 'tous ses lots', n: mandats.length, ok: mandats.length > 0 },
    { k: 'lot', lib: 'Un lot', sous: 'un logement, un local', n: cands.length, ok: true },
    { k: 'ticket', lib: 'Un ticket', sous: 'travaux, sinistre…', n: tickets.length, ok: true },
  ].filter((c) => c.ok);
  return <div className={'mail-carte' + (actif ? ' actif' : '')}>
    <div className="row" style={{ justifyContent: 'space-between' }}><b>{texteMail(m.objet) || '(sans objet)'}</b><span className="muted">{dateHeure(m.le)}</span></div>
    <div className="muted">{m.sens === 'envoye' ? 'Envoyé à ' + (m.a || []).join(', ') : 'Reçu de ' + m.de}{m.boites ? ' · boîte ' + m.boites.join(', ') : ''}</div>
    {m.resume && <p style={{ margin: '6px 0' }}>{texteMail(m.resume)}</p>}
    <Message m={{ ...m, resume: '' }} />

    {sg && <div className="tri-suggestion">
      <div className="muted">Suggestion ({sg.pourquoi})</div>
      <div className="row" style={{ gap: 8, marginTop: 4, alignItems: 'center' }}>
        <button className="btn plein" onClick={() => classer(m, sg.type === 'societe' ? { societe: sg.s.profil_id } : { lot: sg.c.lot })}>
          {sg.type === 'societe' ? 'Ranger sur la société ' : 'Ranger sur le '}{libSuggestion(sg)}</button>
        {actif && <span className="muted"><kbd>Entrée</kbd> pour valider</span>}
      </div>
    </div>}

    <div className="tri-question">{sg ? 'Sinon, ce mail concerne…' : 'Ce mail concerne…'}</div>
    <div className="tri-niveaux">
      {choix.map((c) => <button key={c.k} className={'tri-niveau' + (niveau === c.k ? ' on' : '')} onClick={() => { setNiveau(c.k); setMsg(''); }}>
        <b>{c.lib}{c.n ? <span className="n"> {c.n}</span> : null}</b><span>{c.sous}</span></button>)}
    </div>

    {niveau === 'societe' && <div className="tri-choix">
      {societes.map((s) => <button key={s.profil_id} className={'btn' + (sg?.s?.profil_id === s.profil_id ? ' plein' : '')} onClick={() => classer(m, { societe: s.profil_id })}>
        {s.nom} · {s.mandats} mandat{s.mandats > 1 ? 's' : ''}, {s.lots} lot{s.lots > 1 ? 's' : ''}</button>)}
      {adresses.filter((a) => societes.filter((s) => s.email === a.email).length > 1).map((a) =>
        <button key={a.email} className="btn gris" onClick={() => classer(m, { niveau: a })}>Toutes les sociétés de {a.email} ({a.mandats} mandats, {a.lots} lots)</button>)}
    </div>}

    {niveau === 'mandat' && <div className="tri-choix">
      {mandats.map((n) => <button key={n.mandat_id} className="btn" onClick={() => classer(m, { niveau: n })}>{libNiveau(n)}</button>)}
    </div>}

    {niveau === 'lot' && <ChoixLot m={m} q={q} setQ={setQ} classer={classer} />}

    {niveau === 'ticket' && <div className="tri-choix">
      {tickets.map((t) => <button key={t.ticket_id} className="btn" onClick={() => classer(m, { lot: t.immeuble ? null : t.c.lot, ticket: t.numero })}>
        {t.immeuble ? 'Immeuble' : 'Lot ' + t.c.lot} · ticket n°{t.numero} {t.titre}</button>)}
      <div className="row" style={{ gap: 6, width: '100%', alignItems: 'center' }}>
        <input placeholder="N° du ticket" value={tk.ticket} onChange={(e) => { setTk({ ...tk, ticket: e.target.value }); setMsg(''); }} style={{ width: 130 }} />
        <input placeholder="N° du lot (vide si ticket d’immeuble)" value={tk.lot} onChange={(e) => { setTk({ ...tk, lot: e.target.value }); setMsg(''); }} style={{ width: 250 }} />
        <button className="btn" onClick={() => (tk.ticket.trim() ? classer(m, { lot: tk.lot.trim(), ticket: tk.ticket.trim() }) : setMsg('Indiquez le n° du ticket.'))}>Ranger sur ce ticket</button>
      </div>
    </div>}
    {msg && <div className="err">{msg}</div>}

    <div className="row tri-pied">
      {actif && <span className="muted"><kbd>N</kbd> pas un dossier</span>}
      <button className="btn gris" onClick={() => classer(m, { ignorer: true })}>Pas un dossier</button>
    </div>
  </div>;
}

// Lots candidats regroupés par société puis par adresse ; une recherche filtre (n° de lot, adresse, locataire, société).
function ChoixLot({ m, q, setQ, classer }) {
  const cands = m.candidats || [];
  const noms = Object.fromEntries((m.societes || []).map((s) => [s.profil_id, s.nom]));
  const f = sansAccent(q.trim());
  const groupes = useMemo(() => {
    const g = new Map();
    for (const c of cands) {
      const soc = (c.societes || []).map((id) => noms[id]).filter(Boolean).join(', ') || 'Autres lots';
      if (f && !sansAccent([c.lot, c.adresse, c.locataires, soc].join(' ')).includes(f)) continue;
      if (!g.has(soc)) g.set(soc, new Map());
      const parAdresse = g.get(soc);
      if (!parAdresse.has(c.adresse)) parAdresse.set(c.adresse, []);
      parAdresse.get(c.adresse).push(c);
    }
    return [...g.entries()].map(([soc, a]) => ({ soc, adresses: [...a.entries()], n: [...a.values()].reduce((x, l) => x + l.length, 0) }))
      .sort((a, b) => b.n - a.n);
  }, [m, f]);
  const total = groupes.reduce((x, g) => x + g.n, 0);
  const ouvrir = !!f || cands.length <= 8 || groupes.length === 1;
  const lotSaisi = /^\d+$/.test(q.trim()) && !cands.some((c) => c.lot === q.trim());
  return <div className="tri-choix" style={{ display: 'block' }}>
    <input className="recherche" placeholder="N° de lot, adresse, locataire ou société" value={q} onChange={(e) => setQ(e.target.value)} style={{ width: '100%', maxWidth: 420 }} />
    {lotSaisi && <div style={{ marginTop: 8 }}><button className="btn" onClick={() => classer(m, { lot: q.trim() })}>Ranger sur le lot {q.trim()}</button>
      <span className="muted"> (hors des lots proposés pour ce correspondant)</span></div>}
    {f && !total && !lotSaisi && <p className="muted">Aucun lot ne correspond.</p>}
    {groupes.map((g) => <details key={g.soc + (ouvrir ? '1' : '0')} className="tri-groupe" open={ouvrir}>
      <summary>{g.soc} <span className="muted">· {g.n} lot{g.n > 1 ? 's' : ''}</span></summary>
      {g.adresses.map(([adr, lots]) => <div key={adr} className="tri-adresse">
        <div className="muted">{adr}</div>
        <div className="row" style={{ gap: 6, marginTop: 4 }}>
          {lots.map((c) => <button key={c.lot_id} className="btn" onClick={() => classer(m, { lot: c.lot })}>Lot {c.lot}{c.locataires ? ' · ' + c.locataires : ''}</button>)}
        </div>
      </div>)}
    </details>)}
  </div>;
}

export const libNiveau = (n) => (n.niveau === 'bailleur'
  ? `Bailleur ${n.nom || n.email} · tous ses biens (${n.mandats} mandats, ${n.lots} lots)`
  : `Mandat ${n.reference} · ${n.nom || ''} (${n.lots} lots)`);

// 168 : fiche bailleur — recherche par nom, adresse mail ou n° de mandat
export function FicheBailleur() {
  const [q, setQ] = useState('');
  const [res, setRes] = useState(null);
  const [fiche, setFiche] = useState(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const chercher = async (e) => {
    e?.preventDefault(); setErr(''); setFiche(null); setBusy(true);
    try { setRes(await rpc('pilotage_bailleurs_chercher', { p_q: q })); } catch (x) { setErr(x.message); }
    setBusy(false);
  };
  const ouvrir = async (email) => {
    setErr(''); setBusy(true);
    try { setFiche(await rpc('pilotage_bailleur', { p_email: email })); } catch (x) { setErr(x.message); }
    setBusy(false);
  };
  const eur = (n) => Number(n || 0).toLocaleString('fr-FR', { style: 'currency', currency: 'EUR' });
  return <>
    <div className="entete"><div><h1>Bailleurs</h1>
      <p className="sub">Un bailleur = une adresse mail de propriétaire dans Rivage, avec tous ses mandats (SCI, nom propre…). Ses échanges : mails rangés sur ses lots, ses mandats ou « tous ses biens ».</p></div></div>
    <form className="row" style={{ gap: 6, marginBottom: 12 }} onSubmit={chercher}>
      <input className="recherche" placeholder="Nom, SCI, adresse mail ou n° de mandat" value={q} onChange={(e) => setQ(e.target.value)} style={{ flex: 1, maxWidth: 420 }} />
      <button className="btn plein" disabled={busy || q.trim().length < 2}>Rechercher</button>
    </form>
    {err && <div className="banner">{err}</div>}
    {busy && <p className="muted">Chargement…</p>}
    {!fiche && res && (!res.length ? <p className="sub">Aucun bailleur trouvé.</p> :
      <div className="stack">{res.map((b) => <button key={b.email} className="mail-carte" style={{ textAlign: 'left', cursor: 'pointer' }} onClick={() => ouvrir(b.email)}>
        <b>{b.nom || b.email}</b><div className="muted">{b.email} · {b.mandats} mandat{b.mandats > 1 ? 's' : ''} · {b.lots} lot{b.lots > 1 ? 's' : ''}</div>
      </button>)}</div>)}
    {fiche && <div className="stack">
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <div><h2 style={{ margin: 0 }}>{fiche.nom || fiche.email}</h2>
          <div className="muted">{fiche.email}{fiche.numero ? ` · réf. Gmail [UDI B${fiche.numero}]` : ''} · {fiche.mandats.length} mandat{fiche.mandats.length > 1 ? 's' : ''} · {fiche.lots} lot{fiche.lots > 1 ? 's' : ''}</div></div>
        {res && <button className="btn gris" onClick={() => setFiche(null)}>Retour à la liste</button>}
      </div>
      <details className="fb-bloc fb-complet" open>
        <summary>Mandats et lots</summary>
        {fiche.mandats.map((md) => <div key={md.mandat_id} style={{ margin: '8px 0' }}>
          <b>Mandat {md.reference}</b> <span className="muted">· {md.nom} · réf. Gmail [UDI M{md.code}]</span>
          <ul style={{ margin: '4px 0 0 18px' }}>{(md.lots_detail || []).map((l) => <li key={l.lot_id}>
            Lot {l.lot} · {l.adresse}{l.bail ? ` · bail ${l.bail}` : ' · vacant'}{l.locataires ? ` · ${l.locataires}` : ''}
            {Number(l.impaye) > 0 && <span className="etq ko" style={{ marginLeft: 6 }}>Impayé Rivage {eur(l.impaye)}</span>}</li>)}</ul>
        </div>)}
      </details>
      <details className="fb-bloc fb-complet" open={fiche.tickets.length > 0}>
        <summary>Tickets ouverts · {fiche.tickets.length}</summary>
        {!fiche.tickets.length ? <p className="muted">Aucun.</p> : <ul style={{ margin: '4px 0 0 18px' }}>{fiche.tickets.map((t) => <li key={t.ticket_id}>
          n°{t.numero} · lot {t.lot} · {t.titre}{t.declare_le ? ` · déclaré le ${new Date(t.declare_le).toLocaleDateString('fr-FR')}` : ''}</li>)}</ul>}
      </details>
      <details className="fb-bloc fb-complet" open>
        <summary>Échanges par mail · {fiche.mails.length}{fiche.mails.length >= 300 ? ' (300 derniers)' : ''}</summary>
        {!fiche.mails.length ? <p className="muted">Aucun mail rangé pour ce bailleur.</p> : <Conversations mails={fiche.mails} />}
      </details>
    </div>}
  </>;
}

// Ma journée : rappel des mails à rattacher (rien d'affiché s'il n'y en a pas, ou si la table n'existe pas encore)
export function BandeauMails({ ouvrir }) {
  const [n, setN] = useState(0);
  useEffect(() => { rpc('pilotage_mails_a_verifier').then((l) => setN((l || []).length)).catch(() => setN(0)); }, []);
  if (!n) return null;
  return <div className="mini-alerte haute" style={{ marginBottom: 12, display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
    <span>✉ {n} mail{n > 1 ? 's' : ''} à rattacher à un lot ou un ticket</span>
    <button className="btn" onClick={ouvrir}>Vérifier</button>
  </div>;
}

// 160 : commentaires Rivage du lot (lot, baux, mandat, tickets), en lecture seule. Le journal automatique de Rivage
// (mails d'avis d'échéance, etc.) est replié derrière une case à cocher.
export function CommentairesRivage({ lotId }) {
  const [ouvert, setOuvert] = useState(false);
  const [liste, setListe] = useState(null);
  const [err, setErr] = useState('');
  const [auto, setAuto] = useState(false);
  useEffect(() => { if (ouvert && !liste) rpc('pilotage_rivage_commentaires', { p_asset: lotId }).then(setListe).catch((e) => setErr(e.message)); }, [ouvert]);
  const equipe = (liste || []).filter((c) => !c.auto);
  const vus = (liste || []).filter((c) => auto || !c.auto);
  return <details className="fb-bloc fb-complet" onToggle={(e) => setOuvert(e.currentTarget.open)}>
    <summary>Commentaires Rivage{liste ? ` · ${equipe.length}` : ''}</summary>
    {err && <div className="banner">{err}</div>}
    {ouvert && !liste && !err && <p className="muted">Chargement…</p>}
    {liste && <>
      <label className="muted" style={{ display: 'block', margin: '6px 0' }}><input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} /> Afficher aussi le journal automatique de Rivage ({liste.length - equipe.length})</label>
      {!vus.length && <p className="muted">Aucun commentaire de l’équipe dans Rivage sur ce lot, ses baux, son mandat ou ses tickets.</p>}
      <ol className="histo">{vus.map((c) => <li key={c.id}>
        <span className="muted">{dateHeure(c.le)}</span>
        <span>
          <span className="muted">{c.auteur ? c.auteur + ' · ' : 'Rivage · '}{c.sur}{c.ref ? ' n°' + c.ref : ''}{c.titre_ticket ? ' « ' + c.titre_ticket + ' »' : ''}</span>
          <div style={{ whiteSpace: 'pre-wrap' }}>{c.texte}</div>
        </span>
      </li>)}</ol>
    </>}
  </details>;
}
