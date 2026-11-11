// En-tête du contrôle d'un mandat ou d'un bail (refonte du 11/11/2026), selon le métier de la personne connectée :
//  - commercial : avancement du dossier, pièces à déposer, champs Rivage à corriger, questions, puis « envoyer à la gestion » ;
//  - gestion : points qui concordent avec le document lu, écarts à trancher (corriger ou justifier), clauses à confirmer, puis GO.
// Une donnée Rivage n'est validée que si elle concorde avec le document signé ; un écart demande toujours une justification.
import React, { useEffect, useState } from 'react';
import { rpc } from './supabase.js';

let roleCache = null;
function useMonRole() {
  const [r, setR] = useState(null);
  useEffect(() => { roleCache = roleCache || rpc('pilotage_moi').then((x) => x?.role || null).catch(() => { roleCache = null; return null; }); roleCache.then(setR); }, []);
  return r;
}

const regle = (i) => i.statut === 'ok' || i.statut === 'sans_objet';

export default function ResumeControle({ c, objet }) {
  const role = useMonRole();
  const items = (c?.items || []).filter((i) => i.auto !== 'sans_objet' || i.repondu);
  if (!items.length) return null;
  const commercial = role === 'negociateur';
  // Bail : chaque point dit qui le traite ; mandat : tout le dossier revient au commercial avant la validation
  const pourMoi = (i) => (objet === 'bail' && i.qui ? (commercial ? i.qui === 'commercial' : i.qui === 'gestion') : true);
  const faits = items.filter(regle).length;
  const pct = Math.round((faits / items.length) * 100);
  const ouverts = items.filter((i) => !regle(i));
  const pieces = ouverts.filter((i) => i.bloc === 'pieces' && pourMoi(i));
  const champs = ouverts.filter((i) => i.bloc === 'rivage' && pourMoi(i));
  const questions = ouverts.filter((i) => i.bloc === 'clauses' && pourMoi(i));
  const ecarts = ouverts.filter((i) => i.auto === 'anomalie' && i.bloc !== 'pieces');
  const concordent = items.filter((i) => i.bloc === 'rivage' && regle(i)).length;
  const tuiles = commercial
    ? [[pieces.length, 'pièce(s) à déposer dans Rivage', 'rouge'], [champs.length, 'champ(s) Rivage à corriger ou remplir', 'ambre'], [questions.length, 'question(s) sur le ' + objet, 'bleu']]
    : [[concordent, 'point(s) concordent avec le ' + objet + ' lu', 'vert'], [ecarts.length, 'écart(s) à trancher', 'rouge'],
       [questions.length, 'clause(s) à confirmer', 'ambre'], [pieces.length, 'pièce(s) manquante(s)', 'gris']];
  const reste = commercial ? pieces.length + champs.length + questions.length : ecarts.length + questions.length + pieces.length;
  return <section className="resume-controle" aria-label={'Contrôle du ' + objet}>
    <div className="rc-tete">
      <span className="etq neutre">{commercial ? 'Vue commercial' : 'Vue gestion'}</span>
      {c.go_le ? <span className="etq ok">GO donné{c.go_par ? ' par ' + c.go_par : ''}</span>
        : reste === 0 ? <span className="etq ok">{commercial ? 'Tout est complété : la gestion vérifie' : 'Prêt pour le GO'}</span>
        : <span className="etq rose">{reste} point{reste > 1 ? 's' : ''} pour {commercial ? 'vous' : 'la gestion'}</span>}
    </div>
    <div className="rc-avance">
      <div className="rc-avance-texte"><b>Dossier complété à {pct} %</b><span className="muted">{faits} point{faits > 1 ? 's' : ''} sur {items.length}</span></div>
      <div className="rc-barre" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct}><span style={{ width: pct + '%' }} /></div>
    </div>
    <div className="rc-tuiles">{tuiles.map(([n, l, k]) => <div key={l} className={'rc-tuile ' + k + (n ? '' : ' zero')}><b>{n}</b><span>{l}</span></div>)}</div>
    <p className="muted rc-aide">{commercial
      ? 'Déposez les pièces et corrigez Rivage : chaque ligne passe au vert seule à la synchronisation suivante. Quand tout est vert, la gestion vérifie et donne le GO.'
      : 'Chaque écart se corrige dans Rivage ou se valide avec une justification. Le GO se donne quand il ne reste ni écart ni clause à confirmer.'}</p>
  </section>;
}

// Rivage et document signé côte à côte (écarts du croisement)
export function Comparaison({ rivage, document, page, extrait, doc = 'bail' }) {
  return <div className="comparaison">
    <div><div className="muted">Dans Rivage</div>{rivage || '—'}</div>
    <div className="doc"><div className="muted">Dans le {doc} signé{page ? ` (page ${page})` : ''}</div>{document || 'non trouvé par la lecture'}
      {extrait && <div className="extrait">« {extrait} »</div>}</div>
  </div>;
}
