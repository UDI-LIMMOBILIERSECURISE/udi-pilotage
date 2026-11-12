// Fil des tickets (sorti de App.jsx le 12/11/2026 pour être repris dans la fiche du bien) : mises à jour des dossiers repris de
// Monday / WeRoof et des incidents Rivage, avec les liens Gmail et pièces jointes cliquables.
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';

const dateHeure = (d) => (d ? new Date(d).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—');

// Texte d'une mise à jour avec liens cliquables ; les liens Gmail sont abrégés en « mail envoyé / reçu » (085)
const URL_RE = /(https?:\/\/[^\s<>"]+[^\s<>".,;:!?)\]])/g;
function libelleLien(u) {
  if (u.includes('mail.google.com')) return u.includes('#sent') ? '✉ mail envoyé' : u.includes('#inbox') ? '✉ mail reçu' : '✉ mail';
  if (u.includes('monday.com/protected_static')) return '📎 pièce jointe Monday';
  try { return new URL(u).hostname.replace(/^www\./, ''); } catch { return u; }
}
export function TexteLiens({ texte }) {
  const morceaux = String(texte || '').split(URL_RE);
  return <>{morceaux.map((m, i) => (i % 2 ? <a key={i} href={m} target="_blank" rel="noreferrer" title={m} onClick={(e) => e.stopPropagation()}>{libelleLien(m)}</a> : m))}</>;
}

// Outil d'origine d'un dossier repris (081 Monday, 086 WeRoof)
export const ORIGINE = (x) => (x?.origine === 'weroof' ? 'WeRoof' : 'Monday');

// Fil des mises à jour d'un sinistre : dossiers repris de Monday ou WeRoof (081, 086 ; clôture / réouverture) et incidents Rivage (084)
export function SuiviSinistre({ dossier, recharger }) {
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
