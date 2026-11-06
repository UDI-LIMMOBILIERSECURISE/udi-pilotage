-- 130 : Sorties et DG, étape « État des lieux de sortie » : mail au locataire après la pré-visite en visioconférence (bloc 1 sur 1)
--  Demande de Nicolas du 06/11/2026, texte fourni par lui, repris tel quel sauf :
--   - « Bonjour Madame/Monsieur » remplacé par {bonjour} (civilité et nom du locataire lus dans Rivage, comme les autres mails) ;
--   - « Bien cordialement » remplacé par {signature} (prénom de la personne connectée + UDI Gestion) ;
--   - la liste des travaux (« - - - ») devient le champ {travaux_a_prevoir}, saisi dans une zone de texte avant de préparer le mail ;
--   - fautes corrigées : « remise de l'ensemble des clés, bips, Vigik et télécommandes fournis à l'entrée ».
--  Placé après le mail « vous allez être contacté » et avant la confirmation du rendez-vous : les modèles suivants descendent d'un rang.
--  Comme tout modèle de l'étape, il est proposé pour chaque sortie ; sans pré-visite, « Pas nécessaire » le retire.

update pilotage.messages_modeles set ordre = ordre + 1
 where categorie = 'edl_sortie' and ordre >= 4
   and not exists (select 1 from pilotage.messages_modeles where code = 'es_previsite_email');

insert into pilotage.messages_modeles (code, categorie, canal, cible, envoi, libelle, objet, texte, ordre) values
('es_previsite_email', 'edl_sortie', 'email', 'locataire', 'commercial', 'Mail au locataire : suite à la pré-visite (visioconférence)',
 'Suite à notre pré-visite en visioconférence – Préparation de l''état des lieux de sortie',
'{bonjour}

À la suite de la pré-visite du logement réalisée, je vous remercie pour votre disponibilité et le temps accordé.

Je vous informe qu''un de mes collègues prendra prochainement contact avec vous afin de convenir d''un rendez-vous pour la réalisation de l''état des lieux de sortie.

Dans cette attente, je souhaite vous rappeler plusieurs points importants concernant la restitution du logement.

1. Conditions de restitution du logement

Comme indiqué dans mon précédent courriel, le jour de l''état des lieux de sortie, le logement devra être :
- entièrement vidé de vos meubles et effets personnels ;
- accompagné de la remise de l''ensemble des clés, bips, Vigik et télécommandes fournis à l''entrée ;
- propre et soigneusement nettoyé (sols, sanitaires, cuisine, placards, etc.) ;
- avec l''électricité toujours active, afin de permettre le contrôle du bon fonctionnement des équipements ainsi que le relevé des compteurs.

Je vous remercie donc de ne surtout pas résilier votre contrat d''électricité avant la réalisation complète de l''état des lieux de sortie.

2. Travaux et remises en état à prévoir avant votre départ

À la suite de notre échange de ce jour et des éléments constatés lors de la pré-visite, je vous remercie également de prévoir les interventions suivantes avant la remise des clés :
{travaux_a_prevoir}

Cette liste reprend les principaux points relevés lors de notre pré-visite et n''est pas exhaustive.

3. État des lieux de sortie et restitution du dépôt de garantie

Je vous rappelle que la pré-visite réalisée en visioconférence ne constitue pas l''état des lieux de sortie définitif. Un état des lieux contradictoire sera établi lors de votre départ et comparé à l''état des lieux d''entrée.

Toute dégradation, anomalie ou remise en état relevant de votre responsabilité et constatée à cette occasion pourra donner lieu à une retenue sur votre dépôt de garantie, sur présentation des justificatifs correspondants (devis ou factures).

Concernant les délais de restitution du dépôt de garantie, je vous rappelle les dispositions de l''article 22 de la loi du 6 juillet 1989 :
- 1 mois à compter de la restitution des clés lorsque les états des lieux d''entrée et de sortie sont conformes ;
- 2 mois lorsque des différences ou dégradations imputables au locataire sont constatées entre les deux états des lieux.

Les éventuelles retenues devront être dûment justifiées.

Je vous remercie par avance de prendre les dispositions nécessaires afin que le logement soit restitué dans les conditions attendues et que l''état des lieux de sortie puisse se dérouler dans les meilleures conditions.

Je reste à votre disposition pour toute question complémentaire.
{signature}', 4)
on conflict (code) do nothing;

select code, ordre, libelle from pilotage.messages_modeles where categorie = 'edl_sortie' order by ordre;
