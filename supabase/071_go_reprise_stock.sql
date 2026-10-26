-- 071 — GO de reprise et attribution à Mathilde des mandats du stock de production (décisions de Nicolas du 26/10 :
-- « un GO partout » ; « attribue tout à Mathilde sauf Fleurs de Blé Noir »).
-- Les mandats commencés depuis le 01/01/2026 entrent dans le suivi des commissions ; aucun GO n'existait pour eux
-- dans le pilotage après la bascule, d'où « 42 mandats loués sans GO ». GO posé sur les 88 mandats de 2026 sans GO,
-- loués ou non, au nom de Nicolas, avec la note qui le justifie (forçage tracé, règle des forçages Nicolas/Romain).
-- Négociateur : Mathilde sur les mandats de 2026 (suivi des commissions), sauf les deux mandats de la SCI Fleurs de Blé
-- Noir (n° 388 et 391), production de la direction non commissionnée.
-- Effet sur les commissions : GO + négociateur rendent dus dans le pilotage le 1er versement (50 %) et le 2e (25 %) de ces
-- mandats, puis le 3e à la validation du bail. Les versements déjà payés hors pilotage sont à marquer comme facturés.

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

-- Négociateur : Mathilde, sauf SCI Fleurs de Blé Noir ; un négociateur déjà attribué n'est pas remplacé
update pilotage.mandats_suivi s
set negociateur = (select user_id from pilotage.membres where prenom = 'Mathilde' and role = 'negociateur' limit 1),
    note = s.note || E'\nNégociateur attribué à la reprise (26/10/2026) : Mathilde', maj_le = now()
from pilotage.v_mandats m
where m.id = s.mandat_id and m.debut >= date '2026-01-01' and s.negociateur is null
  and pilotage.bailleurs_mandat(m.id)::text not ilike '%fleurs de ble noir%';

-- Passage de synchronisation de 13 h 44 (ancienne version de la fonction), coupé sans clôture
update pilotage.syncs set fin = now(), erreur = 'Interrompue par la limite de temps de la fonction (ancienne version)'
where fin is null and debut < now() - interval '10 minutes';

commit;

select count(*) mandats_2026,
       count(*) filter (where s.go_le is not null) avec_go,
       count(*) filter (where pilotage.bail_location(m.id) is not null and s.go_le is null) loues_sans_go,
       count(*) filter (where s.negociateur is not null) attribues_mathilde,
       string_agg(m.reference, ', ') filter (where s.negociateur is null) non_attribues
from pilotage.v_mandats m left join pilotage.mandats_suivi s on s.mandat_id = m.id
where m.debut >= date '2026-01-01';
