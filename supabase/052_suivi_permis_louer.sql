-- 052 : suivi d'ensemble du permis de louer (onglet À louer)
-- Jusqu'ici, les demandes d'autorisation préalable et les déclarations de mise en location ne se suivaient que lot par lot,
-- dans la fiche du mandat (038). Cette fonction rassemble tous les logements gérés soumis (ou peut-être soumis) au permis
-- de louer, avec l'état de leur démarche et la prochaine action :
--   autorisation préalable (logement loué : à demander au prochain départ) : à demander → déposée (relance à 21 jours) → accord tacite à 1 mois sans réponse
--     (attestation à demander à la mairie) → accordée / refusée ; l'autorisation devient caduque 2 ans après
--     si aucun bail n'est signé ;
--   déclaration de mise en location : à faire dans les 15 jours de la signature du bail ;
--   commune non vérifiée ou adresse à vérifier : à trancher par la gestion (table des communes).
-- Lecture pour tous les membres ; les actions passent par pilotage_permis_action (038), qui garde ses propres droits.
-- À passer après le 051.

create or replace function public.pilotage_permis_suivi() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((
    select jsonb_agg(x order by (x->>'ordre')::int, x->>'echeance' nulls last, x->>'lot')
    from (
      select jsonb_build_object(
        'asset_id', l.id, 'lot', l.reference, 'adresse', l.adresse, 'nature', l.nature,
        'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
        'mandat_id', l.mandat_id, 'bailleur', pilotage.bailleurs_mandat(l.mandat_id),
        'a_louer', exists (select 1 from pilotage.lots_a_louer a where a.asset_id = l.id and a.sorti_le is null),
        'permis', p.reg,
        'demandes', coalesce((select jsonb_agg(to_jsonb(d) - 'par' order by d.depot_le desc) from pilotage.permis_demandes d where d.asset_id = l.id), '[]'::jsonb),
        'bail', case when b.id is not null then jsonb_build_object('id', b.id, 'reference', b.reference, 'signe_le', coalesce(b.signe_le, b.debut), 'locataires', b.locataires) end,
        'peut', pilotage.peut_traiter_lot(l.id),
        'etat', e.etat, 'gravite', e.gravite, 'action', e.action, 'echeance', e.echeance, 'ordre', e.ordre
      ) x
      from pilotage.v_lots l
      cross join lateral (select pilotage.permis_lot(l.id) reg) p
      -- bail en cours ou à venir le plus récent du lot
      left join lateral (select vb.* from pilotage.v_baux vb where vb.lot_id = l.id and vb.statut in ('created', 'move_in', 'in_progress')
                         order by coalesce(vb.signe_le, vb.debut) desc nulls last limit 1) b on true
      -- demande ouverte (non close) la plus récente
      left join lateral (select d.* from pilotage.permis_demandes d where d.asset_id = l.id and d.close_le is null order by d.depot_le desc limit 1) o on true
      cross join lateral (
          select
            case
              when p.reg->>'regime' in ('inconnu', 'a_verifier') then 'Régime à vérifier'
              when p.reg->>'regime' = 'autorisation' and o.id is null and b.id is not null
                   and not exists (select 1 from pilotage.lots_a_louer a where a.asset_id = l.id and a.sorti_le is null)
                then 'À demander avant la prochaine location'
              when p.reg->>'regime' = 'autorisation' and o.id is null then 'Autorisation à demander'
              when p.reg->>'regime' = 'autorisation' and o.reponse is null and current_date - o.depot_le >= 30 then 'Accord tacite à constater'
              when p.reg->>'regime' = 'autorisation' and o.reponse is null and current_date - o.depot_le >= 21 then 'Relancer la mairie'
              when p.reg->>'regime' = 'autorisation' and o.reponse is null then 'Demande déposée'
              when o.reponse = 'refus' then 'Autorisation refusée'
              when o.reponse = 'tacite' and o.attestation_recue_le is null then 'Attestation d''accord tacite à obtenir'
              when o.reponse in ('accord', 'tacite') and b.id is null and o.reponse_le + interval '2 years' < current_date then 'Autorisation caduque'
              when o.reponse in ('accord', 'tacite') then 'Autorisation obtenue'
              when p.reg->>'regime' = 'declaration' and b.id is null then 'Déclaration à faire à la signature du bail'
              when p.reg->>'regime' = 'declaration' and o.id is not null and o.depot_le >= coalesce(b.signe_le, b.debut) - 30 then 'Déclaration faite'
              when p.reg->>'regime' = 'declaration' then 'Déclaration à faire'
              else 'Suivi'
            end etat,
            case
              when p.reg->>'regime' = 'declaration' and b.id is not null and not (o.id is not null and o.depot_le >= coalesce(b.signe_le, b.debut) - 30)
                then (coalesce(b.signe_le, b.debut) + 15)
              when p.reg->>'regime' = 'autorisation' and o.id is not null and o.reponse is null then o.depot_le + 30
              when o.reponse in ('accord', 'tacite') and b.id is null then (o.reponse_le + interval '2 years')::date
            end echeance
      ) e0
      cross join lateral (
        select e0.etat,
          case e0.etat
            when 'Autorisation à demander' then case when exists (select 1 from pilotage.lots_a_louer a where a.asset_id = l.id and a.sorti_le is null) then 'critique' else 'haute' end
            when 'Déclaration à faire' then case when e0.echeance < current_date then 'critique' else 'haute' end
            when 'Autorisation refusée' then 'critique'
            when 'Autorisation caduque' then 'critique'
            when 'Relancer la mairie' then 'haute'
            when 'Accord tacite à constater' then 'haute'
            when 'Attestation d''accord tacite à obtenir' then 'haute'
            when 'Régime à vérifier' then 'haute'
            else 'normale' end gravite,
          case e0.etat
            when 'Autorisation à demander' then 'Déposer le Cerfa 15652 et les pièces en mairie, avant toute mise en location.'
            when 'Demande déposée' then 'Attendre la réponse ; relance à 21 jours, accord tacite à 1 mois.'
            when 'Relancer la mairie' then 'Relancer la mairie : sans réponse dans le mois du dépôt, l''accord est tacite.'
            when 'Accord tacite à constater' then 'Enregistrer l''accord tacite et demander l''attestation à la mairie.'
            when 'Attestation d''accord tacite à obtenir' then 'Obtenir l''attestation de la mairie (à joindre au bail).'
            when 'Autorisation refusée' then 'Ne pas louer : informer le bailleur des travaux demandés par la mairie.'
            when 'Autorisation caduque' then 'Aucun bail signé dans les 2 ans : nouvelle demande à déposer.'
            when 'Déclaration à faire' then 'Déposer le Cerfa 15651 dans les 15 jours de la signature du bail.'
            when 'Déclaration à faire à la signature du bail' then 'À déposer dans les 15 jours de la signature du prochain bail.'
            when 'À demander avant la prochaine location' then 'Logement loué : la demande sera à déposer dès son retour à la location.'
            when 'Régime à vérifier' then 'Confirmer le régime de la commune dans la table des communes ci-dessous.'
            else null end action,
          e0.echeance,
          case when e0.etat in ('Autorisation à demander', 'Déclaration à faire', 'Autorisation refusée', 'Autorisation caduque') then 1
               when e0.etat in ('Relancer la mairie', 'Accord tacite à constater', 'Attestation d''accord tacite à obtenir', 'Régime à vérifier') then 2
               when e0.etat in ('Demande déposée', 'Déclaration à faire à la signature du bail', 'À demander avant la prochaine location') then 3 else 4 end ordre
      ) e
      where l.mandat_id is not null and l.nature in ('flat', 'room', 'house')
        and (p.reg->>'regime' in ('autorisation', 'declaration', 'a_verifier', 'inconnu')
             or exists (select 1 from pilotage.permis_demandes d where d.asset_id = l.id))
    ) t
  ), '[]'::jsonb);
end $$;

revoke all on function public.pilotage_permis_suivi() from public, anon;
grant execute on function public.pilotage_permis_suivi() to authenticated;

-- Contrôle : nombre de logements suivis par état (vide sur le compte de test si aucune commune n'est soumise)
select pilotage.permis_lot(l.id)->>'regime' regime, count(*) from pilotage.v_lots l
where l.mandat_id is not null and l.nature in ('flat', 'room', 'house') group by 1;
