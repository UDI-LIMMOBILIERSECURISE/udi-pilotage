-- 073 — Date de référence de la reprise au 20/10/2026 (décision de Nicolas du 26/10, remplace le 01/09 du 072).
-- Dossier nouveau = mandat signé, bail signé ou commencé depuis le 20/10, ou créé dans Rivage après la reprise.
-- Aucun dossier de production ne remplit ces conditions aujourd'hui : le circuit ne s'appliquera qu'aux dossiers à venir,
-- tout le portefeuille existant relève de l'audit (onglet Reprise).

begin;

update pilotage.parametres set valeur = '2026-10-20' where cle = 'controle_entree_depuis';

select pilotage.executer_controles();
select pilotage.rattacher_alertes();

commit;

select regle, count(*) n from pilotage.alertes where statut <> 'resolue' group by 1 order by 2 desc;
select jsonb_array_length(public.pilotage_baux_a_lire(1000)) baux_lus_d_office,
       jsonb_array_length(public.pilotage_mandats_a_lire(1000)) mandats_lus_d_office;
