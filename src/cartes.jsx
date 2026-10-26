// Informations affichées sur les cartes des mandats et des baux (079) : type de bien, adresse, coordonnées des parties.
import React from 'react';

export const NATURES = { flat: 'Appartement', house: 'Maison', room: 'Chambre', commercial: 'Local commercial', office: 'Bureau',
  parking: 'Parking', box: 'Box', cellar: 'Cave', land: 'Terrain', building: 'Immeuble', antenna_site: 'Antenne' };
export const nature = (n) => (n ? NATURES[n] || n : 'Type ?');

// Téléphone Rivage (« 33610240756 ») affiché à la française : 06 10 24 07 56
export function tel(t) {
  const c = String(t || '').replace(/[^0-9+]/g, '');
  if (!c) return '';
  const fr = c.startsWith('+33') ? '0' + c.slice(3) : c.startsWith('33') && c.length === 11 ? '0' + c.slice(2) : c;
  if (/^0\d{9}$/.test(fr)) return fr.replace(/(\d{2})(?=\d)/g, '$1 ');
  return /^\d{11,15}$/.test(c) ? '+' + c : c; // numéro étranger repris de Rivage sans « + » (ex. 216…)
}
const sansCivilite = (n) => String(n || '').replace(/^\s*(mr|mrs|ms|miss|m\.|mme|mlle)\s+/i, '');

const stop = (e) => e.stopPropagation();
const telLien = (t) => { const c = String(t || '').replace(/[^0-9+]/g, ''); return c.startsWith('+') || c.startsWith('0') ? c : /^\d{11,15}$/.test(c) ? '+' + c : c; };

// Une ligne par personne : nom, téléphone (appel d'un toucher sur mobile), e-mail (ouvre la messagerie)
export function Parties({ titre, liste, max = 2 }) {
  const l = liste || [];
  if (!l.length) return null;
  return <div style={{ marginTop: 6, fontSize: 12 }}>
    <div className="muted">{titre}</div>
    {l.slice(0, max).map((p, i) => <div key={i} style={{ overflowWrap: 'anywhere' }}>
      <span>{sansCivilite(p.nom) || '—'}</span>
      {p.telephone && <> · <a className="mono" href={'tel:' + telLien(p.telephone)} onClick={stop}>{tel(p.telephone)}</a></>}
      {p.email && <> · <a href={'mailto:' + p.email} onClick={stop}>{p.email}</a></>}
    </div>)}
    {l.length > max && <div className="muted">+ {l.length - max} autre(s)</div>}
  </div>;
}

// Carte cliquable : <div role="button"> (et non <button>) pour pouvoir contenir des liens tel: et mailto:
export function Carte({ className, onClick, children }) {
  return <div role="button" tabIndex={0} className={className} onClick={onClick}
    onKeyDown={(e) => { if ((e.key === 'Enter' || e.key === ' ') && e.target === e.currentTarget) { e.preventDefault(); onClick(); } }}>{children}</div>;
}

// Texte de recherche : tout ce qui est lisible sur la carte (noms, adresses, téléphones, e-mails, type de bien)
export function texteRecherche(...morceaux) {
  const plat = [];
  const ajoute = (x) => { if (x == null) return; if (Array.isArray(x)) x.forEach(ajoute); else if (typeof x === 'object') Object.values(x).forEach(ajoute); else plat.push(String(x)); };
  morceaux.forEach(ajoute);
  const t = plat.join(' ');
  return (t + ' ' + plat.map((x) => { const f = tel(x); return f + ' ' + f.replace(/ /g, ''); }).join(' ')).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
}
export const normaliser = (q) => String(q || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
export const correspond = (texte, q) => normaliser(q).split(/\s+/).filter(Boolean).every((mot) => texte.includes(mot));
