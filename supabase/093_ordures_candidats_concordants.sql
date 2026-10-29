-- 093 — Ordures ménagères des lots restés « à trancher » quand les biens WeRoof candidats concordent (Nicolas, 29/10/2026).
-- Situation au 29/10, 14 h 40 : 339 rapprochements validés, ordures reprises pour 173 lots ; 29 lots restent à trancher
-- (plusieurs candidats ou concordance faible). Parmi eux, 13 ont au moins un candidat renseigné et aucun candidat divergent
-- (12 taxe foncière, 1 organisme externe). Le choix taxe / redevance se fait en général pour toute la commune, et tous les
-- candidats d'un lot sont à la même adresse : la réponse est reprise sans choisir le bien (source « weroof », modifiable dans
-- le contrôle d'entrée). Aucun rapprochement n'est validé par ce script. Les 16 autres lots (WeRoof ne dit rien) restent sans réponse.
-- La page « Rapprochement WeRoof » est retirée du menu (PR 093) ; les tables et fonctions du 092 restent, la question
-- « ordures ménagères » du contrôle d'entrée continue d'afficher la proposition WeRoof des lots rapprochés.
-- Retour arrière : delete from pilotage.lots_ordures where source = 'weroof' and le >= '<date de passage>' and par is null.
-- Un seul bloc.

begin;

insert into pilotage.lots_ordures (asset_id, mode, organisme_id, source, par, le)
select p.asset_id, max(b.teom_mode), max(o.id), 'weroof', null, now()
  from pilotage.weroof_rapprochements p
  join public.biens b on b.id = p.bien_id
  left join pilotage.organismes_ordures o on o.weroof_id = b.organisme_teom_id and b.teom_mode = 'organisme_externe'
 where p.statut = 'propose'
   and not exists (select 1 from pilotage.lots_ordures lo where lo.asset_id = p.asset_id)
 group by p.asset_id
having count(b.teom_mode) filter (where b.teom_mode in ('taxe_fonciere', 'organisme_externe')) > 0
   and count(distinct b.teom_mode) filter (where b.teom_mode in ('taxe_fonciere', 'organisme_externe')) = 1
   and (max(b.teom_mode) = 'taxe_fonciere'
        or (count(distinct o.id) = 1 and count(distinct b.organisme_teom_id) filter (where b.teom_mode = 'organisme_externe') = 1));

commit;

-- Vérification : doit renvoyer 13 (lots repris par ce script)
-- select count(*) from pilotage.lots_ordures where source = 'weroof' and par is null;
