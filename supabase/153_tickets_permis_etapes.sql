-- 153 : étapes d'un ticket PL / DMEL lues dans le suivi du permis de louer, plus dans les interventions (décision de Nicolas du 12/11/2026)
--  Constat : ticket n°51 « DMEL » (lot 428) affiché « Devis à demander » parce que le service permis de louer de Corbeil y est
--  désigné comme intervenant (demande de devis en attente). Un ticket tagué PL ou DMEL (et ni Sinistre ni Travaux) suit maintenant
--  la demande du lot dans pilotage.permis_demandes (fiche du lot, Permis de louer) :
--   - déclaration (DMEL) : dossier à déposer → déposée, récépissé attendu (7 j) → récépissé reçu, ticket à clôturer dans Rivage ;
--   - autorisation (PL) : dossier à déposer → déposée, réponse attendue (21 j ; accord tacite à constater après 1 mois)
--     → accord tacite, attestation à obtenir → permis obtenu, ticket à clôturer ; refus : prévenir le bailleur.
--  Les relances « ticket sans changement » restent réservées aux tickets Sinistre et Travaux ; le permis garde ses alertes (052, 132).
--  Bloc unique.

begin;

create or replace function pilotage.ticket_suivi()
 returns table(ticket_id text, numero text, titre text, asset_id text, mandat_id text, bail_id text, tags text[], sinistre boolean, travaux boolean, permis boolean, a_facturer boolean, occupation text, etape text, etape_libelle text, action text, depuis date, delai integer, ouvres boolean, retard integer, statut_rivage text)
 language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with t as (
    select i.id, i.data, pilotage.ticket_tags(i.data) tg
      from pilotage.objets i
     where i.type = 'Incident' and i.supprime_le is null and i.data->>'status' in ('open', 'in_progress')
  ), e as (
    select t.*, x.v, p.dem,
      ('pl' = any(t.tg) or 'dmel' = any(t.tg)) and not ('sinistre' = any(t.tg) or 'travaux' = any(t.tg)) est_permis,
      case
        -- 153 : ticket PL / DMEL : demande du lot dans le suivi du permis
        when ('pl' = any(t.tg) or 'dmel' = any(t.tg)) and not ('sinistre' = any(t.tg) or 'travaux' = any(t.tg)) then
          case when p.dem is null or (p.dem->>'depot_le') is null then 'permis_a_deposer'
               when p.dem->>'reponse' = 'refus' then 'permis_refuse'
               when p.dem->>'regime' = 'declaration' and (p.dem->>'recepisse_le') is null then 'recepisse_attendu'
               when p.dem->>'regime' = 'declaration' then 'permis_termine'
               when (p.dem->>'reponse') is null then 'reponse_attendue'
               when p.dem->>'reponse' = 'tacite' and (p.dem->>'attestation_recue_le') is null then 'attestation_attendue'
               else 'permis_termine' end
        when x.v is null then 'declare'
        when x.v->>'status' = 'estimate_request_pending' then 'devis_a_demander'
        when x.v->>'status' = 'estimate_requested' then 'devis_demande'
        when x.v->>'status' = 'selected' then 'devis_accepte'
        when x.v->>'status' = 'scheduled' and (x.v->>'scheduled_end_at')::date < current_date then 'fin_depassee'
        when x.v->>'status' = 'scheduled' and (x.v->>'scheduled_start_at')::date <= current_date then 'en_cours'
        when x.v->>'status' = 'scheduled' then 'planifie'
        when x.v->>'status' = 'done' and jsonb_array_length(case when jsonb_typeof(x.v->'invoice_ids') = 'array' then x.v->'invoice_ids' else '[]'::jsonb end) = 0 then 'fait'
        when x.v->>'status' = 'done' then 'facture'
        else 'declare' end etape
    from t
    left join lateral (
      select v from jsonb_array_elements(case when jsonb_typeof(t.data->'interventions') = 'array' then t.data->'interventions' else '[]'::jsonb end) v
       where coalesce(v->>'status', '') not in ('cancelled', 'canceled', 'rejected', 'refused')
       order by array_position(array['estimate_request_pending', 'estimate_requested', 'selected', 'scheduled', 'done'], v->>'status') desc nulls last,
                v->>'updated_at' desc nulls last
       limit 1) x on true
    left join lateral (
      select to_jsonb(d) dem from pilotage.permis_demandes d
       where d.asset_id = t.data->>'asset_id' and d.close_le is null
       order by d.cree_le desc limit 1) p on true
  ), d as (
    select e.*,
      case e.etape when 'declare' then 'Déclaré' when 'devis_a_demander' then 'Devis à demander' when 'devis_demande' then 'Devis demandé'
        when 'devis_accepte' then 'Devis accepté' when 'planifie' then 'Travaux planifiés' when 'en_cours' then 'Travaux en cours'
        when 'fin_depassee' then 'Travaux en cours, fin prévue dépassée' when 'fait' then 'Travaux faits' when 'facture' then 'Facturé'
        when 'permis_a_deposer' then 'Dossier à déposer en mairie'
        when 'recepisse_attendu' then 'Déclaration déposée le ' || to_char((e.dem->>'depot_le')::date, 'DD/MM/YYYY') || ', récépissé attendu'
        when 'reponse_attendue' then 'Demande déposée le ' || to_char((e.dem->>'depot_le')::date, 'DD/MM/YYYY') || ', réponse de la mairie attendue'
        when 'attestation_attendue' then 'Accord tacite, attestation à obtenir'
        when 'permis_refuse' then 'Permis de louer refusé'
        when 'permis_termine' then case when e.dem->>'regime' = 'declaration' then 'Récépissé reçu' else 'Permis de louer obtenu' end end lib,
      case e.etape when 'declare' then 'Missionner un artisan' when 'devis_a_demander' then 'Demander le devis à l''artisan'
        when 'devis_demande' then 'Relancer l''artisan pour le devis' when 'devis_accepte' then 'Planifier les travaux avec l''artisan'
        when 'fin_depassee' then 'Vérifier avec l''artisan que les travaux sont faits' when 'fait' then 'Récupérer la facture de l''artisan'
        when 'facture' then 'Clôturer le ticket dans Rivage'
        when 'permis_a_deposer' then case when 'pl' = any(e.tg) then 'Déposer la demande de permis de louer' else 'Déposer la déclaration de mise en location' end
                                     || ' et noter le dépôt dans la fiche du lot (Permis de louer)'
        when 'recepisse_attendu' then 'Relancer la mairie pour le récépissé, puis le noter dans la fiche du lot'
        when 'reponse_attendue' then case when current_date - (e.dem->>'depot_le')::date >= 30 then 'Constater l''accord tacite et demander l''attestation à la mairie'
                                          else 'Relancer la mairie si pas de réponse' end
        when 'attestation_attendue' then 'Relancer la mairie pour l''attestation d''accord tacite'
        when 'permis_refuse' then 'Prévenir le bailleur et voir avec lui les travaux demandés'
        when 'permis_termine' then 'Clôturer le ticket dans Rivage' end act,
      case e.etape when 'declare' then coalesce(e.data->>'declared_at', e.data->>'created_at')::date
        when 'fin_depassee' then (e.v->>'scheduled_end_at')::date
        when 'planifie' then null when 'en_cours' then null
        when 'permis_a_deposer' then coalesce(e.data->>'declared_at', e.data->>'created_at')::date
        when 'recepisse_attendu' then (e.dem->>'depot_le')::date
        when 'reponse_attendue' then (e.dem->>'depot_le')::date
        when 'attestation_attendue' then coalesce((e.dem->>'attestation_demandee_le')::date, (e.dem->>'reponse_le')::date)
        when 'permis_refuse' then (e.dem->>'reponse_le')::date
        when 'permis_termine' then coalesce((e.dem->>'recepisse_le')::date, (e.dem->>'attestation_recue_le')::date, (e.dem->>'reponse_le')::date)
        else coalesce(e.v->>'updated_at', e.v->>'created_at', e.data->>'updated_at')::date end dep,
      case e.etape when 'declare' then pilotage.param('ticket_relance', 'j_declare', 2)
        when 'devis_a_demander' then pilotage.param('ticket_relance', 'j_devis_a_demander', 2)
        when 'devis_demande' then pilotage.param('ticket_relance', 'j_devis_demande', 7)
        when 'devis_accepte' then pilotage.param('ticket_relance', 'j_devis_accepte', 5)
        when 'fin_depassee' then pilotage.param('ticket_relance', 'j_fin_depassee', 1)
        when 'fait' then pilotage.param('ticket_relance', 'j_facture', 15)
        when 'facture' then pilotage.param('ticket_relance', 'j_cloture', 15)
        when 'permis_a_deposer' then 2 when 'recepisse_attendu' then 7 when 'reponse_attendue' then 21
        when 'attestation_attendue' then 15 when 'permis_refuse' then 2 when 'permis_termine' then 7 end::int del,
      e.etape in ('declare', 'devis_a_demander', 'permis_a_deposer') ouv
    from e
  )
  select d.id, d.data->>'number', d.data->>'title', d.data->>'asset_id', pilotage.mandat_de('Incident', d.id), d.data->>'leasing_contract_id', d.tg,
    'sinistre' = any(d.tg), 'travaux' = any(d.tg), ('pl' = any(d.tg) or 'dmel' = any(d.tg)), 'a facturer' = any(d.tg),
    case when 'logement occupe' = any(d.tg) then 'occupé' when 'logement vide' = any(d.tg) then 'vide' end,
    d.etape, d.lib, d.act, d.dep, d.del, d.ouv,
    case when d.dep is null or d.del is null then null
         when d.ouv then pilotage.jours_ouvres(d.dep, current_date) - d.del
         else (current_date - d.dep) - d.del end,
    d.data->>'status'
  from d
$$;
revoke all on function pilotage.ticket_suivi() from public, anon, authenticated;

commit;

-- Vérification : select numero, etape, etape_libelle, action from pilotage.ticket_suivi() where permis;
