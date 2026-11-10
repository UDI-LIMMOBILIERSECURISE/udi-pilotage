-- 136 : page « Biens », frise de chaque lot (bloc unique)
--  Décision de Nicolas du 10/11/2026 : suivre chaque bien sur une frise en quatre phases, déduite de Rivage, avec le détail de la
--  phase en cours ; page « Biens » avec les compteurs par phase, une ligne par lot et une vue « À moi ».
--  Une seule phase par lot, dans cet ordre :
--   - Hors gestion : mandat perdu dans Rivage, ou résiliation effective (ManagementTermination « effective »).
--   - Entrée en gestion : mandat nouveau (après la reprise du 20/10) pas encore validé par la gestion ni retiré.
--       Mandat signé → dossier complété par le commercial → validé par la gestion → GO de la rémunération.
--   - Sortie : bail en sortie dans Rivage (congé reçu) dont le départ est à venir ou date de moins de 2 mois, sauf si le nouveau bail
--     a déjà commencé. Congé reçu → EDL de sortie → départ → clôture du bail dans Rivage.
--   - Bail en cours : bail créé ou en cours dans Rivage. Bail signé → contrôle d'entrée (GO ; « repris » pour le stock) → entrée du
--     locataire → bail en cours (impayé signalé).
--   - Mise en location : mandat actif sans bail. Libre → mis en location (liste « À louer ») → bail signé.
--  Signalés à part : baux restés en sortie plus de 2 mois après le départ (« à clôturer dans Rivage », ils ne comptent pas en
--  Sortie), fin de gestion programmée (résiliation « scheduled »), relocation en cours pendant une sortie.
--  « À moi » : lots dont je suis le commercial (négociateur du mandat ou « loué par » du bail) ou qui portent une alerte ouverte
--  qui m'est adressée (mêmes règles que Ma journée).
--  Lecture seule, à partir de la base du pilotage (aucun appel à Rivage) ; les contrôles d'entrée viennent des caches 032 et 073.
--  Mesure du 10/11 : 371 lots en gestion (≈ 301 baux en cours, 14 congés, 8 départs récents, 48 libres), 50 hors gestion.

