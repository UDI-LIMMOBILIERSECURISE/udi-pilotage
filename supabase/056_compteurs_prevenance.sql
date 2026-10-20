-- 056 (déjà exécuté le 20/10/2026) : -- Relances relevé des compteurs : mail de prévenance à J-7 et remise en ordre des étapes
-- Calendrier cible : J-7 prévenance, J0 mail, J+5 SMS, J+10 mail, J+15 SMS, J+20 relevé sur place, J+20 info bailleur

begin;

-- 1. Décale temporairement les numéros d'ordre pour éviter les conflits de clé (nature, ordre)
update pilotage.calendriers
   set ordre = ordre + 100
 where nature = 'compteur';

-- 2. Renumérote les étapes existantes dans l'ordre chronologique, en laissant la place 1 à la prévenance
update pilotage.calendriers set ordre = 2 where nature = 'compteur' and modele = 'compteur_1';
update pilotage.calendriers set ordre = 3 where nature = 'compteur' and modele = 'compteur_sms';
update pilotage.calendriers set ordre = 4 where nature = 'compteur' and modele = 'compteur_2';
update pilotage.calendriers set ordre = 5 where nature = 'compteur' and modele = 'compteur_sms3';
update pilotage.calendriers set ordre = 6 where nature = 'compteur' and canal = 'tache' and ordre > 100;
update pilotage.calendriers set ordre = 7 where nature = 'compteur' and modele = 'compteur_bailleur';

-- 3. Libellé de l'étape J0, qui devient un rappel puisque le locataire a été prévenu à J-7
update pilotage.calendriers
   set libelle = 'Mail au locataire : relevé des compteurs à transmettre'
 where nature = 'compteur' and ordre = 2;

-- 4. Ajoute le mail de prévenance à J-7
insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele)
values ('compteur', 1, -7, 'Mail de prévenance au locataire : relevé à faire à la date prévue', 'mail_locataire', 'compteur_prevenance');

-- 5. Contrôle : doit renvoyer 7 lignes numérotées de 1 à 7, sans aucun ordre supérieur à 100
select ordre, jours, canal, libelle, modele
  from pilotage.calendriers
 where nature = 'compteur'
 order by ordre;

commit;
