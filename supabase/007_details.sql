-- Détail des cartes : historique des événements reçus de Rivage, incidents et alertes liés au bail.

create or replace function pilotage.historique(p_id text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('le', e.received_at, 'evenement', e.event_type,
           'statut', e.payload->'payload'->>'status') order by e.received_at desc), '[]'::jsonb)
  from (select * from public.rivage_webhook_events where object_id = p_id order by received_at desc limit 15) e
$$;

create or replace function pilotage.alertes_de(p_type text, p_id text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('gravite', a.gravite, 'libelle', g.libelle, 'titre', a.titre, 'detail', a.detail)
           order by case a.gravite when 'critique' then 0 when 'haute' then 1 else 2 end), '[]'::jsonb)
  from pilotage.alertes a join pilotage.regles g on g.cle = a.regle
  where a.objet_type = p_type and a.objet_id = p_id and a.statut = 'ouverte'
$$;

create or replace function pilotage.nom_profil(p_id text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(nullif(data->>'company_name', ''), nullif(concat_ws(' ', data->>'last_name', data->>'first_name'), ''))
  from pilotage.objets where type = 'Profile' and id = p_id
$$;

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
        'declare_le', i.data->>'declared_at', 'resolu_le', left(i.data->>'resolved_at', 10), 'cree_le', i.data->>'created_at',
        'jours', (coalesce((i.data->>'resolved_at')::date, current_date) - (i.data->>'declared_at')::date),
        'a_charge', i.data->>'charged_to',
        'montant_estime', round((i.data->>'estimated_amount_in_cents')::numeric / 100, 2),
        'prestataires', jsonb_array_length(coalesce(i.data->'contractor_ids', '[]'::jsonb)),
        'adresse', l.adresse, 'lot', l.reference, 'locataires', b.locataires, 'bail', b.reference,
        'bailleur', pilotage.nom_profil(i.data->>'landlord_id'),
        'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
        'historique', pilotage.historique(i.id),
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

create or replace function public.pilotage_dg() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((
    select jsonb_agg(x order by x->>'fin') from (
      select jsonb_build_object(
        'bail_id', b.id, 'reference', b.reference, 'locataires', b.locataires, 'adresse', l.adresse, 'lot', l.reference,
        'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
        'statut', b.statut, 'debut', b.debut, 'fin', b.fin, 'parti', b.fin <= current_date,
        'depot', b.depot_garantie, 'loyer_hc', b.loyer_hc, 'charges', b.charges, 'impaye', b.impaye,
        'limite_1_mois', (b.fin + interval '1 month')::date, 'limite_2_mois', (b.fin + interval '2 months')::date,
        'restitution_creee', g.id is not null, 'restitution_creee_le', left(g.data->>'created_at', 10),
        'validee', coalesce((g.data->>'deposit_refund_validated')::boolean, false),
        'remboursee', coalesce((g.data->>'deposit_refunded')::boolean, false),
        'incidents', (select coalesce(jsonb_agg(jsonb_build_object('numero', i.data->>'number', 'titre', i.data->>'title',
                         'statut', i.data->>'status', 'a_charge', i.data->>'charged_to',
                         'montant_estime', round((i.data->>'estimated_amount_in_cents')::numeric / 100, 2),
                         'lien', 'https://rivage.immo/incidents/' || i.id) order by i.data->>'declared_at'), '[]'::jsonb)
                      from pilotage.objets i where i.type = 'Incident' and i.supprime_le is null and i.data->>'leasing_contract_id' = b.id),
        'alertes', pilotage.alertes_de('LeasingContract', b.id),
        'historique', pilotage.historique(b.id),
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

create or replace function public.pilotage_compta() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'periodes', coalesce((
      select jsonb_agg(x order by abs((x->>'solde')::numeric) desc) from (
        select jsonb_build_object(
          'id', g.id, 'bail_id', b.id, 'reference', b.reference, 'locataires', b.locataires, 'adresse', l.adresse, 'lot', l.reference,
          'statut_bail', b.statut, 'loyer_hc', b.loyer_hc, 'charges', b.charges,
          'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
          'periode', g.data->>'billing_period_start_date', 'periode_fin', g.data->>'billing_period_end_date',
          'appele', round((g.data->>'tenant_called_amount')::numeric / 100, 2),
          'du', round((g.data->>'tenant_total_amount_due')::numeric / 100, 2),
          'recu', round((g.data->>'tenant_received_amount')::numeric / 100, 2),
          'solde', round(((g.data->>'tenant_received_amount')::numeric - (g.data->>'tenant_total_amount_due')::numeric) / 100, 2),
          'report_locataire', round((g.data->>'tenant_balance_from_previous_months')::numeric / 100, 2),
          'report_proprio', round((g.data->>'landlord_balance_from_previous_months')::numeric / 100, 2),
          'recu_le', g.data->>'tenant_rent_received_date',
          'reverse_proprio', round((g.data->>'transferred_amount')::numeric / 100, 2),
          'dernier_virement_proprio', g.data->>'last_landlord_transfer_date',
          'evenements', (select coalesce(jsonb_agg(e->>'nature'), '[]'::jsonb) from jsonb_array_elements(coalesce(g.data->'accounting_events', '[]'::jsonb)) e),
          'avis_echeance', g.data->>'rent_due_notice_file_url' is not null,
          'quittance', g.data->>'rent_receipt_file_url' is not null,
          'compte_rendu', g.data->>'management_report_file_url' is not null,
          'alertes', pilotage.alertes_de('LeasingContract', b.id),
          'historique', pilotage.historique(g.id),
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
               'libelle', a.data->>'description', 'bail_id', a.data->>'leasing_contract_id',
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

create or replace function public.pilotage_agence() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'libelle', g.libelle, 'domaine', g.domaine, 'categorie', g.categorie, 'gravite', a.gravite,
      'titre', a.titre, 'detail', a.detail, 'explication', g.explication, 'depuis', a.premiere_detection, 'lien', a.lien_rivage,
      'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = a.mandat_id),
      'qui', coalesce((select string_agg(mb.prenom, ', ' order by mb.prenom) from pilotage.attributions t join pilotage.membres mb on mb.user_id = t.user_id
                       where t.mandat_id = a.mandat_id), 'Non attribué')
    ) order by case a.gravite when 'critique' then 0 when 'haute' then 1 else 2 end, a.premiere_detection)
    from pilotage.alertes a join pilotage.regles g on g.cle = a.regle
    where a.statut = 'ouverte'
  ), '[]'::jsonb);
end $$;

revoke all on function pilotage.historique(text), pilotage.alertes_de(text, text), pilotage.nom_profil(text) from public, anon, authenticated;
