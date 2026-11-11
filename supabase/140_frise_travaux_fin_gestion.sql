-- 140 : frise du bien complétée (bloc unique, après le 139)
--  Décisions de Nicolas du 11/11/2026 :
--   - après la sortie du locataire, trois suites : travaux avant relocation, mise en location, fin de gestion. Relouer et fin de
--     gestion ne sont pas le même état ;
--   - « Travaux avant relocation » : phase propre, quand le lot est libre (locataire parti, pas de nouveau bail commencé) et qu'un ticket
--     Rivage ouvert du lot est tagué Travaux. Étapes lues sur l'intervention (devis demandé, devis accepté, planifié, en cours, faits).
--     La phase se termine quand le ticket est clos dans Rivage ou l'intervention faite ; le lot peut être mis « À louer » pendant les
--     travaux (visites et bail avant la fin du chantier) ;
--   - « Fin de gestion » : phase d'arrivée dès qu'une résiliation du mandat est programmée dans Rivage, même si le locataire est encore
--     dans les lieux (vente occupée). Résiliation enregistrée → fin de gestion (clés, documents, dernier compte rendu) → résiliation
--     passée en « effective » dans Rivage (le lot sort alors de la gestion) ;
--   - sortie alignée : congé reçu → EDL de sortie → départ → dépôt de garantie restitué (comptabilité, 1 mois après le départ ; lu
--     dans la compta Rivage) → bail clos dans Rivage. Les clés ne sont plus une étape : rappel à part (139) ;
--   - la suite prévue est affichée pendant la sortie (fiche congé « relouer » ou « vente », lot déjà « À louer », résiliation).
--  Nouvelle fonction pilotage_bien(lot) pour la fiche du bien : tickets du lot avec leur étape, impayé, assurance du locataire,
--  données à corriger. Lecture seule, rien n'est écrit dans Rivage.

