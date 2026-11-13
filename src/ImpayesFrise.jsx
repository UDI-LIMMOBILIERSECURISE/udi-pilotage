// Frise d'avancement d'un dossier d'impayé et obligations du mois, selon l'organisme (13/11/2026, demande de Nicolas :
// « voir les différentes phases en fonction des frises d'avancement et des obligations à suivre selon Zelok, Mila… »).
// Tout est déduit de ce qui est déjà en base : cycle d'impayé Rivage (ouvert, relancé, mis en demeure, déclaré à la GLI,
// contentieux, clos), date de déclaration, prise en charge, indemnisation, reversement au bailleur, commandement, procédure,
// audience ; obligations tirées du bloc « Ce mois-ci » (déclarations, actualisations, règlements à signaler).
import React from 'react';

const date = (d) => (d ? new Date(d).toLocaleDateString('fr-FR') : '');
const euro = (n) => (n == null ? '—' : Number(n).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €');
export const NOMS_ORG = { zelok: 'Zelok', mila: 'Mila', smartgarant: 'Smart Garant', garantme: 'Garantme', visale: 'Visale', avocats: 'Avocats', aucun: 'Sans garantie' };
const GLI = ['zelok', 'mila', 'smartgarant', 'garantme', 'visale'];
const RANG = { opened: 1, reminded: 2, formal_notice: 3, gli_reported: 4, long_contentious: 5, closed: 6 };

// Relances notées dans le dossier (13/11) : « Relance amiable faite », « Mise en demeure envoyée » (boutons de la fiche),
// ou toute action au statut Fait dont le libellé parle de relance / mise en demeure. La frise n'attend plus Rivage seul.
export const ACTIONS_RELANCE = { relance: 'Relance amiable faite', med: 'Mise en demeure envoyée' };
const MOTIF = { relance: /relance|relanc[ée]/i, med: /mise en demeure|\bMED\b/i };
export function derniereAction(x, quoi) {
  const l = (x.actions || []).filter((a) => a.statut === 'Fait' && MOTIF[quoi].test(a.libelle || ''));
  if (!l.length) return null;
  return l.map((a) => a.le || (a.cree_le || '').slice(0, 10)).filter(Boolean).sort().pop() || '';
}

export const detteSoldee = (x) => !!x.bail_id && x.rivage && Number(x.rivage.impaye || 0) <= 0 && Number(x.rivage.solde_locataire || 0) <= 0;

// Étape de relance : faite si notée dans le dossier ou si le cycle Rivage l'a passée ; si l'étape suivante est franchie
// sans relance notée, elle apparaît « sautée » (grisée) au lieu d'être cochée à tort.
function etapeRelance(x, quoi, lib, parRivage, depassee) {
  const le = derniereAction(x, quoi);
  if (le != null) return [lib, true, le ? 'le ' + date(le) : 'notée dans le dossier'];
  if (parRivage) return [lib, true, 'selon Rivage'];
  if (depassee) return [lib + ' (non notée)', false, 'Aucune ' + lib.toLowerCase() + ' notée dans le dossier', true];
  return [lib, false, ''];
}

// Phases du dossier : [libellé, fait, détail, refus]
export function phasesImpaye(x) {
  const rang = RANG[x.cycle?.statut] || (x.cycle ? 1 : 0);
  const declare = !!x.declaration_le || rang >= 4;
  const t = (v) => String(v || '');
  if (GLI.includes(x.organisme)) {
    const org = NOMS_ORG[x.organisme];
    const refus = /NON|REFUS/i.test(t(x.prise_en_charge));
    return [
      ['Impayé constaté', true, x.cycle?.ouvert_le ? 'le ' + date(x.cycle.ouvert_le) : ''],
      etapeRelance(x, 'relance', 'Relance amiable', rang >= 2, declare),
      etapeRelance(x, 'med', 'Mise en demeure', rang >= 3, declare),
      ['Déclaré à ' + org, declare, x.declaration_le ? 'le ' + date(x.declaration_le) : ''],
      [refus ? 'Prise en charge refusée' : 'Prise en charge', /OUI|DECOMPTE|OK/i.test(t(x.prise_en_charge)), t(x.prise_en_charge), refus],
      ['Indemnisation reçue', /OK|RECUE|QUITTANCE/i.test(t(x.indemnisation_recue)), x.indemnisation_montant ? euro(x.indemnisation_montant) : ''],
      ['Reversée au bailleur', /OK|OUI/i.test(t(x.indemnite_versee_bailleur)), ''],
    ];
  }
  const p = t(x.procedure);
  return [
    ['Impayé constaté', true, x.cycle?.ouvert_le ? 'le ' + date(x.cycle.ouvert_le) : ''],
    etapeRelance(x, 'relance', 'Relance amiable', rang >= 2, !!x.commandement_le || !!p),
    etapeRelance(x, 'med', 'Mise en demeure', rang >= 3, !!x.commandement_le || !!p),
    ['Commandement de payer', !!x.commandement_le || /CDT|COMMANDEMENT|AVOCAT|ASSIGNATION/i.test(p), x.commandement_le ? 'le ' + date(x.commandement_le) : ''],
    ['Avocat, assignation', /AVOCAT|ASSIGNATION/i.test(p) || !!x.audience_le, ''],
    ['Audience', !!x.audience_le && x.audience_le < new Date().toISOString().slice(0, 10), x.audience_le ? 'le ' + date(x.audience_le) : ''],
  ];
}

// Obligations du mois pour ce dossier, d'après le bloc « Ce mois-ci » (mois = réponse de pilotage_impayes_mois)
export function obligationsImpaye(x, mois) {
  const o = [];
  if (!mois) return o;
  const decl = (mois.a_declarer || []).find((a) => a.bail_id === x.bail_id);
  if (decl) o.push(['alerte', `À déclarer à Zelok du 16 au 19 (dette ${euro(decl.dette)})`]);
  if ((mois.en_attente || []).some((a) => a.bail_id === x.bail_id)) o.push(['en_cours', 'Loyer du mois en attente de prélèvement : rien à déclarer avant le 16']);
  const regl = (mois.reglements || []).find((r) => r.dossier_id === x.id);
  if (regl) o.push(['alerte', `Règlement de ${euro(regl.montant)} reçu le ${date(regl.recu_le)} : à signaler à ${NOMS_ORG[regl.organisme] || regl.organisme}`]);
  const org = /avocat/i.test(String(x.procedure || '')) ? 'avocats' : x.organisme;
  const actu = (mois.actualisations || []).find((a) => a.organisme === org && (a.dossiers || []).some((d) => d.id === x.id));
  if (actu) {
    const quoi = org === 'mila' ? 'Décompte mensuel à Mila' : org === 'avocats' ? 'Point mensuel avec l’avocat' : 'Actualisation mensuelle ' + (NOMS_ORG[org] || org);
    o.push(actu.fait_le ? ['fait', `${quoi} faite le ${date(actu.fait_le)}`] : ['en_cours', `${quoi} : à faire ce mois-ci`]);
  }
  if (detteSoldee(x)) o.push(['alerte', 'Dette soldée dans Rivage : dossier à clôturer ?']);
  return o;
}

export function FriseImpaye({ x, mois }) {
  const ph = phasesImpaye(x);
  const clos = x.groupe === 'Clôturé';
  const courante = clos ? -1 : ph.findIndex((p) => !p[1] && !p[3]);
  const obl = clos ? [] : obligationsImpaye(x, mois);
  return <div>
    <ol className="frise" aria-label="Avancement du dossier d’impayé">
      {ph.map(([lib, fait, det, refus], i) => <li key={lib} title={det || lib}
        className={'frise-phase ' + (refus ? 'hors' : clos || fait ? 'passee' : i === courante ? 'courante' : '')}>{lib}</li>)}
    </ol>
    {obl.length > 0 && <ul className="etapes" aria-label="Obligations du mois">
      {obl.map(([etat, txt]) => <li key={txt} className={'etape e-' + etat}><span className="etape-marque">{etat === 'fait' ? '✓' : etat === 'alerte' ? '!' : '•'}</span>{txt}</li>)}
    </ul>}
  </div>;
}
