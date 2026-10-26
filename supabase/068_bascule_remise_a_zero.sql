-- 068 — Bascule sur le compte Rivage de production : remise à zéro de tout ce qui vient du compte de test.
-- À passer à la main dans l'éditeur SQL Supabase, APRÈS avoir supprimé le webhook dans le compte Rivage de TEST.
--
-- Ce que fait le script :
--   1. met en pause toutes les tâches planifiées du pilotage (pilotage-*) : plus aucune lecture Rivage ni IA,
--      plus aucun contrôle, jusqu'au script 069 ;
--   2. vide le reflet Rivage et tout ce qui est rattaché à un bail, un mandat, un lot ou une pièce du compte de test ;
--   3. retire les communes de permis de louer non confirmées (communes de démonstration du compte de test) ;
--   4. abaisse le plafond de l'audit du stock à 20 par jour (audit toujours inactif).
--
-- Conservés : membres et rôles, paramètres, calendriers, règles de relance, obligations et catégories,
-- questionnaire de contrôle, rémunération, communes confirmées et leurs voies,
-- 231 dossiers d'impayés avec leurs notes et actions (aucun n'est relié à un bail du compte de test).
--
-- TRUNCATE sans CASCADE : si une table conservée dépendait d'une table vidée, le script s'arrête au lieu d'effacer.

begin;

-- 1. Pause des tâches planifiées du pilotage
select jobname, cron.alter_job(jobid, active := false) from cron.job where jobname like 'pilotage-%';

-- 2. Reflet Rivage et données rattachées aux dossiers du compte de test
truncate table
  public.rivage_webhook_events,
  pilotage.objets,
  pilotage.syncs,
  pilotage.erreurs,
  pilotage.alertes,
  pilotage.attributions,
  pilotage.dossiers_vus,
  pilotage.dossiers_messages,
  pilotage.dossiers_forcages,
  pilotage.resumes,
  pilotage.suivis_etapes,
  pilotage.saisies,
  pilotage.correspondances,
  pilotage.rivage_ecritures,
  pilotage.sms_envois,
  pilotage.lectures_echecs,
  pilotage.baux_cache,
  pilotage.baux_situation,
  pilotage.baux_fiche,
  pilotage.baux_lectures,
  pilotage.baux_reponses,
  pilotage.baux_suivi,
  pilotage.baux_echeance,
  pilotage.baux_actes,
  pilotage.baux_paliers,
  pilotage.baux_loyers_historique,
  pilotage.baux_obligations,
  pilotage.edl_lectures,
  pilotage.dg_suivi,
  pilotage.compteurs_releves,
  pilotage.lots_equipements,
  pilotage.lots_propositions,
  pilotage.lots_sans,
  pilotage.lots_a_louer,
  pilotage.permis_lots,
  pilotage.permis_demandes,
  pilotage.mandats_cache,
  pilotage.mandats_suivi,
  pilotage.mandats_obligations,
  pilotage.mandats_justificatifs,
  pilotage.obligations_justificatifs,
  pilotage.commissions_validations,
  pilotage.commissions_factures
restart identity;

-- 3. Communes de démonstration (recherche IA non confirmée) ; les 4 communes confirmées et leurs voies restent
delete from pilotage.permis_rues where commune in (select commune from pilotage.permis_communes where statut <> 'confirme');
delete from pilotage.permis_communes where statut <> 'confirme';

-- 4. Audit du stock : plafond bas pour la reprise (le paramètre audit_stock reste « inactif »)
update pilotage.parametres set valeur = '20' where cle = 'audit_max_jour';

commit;

-- Vérification : tout à 0 sauf les données conservées
select 'objets' t, count(*) from pilotage.objets
union all select 'webhooks', count(*) from public.rivage_webhook_events
union all select 'alertes', count(*) from pilotage.alertes
union all select 'impayes (231 attendus)', count(*) from pilotage.impayes
union all select 'impayes_notes', count(*) from pilotage.impayes_notes
union all select 'membres', count(*) from pilotage.membres
union all select 'regles', count(*) from pilotage.regles
union all select 'communes confirmees (4)', count(*) from pilotage.permis_communes
union all select 'taches pilotage actives (0 attendu)', count(*) from cron.job where jobname like 'pilotage-%' and active;
