-- Tableaux de suivi : sinistres, sorties et dépôts de garantie, comptabilité, vue agence.
-- Lecture seule sur le reflet pilotage.objets. Droits :
--   direction, superviseur : tout ;
--   comptable : comptabilité + sorties/DG, tous mandats ;
--   gestionnaire : sinistres + sorties/DG, mandats attribués ;
--   négociateur : rien ici.

create or replace function pilotage.voit_tableau(p_tableau text, p_mandat text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select case pilotage.mon_role()
    when 'direction' then true
    when 'superviseur' then true
    when 'comptable' then p_tableau in ('compta', 'dg')
    when 'gestionnaire' then p_tableau in ('sinistres', 'dg')
      and exists (select 1 from pilotage.attributions t where t.mandat_id = p_mandat and t.user_id = auth.uid())
    else false end
$$;

create or replace function public.pilotage_tableaux_visibles() returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case pilotage.mon_role()
    when 'direction' then '["agence","sinistres","dg","compta"]'::jsonb
    when 'superviseur' then '["agence","sinistres","dg","compta"]'::jsonb
    when 'comptable' then '["dg","compta"]'::jsonb
    when 'gestionnaire' then '["sinistres","dg"]'::jsonb
    else '[]'::jsonb end
$$;

-- Sinistres et incidents
create or replace function public.pilotage_sinistres() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((
    select jsonb_agg(x order by (x->>'clos')::boolean, x->>'declare_le' desc) from (
      select jsonb_build_object(
        'id', i.id, 'numero', i.data->>'number', 'titre', i.data->>'title', 'description', i.data->>'description',
        'type', i.data->>'incident_type', 'urgence', i.data->>'urgency', 'statut', i.data->>'status',
        'clos', (i.data->>'status') in ('closed', 'resolved', 'cancelled') or i.data->>'archived_at' is not null,
        'declare_le', i.data->>'declared_at', 'resolu_le', left(i.data->>'resolved_at', 10),
        'jours', (coalesce((i.data->>'resolved_at')::date, current_date) - (i.data->>'declared_at')::date),
        'a_charge', i.data->>'charged_to',
        'montant_estime', round((i.data->>'estimated_amount_in_cents')::numeric / 100, 2),
        'prestataires', jsonb_array_length(coalesce(i.data->'contractor_ids', '[]'::jsonb)),
        'adresse', l.adresse, 'lot', l.reference, 'locataires', b.locataires,
        'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
        'lien', 'https://rivage.immo/incidents/' || i.id
      ) x
      from pilotage.objets i
      left join pilotage.v_lots l on l.id = i.data->>'asset_id'
      left join pilotage.v_baux b on b.id = i.data->>'leasing_contract_id'
      where i.type = 'Incident' and i.supprime_le is null
        and pilotage.voit_tableau('sinistres', l.mandat_id)
    ) t
  ), '[]'::jsonb);
end $$;

-- Sorties de locataires et restitution des dépôts de garantie
-- Délai légal (loi du 6 juillet 1989, art. 22) : 1 mois après remise des clés si l'état des lieux de sortie
-- est conforme à celui d'entrée, 2 mois sinon ; au-delà, majoration de 10 % du loyer hors charges par mois de retard.
create or replace function public.pilotage_dg() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((
    select jsonb_agg(x order by x->>'fin') from (
      select jsonb_build_object(
        'bail_id', b.id, 'reference', b.reference, 'locataires', b.locataires, 'adresse', l.adresse,
        'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
        'statut', b.statut, 'fin', b.fin, 'parti', b.fin <= current_date,
        'depot', b.depot_garantie, 'loyer_hc', b.loyer_hc,
        'limite_1_mois', (b.fin + interval '1 month')::date, 'limite_2_mois', (b.fin + interval '2 months')::date,
        'restitution_creee', g.id is not null,
        'validee', coalesce((g.data->>'deposit_refund_validated')::boolean, false),
        'remboursee', coalesce((g.data->>'deposit_refunded')::boolean, false),
        'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
      ) x
      from pilotage.v_baux b
      left join pilotage.v_lots l on l.id = b.lot_id
      left join lateral (select o.id, o.data from pilotage.objets o
                         where o.type = 'AccountingEventGroup' and o.supprime_le is null
                           and o.data->>'nature' = 'refund_deposit' and o.data->>'leasing_contract_id' = b.id
                         order by o.data->>'billing_period_start_date' desc limit 1) g on true
      where (b.statut = 'move_out' or b.fin is not null)
        and pilotage.voit_tableau('dg', l.mandat_id)
    ) t
  ), '[]'::jsonb);
end $$;

-- Comptabilité : situation des locataires par période quittancée, et comptes tiers
create or replace function public.pilotage_compta() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'periodes', coalesce((
      select jsonb_agg(x order by abs((x->>'solde')::numeric) desc) from (
        select jsonb_build_object(
          'bail_id', b.id, 'reference', b.reference, 'locataires', b.locataires, 'adresse', l.adresse,
          'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
          'periode', g.data->>'billing_period_start_date',
          'du', round((g.data->>'tenant_total_amount_due')::numeric / 100, 2),
          'recu', round((g.data->>'tenant_received_amount')::numeric / 100, 2),
          'solde', round(((g.data->>'tenant_received_amount')::numeric - (g.data->>'tenant_total_amount_due')::numeric) / 100, 2),
          'recu_le', g.data->>'tenant_rent_received_date',
          'reverse_proprio', round((g.data->>'transferred_amount')::numeric / 100, 2),
          'dernier_virement_proprio', g.data->>'last_landlord_transfer_date',
          'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
        ) x
        from pilotage.objets g
        join pilotage.v_baux b on b.id = g.data->>'leasing_contract_id'
        left join pilotage.v_lots l on l.id = b.lot_id
        where g.type = 'AccountingEventGroup' and g.supprime_le is null and g.data->>'nature' = 'rent'
          and pilotage.voit_tableau('compta', l.mandat_id)
      ) t), '[]'::jsonb),
    'impayes_baux', coalesce((
      select jsonb_agg(jsonb_build_object('bail_id', b.id, 'reference', b.reference, 'locataires', b.locataires, 'adresse', l.adresse,
               'impaye', b.impaye, 'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id) order by b.impaye desc)
      from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id
      where b.impaye > 0 and pilotage.voit_tableau('compta', l.mandat_id)), '[]'::jsonb),
    'comptes', coalesce((
      select jsonb_agg(jsonb_build_object('compte', a.data->>'general_number', 'titulaire', a.data->>'holder_type',
               'libelle', a.data->>'description',
               'debit', round((a.data->>'debit_in_cents')::numeric / 100, 2), 'credit', round((a.data->>'credit_in_cents')::numeric / 100, 2),
               'solde', round(((a.data->>'credit_in_cents')::numeric - (a.data->>'debit_in_cents')::numeric) / 100, 2))
             order by a.data->>'holder_type', a.data->>'general_number')
      from pilotage.objets a
      where a.type = 'AccountingAccount' and a.supprime_le is null
        and a.data->>'holder_type' in ('tenant', 'landlord')
        and (a.data->>'credit_in_cents')::numeric <> (a.data->>'debit_in_cents')::numeric
        and pilotage.voit_tableau('compta', coalesce(pilotage.mandat_de('LeasingContract', a.data->>'leasing_contract_id'),
                                                     pilotage.mandat_de('Asset', a.data->>'asset_id')))), '[]'::jsonb)
  );
end $$;

-- Vue agence : toutes les alertes ouvertes, avec la personne attributaire du mandat
create or replace function public.pilotage_agence() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'libelle', g.libelle, 'domaine', g.domaine, 'categorie', g.categorie, 'gravite', a.gravite,
      'titre', a.titre, 'depuis', a.premiere_detection, 'lien', a.lien_rivage,
      'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = a.mandat_id),
      'qui', coalesce((select string_agg(mb.prenom, ', ' order by mb.prenom) from pilotage.attributions t join pilotage.membres mb on mb.user_id = t.user_id
                       where t.mandat_id = a.mandat_id), 'Non attribué')
    ) order by case a.gravite when 'critique' then 0 when 'haute' then 1 else 2 end, a.premiere_detection)
    from pilotage.alertes a join pilotage.regles g on g.cle = a.regle
    where a.statut = 'ouverte'
  ), '[]'::jsonb);
end $$;

revoke all on function pilotage.voit_tableau(text, text) from public, anon, authenticated;
revoke all on function public.pilotage_tableaux_visibles(), public.pilotage_sinistres(), public.pilotage_dg(), public.pilotage_compta(), public.pilotage_agence() from public, anon;
grant execute on function public.pilotage_tableaux_visibles(), public.pilotage_sinistres(), public.pilotage_dg(), public.pilotage_compta(), public.pilotage_agence() to authenticated;
