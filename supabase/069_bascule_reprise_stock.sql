-- 069 — Bascule : le contenu du compte de production devient « stock repris », puis remise en route des tâches.
-- À passer UNIQUEMENT après la synchronisation complète du compte de production (bouton « Mettre à jour maintenant »)
-- et sa vérification (nombre de baux, mandats, lots, pièces conforme à Rivage).
--
-- Pourquoi : la date d'arrivée d'un objet (recu_le) vaut l'heure de son entrée dans le pilotage. Après la
-- synchronisation, tous les baux, mandats et pièces de production auraient la date du jour : ils entreraient
-- tous dans le contrôle d'entrée et dans la lecture IA « dès l'arrivée », contrairement à la règle
-- « pas de circuit bloquant pour le stock repris ». On les date donc comme le stock (même convention que 058 : -infinity).
-- Ce qui arrivera ensuite par webhook ou par synchronisation gardera sa vraie date d'arrivée.
-- Les mandats signés et les baux commencés depuis controle_entree_depuis restent contrôlés (critère de date propre).
--
-- GED pas encore chargée dans Rivage (décision du 26/10) : les pièces du stock arriveront plus tard, par webhook, avec
-- la date du jour. La lecture IA les prendrait pour des pièces nouvelles et lirait tout le stock. Les quatre tâches de
-- lecture IA (baux, mandats, EDL, justificatifs) restent donc en pause jusqu'au chargement complet de la GED ;
-- un script suivant datera alors ces pièces comme stock et relancera la lecture.

begin;

update pilotage.objets set recu_le = '-infinity' where recu_le > '-infinity';

select jobname, cron.alter_job(jobid, active := true) from cron.job
where jobname like 'pilotage-%'
  and jobname not in ('pilotage-lecture-baux', 'pilotage-lecture-mandats', 'pilotage-lecture-edl', 'pilotage-lecture-justificatifs');

commit;

-- Vérification
select type, count(*) n, count(*) filter (where recu_le > '-infinity') recus_apres_reprise
from pilotage.objets where supprime_le is null group by type order by type;

-- Tâches encore en pause (4 lectures IA attendues)
select jobname from cron.job where jobname like 'pilotage-%' and not active order by jobname;

-- Lecture IA qui partirait d'office si on la relançait aujourd'hui (pour information)
select jsonb_array_length(public.pilotage_baux_a_lire(1000)) baux_a_lire,
       jsonb_array_length(public.pilotage_mandats_a_lire(1000)) mandats_a_lire;
