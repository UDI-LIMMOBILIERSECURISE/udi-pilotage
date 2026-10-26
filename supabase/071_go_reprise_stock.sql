-- 071 — GO de reprise sur les mandats du stock de production (décision de Nicolas du 26/10 : « un GO partout »).
-- Les mandats commencés depuis le 01/01/2026 entrent dans le suivi des commissions ; aucun GO n'existait pour eux
-- dans le pilotage après la bascule, d'où « 42 mandats loués sans GO ». GO posé sur les 88 mandats de 2026 sans GO,
-- loués ou non, au nom de Nicolas, avec la note qui le justifie (forçage tracé, règle des forçages Nicolas/Romain).
-- Effet sur les commissions : le 2e versement (25 %) devient dû au GO, mais seulement si un négociateur est attribué
-- au mandat ; aujourd'hui aucun ne l'est (reprise), donc aucun versement ne devient dû tant qu'on n'attribue pas.

begin;

insert into pilotage.mandats_suivi (mandat_id, go_le, go_par, note, maj_par)
select m.id, current_date, n.user_id,
       'GO de reprise posé à la bascule sur le compte Rivage de production (26/10/2026), dossier antérieur au pilotage',
       n.user_id
from pilotage.v_mandats m
cross join (select user_id from pilotage.membres where prenom = 'Nicolas' and role = 'direction' limit 1) n
where m.debut >= date '2026-01-01'
on conflict (mandat_id) do update
  set go_le = excluded.go_le, go_par = excluded.go_par,
      note = coalesce(pilotage.mandats_suivi.note || E'\n', '') || excluded.note,
      maj_par = excluded.maj_par, maj_le = now()
  where pilotage.mandats_suivi.go_le is null;

-- Passage de synchronisation de 13 h 44 (ancienne version de la fonction), coupé sans clôture
update pilotage.syncs set fin = now(), erreur = 'Interrompue par la limite de temps de la fonction (ancienne version)'
where fin is null and debut < now() - interval '10 minutes';

commit;

select count(*) mandats_2026,
       count(*) filter (where s.go_le is not null) avec_go,
       count(*) filter (where pilotage.bail_location(m.id) is not null and s.go_le is null) loues_sans_go
from pilotage.v_mandats m left join pilotage.mandats_suivi s on s.mandat_id = m.id
where m.debut >= date '2026-01-01';
