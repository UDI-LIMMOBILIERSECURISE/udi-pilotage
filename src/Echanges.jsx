// Échanges par mail (145) : mails Gmail des boîtes branchées, rattachés à un lot / bail / ticket par la fonction pilotage-mails.
//  - EchangesLot : onglet de la fiche du bien, présenté comme une boîte Gmail (une ligne par conversation) ;
//  - EchangesTicket : mails d'un ticket, sous son fil de mises à jour ;
//  - MailsAVerifier : page des mails que le pilotage n'a pas pu rattacher avec certitude (un clic pour choisir le lot).
// Le texte est en base, les pièces jointes sur R2 (lien de 5 minutes demandé à la fonction pilotage-mails).
import React, { useEffect, useMemo, useState } from 'react';
import { supabase, rpc } from './supabase.js';

const dateHeure = (d) => (d ? new Date(d).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—');
const ROLES = { locataire: 'Locataire', bailleur: 'Bailleur', prestataire: 'Prestataire', syndic: 'Syndic', garant: 'Garant', organisme: 'Organisme' };
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
    <div className="mail-resume">{m.resume || m.extrait || ''}</div>
    <div className="row" style={{ gap: 6, marginTop: 4 }}>
      <button className="lien" onClick={lire}>{plein ? 'Replier' : 'Lire le mail'}</button>
      {(m.pj || []).map((p) => p.cle
        ? <button key={p.cle} className="lien" onClick={() => ouvrirPj(m.id, p.cle)}>📎 {p.nom}</button>
        : <span key={p.nom} className="muted">📎 {p.nom} (dans Gmail)</span>)}
      {m.ticket && <span className="etq neutre">Ticket n°{m.ticket.numero}</span>}
    </div>
    {err && <div className="err">{err}</div>}
    {plein && <pre className="mail-corps">{plein.corps || '(mail sans texte)'}</pre>}
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
        <span className="mail-objet"><b>{dernier.objet || '(sans objet)'}</b>{l.length > 1 ? <span className="muted"> ({l.length})</span> : null}
          <span className="muted"> — {dernier.resume || dernier.extrait || ''}</span></span>
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

export function MailsAVerifier() {
  const [liste, setListe] = useState(null);
  const [err, setErr] = useState('');
  const [saisie, setSaisie] = useState({});
  const charger = () => rpc('pilotage_mails_a_verifier').then(setListe).catch((e) => setErr(e.message));
  useEffect(() => { charger(); }, []);
  const classer = async (m, lot, ticket, ignorer = false) => {
    setErr('');
    try {
      await rpc('pilotage_mail_classer', { p_id: m.id, p_lot_ref: lot || null, p_ticket_numero: ticket || null, p_ignorer: ignorer });
      supabase.functions.invoke('pilotage-mails', { body: { action: 'etiqueter', id: m.id } }).catch(() => {});
      setListe((l) => l.filter((x) => x.id !== m.id));
    } catch (e) { setErr(e.message); }
  };
  return <>
    <div className="entete"><div><h1>Mails à vérifier</h1>
      <p className="sub">Mails échangés avec un contact Rivage que le pilotage n’a pas pu rattacher avec certitude. Un clic sur le bon lot (et le ticket s’il y a lieu) :
        le choix est retenu pour ce correspondant et le libellé Gmail passe à « Pilotage/Classé ».</p></div></div>
    {err && <div className="banner">{err}</div>}
    {!liste ? <p className="sub">Chargement…</p> : !liste.length ? <p className="sub">Rien à vérifier.</p> :
      <div className="stack">{liste.map((m) => <div key={m.id} className="mail-carte">
        <div className="row" style={{ justifyContent: 'space-between' }}><b>{m.objet || '(sans objet)'}</b><span className="muted">{dateHeure(m.le)}</span></div>
        <div className="muted">{m.sens === 'envoye' ? 'Envoyé à ' + (m.a || []).join(', ') : 'Reçu de ' + m.de} · {qui(m)}{m.boites ? ' · boîte ' + m.boites.join(', ') : ''}</div>
        {m.resume && <p style={{ margin: '6px 0' }}>{m.resume}</p>}
        <Message m={{ ...m, resume: '' }} />
        <div className="row" style={{ gap: 6, marginTop: 8 }}>
          {(m.candidats || []).map((c) => <React.Fragment key={c.lot_id}>
            <button className="btn" onClick={() => classer(m, c.lot)}>Lot {c.lot} · {c.adresse}{c.locataires ? ' · ' + c.locataires : ''}</button>
            {(c.tickets || []).map((t) => <button key={t.ticket_id} className="btn gris" onClick={() => classer(m, c.lot, t.numero)}>Lot {c.lot} · ticket n°{t.numero} {t.titre}</button>)}
          </React.Fragment>)}
        </div>
        <div className="row" style={{ gap: 6, marginTop: 8 }}>
          <input placeholder="N° de lot" value={saisie[m.id]?.lot || ''} onChange={(e) => setSaisie({ ...saisie, [m.id]: { ...saisie[m.id], lot: e.target.value } })} style={{ width: 110 }} />
          <input placeholder="N° de ticket (facultatif)" value={saisie[m.id]?.ticket || ''} onChange={(e) => setSaisie({ ...saisie, [m.id]: { ...saisie[m.id], ticket: e.target.value } })} style={{ width: 190 }} />
          <button className="btn plein" disabled={!saisie[m.id]?.lot} onClick={() => classer(m, saisie[m.id].lot, saisie[m.id].ticket)}>Rattacher</button>
          <button className="btn gris" onClick={() => classer(m, null, null, true)}>Pas un dossier</button>
        </div>
      </div>)}</div>}
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
