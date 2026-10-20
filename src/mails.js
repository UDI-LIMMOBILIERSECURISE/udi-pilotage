// Modèles de mails, SMS et courriers du suivi des baux.
// Rien n'est envoyé automatiquement : le pilotage ouvre un brouillon dans la messagerie Gmail de l'utilisateur connecté,
// qui relit, corrige et envoie lui-même. Les courriers recommandés sont à copier dans l'outil d'envoi (Rivage ou LRAR en ligne).

const d = (x) => (x ? new Date(x).toLocaleDateString('fr-FR') : '…');
// Dates calculées (jours ou mois ajoutés), au format AAAA-MM-JJ
const plusJours = (x, n) => { if (!x) return null; const t = new Date(x); t.setDate(t.getDate() + n); return t.toISOString().slice(0, 10); };
const plusMois = (x, n) => { if (!x) return null; const t = new Date(x); t.setMonth(t.getMonth() + n); return t.toISOString().slice(0, 10); };
const eur = (n) => (n == null ? '…' : Number(n).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €');

export const TYPES_BAIL = {
  vide: 'Habitation vide', meuble: 'Habitation meublée', etudiant: 'Meublé étudiant', mobilite: 'Bail mobilité', mixte: 'Mixte habitation et professionnel',
  commercial: 'Commercial', derogatoire: 'Dérogatoire (courte durée)', professionnel: 'Professionnel', autre: 'Autre (parking, garage...)',
};

export const DECISIONS = {
  reconduire: 'Laisser le bail se reconduire',
  renouveler_loyer: 'Proposer un nouveau loyer (loyer manifestement sous-évalué)',
  conge_reprise: 'Congé pour reprise',
  conge_vente: 'Congé pour vente',
  conge_motif: 'Congé pour motif légitime et sérieux',
  conge: 'Donner congé',
  ne_rien_faire: 'Ne rien faire (tacite prolongation)',
  conge_offre: 'Congé avec offre de renouvellement',
  refus_indemnite: 'Refus de renouvellement avec indemnité d\'éviction',
  refus_motif_grave: 'Refus sans indemnité pour motif grave et légitime',
  opposition: 'S\'opposer au maintien du preneur à la fin du bail',
  laisser_commercial: 'Laisser naître un bail commercial',
};

// Conséquences affichées à côté de chaque choix (rappel, à faire valider par un conseil pour les cas sensibles)
export const CONSEQUENCES = {
  reconduire: 'Le bail repart pour la même durée aux mêmes conditions.',
  renouveler_loyer: 'Proposition au moins 6 mois avant l\'échéance avec des références de loyers du voisinage (article 17-2). Impossible pour un logement classé F ou G.',
  conge_reprise: 'Bénéficiaire prévu par la loi, notice d\'information jointe, délai respecté. Vérifier l\'âge et les ressources du locataire.',
  conge_vente: 'Le congé vaut offre de vente au locataire (prix et conditions), notice d\'information jointe. Vérifier l\'âge et les ressources du locataire.',
  conge_motif: 'Motif à justifier (impayés répétés, troubles...). Vérifier l\'âge et les ressources du locataire.',
  conge: 'Congé 6 mois avant l\'échéance, par LRAR ou commissaire de justice.',
  ne_rien_faire: 'Le bail se prolonge. Au-delà de 12 ans de durée totale, le loyer du bail renouvelé peut être déplafonné.',
  conge_offre: 'Acte de commissaire de justice, au moins 6 mois avant (pour le dernier jour d\'un trimestre civil en tacite prolongation). Loyer en principe plafonné.',
  refus_indemnite: 'Acte de commissaire de justice. Le preneur peut prétendre à une indemnité d\'éviction : à chiffrer avant de décider.',
  refus_motif_grave: 'Mise en demeure préalable et motif sérieux : à traiter avec un avocat.',
  opposition: 'Manifester l\'opposition avant la fin du mois qui suit le terme, sinon un bail commercial de 9 ans naît (L145-5).',
  laisser_commercial: 'Le preneur bénéficiera du statut des baux commerciaux (bail de 9 ans).',
};

const civil = (noms) => (noms && noms.length ? noms.join(', ') : '');
const salutation = (noms) => (noms && noms.length === 1 ? `Bonjour ${noms[0]},` : 'Bonjour,');

// ctx : { bail, fiche, ech, ob, contacts, moi: {prenom, email}, manquants }
export function preparer(code, ctx) {
  const { bail = {}, ech = {}, ob = {}, contacts = {}, moi = {}, fiche = {} } = ctx;
  const loc = (contacts.locataires || []); const bai = (contacts.bailleurs || []);
  const nomsLoc = loc.map((x) => x.nom); const nomsBai = bai.map((x) => x.nom);
  const adr = bail.adresse || 'bien loué';
  const sign = `\n\nBien cordialement,\n${moi.prenom || ''}\nUDI Gestion`;
  const typ = ech.type || fiche.type_bail;
  const commercial = ['commercial', 'derogatoire', 'professionnel'].includes(typ);
  const versLoc = { to: loc.map((x) => x.email).filter(Boolean), dest: 'locataire', noms: nomsLoc };
  const versBai = { to: bai.map((x) => x.email).filter(Boolean), dest: 'bailleur', noms: nomsBai };
  const L = (o) => ({ ...o, corps: o.corps + (o.courrier ? '' : sign) });

  switch (code) {
    // ----- Échéance du bail (bailleur) -----
    case 'echeance_info': {
      let corps;
      if (typ === 'commercial' && ech.mode === 'prolongation') {
        corps = `${salutation(nomsBai)}\n\nLe bail commercial consenti à ${civil(nomsLoc)} pour les locaux du ${adr} est arrivé à son terme le ${d(ech.echeance)} et se poursuit depuis par tacite prolongation.\n\nVous pouvez à tout moment y mettre fin ou proposer son renouvellement par un acte de commissaire de justice, au moins six mois à l'avance et pour le dernier jour d'un trimestre civil : un acte délivré aujourd'hui prendrait effet au plus tôt le ${d(ech.effet_conge_au_plus_tot)}. Plusieurs choix s'offrent à vous : laisser le bail se poursuivre, délivrer un congé avec offre de renouvellement, ou refuser le renouvellement (avec en principe une indemnité d'éviction). Le preneur peut aussi demander lui-même le renouvellement à tout moment.\n\nUn point d'attention : si la durée totale du bail dépasse douze ans${ech.douze_ans ? ` (le ${d(ech.douze_ans)})` : ''}, le loyer du bail renouvelé peut être fixé à la valeur locative et non plus plafonné.\n\nPourriez-vous me faire part de vos intentions ? Je reste à votre disposition pour en parler.`;
      } else if (typ === 'commercial') {
        corps = `${salutation(nomsBai)}\n\nLe bail commercial consenti à ${civil(nomsLoc)} pour les locaux du ${adr} arrive à échéance le ${d(ech.echeance)}.\n\nSi vous souhaitez agir sur cette échéance, l'acte doit être délivré par un commissaire de justice au plus tard le ${d(ech.limite)}. Vos possibilités sont les suivantes : ne rien faire, le bail se poursuivra alors par tacite prolongation ; délivrer un congé avec offre de renouvellement, éventuellement avec un nouveau loyer ; ou refuser le renouvellement, ce qui ouvre en principe droit pour le preneur à une indemnité d'éviction.\n\nLe preneur peut également demander le renouvellement dans les six mois qui précèdent l'échéance ; vous disposeriez alors de trois mois pour répondre.\n\nPourriez-vous me faire connaître votre choix avant le ${d(ech.decision)} ? Cela nous laisse le temps de préparer l'acte avec le commissaire de justice.`;
      } else if (typ === 'professionnel') {
        corps = `${salutation(nomsBai)}\n\nLe bail professionnel consenti à ${civil(nomsLoc)} pour les locaux du ${adr} arrive à échéance le ${d(ech.echeance)}.\n\nSans congé, il sera reconduit pour la même durée. Si vous souhaitez y mettre fin, le congé doit être notifié par lettre recommandée ou par commissaire de justice au plus tard le ${d(ech.limite)}.\n\nPourriez-vous me faire connaître votre choix avant le ${d(ech.decision)} ?`;
      } else if (typ === 'derogatoire') {
        corps = `${salutation(nomsBai)}\n\nLe bail de courte durée consenti à ${civil(nomsLoc)} pour les locaux du ${adr} prend fin le ${d(ech.echeance)}.\n\nAttention : si le preneur reste dans les lieux plus d'un mois après cette date sans que vous vous y opposiez, il bénéficiera d'un bail commercial de neuf ans. Souhaitez-vous qu'il quitte les lieux à la date prévue, ou envisagez-vous de lui consentir un bail commercial ?\n\nMerci de me répondre avant le ${d(ech.decision)}.`;
      } else {
        corps = `${salutation(nomsBai)}\n\nLe bail ${typ === 'meuble' ? 'meublé ' : ''}de ${civil(nomsLoc)} pour le logement du ${adr} arrive à échéance le ${d(ech.echeance)}.\n\nSans démarche de votre part, il sera reconduit automatiquement aux mêmes conditions. Si vous souhaitez y mettre fin, le congé doit être reçu par le locataire au plus tard le ${d(ech.limite)}, et ne peut être donné que pour l'un de ces motifs : reprise du logement pour l'habiter vous-même ou y loger un proche, vente du logement, ou motif légitime et sérieux.${typ === 'vide' ? ' Si le loyer est manifestement sous-évalué, une proposition de nouveau loyer est aussi possible dans le même délai.' : ''}\n\nPourriez-vous me faire connaître vos intentions avant le ${d(ech.decision)} ?`;
      }
      return L({ ...versBai, objet: `Échéance du bail du ${adr} le ${d(ech.echeance)}`, corps });
    }
    case 'echeance_relance':
      return L({ ...versBai, objet: `Relance : échéance du bail du ${adr}`, corps: `${salutation(nomsBai)}\n\nJe reviens vers vous au sujet de l'échéance du bail de ${civil(nomsLoc)} (${adr}) le ${d(ech.echeance)}, dont je vous ai écrit le ${d(ech.informe_le)}.\n\n${ech.limite ? `La date limite pour agir est le ${d(ech.limite)}. ` : ''}Sans réponse de votre part, le bail se poursuivra aux mêmes conditions. Pourriez-vous me faire part de votre décision ?` });
    case 'echeance_lrar':
      return { ...versBai, courrier: true, objet: `Lettre recommandée avec accusé de réception — échéance du bail du ${adr}`, corps: `${civil(nomsBai)}\n\nObjet : échéance du bail de ${civil(nomsLoc)}, ${adr}\n\nMadame, Monsieur,\n\nPar courriers électroniques des ${d(ech.informe_le)}${ech.relance_le ? ` et ${d(ech.relance_le)}` : ''}, nous vous avons informé de l'échéance du bail visé en objet au ${d(ech.echeance)} et des possibilités qui s'offrent à vous.\n\nÀ ce jour, nous n'avons pas reçu d'instruction de votre part. Nous en prenons acte : sauf instruction écrite contraire de votre part reçue avant le ${d(ech.limite || ech.decision)}, aucun congé ne sera délivré et le bail se poursuivra aux mêmes conditions.\n\nNous vous prions d'agréer, Madame, Monsieur, l'expression de nos salutations distinguées.\n\n${moi.prenom || ''}\nUDI Gestion` };

    // ----- Contrôle d'entrée -----
    case 'pieces_manquantes':
      return L({ ...versBai, objet: `Documents à nous transmettre — ${adr}`, corps: `${salutation(nomsBai)}\n\nPour la bonne gestion du bail de ${civil(nomsLoc)} (${adr}), il nous manque les documents suivants :\n\n${(ctx.manquants || []).map((x) => '- ' + x).join('\n')}\n\nPourriez-vous nous les adresser ? Merci par avance.` });

    case 'pieces_manquantes_locataire':
      return L({ ...versLoc, objet: `Documents à nous transmettre — ${adr}`, corps: `${salutation(nomsLoc)}\n\nPour compléter votre dossier de location ${commercial ? 'des locaux' : 'du logement'} situé${commercial ? 's' : ''} ${adr}, il nous manque les documents suivants :\n\n${(ctx.manquants || []).map((x) => '- ' + x).join('\n')}\n\nMerci de nous les adresser en réponse à ce mail.` });

    // ----- Assurance -----
    case 'assurance_1':
      return L({ ...versLoc, objet: `Attestation d'assurance — ${adr}`, corps: `${salutation(nomsLoc)}\n\nVotre attestation d'assurance pour ${commercial ? 'les locaux' : 'le logement'} du ${adr} arrive à échéance le ${d(ob.prochaine)}. Comme le prévoit votre bail, merci de nous transmettre la nouvelle attestation dès que vous l'aurez reçue de votre assureur.` });
    case 'assurance_2':
      return L({ ...versLoc, objet: `Relance : attestation d'assurance — ${adr}`, corps: `${salutation(nomsLoc)}\n\nSauf erreur de notre part, nous n'avons pas encore reçu votre nouvelle attestation d'assurance, attendue pour le ${d(ob.prochaine)}. Merci de nous l'adresser rapidement. Sans justificatif à cette date, nous serons tenus de vous mettre en demeure.` });
    case 'assurance_md':
      return { ...versLoc, courrier: true, objet: `Mise en demeure — attestation d'assurance — ${adr}`, corps: `${civil(nomsLoc)}\n\nObjet : mise en demeure de justifier de votre assurance, ${adr}\n\nMadame, Monsieur,\n\nMalgré nos relances, vous ne nous avez pas transmis l'attestation d'assurance couvrant ${commercial ? 'les locaux' : 'les risques locatifs du logement'} que vous occupez au ${adr}, à laquelle vous êtes tenu${commercial ? ' en application de votre bail' : ' en application de l\'article 7 g) de la loi du 6 juillet 1989 et de votre bail'}.\n\nNous vous mettons en demeure de nous adresser cette attestation dans un délai d'un mois à compter de la réception de la présente.\n\n${commercial ? 'À défaut, le bailleur se réserve d\'exercer les droits que lui confère le bail.' : 'À défaut, le bailleur pourra souscrire une assurance pour votre compte et vous en répercuter le coût, ou se prévaloir de la clause résolutoire du bail.'}\n\nNous vous prions d'agréer, Madame, Monsieur, l'expression de nos salutations distinguées.\n\n${moi.prenom || ''}\nUDI Gestion` };
    case 'assurance_bailleur':
      return L({ ...versBai, objet: `Assurance de votre locataire — ${adr}`, corps: `${salutation(nomsBai)}\n\nMalgré nos relances, ${civil(nomsLoc)} ne nous a pas transmis d'attestation d'assurance valable au-delà du ${d(ob.prochaine)}. Nous venons de lui adresser une mise en demeure.\n\nPar précaution, je vous invite à vérifier que votre propre assurance (propriétaire non occupant) est bien en cours. Je vous tiendrai informé de la suite.` });

    // ----- Entretien -----
    case 'entretien_1':
      return L({ ...versLoc, objet: `Entretien annuel : ${ob.libelle || 'équipement'} — ${adr}`, corps: `${salutation(nomsLoc)}\n\nL'entretien annuel de l'équipement suivant est à votre charge : ${ob.libelle || 'équipement'}. Il doit être réalisé avant le ${d(ob.prochaine)}.\n\nMerci de nous transmettre l'attestation de l'entreprise dès que l'intervention aura eu lieu.` });
    case 'entretien_2':
      return L({ ...versLoc, objet: `Relance : entretien ${ob.libelle || ''} — ${adr}`, corps: `${salutation(nomsLoc)}\n\nNous n'avons pas encore reçu l'attestation d'entretien (${ob.libelle || 'équipement'}) attendue pour le ${d(ob.prochaine)}. Merci de nous la faire parvenir ou de nous indiquer la date d'intervention prévue.` });
    case 'entretien_md': {
      const jours = fiche.exec_substitutive_jours || 15;
      return { ...versLoc, courrier: true, objet: `Mise en demeure — entretien ${ob.libelle || ''} — ${adr}`, corps: `${civil(nomsLoc)}\n\nObjet : mise en demeure de faire procéder à l'entretien (${ob.libelle || 'équipement'}), ${adr}\n\nMadame, Monsieur,\n\nMalgré nos relances, vous ne nous avez pas justifié de l'entretien annuel de l'équipement cité en objet, qui vous incombe en application de votre bail.\n\nNous vous mettons en demeure d'y faire procéder et de nous en adresser le justificatif dans un délai de ${jours} jours à compter de la réception de la présente.\n\nÀ défaut, le bailleur se réserve la possibilité de faire réaliser cet entretien à vos frais si le bail le prévoit, ainsi que d'exercer les autres droits qu'il tient du bail.\n\nNous vous prions d'agréer, Madame, Monsieur, l'expression de nos salutations distinguées.\n\n${moi.prenom || ''}\nUDI Gestion` };
    }
    case 'entretien_bailleur':
      return L({ ...versBai, objet: `Entretien non justifié par votre locataire — ${adr}`, corps: `${salutation(nomsBai)}\n\nMalgré nos relances et une mise en demeure, ${civil(nomsLoc)} ne nous a pas justifié de l'entretien annuel suivant : ${ob.libelle || 'équipement'} (échéance du ${d(ob.prochaine)}).\n\nNous pouvons, si le bail le prévoit, faire réaliser l'intervention aux frais du locataire. Souhaitez-vous que nous procédions ainsi ?` });
    case 'entretien_bailleur_relance':
      return L({ ...versBai, objet: `Relance : entretien non justifié — ${adr}`, corps: `${salutation(nomsBai)}\n\nJe reviens vers vous au sujet de l'entretien non justifié par ${civil(nomsLoc)} (${ob.libelle || 'équipement'}). Pourriez-vous me dire si vous souhaitez que nous fassions intervenir une entreprise aux frais du locataire ?` });
    case 'entretien_resolutoire':
      return L({ ...versBai, objet: `Suite à donner : entretien non réalisé — ${adr}`, corps: `${salutation(nomsBai)}\n\nL'entretien (${ob.libelle || 'équipement'}) n'est toujours pas justifié par ${civil(nomsLoc)} malgré la mise en demeure. Si la clause résolutoire du bail vise ce manquement, vous pouvez envisager de vous en prévaloir, ce qui suppose un commandement par commissaire de justice, ou saisir le juge.\n\nC'est une décision importante : je vous propose d'en parler avant toute démarche. Quelle suite souhaitez-vous donner ?` });

    // ----- Compteurs -----
    case 'compteur_prevenance':
      return L({ ...versLoc, objet: `Relevé de vos compteurs le ${d(ob.prochaine)} — ${adr}`, corps: `${salutation(nomsLoc)}\n\nPour établir la régularisation des charges de votre ${commercial ? 'local' : 'logement'} situé ${adr}, nous aurons besoin du relevé de vos compteurs (${ob.libelle || 'eau, chauffage'}) à la date du ${d(ob.prochaine)}.\n\nCe jour-là, merci de nous envoyer en réponse à ce mail une photo lisible de chaque compteur, sur laquelle apparaissent l'index et, si possible, le numéro du compteur.\n\nSans relevé de votre part, nous devrons organiser un passage sur place.` });
    case 'compteur_1':
      return L({ ...versLoc, objet: `Relevé de vos compteurs — ${adr}`, corps: `${salutation(nomsLoc)}\n\nMerci de nous transmettre le relevé de vos compteurs (${ob.libelle || 'eau, chauffage'}) au ${d(ob.prochaine)}, avec une photo de chaque compteur sur laquelle l'index est lisible. Ces relevés servent à la régularisation de vos charges.` });
    case 'compteur_2':
      return L({ ...versLoc, objet: `Relance : relevé de vos compteurs — ${adr}`, corps: `${salutation(nomsLoc)}\n\nNous n'avons pas encore reçu le relevé de vos compteurs (${ob.libelle || 'eau, chauffage'}). Merci de nous l'envoyer rapidement avec les photos. À défaut, nous devrons organiser un passage sur place.` });

    // ----- Garantie -----
    case 'garantie_1':
      return L({ ...versLoc, objet: `Renouvellement de votre garantie — ${adr}`, corps: `${salutation(nomsLoc)}\n\nLa garantie prévue à votre bail (${fiche.garantie_type || 'garantie'}) expire le ${d(ob.prochaine)}. Merci de nous adresser son renouvellement avant cette date.` });
    case 'garantie_2':
      return L({ ...versLoc, objet: `Relance : renouvellement de votre garantie — ${adr}`, corps: `${salutation(nomsLoc)}\n\nSauf erreur, nous n'avons pas reçu le renouvellement de votre garantie, qui expire le ${d(ob.prochaine)}. Merci de nous le transmettre sans attendre.` });

    // ----- Diagnostics, taxes, tertiaire (bailleur) -----
    case 'dpe_bailleur':
      return L({ ...versBai, objet: `Validité du DPE — ${adr}`, corps: `${salutation(nomsBai)}\n\nLe diagnostic de performance énergétique du bien du ${adr} arrive en fin de validité le ${d(ob.prochaine)}. Je vous propose de faire réaliser un nouveau diagnostic ; souhaitez-vous que nous nous en chargions ?` });
    case 'tsb_rappel':
      return L({ ...versBai, objet: `Taxe sur les bureaux — ${adr}`, corps: `${salutation(nomsBai)}\n\nPetit rappel : la déclaration et le paiement de la taxe annuelle sur les bureaux et locaux commerciaux en Île-de-France doivent être faits par le propriétaire avant le ${d(ob.prochaine)}, pour les locaux du ${adr}.\n\nLe bail permet de la refacturer au preneur : merci de nous adresser une copie de la déclaration et la preuve du paiement dès qu'ils seront faits.` });
    case 'tsb_justif':
      return L({ ...versBai, objet: `Taxe sur les bureaux : justificatifs — ${adr}`, corps: `${salutation(nomsBai)}\n\nPourriez-vous nous transmettre la copie de votre déclaration de taxe sur les bureaux et la preuve du paiement pour les locaux du ${adr} ? Nous pourrons ainsi la refacturer au preneur comme le prévoit le bail.` });
    case 'tertiaire':
      return L({ ...versBai, objet: `Décret tertiaire : déclaration annuelle — ${adr}`, corps: `${salutation(nomsBai)}\n\nLes locaux du ${adr} relèvent du dispositif « éco-énergie tertiaire ». Les consommations de l'année doivent être déclarées sur la plateforme OPERAT avant le ${d(ob.prochaine)}. Le bail précise qui, du bailleur ou du preneur, s'en charge : souhaitez-vous que nous fassions le point ensemble ?` });

    // ----- Compléments 034 : compteurs, DPE, garantie, travaux, tertiaire, dépôt de garantie -----
    case 'compteur_bailleur':
      return L({ ...versBai, objet: `Relevé des compteurs sur place — ${adr}`, corps: `${salutation(nomsBai)}\n\nMalgré trois relances, ${civil(nomsLoc)} ne nous a pas transmis le relevé des compteurs divisionnaires (${ob.libelle || 'eau, chauffage'}) du ${adr}, nécessaire à la régularisation des charges.\n\nNous organisons donc un relevé sur place. Je vous tiendrai informé ; si le bail le prévoit, le coût du déplacement pourra être refacturé au locataire.` });
    case 'dpe_relance':
      return L({ ...versBai, objet: `Relance : validité du DPE — ${adr}`, corps: `${salutation(nomsBai)}\n\nJe reviens vers vous au sujet du diagnostic de performance énergétique du bien du ${adr}, qui arrive en fin de validité le ${d(ob.prochaine)}. Un DPE en cours de validité est obligatoire pour toute nouvelle mise en location.\n\nSouhaitez-vous que nous commandions le nouveau diagnostic ?` });
    case 'garantie_bailleur':
      return L({ ...versBai, objet: `Garantie du preneur non renouvelée — ${adr}`, corps: `${salutation(nomsBai)}\n\nLa garantie consentie par ${civil(nomsLoc)} (${fiche.garantie_type || 'garantie'}) pour les locaux du ${adr} expire le ${d(ob.prochaine)}, et malgré nos deux demandes nous n'avons pas reçu son renouvellement.\n\nNous allons mettre le preneur en demeure de la renouveler. Si rien n'est fait, il faudra décider avant l'expiration s'il convient de mettre en jeu la garantie : je reviendrai vers vous à ce moment-là.` });
    case 'garantie_md':
      return { ...versLoc, courrier: true, objet: `Mise en demeure — renouvellement de la garantie — ${adr}`, corps: `${civil(nomsLoc)}\n\nObjet : mise en demeure de renouveler la garantie prévue au bail, ${adr}\n\nMadame, Monsieur,\n\nLa garantie prévue à votre bail (${fiche.garantie_type || 'garantie'}) expire le ${d(ob.prochaine)}. Malgré nos courriers, vous ne nous avez pas justifié de son renouvellement.\n\nNous vous mettons en demeure de nous adresser ce renouvellement dans un délai de quinze jours à compter de la réception de la présente.\n\nÀ défaut, le bailleur se réserve d'exercer les droits qu'il tient du bail et de la garantie.\n\nNous vous prions d'agréer, Madame, Monsieur, l'expression de nos salutations distinguées.\n\n${moi.prenom || ''}\nUDI Gestion` };
    case 'etat_travaux_preneur':
      return L({ ...versLoc, objet: `État des travaux — ${adr}`, corps: `${salutation(nomsLoc)}\n\nComme le prévoit votre bail, vous trouverez ci-joint l'état récapitulatif des travaux réalisés au cours des trois dernières années et l'état prévisionnel des travaux envisagés pour les trois prochaines années, avec leur budget, pour les locaux du ${adr}.\n\nJe reste à votre disposition pour toute question.` });
    case 'tertiaire_relance':
      return L({ ...versBai, objet: `Relance : déclaration OPERAT — ${adr}`, corps: `${salutation(nomsBai)}\n\nJe reviens vers vous au sujet de la déclaration annuelle des consommations des locaux du ${adr} sur la plateforme OPERAT, attendue avant le ${d(ob.prochaine)}. Pouvez-vous me confirmer qu'elle a été faite, ou par qui elle sera faite ?` });
    case 'dg_ajust':
      return L({ ...versLoc, objet: `Ajustement du dépôt de garantie — ${adr}`, corps: `${salutation(nomsLoc)}\n\nÀ la suite de la révision de votre loyer, et comme le prévoit votre bail, le dépôt de garantie est ajusté au nouveau montant du loyer. Le complément correspondant figurera sur votre prochain avis d'échéance.\n\nJe reste à votre disposition pour toute question.` });

    // ----- Pièces du dossier de mandat (063) : textes « Bienvenue et demande de pièces » et « Relance des pièces »
    // du document « Tous les mails et SMS », liste des pièces encore manquantes à la date du brouillon -----
    case 'mandat_pieces':
      return L({ ...versBai, objet: `Bienvenue chez UDI Gestion — ${adr}`, corps: `${salutation(nomsBai)}\n\nToute l'équipe d'UDI Gestion vous remercie de la confiance que vous nous accordez en nous confiant la gestion de votre bien situé ${adr}.\n\nPour démarrer la gestion dans de bonnes conditions, merci de nous transmettre en réponse à ce mail les documents suivants :\n${(ctx.manquants || []).map((x) => '- ' + x).join('\n')}\n\nDès réception, nous activons l'ensemble de nos services. Vous recevrez ensuite les accès à votre espace propriétaire, où vous retrouverez vos comptes rendus de gestion et vos documents.\n\nNous restons à votre disposition pour toute question.` });
    case 'mandat_pieces_relance':
      return L({ ...versBai, objet: `Rappel : documents en attente pour votre bien ${adr}`, corps: `${salutation(nomsBai)}\n\nNous revenons vers vous au sujet de la mise en gestion de votre bien situé ${adr}. Pour la finaliser, il nous manque encore :\n${(ctx.manquants || []).map((x) => '- ' + x).join('\n')}\n\nSi vous nous les avez transmis entre-temps, merci de ne pas tenir compte de ce message. Si l'une de ces pièces vous pose difficulté, répondez à ce mail : nous pouvons vous aider à la réunir.` });

    // ----- Suivis du mandat (mail au mandant) -----
    case 'pno_1':
      return L({ ...versBai, objet: `Attestation d'assurance propriétaire non occupant — ${adr}`, corps: `${salutation(nomsBai)}\n\nVotre attestation d'assurance propriétaire non occupant (PNO) pour ${adr} arrive à échéance le ${d(ob.prochaine)}. Pourriez-vous nous adresser la nouvelle attestation dès que vous l'aurez reçue de votre assureur ?` });
    case 'pno_2':
      return L({ ...versBai, objet: `Relance : attestation PNO — ${adr}`, corps: `${salutation(nomsBai)}\n\nSauf erreur de notre part, nous n'avons pas reçu votre nouvelle attestation d'assurance propriétaire non occupant pour ${adr}, attendue pour le ${d(ob.prochaine)}.\n\nPour un lot en copropriété, cette assurance de responsabilité civile est obligatoire ; elle vous protège aussi en cas de sinistre pendant une période de vacance. Merci de nous la transmettre rapidement.` });
    // Loi Chatel (art. L215-1 du code de la consommation) : mail dédié, envoyé entre 3 mois et 1 mois avant la date limite de
    // non-reconduction, qui figure dans un encadré apparent. Mandat UDI : préavis de 3 mois par LRAR, date limite = échéance - 3 mois.
    case 'mandat_echeance': {
      const preavis = ctx.mandat?.preavis_mois || 3;
      const limite = plusMois(ob.prochaine, -preavis);
      const auj = new Date().toISOString().slice(0, 10);
      const passee = limite && limite < auj;
      const tard = limite && !passee && limite < plusJours(auj, 30);
      const ref = ctx.mandat?.reference ? ` n° ${ctx.mandat.reference}` : '';
      const cadre = '==================================================';
      return L({ ...versBai, objet: `Votre mandat de gestion${ref} — possibilité de ne pas le reconduire`, corps: `${salutation(nomsBai)}\n\nLe mandat de gestion${ref} que vous nous avez confié arrive au terme de sa période en cours le ${d(ob.prochaine)}. Il comporte une clause de reconduction tacite : sans démarche de votre part, il sera reconduit${ctx.mandat?.duree_reconduction ? ` pour ${ctx.mandat.duree_reconduction} an(s)` : ''}, aux mêmes conditions.\n\nVous pouvez refuser cette reconduction.\n\n${cadre}\nDATE LIMITE POUR REFUSER LA RECONDUCTION : ${d(limite)}\n${cadre}\n\nPour cela, il vous suffit de nous en informer avant cette date par lettre recommandée avec demande d'avis de réception, conformément au préavis de ${preavis} mois prévu au mandat.${passee ? '\n\nCette information vous parvenant après la date limite, vous pourrez, si le mandat est reconduit, y mettre fin gratuitement à tout moment.' : tard ? '\n\nCette information vous parvenant moins d\'un mois avant la date limite, vous pourrez, si le mandat est reconduit, y mettre fin gratuitement à tout moment.' : ''}\n\nCette information vous est adressée en application de l'article L. 215-1 du code de la consommation.\n\nNous restons à votre disposition pour faire le point sur la gestion de votre bien.` });
    }

    // ----- Assurance : accord du bailleur pour souscrire à la place du locataire (J+10) -----
    case 'assurance_souscription': {
      const md = plusJours(ob.prochaine, 1); const fin = plusJours(ob.prochaine, 35);
      if (commercial) return L({ ...versBai, objet: `Assurance de votre preneur : suite à donner — ${adr}`, corps: `${salutation(nomsBai)}\n\nMalgré notre mise en demeure du ${d(md)}, ${civil(nomsLoc)} ne nous a toujours pas justifié de l'assurance des locaux du ${adr}, que le bail lui impose.\n\nSi rien n'est transmis d'ici le ${d(fin)}, vous pourrez, si le bail comporte une clause résolutoire visant ce manquement, faire délivrer un commandement par commissaire de justice. Souhaitez-vous que nous préparions cette démarche ?` });
      return L({ ...versBai, objet: `Assurance de votre locataire : votre accord pour souscrire à sa place — ${adr}`, corps: `${salutation(nomsBai)}\n\nMalgré notre mise en demeure du ${d(md)}, ${civil(nomsLoc)} ${nomsLoc.length > 1 ? 'ne nous ont' : 'ne nous a'} toujours pas transmis d'attestation d'assurance pour le logement du ${adr}. Le délai d'un mois laissé par la mise en demeure expire vers le ${d(fin)}.\n\nSans justificatif à cette date, deux voies s'offrent à vous :\n- souscrire une assurance pour son compte et lui en refacturer le coût, réparti sur les loyers (article 7 g de la loi du 6 juillet 1989). Ce choix vaut renonciation à la clause résolutoire pour défaut d'assurance ;\n- faire délivrer un commandement par commissaire de justice visant la clause résolutoire du bail.\n\nAcceptez-vous que nous souscrivions l'assurance pour votre compte si nécessaire ? Merci de nous répondre avant le ${d(fin)}.` });
    }

    // ----- Permis de louer (mail au bailleur) -----
    case 'permis_choix':
      return L({ ...versBai, objet: `Permis de louer : votre accord pour la demande d'autorisation — ${adr}`, corps: `${salutation(nomsBai)}\n\nVotre bien situé ${adr} se trouve dans un secteur où la commune impose une autorisation préalable de mise en location (« permis de louer »). Chaque nouvelle location doit être autorisée par la mairie avant la signature du bail.\n\nLa mairie dispose d'un mois à compter du dépôt du dossier complet pour se prononcer ; sans réponse, l'autorisation est acquise. Elle peut subordonner son accord à des travaux. Louer sans autorisation expose le propriétaire à une amende pouvant atteindre 5 000 €, et 15 000 € en cas de location malgré un refus.\n\nDeux possibilités :\n1. Nous préparons et déposons la demande pour vous (formulaire Cerfa n° 15652 et diagnostics), puis en assurons le suivi jusqu'à la décision. Cette prestation est facturée 90 € TTC, conformément à notre barème.\n2. Vous effectuez la démarche vous-même et nous transmettez le récépissé de dépôt, puis l'autorisation. Nous ne pourrons pas signer de bail sans elle.\n\nMerci de nous indiquer votre choix en réponse à ce mail.` });
    case 'permis_choix_relance':
      return L({ ...versBai, objet: `Relance : permis de louer — ${adr}`, corps: `${salutation(nomsBai)}\n\nJe reviens vers vous au sujet du permis de louer de votre bien situé ${adr}. Pour pouvoir le remettre en location, il nous faut savoir qui dépose la demande en mairie : nous-mêmes (90 € TTC, conformément à notre barème) ou vous.\n\nPourriez-vous nous indiquer votre choix en réponse à ce mail ? Tant que l'autorisation n'est pas acquise, aucun bail ne peut être signé.` });
    case 'permis_recepisse':
      return L({ ...versBai, objet: `Permis de louer : récépissé de votre demande — ${adr}`, corps: `${salutation(nomsBai)}\n\nVous nous avez indiqué déposer vous-même la demande d'autorisation de mise en location de votre bien situé ${adr}. Pourriez-vous nous transmettre le récépissé de dépôt délivré par la mairie, avec la date de dépôt ?\n\nNous suivrons ainsi le délai de réponse d'un mois. Pour rappel, aucun bail ne peut être signé avant que l'autorisation soit acquise.` });
    case 'permis_depose':
      return L({ ...versBai, objet: `Permis de louer : demande déposée — ${adr}`, corps: `${salutation(nomsBai)}\n\nLa demande d'autorisation préalable de mise en location de votre bien situé ${adr} a été déposée en mairie le ${d(plusJours(ob.prochaine, -30))}.\n\nLa mairie dispose d'un mois pour se prononcer ; sans réponse dans ce délai, l'autorisation sera acquise. Par prudence, nous attendrons le ${d(plusJours(ob.prochaine, 5))} et l'attestation de la mairie avant de signer le bail. Nous vous tiendrons informé(e) de la décision.` });
    case 'permis_accord':
      return L({ ...versBai, objet: `Permis de louer accordé — ${adr}`, corps: `${salutation(nomsBai)}\n\nL'autorisation de mise en location de votre bien situé ${adr} est acquise depuis le ${d(plusMois(ob.prochaine, -24))}. Nous pouvons donc signer le bail.\n\nCette autorisation devient caduque si le bien n'est pas loué dans les deux ans, soit le ${d(ob.prochaine)} : nous en assurons le suivi.` });
    case 'permis_refus':
      return L({ ...versBai, objet: `Permis de louer refusé — ${adr}`, corps: `${salutation(nomsBai)}\n\nLa mairie a refusé l'autorisation de mise en location de votre bien situé ${adr}, pour le motif suivant : [motif indiqué par la mairie].\n\nLe bien ne peut pas être loué en l'état. Nous vous proposons d'en parler pour définir les travaux nécessaires et déposer une nouvelle demande.` });

    // ----- Départ d'un colocataire, fin d'engagement d'un garant (alertes de Ma journée) -----
    // ctx.coloc = { nom, sortie } ; solidarité jusqu'à l'arrivée d'un remplaçant, au plus tard 6 mois après la date d'effet du congé (art. 8-1)
    case 'coloc_sortant': {
      // Le nom de l'alerte est « nom prénom », celui des contacts « civilité prénom nom » : comparaison mot à mot
      const mots = (ctx.coloc?.nom || '').toLowerCase().split(/\s+/).filter(Boolean);
      const restants = nomsLoc.filter((n) => !mots.length || !mots.every((w) => n.toLowerCase().includes(w)));
      return L({ ...versLoc, objet: `Départ de ${ctx.coloc?.nom || 'un colocataire'} — ${adr}`, corps: `Bonjour,\n\nNous avons enregistré le départ de ${ctx.coloc?.nom || '[colocataire sortant]'} du logement situé ${adr}, effectif le ${d(ctx.coloc?.sortie)}.${restants.length ? ` Le bail continue avec ${civil(restants)}.` : ''}\n\nSauf remplacement par un nouveau colocataire inscrit au bail, ${ctx.coloc?.nom || 'le colocataire sortant'} et sa caution restent solidairement tenus du paiement du loyer et des charges jusqu'au ${d(plusMois(ctx.coloc?.sortie, 6))}, soit six mois après la date d'effet de son congé.\n\nPour toute question, répondez à ce mail.` });
    }
    case 'coloc_bailleur':
      return L({ ...versBai, objet: `Départ d'un colocataire — ${adr}`, corps: `${salutation(nomsBai)}\n\nPour information, ${ctx.coloc?.nom || 'l\'un des colocataires'} quitte le logement situé ${adr} le ${d(ctx.coloc?.sortie)}. Le bail continue avec les autres colocataires.\n\nSauf arrivée d'un remplaçant inscrit au bail, le colocataire sortant et sa caution restent solidairement tenus jusqu'au ${d(plusMois(ctx.coloc?.sortie, 6))}. Nous vous tiendrons informé(e) si un nouveau colocataire est proposé.` });
    case 'garant_fin':
      return L({ ...versBai, objet: `Fin de l'engagement de caution — ${civil(nomsLoc)} — ${adr}`, corps: `${salutation(nomsBai)}\n\nL'engagement de caution de [nom du garant] pour le bail de ${civil(nomsLoc)}, logement situé ${adr}, a pris fin le ${d(ctx.garant?.fin)}. Le bail n'est plus garanti par cette caution.\n\nNous vous proposons [une nouvelle caution / la garantie loyers impayés à 2,8 % des sommes quittancées] pour couvrir la suite du bail. Répondez à ce mail pour nous indiquer votre choix.` });

    // ----- Impayés (mail au bailleur, depuis le dossier impayé) -----
    // ctx.impaye = { declaration_le, organisme }
    case 'gli_declaree':
      return L({ ...versBai, objet: `Impayé déclaré à votre assurance loyers impayés — ${adr}`, corps: `${salutation(nomsBai)}\n\nL'impayé de ${civil(nomsLoc)}, pour votre bien situé ${adr}, a été déclaré le ${d(ctx.impaye?.declaration_le)} à votre assurance loyers impayés${ctx.impaye?.organisme ? `, ${ctx.impaye.organisme}` : ''}.\n\nLa suite est désormais encadrée par l'assureur : il instruit le dossier, puis verse les indemnités prévues par le contrat. Nous vous reverserons chaque indemnisation dès sa réception, et elle apparaîtra dans votre compte rendu de gestion.\n\nNous vous tiendrons informé(e) de chaque étape de la procédure.` });
    case 'impaye_regularise':
      return L({ ...versBai, objet: `Votre locataire a régularisé sa situation — ${adr}`, corps: `${salutation(nomsBai)}\n\nBonne nouvelle : ${civil(nomsLoc)} a réglé l'intégralité des sommes dues pour votre bien situé ${adr}. Son compte est à jour à ce jour.${ctx.impaye?.declaration_le ? '\n\nUne déclaration était en cours auprès de votre assurance loyers impayés : nous l\'en informons et procédons, le cas échéant, au reversement des sommes perçues.' : ''}` });
    case 'entretien_lot':
      return L({ ...versBai, objet: `Entretien à prévoir — ${adr}`, corps: `${salutation(nomsBai)}\n\nLe lot ${ob.lot ? ob.lot + ' ' : ''}du ${adr} est actuellement vacant. L'entretien annuel de l'équipement suivant est à prévoir avant le ${d(ob.prochaine)} : ${(ob.libelle || 'équipement').replace(/ \(lot vacant\)$/, '').replace(/^Entretien /, '')}. Pendant la vacance, il est à votre charge.\n\nSouhaitez-vous que nous le commandions pour votre compte ? Nous vous transmettrons l'attestation d'intervention.` });

    // ----- Restitution du dépôt de garantie (054) -----
    // ctx.dg = { depot, sortie, limite_1_mois, limite_2_mois, loyer_hc, demande_le }
    // Uniquement quand le dépôt est détenu par le bailleur (deposit_retained_by = landlord) : proposé dès 15 jours avant la fin du bail
    case 'dg_reversement_demande': {
      const avant = ctx.dg?.sortie && ctx.dg.sortie > new Date().toISOString().slice(0, 10);
      return L({ ...versBai, objet: `Dépôt de garantie à reverser — ${adr}`, corps: `${salutation(nomsBai)}\n\n${civil(nomsLoc)} ${avant ? 'quittera' : 'a quitté'} le logement situé ${adr} le ${d(ctx.dg?.sortie)}. Le dépôt de garantie de ${eur(ctx.dg?.depot)}, qui vous a été reversé à l'entrée du locataire, ${avant ? 'devra lui être restitué' : 'doit lui être restitué'} au plus tard le ${d(ctx.dg?.limite_1_mois)} si l'état des lieux de sortie est conforme à celui d'entrée, le ${d(ctx.dg?.limite_2_mois)} dans le cas contraire, déduction faite des sommes justifiées. Au-delà, la loi prévoit une majoration de 10 % du loyer mensuel hors charges par mois de retard.\n\nMerci de nous retourner ce montant par virement sur le compte de l'agence, IBAN ${ctx.iban || '[IBAN de l\'agence]'}, en indiquant l'adresse du bien en référence. Nous établissons le décompte de sortie et procédons à la restitution.` });
    }
    case 'dg_reversement_relance':
      return L({ ...versBai, objet: `Relance : dépôt de garantie à reverser — ${adr}`, corps: `${salutation(nomsBai)}\n\nSauf erreur de notre part, nous n'avons pas reçu le reversement du dépôt de garantie de ${eur(ctx.dg?.depot)} de ${civil(nomsLoc)}, demandé le ${d(ctx.dg?.demande_le)}.\n\nLa restitution au locataire doit intervenir au plus tard le ${d(ctx.dg?.limite_1_mois)} si l'état des lieux de sortie est conforme. Passé le délai légal, le dépôt restant dû est majoré de 10 % du loyer hors charges, soit ${eur(ctx.dg?.loyer_hc != null ? Math.round(ctx.dg.loyer_hc * 10) / 100 : null)}, par mois de retard commencé, et cette majoration resterait à votre charge.\n\nMerci de procéder au virement dès que possible sur le compte de l'agence, IBAN ${ctx.iban || '[IBAN de l\'agence]'}, en indiquant l'adresse du bien en référence.` });
    case 'dg_restitution':
      return L({ ...versLoc, objet: `Restitution de votre dépôt de garantie — ${adr}`, corps: `${salutation(nomsLoc)}\n\nÀ la suite de votre départ du logement situé ${adr}, voici le décompte de votre dépôt de garantie :\n\nDépôt de garantie versé : ${eur(ctx.dg?.depot)}\n[Retenues justifiées : intitulé – montant, avec justificatif joint]\n[Solde de charges : montant]\nMontant restitué : [montant]\n\nCe montant est viré ce jour sur le compte que vous nous avez communiqué.\n\nPour toute question sur ce décompte, répondez à ce mail.` });

    // ----- Révision ou évolution du loyer, au bailleur (054) : ctx.revision = { ancien, nouveau, le, indice, commercial }
    case 'revision_bailleur': {
      const r = ctx.revision || {}; const i = r.indice || {};
      const indice = i.nature ? `, en application de la clause de révision du bail (indice ${String(i.nature).toUpperCase().replace(/_/g, ' ')} du ${i.quarter ? 'T' + i.quarter + ' ' : ''}${i.year || ''} : ${String(i.value).replace('.', ',')})` : '';
      return L({ ...versBai, objet: `Révision du loyer — ${adr}`, corps: `${salutation(nomsBai)}\n\nLe loyer de votre bien situé ${adr}, loué à ${civil(nomsLoc)}, a été révisé${indice}. Il passe de ${eur(r.ancien)} à ${eur(r.nouveau)} par mois hors charges${r.commercial ? ' et hors taxes' : ''}.\n\nLe nouveau montant est appliqué sur les appels de loyer et apparaîtra sur votre compte rendu de gestion.` });
    }

    // ----- Paliers -----
    case 'palier_locataire':
      return L({ ...versLoc, objet: `Évolution de votre loyer — ${adr}`, corps: `${salutation(nomsLoc)}\n\nComme prévu à votre bail, votre loyer évolue à compter du ${d(ctx.palier?.debut)}. Le montant appelé sera de ${eur(ctx.palier?.loyer_rivage)} hors charges${commercial ? ' et hors taxes' : ''}.` });
    default:
      return null;
  }
}

export const SMS = {
  assurance_sms: (ctx) => `UDI Gestion : votre attestation d'assurance pour ${ctx.bail?.adresse || 'votre logement'} expire le ${d(ctx.ob?.prochaine)}. Merci de nous l'envoyer par mail.`,
  compteur_sms: (ctx) => `UDI Gestion : merci de nous envoyer le relevé et la photo de vos compteurs (${ctx.ob?.libelle || 'eau, chauffage'}) pour ${ctx.bail?.adresse || 'votre logement'}.`,
  compteur_sms3: (ctx) => `UDI Gestion : dernier rappel, merci de nous envoyer sous 5 jours le relevé et la photo de vos compteurs pour ${ctx.bail?.adresse || 'votre logement'}. A défaut, un relevé sur place sera organisé.`,
};

// Brouillon Gmail dans la boîte de l'utilisateur connecté (authuser = son adresse)
export function lienGmail(m, moiEmail) {
  const p = new URLSearchParams({ view: 'cm', fs: '1', to: (m.to || []).join(','), su: m.objet || '', body: m.corps || '' });
  if (moiEmail) p.set('authuser', moiEmail);
  return 'https://mail.google.com/mail/?' + p.toString();
}

// Codes des modèles de mails et de SMS, proposés dans l'écran des calendriers de relance
export const MODELES = ['echeance_info', 'echeance_relance', 'echeance_lrar', 'pieces_manquantes', 'pieces_manquantes_locataire', 'assurance_1', 'assurance_2', 'assurance_md', 'assurance_bailleur', 'entretien_1', 'entretien_2', 'entretien_md', 'entretien_bailleur', 'entretien_bailleur_relance', 'entretien_resolutoire', 'compteur_prevenance', 'compteur_1', 'compteur_2', 'garantie_1', 'garantie_2', 'dpe_bailleur', 'tsb_rappel', 'tsb_justif', 'tertiaire', 'compteur_bailleur', 'dpe_relance', 'garantie_bailleur', 'garantie_md', 'etat_travaux_preneur', 'tertiaire_relance', 'dg_ajust', 'pno_1', 'pno_2', 'mandat_echeance', 'mandat_pieces', 'mandat_pieces_relance', 'assurance_souscription', 'permis_choix', 'permis_choix_relance', 'permis_recepisse', 'permis_depose', 'permis_accord', 'permis_refus', 'coloc_sortant', 'coloc_bailleur', 'garant_fin', 'gli_declaree', 'impaye_regularise', 'entretien_lot', 'dg_reversement_demande', 'dg_reversement_relance', 'dg_restitution', 'revision_bailleur', 'palier_locataire'].concat(Object.keys(SMS));
