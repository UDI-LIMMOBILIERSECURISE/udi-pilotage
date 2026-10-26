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
  return /^0\d{9}$/.test(fr) ? fr.replace(/(\d{2})(?=\d)/g, '$1 ') : c;
}
const sansCivilite = (n) => String(n || '').replace(/^\s*(mr|mrs|ms|miss|m\.|mme|mlle)\s+/i, '');

// Une ligne par personne : nom, téléphone, e-mail (texte sélectionnable : les cartes sont des boutons, pas de liens dedans)
export function Parties({ titre, liste, max = 2 }) {
  const l = liste || [];
  if (!l.length) return null;
  return <div style={{ marginTop: 6, fontSize: 12 }}>
    <div className="muted">{titre}</div>
    {l.slice(0, max).map((p, i) => <div key={i} style={{ overflowWrap: 'anywhere' }}>
      <span>{sansCivilite(p.nom) || '—'}</span>
      {p.telephone && <span className="mono"> · {tel(p.telephone)}</span>}
      {p.email && <span className="muted"> · {p.email}</span>}
    </div>)}
    {l.length > max && <div className="muted">+ {l.length - max} autre(s)</div>}
  </div>;
}