create or replace function pilotage.biens(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare j date := current_date; lots jsonb;
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
    select distinct on (l.id) l.id lot_id, t.data->>'status' tstatut, (t.data->>'termination_date')::date tdate
      from lot l join pilotage.objets t on t.type = 'ManagementTermination' and t.supprime_le is null and t.data->>'status' in ('scheduled', 'effective')
       and (coalesce(t.data->'asset_ids', '[]'::jsonb) ? l.id or coalesce(t.data->'management_contract_ids', '[]'::jsonb) ? l.mandat_id)
     order by l.id, (t.data->>'status' = 'effective') desc, (t.data->>'termination_date')::date
  ), b as (
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
  ), p as (
    select l.*, b.actif, b.conge, b.bloques, b.libre_depuis, b.en_location, b.disponible, r.tstatut, r.tdate,
      case when l.mstatut = 'lost' or r.tstatut = 'effective' then 'hors'
           when pilotage.dossier_nouveau('ManagementContract', l.mandat_id) and l.valide_le is null and l.retire_le is null then 'entree'
           when (b.conge).id is not null and ((b.actif).id is null or (b.actif).debut > j) then 'sortie'
           when (b.actif).id is not null then 'bail'
           else 'location' end phase
    from lot l join b on b.lot_id = l.id left join resil r on r.lot_id = l.id
  ), q as (
    select p.*,
      case p.phase when 'sortie' then (p.conge).id when 'bail' then (p.actif).id when 'entree' then (p.actif).id end bail_id
    from p
  ), r2 as (
    select q.*, bc.ligne bc, fc.recu_le conge_recu, fc.edl_le edl_sortie, ee.edl_le edl_entree,
      case when q.phase = 'entree' then pilotage.etat_dossier('mandat', q.mandat_id) end em,
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
  ), e as (
    select r2.*,
      case r2.phase
        when 'entree' then jsonb_build_array(
          jsonb_build_object('libelle', 'Mandat signé', 'etat', 'fait', 'date', coalesce(r2.msigne, r2.mdebut)),
          jsonb_build_object('libelle', 'Dossier complété par le commercial',
            'etat', case when r2.em->>'etat' = 'a_finaliser' then 'en_cours' else 'fait' end,
            'info', case when r2.em->>'etat' = 'a_finaliser' then coalesce(r2.em->>'restant', '?') || ' point(s) à traiter'
                         || case when jsonb_array_length(coalesce(r2.em->'vides', '[]'::jsonb)) > 0 then ', ' || jsonb_array_length(r2.em->'vides') || ' champ(s) vide(s) dans Rivage' else '' end end),
          jsonb_build_object('libelle', 'Validé par la gestion', 'etat', case when r2.em->>'etat' = 'en_attente' then 'en_cours' else 'a_venir' end),
          jsonb_build_object('libelle', 'GO de la rémunération', 'etat', case when r2.go_le is not null then 'fait' else 'a_venir' end, 'date', r2.go_le::date))
        when 'location' then jsonb_build_array(
          jsonb_build_object('libelle', 'Libre', 'etat', 'fait', 'date', coalesce(r2.libre_depuis, r2.mdebut)),
          jsonb_build_object('libelle', 'Mis en location', 'etat', case when r2.en_location is not null then 'fait' else 'alerte' end,
            'date', r2.en_location, 'info', case when r2.en_location is null then 'Pas dans la liste « À louer »' when r2.disponible is not null then 'Disponible le ' || to_char(r2.disponible, 'DD/MM/YYYY') end),
          jsonb_build_object('libelle', 'Bail signé', 'etat', case when r2.en_location is not null then 'en_cours' else 'a_venir' end))
        when 'bail' then jsonb_build_array(
          jsonb_build_object('libelle', 'Bail signé', 'etat', 'fait', 'date', coalesce((r2.actif).signe_le, (r2.actif).debut)),
          case when coalesce((r2.bc->'controle'->>'soumis')::boolean, false) then
            jsonb_build_object('libelle', 'Contrôle d''entrée', 'etat', case when r2.bc->'controle'->>'go_le' is not null then 'fait' else 'en_cours' end,
              'date', (r2.bc->'controle'->>'go_le')::timestamptz::date,
              'info', case when r2.bc->'controle'->>'go_le' is not null then 'GO par ' || coalesce(r2.bc->'controle'->>'go_par', '?')
                           else coalesce(r2.bc->'controle'->>'restant', '?') || ' point(s) à traiter' end)
          else jsonb_build_object('libelle', 'Contrôle d''entrée', 'etat', 'fait', 'info', 'Stock repris') end,
          jsonb_build_object('libelle', 'Entrée du locataire', 'etat', case when (r2.actif).debut <= j then 'fait' else 'a_venir' end,
            'date', (r2.actif).debut, 'info', case when r2.edl_entree is not null then 'EDL d''entrée le ' || to_char(r2.edl_entree, 'DD/MM/YYYY') end),
          jsonb_build_object('libelle', 'Bail en cours',
            'etat', case when (r2.actif).debut > j then 'a_venir' when coalesce((r2.actif).impaye, 0) > 0 then 'alerte' else 'en_cours' end,
            'info', case when coalesce((r2.actif).impaye, 0) > 0 then 'Impayé : ' || replace(to_char((r2.actif).impaye, 'FM999999990.00'), '.', ',') || ' €' end))
        when 'sortie' then jsonb_build_array(
          jsonb_build_object('libelle', 'Congé reçu', 'etat', 'fait', 'date', r2.conge_recu),
          jsonb_build_object('libelle', 'EDL de sortie',
            'etat', case when r2.edl_sortie <= j then 'fait' when r2.edl_sortie is not null then 'en_cours'
                         when (r2.conge).fin <= j + 15 then 'alerte' else 'en_cours' end,
            'date', r2.edl_sortie, 'info', case when r2.edl_sortie is null then 'À planifier' end),
          jsonb_build_object('libelle', 'Départ', 'etat', case when (r2.conge).fin <= j then 'fait' else 'a_venir' end, 'date', (r2.conge).fin),
          jsonb_build_object('libelle', 'Bail clos dans Rivage', 'etat', case when (r2.conge).fin < j then 'en_cours' else 'a_venir' end,
            'info', case when (r2.conge).fin < j then 'À clôturer dans Rivage' end))
        else '[]'::jsonb end etapes
    from r2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'lot', e.reference, 'nature', e.nature, 'adresse', e.adresse,
      'mandat_id', e.mandat_id, 'mandat', e.mref, 'bailleur', pilotage.bailleurs_mandat(e.mandat_id),
      'phase', e.phase, 'etapes', e.etapes,
      'etape', (select min(i) - 1 from jsonb_array_elements(e.etapes) with ordinality t(x, i) where x->>'etat' <> 'fait'),
      'bail_id', e.bail_id,
      'bail', case e.phase when 'sortie' then (e.conge).reference else (e.actif).reference end,
      'locataires', case e.phase when 'sortie' then (e.conge).locataires else (e.actif).locataires end,
      'commercial', pilotage.prenom_membre(e.commercial),
      'fin_gestion', case when e.tstatut = 'scheduled' then e.tdate end,
      'relocation', case when e.phase = 'sortie' then
          case when (e.actif).id is not null then 'Reloué, entrée le ' || to_char((e.actif).debut, 'DD/MM/YYYY')
               when e.en_location is not null then 'En relocation' end end,
      'a_cloturer', e.bloques,
      'alertes', e.alertes, 'alertes_moi', e.alertes_moi,
      'a_moi', p_user is not null and (e.commercial = p_user or e.alertes_moi > 0))
    order by array_position(array['entree', 'sortie', 'location', 'bail', 'hors'], e.phase), e.adresse), '[]'::jsonb)
    into lots from e;
  return lots;
end $$;
revoke all on function pilotage.biens(uuid) from public, anon, authenticated;

create or replace function public.pilotage_biens()
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare l jsonb;
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  l := pilotage.biens(auth.uid());
  return jsonb_build_object(
    'moi', auth.uid(), 'peut', pilotage.peut_suivre_baux(),
    'compteurs', (select jsonb_object_agg(k, n) from (
        select x->>'phase' k, count(*) n from jsonb_array_elements(l) x group by 1
        union all select 'a_cloturer', count(*) from jsonb_array_elements(l) x where (x->>'a_cloturer')::int > 0
        union all select 'a_moi', count(*) from jsonb_array_elements(l) x where (x->>'a_moi')::boolean and x->>'phase' <> 'hors') c),
    'lots', l);
end $$;
revoke all on function public.pilotage_biens() from public, anon;
grant execute on function public.pilotage_biens() to authenticated;

-- Vérification : répartition des lots par phase
select x->>'phase' as phase, count(*) as lots from jsonb_array_elements(pilotage.biens(null)) x group by 1
order by array_position(array['entree', 'sortie', 'location', 'bail', 'hors'], x->>'phase');