create or replace function pilotage.biens(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare j date := current_date; lots jsonb; mon_role text := (select m.role from pilotage.membres m where m.user_id = p_user and m.actif);
begin
  with lot as (
    select a.id, a.data->>'reference' reference, a.data->>'nature' nature,
           concat_ws(' ', a.data->'address'->>'number', a.data->'address'->>'street', a.data->'address'->>'zip_code', a.data->'address'->>'city') adresse,
           a.data->>'management_contract_id' mandat_id, m.data->>'status' mstatut, m.data->>'reference' mref,
           (m.data->>'signed_at')::date msigne, (m.data->>'start_date')::date mdebut,
           s.negociateur, s.valide_le, s.valide_par, s.go_le, s.retire_le
      from pilotage.objets a
      join pilotage.objets m on m.type = 'ManagementContract' and m.id = a.data->>'management_contract_id' and m.supprime_le is null
      left join pilotage.mandats_suivi s on s.mandat_id = m.id
     where a.type = 'Asset' and a.supprime_le is null
  ), resil as (   -- résiliations du mandat ou du lot (hors annulées), la plus proche
    select distinct on (l.id) l.id lot_id, t.data->>'status' tstatut, (t.data->>'termination_date')::date tdate, (t.data->>'created_at')::date tcree
      from lot l join pilotage.objets t on t.type = 'ManagementTermination' and t.supprime_le is null and t.data->>'status' in ('scheduled', 'effective')
       and (coalesce(t.data->'asset_ids', '[]'::jsonb) ? l.id or coalesce(t.data->'management_contract_ids', '[]'::jsonb) ? l.mandat_id)
     order by l.id, (t.data->>'status' = 'effective') desc, (t.data->>'termination_date')::date
  ), trav as materialized (   -- 140 : ticket Travaux ouvert du lot (le plus récent)
    select distinct on (s.asset_id) s.asset_id, s.ticket_id, s.numero, s.etape, s.action, s.retard
      from pilotage.ticket_suivi() s where s.travaux and s.asset_id is not null
     order by s.asset_id, s.numero desc
  ), b as materialized (
    select l.id lot_id,
      (select x from pilotage.v_baux x where x.lot_id = l.id and x.statut in ('created', 'move_in', 'in_progress') and (x.fin is null or x.fin > j)
        order by x.debut desc nulls last limit 1) actif,
      (select x from pilotage.v_baux x where x.lot_id = l.id and x.statut = 'move_out' and (x.fin is null or x.fin >= j - 60)
        order by x.fin nulls first limit 1) conge,
      (select count(*) from pilotage.v_baux x where x.lot_id = l.id and x.statut = 'move_out' and x.fin < j - 60) bloques,
      (select max(x.fin) from pilotage.v_baux x where x.lot_id = l.id and x.fin <= j) libre_depuis,
      (select al.depuis from pilotage.lots_a_louer al where al.asset_id = l.id and al.sorti_le is null) en_location,
      (select al.disponible_le from pilotage.lots_a_louer al where al.asset_id = l.id and al.sorti_le is null) disponible
    from lot l
  ), p as materialized (
    select l.*, b.actif, b.conge, b.bloques, b.libre_depuis, b.en_location, b.disponible, r.tstatut, r.tdate, r.tcree,
      t.ticket_id trav_id, t.numero trav_num, t.etape trav_etape, t.action trav_action, t.retard trav_retard,
      case when l.mstatut = 'lost' or r.tstatut = 'effective' then 'hors'
           when r.tstatut = 'scheduled' then 'fin'
           when pilotage.dossier_nouveau('ManagementContract', l.mandat_id) and l.valide_le is null and l.retire_le is null then 'entree'
           -- travaux avant relocation : locataire parti (ou aucun), pas de nouveau bail commencé, ticket Travaux ouvert
           when t.ticket_id is not null and ((b.actif).id is null or (b.actif).debut > j) and ((b.conge).id is null or (b.conge).fin <= j)
                and t.etape not in ('fait', 'facture') then 'travaux'
           when (b.conge).id is not null and ((b.actif).id is null or (b.actif).debut > j) then 'sortie'
           when (b.actif).id is not null then 'bail'
           else 'location' end phase
    from lot l join b on b.lot_id = l.id left join resil r on r.lot_id = l.id left join trav t on t.asset_id = l.id
  ), q as (
    select p.*,
      case p.phase when 'sortie' then (p.conge).id when 'bail' then (p.actif).id when 'entree' then (p.actif).id
                   when 'fin' then coalesce((p.actif).id, (p.conge).id) end bail_id
    from p
  ), r2 as materialized (
    select q.*, bc.ligne bc, fc.recu_le conge_recu, fc.suite conge_suite, case when q.phase = 'sortie' then pilotage.edl_sortie_le(q.bail_id) end edl_sortie, ee.edl_le edl_entree,
      -- 137 : impayé = cycle d'impayé ouvert dans Rivage (le montant dû seul compte aussi le loyer du mois pas encore échu)
      exists (select 1 from pilotage.objets ra where ra.type = 'RentArrear' and ra.supprime_le is null and ra.id = q.bail_id and ra.data->'rent_arrear'->>'status' = 'opened') en_impaye,
      -- 140 : dépôt de garantie restitué, lu dans la compta Rivage
      case when q.phase = 'sortie' then exists (select 1 from pilotage.objets g where g.type = 'AccountingEventGroup' and g.supprime_le is null
          and g.data->>'nature' = 'refund_deposit' and g.data->>'leasing_contract_id' = q.bail_id and coalesce((g.data->>'deposit_refunded')::boolean, false)) end dg_rendu,
      case when q.phase = 'entree' then pilotage.etat_dossier('mandat', q.mandat_id) end em,
      case when q.phase = 'bail' and coalesce((bc.ligne->'controle'->>'soumis')::boolean, false) and bc.ligne->'controle'->>'go_le' is null
           then coalesce((pilotage.bail_restants(q.bail_id)->>'commercial')::int, 0) else 0 end restants_com,
      coalesce(case when q.phase in ('bail', 'sortie') then pilotage.commercial_dossier('bail', q.bail_id) end, q.negociateur) commercial,
      (select count(*) from pilotage.alertes al where al.statut = 'ouverte'
          and ((al.objet_type = 'LeasingContract' and al.objet_id in (select x.id from pilotage.v_baux x where x.lot_id = q.id))
               or (al.objet_type = 'ManagementContract' and al.objet_id = q.mandat_id))) alertes,
      (select count(*) from pilotage.alertes al where al.statut = 'ouverte' and p_user is not null
          and ((al.objet_type = 'LeasingContract' and al.objet_id in (select x.id from pilotage.v_baux x where x.lot_id = q.id))
               or (al.objet_type = 'ManagementContract' and al.objet_id = q.mandat_id))
          and pilotage.alerte_visible_objet(al.regle, coalesce(al.mandat_id, q.mandat_id), p_user, al.objet_type, al.objet_id)) alertes_moi
    from q
    left join pilotage.baux_cache bc on bc.bail_id = q.bail_id
    left join pilotage.fiches_conge fc on fc.bail_id = q.bail_id
    left join pilotage.edl_entree ee on ee.bail_id = q.bail_id
  ), e as materialized (
    select r2.*,
      case r2.phase
        when 'entree' then jsonb_build_array(
          jsonb_build_object('libelle', 'Mandat signé', 'etat', 'fait', 'date', coalesce(r2.msigne, r2.mdebut)),
          jsonb_build_object('libelle', 'Dossier complété par le commercial', 'qui', 'commercial', 'action', 'Compléter le dossier du mandat',
            'etat', case when r2.em->>'etat' = 'a_finaliser' then 'en_cours' else 'fait' end,
            'info', case when r2.em->>'etat' = 'a_finaliser' then coalesce(r2.em->>'restant', '?') || ' point(s) à traiter'
                         || case when jsonb_array_length(coalesce(r2.em->'vides', '[]'::jsonb)) > 0 then ', ' || jsonb_array_length(r2.em->'vides') || ' champ(s) vide(s) dans Rivage' else '' end end),
          jsonb_build_object('libelle', 'Validé par la gestion', 'qui', 'gestion', 'action', 'Vérifier et valider le dossier du mandat', 'etat', case when r2.em->>'etat' = 'en_attente' then 'en_cours' else 'a_venir' end),
          jsonb_build_object('libelle', 'GO de la rémunération', 'qui', 'direction', 'action', 'Valider la rémunération', 'etat', case when r2.go_le is not null then 'fait' else 'a_venir' end, 'date', r2.go_le::date))
        when 'location' then jsonb_build_array(
          jsonb_build_object('libelle', 'Libre', 'etat', 'fait', 'date', coalesce(r2.libre_depuis, r2.mdebut)),
          jsonb_build_object('libelle', 'Mis en location', 'qui', 'gestion', 'action', 'Mettre le lot dans la liste « À louer »', 'etat', case when r2.en_location is not null then 'fait' else 'alerte' end,
            'date', r2.en_location, 'info', case when r2.disponible is not null then 'Disponible le ' || to_char(r2.disponible, 'DD/MM/YYYY') end),
          jsonb_build_object('libelle', 'Bail signé', 'qui', 'commercial', 'action', 'Trouver le locataire et faire signer le bail',
            'etat', case when r2.en_location is not null then 'en_cours' else 'a_venir' end))
        when 'travaux' then jsonb_build_array(
          jsonb_build_object('libelle', 'Lot libre', 'etat', 'fait', 'date', r2.libre_depuis),
          jsonb_build_object('libelle', 'Devis demandé', 'qui', 'gestion', 'action', r2.trav_action,
            'etat', case when r2.trav_etape in ('declare', 'devis_a_demander') then case when r2.trav_retard >= 0 then 'alerte' else 'en_cours' end else 'fait' end),
          jsonb_build_object('libelle', 'Devis accepté', 'qui', 'gestion', 'action', r2.trav_action,
            'etat', case when r2.trav_etape = 'devis_demande' then case when r2.trav_retard >= 0 then 'alerte' else 'en_cours' end
                         when r2.trav_etape in ('declare', 'devis_a_demander') then 'a_venir' else 'fait' end),
          jsonb_build_object('libelle', 'Travaux planifiés', 'qui', 'gestion', 'action', r2.trav_action,
            'etat', case when r2.trav_etape = 'devis_accepte' then case when r2.trav_retard >= 0 then 'alerte' else 'en_cours' end
                         when r2.trav_etape in ('planifie', 'en_cours', 'fin_depassee') then 'fait' else 'a_venir' end),
          jsonb_build_object('libelle', 'Travaux faits', 'qui', 'gestion', 'action', coalesce(r2.trav_action, 'Suivre les travaux'),
            'etat', case when r2.trav_etape = 'fin_depassee' then 'alerte' when r2.trav_etape in ('planifie', 'en_cours') then 'en_cours' else 'a_venir' end,
            'info', 'Ticket Rivage n°' || coalesce(r2.trav_num, '?') || case when r2.en_location is not null then ' · déjà en location' else '' end))
        when 'bail' then jsonb_build_array(
          jsonb_build_object('libelle', 'Bail signé', 'etat', 'fait', 'date', coalesce((r2.actif).signe_le, (r2.actif).debut)),
          case when coalesce((r2.bc->'controle'->>'soumis')::boolean, false) then
            jsonb_build_object('libelle', 'Contrôle d''entrée', 'etat', case when r2.bc->'controle'->>'go_le' is not null then 'fait' else 'en_cours' end,
              'qui', case when r2.bc->'controle'->>'go_le' is null and r2.restants_com > 0 then 'commercial' else 'gestion' end,
              'action', case when r2.bc->'controle'->>'go_le' is null and r2.restants_com > 0 then 'Compléter le contrôle d''entrée du bail' else 'Vérifier et donner le GO du contrôle d''entrée' end,
              'date', (r2.bc->'controle'->>'go_le')::timestamptz::date,
              'info', case when r2.bc->'controle'->>'go_le' is not null then 'GO par ' || coalesce(r2.bc->'controle'->>'go_par', '?')
                           when r2.restants_com > 0 then r2.restants_com || ' point(s) à traiter par le commercial'
                           else 'Tout est complété, en attente du GO de la gestion' end)
          else jsonb_build_object('libelle', 'Contrôle d''entrée', 'etat', 'fait', 'info', 'Stock repris') end,
          jsonb_build_object('libelle', 'Entrée du locataire et EDL', 'qui', 'commercial', 'action', 'Commander l''EDL d''entrée',
            'etat', case when (r2.actif).debut <= j then 'fait' when r2.edl_entree is null then 'en_cours' else 'a_venir' end,
            'date', (r2.actif).debut, 'info', case when r2.edl_entree is not null then 'EDL d''entrée le ' || to_char(r2.edl_entree, 'DD/MM/YYYY')
                                                   when (r2.actif).debut > j then 'EDL d''entrée pas encore planifié' end),
          jsonb_build_object('libelle', 'Bail en cours',
            'qui', case when r2.en_impaye then 'compta' end, 'action', case when r2.en_impaye then 'Suivre l''impayé' end,
            'etat', case when (r2.actif).debut > j then 'a_venir' when r2.en_impaye then 'alerte' else 'en_cours' end,
            'info', case when r2.en_impaye then 'Impayé : ' || replace(to_char((r2.actif).impaye, 'FM999999990.00'), '.', ',') || ' €' end))
        when 'sortie' then jsonb_build_array(
          jsonb_build_object('libelle', 'Congé reçu', 'etat', 'fait', 'date', r2.conge_recu),
          jsonb_build_object('libelle', 'EDL de sortie', 'qui', 'gestion', 'action', 'Planifier l''EDL de sortie',
            'etat', case when r2.edl_sortie <= j then 'fait' when r2.edl_sortie is not null then 'en_cours'
                         when (r2.conge).fin <= j + 15 then 'alerte' else 'en_cours' end,
            'date', r2.edl_sortie, 'info', case when r2.edl_sortie is null then 'À planifier' end),
          jsonb_build_object('libelle', 'Départ', 'etat', case when (r2.conge).fin <= j then 'fait' else 'a_venir' end, 'date', (r2.conge).fin),
          jsonb_build_object('libelle', 'Dépôt de garantie restitué', 'qui', 'compta', 'action', 'Restituer le dépôt de garantie ou justifier les retenues',
            'etat', case when coalesce((r2.conge).depot_garantie, 0) = 0 or r2.dg_rendu then 'fait'
                         when (r2.conge).fin > j then 'a_venir'
                         when (r2.conge).fin + 30 < j then 'alerte' else 'en_cours' end,
            'info', case when coalesce((r2.conge).depot_garantie, 0) = 0 then 'Pas de dépôt de garantie'
                         when not r2.dg_rendu and (r2.conge).fin <= j then 'Au plus tard le ' || to_char((r2.conge).fin + 30, 'DD/MM/YYYY') end),
          jsonb_build_object('libelle', 'Bail clos dans Rivage', 'qui', 'gestion', 'action', 'Faire clôturer le bail dans Rivage', 'etat', case when (r2.conge).fin < j then 'en_cours' else 'a_venir' end,
            'info', case when (r2.conge).fin < j then 'À clôturer dans Rivage' end))
        when 'fin' then jsonb_build_array(
          jsonb_build_object('libelle', 'Résiliation enregistrée', 'etat', 'fait', 'date', r2.tcree),
          jsonb_build_object('libelle', 'Fin de gestion', 'qui', 'gestion', 'action', 'Préparer la fin de gestion : clés, documents, dernier compte rendu au bailleur',
            'etat', case when r2.tdate <= j then 'fait' when r2.tdate <= j + 30 then 'en_cours' else 'a_venir' end, 'date', r2.tdate,
            'info', case when coalesce((r2.actif).id, (r2.conge).id) is not null then 'Locataire en place : ' || coalesce((r2.actif).locataires, (r2.conge).locataires) end),
          jsonb_build_object('libelle', 'Résiliation effective dans Rivage', 'qui', 'gestion', 'action', 'Passer la résiliation en « effective » dans Rivage',
            'etat', case when r2.tdate < j then 'alerte' else 'a_venir' end))
        else '[]'::jsonb end etapes
    from r2
  )
  , f as materialized (
    select e.*, (select min(i) - 1 from jsonb_array_elements(e.etapes) with ordinality t(x, i) where x->>'etat' <> 'fait') n_etape
    from e
  ), g as (
    select f.*, f.etapes->f.n_etape::int cour from f
  ), h as (
    select g.*,
      case when g.cour->>'qui' is null or g.cour->>'etat' = 'a_venir' then null
           else jsonb_build_object('qui', g.cour->>'qui', 'action', g.cour->>'action', 'urgent', g.cour->>'etat' = 'alerte',
             'prenom', case g.cour->>'qui' when 'commercial' then coalesce(pilotage.prenom_membre(g.commercial), 'commercial à attribuer')
                                          when 'gestion' then 'la gestion' when 'direction' then 'la direction' when 'compta' then 'la comptabilité' end) end a_faire
    from g
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'lot', e.reference, 'nature', e.nature, 'adresse', e.adresse,
      'mandat_id', e.mandat_id, 'mandat', e.mref, 'bailleur', pilotage.bailleurs_mandat(e.mandat_id),
      'phase', e.phase, 'etapes', e.etapes,
      'etape', e.n_etape, 'a_faire', e.a_faire,
      'bail_id', e.bail_id,
      'bail', case when e.phase = 'sortie' then (e.conge).reference else coalesce((e.actif).reference, (e.conge).reference) end,
      'locataires', case when e.phase = 'sortie' then (e.conge).locataires else coalesce((e.actif).locataires, (e.conge).locataires) end,
      'depart', case when e.phase = 'sortie' then (e.conge).fin end,
      'commercial', pilotage.prenom_membre(e.commercial),
      'fin_gestion', case when e.tstatut = 'scheduled' then e.tdate end,
      'ticket_travaux', e.trav_id,
      -- 140 : suite prévue après la sortie (relouer, travaux, vente, fin de gestion)
      'suite', case when e.phase in ('sortie', 'travaux') then
          case when (e.actif).id is not null then 'Reloué, entrée le ' || to_char((e.actif).debut, 'DD/MM/YYYY')
               when e.phase = 'sortie' and e.trav_id is not null then 'Travaux avant relocation (ticket n°' || coalesce(e.trav_num, '?') || ')'
               when e.en_location is not null then 'En location depuis le ' || to_char(e.en_location, 'DD/MM/YYYY')
               when e.conge_suite = 'relouer' then 'À relouer'
               when e.conge_suite = 'vente' then 'Vente annoncée par le bailleur' end end,
      'relocation', case when e.phase = 'sortie' then
          case when (e.actif).id is not null then 'Reloué, entrée le ' || to_char((e.actif).debut, 'DD/MM/YYYY')
               when e.en_location is not null then 'En relocation' end end,
      'en_location', e.en_location,
      'a_cloturer', e.bloques,
      'alertes', e.alertes, 'alertes_moi', e.alertes_moi,
      -- 137 : « À moi » = l'étape en cours m'appartient (commercial du dossier, gestionnaire, direction, comptable)
      'a_moi', p_user is not null and e.phase <> 'hors' and e.a_faire is not null and case e.a_faire->>'qui'
          when 'commercial' then e.commercial = p_user
          when 'gestion' then mon_role = 'gestionnaire'
          when 'direction' then mon_role = 'direction'
          when 'compta' then mon_role = 'comptable' else false end)
    order by array_position(array['entree', 'sortie', 'travaux', 'location', 'bail', 'fin', 'hors'], e.phase), e.adresse), '[]'::jsonb)
    into lots from h e;
  return lots;
end $$;
revoke all on function pilotage.biens(uuid) from public, anon, authenticated;

-- Fiche du bien : dossiers ouverts du lot (tickets avec leur étape, impayé, assurance du locataire, données à corriger)
create or replace function public.pilotage_bien(p_asset text)
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare bail text;
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  select x.id into bail from pilotage.v_baux x where x.lot_id = p_asset and x.statut in ('created', 'move_in', 'in_progress', 'move_out')
   order by (x.statut = 'move_out'), x.debut desc nulls last limit 1;
  return jsonb_build_object(
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', s.ticket_id, 'numero', s.numero, 'titre', s.titre, 'tags', s.tags,
        'sinistre', s.sinistre, 'travaux', s.travaux, 'permis', s.permis, 'a_facturer', s.a_facturer, 'occupation', s.occupation,
        'etape', s.etape, 'etape_libelle', s.etape_libelle, 'action', s.action, 'depuis', s.depuis, 'retard', s.retard,
        'lien', 'https://rivage.immo/incidents/' || s.ticket_id) order by s.numero desc)
      from pilotage.ticket_suivi() s where s.asset_id = p_asset or (s.asset_id is null and s.bail_id in (select x.id from pilotage.v_baux x where x.lot_id = p_asset))), '[]'::jsonb),
    'bail_id', bail,
    'impaye', (select jsonb_build_object('montant', (select x.impaye from pilotage.v_baux x where x.id = bail), 'depuis', (ra.data->'rent_arrear'->>'opened_at')::date)
                 from pilotage.objets ra where ra.type = 'RentArrear' and ra.supprime_le is null and ra.id = bail and ra.data->'rent_arrear'->>'status' = 'opened'),
    'assurance', (select jsonb_build_object('prochaine', o.prochaine, 'derniere_le', o.derniere_le)
                    from pilotage.baux_obligations o where o.bail_id = bail and o.nature = 'assurance' and o.actif order by o.prochaine limit 1),
    'donnees', pilotage_donnees_lot(p_asset),
    'trousseaux', (select count(*) from pilotage.cles_trousseaux t where t.asset_id = p_asset and t.supprime_le is null));
end $$;
revoke all on function public.pilotage_bien(text) from public, anon;
grant execute on function public.pilotage_bien(text) to authenticated;

-- Vérification : répartition des lots par phase
select x->>'phase' as phase, count(*) as lots from jsonb_array_elements(pilotage.biens(null)) x group by 1
order by array_position(array['entree', 'sortie', 'travaux', 'location', 'bail', 'fin', 'hors'], x->>'phase');
