-- Situation locative d'un lot, pour les incidents : libre, occupé, congé en cours, libre en attente de restitution du DG.
-- Rivage n'expose pas la date de l'état des lieux de sortie : la date de fin du bail sert de date de départ.
create or replace function pilotage.situation_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  actif record; conge record; parti record; j date := current_date;
  dg_rendu boolean;
begin
  if p_asset is null then
    return jsonb_build_object('code', 'immeuble', 'libelle', 'Immeuble', 'detail', 'Incident sur l''immeuble, pas sur un lot précis.', 'gravite', 'normale');
  end if;

  -- Bail en cours (ou signé, entrée à venir) sans congé
  select * into actif from pilotage.v_baux b
   where b.lot_id = p_asset and b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > j)
   order by b.debut desc nulls last limit 1;
  -- Congé : bail en sortie dont la fin n'est pas encore passée
  select * into conge from pilotage.v_baux b
   where b.lot_id = p_asset and b.statut = 'move_out' and b.fin > j order by b.fin limit 1;

  if conge.id is not null then
    return jsonb_build_object('code', 'conge', 'libelle', 'Congé en cours',
      'detail', 'Locataire ' || coalesce(conge.locataires, '') || ' en préavis, départ prévu le ' || to_char(conge.fin, 'DD/MM/YYYY') || '.',
      'gravite', 'haute', 'bail', conge.reference, 'fin', conge.fin);
  end if;

  if actif.id is not null then
    return jsonb_build_object('code', 'occupe', 'libelle', 'Occupé',
      'detail', case when actif.debut > j then 'Bail signé, entrée de ' || coalesce(actif.locataires, '') || ' le ' || to_char(actif.debut, 'DD/MM/YYYY') || '.'
                     else 'Loué à ' || coalesce(actif.locataires, '') || ' depuis le ' || to_char(actif.debut, 'DD/MM/YYYY') || '.' end,
      'gravite', 'normale', 'bail', actif.reference);
  end if;

  -- Dernier bail terminé
  select * into parti from pilotage.v_baux b
   where b.lot_id = p_asset and b.fin is not null and b.fin <= j order by b.fin desc limit 1;

  if parti.id is null then
    return jsonb_build_object('code', 'libre', 'libelle', 'Bien libre', 'detail', 'Aucun bail enregistré dans Rivage sur ce lot.', 'gravite', 'normale');
  end if;

  select coalesce(bool_or((o.data->>'deposit_refunded')::boolean), false) into dg_rendu
    from pilotage.objets o where o.type = 'AccountingEventGroup' and o.supprime_le is null
     and o.data->>'nature' = 'refund_deposit' and o.data->>'leasing_contract_id' = parti.id;

  if dg_rendu or coalesce(parti.depot_garantie, 0) = 0 then
    return jsonb_build_object('code', 'libre', 'libelle', 'Bien libre',
      'detail', 'Dernier locataire (' || coalesce(parti.locataires, '') || ') parti le ' || to_char(parti.fin, 'DD/MM/YYYY') ||
                case when dg_rendu then ', dépôt de garantie restitué.' else ', pas de dépôt de garantie.' end,
      'gravite', 'normale', 'bail', parti.reference);
  end if;

  return jsonb_build_object('code', 'attente_dg',
    'libelle', case when j > (parti.fin + interval '2 months')::date then 'Libre, DG hors délai'
                    when j > (parti.fin + interval '1 month')::date then 'Libre, DG délai 1 mois dépassé'
                    else 'Libre, attente restitution DG' end,
    'detail', 'Locataire ' || coalesce(parti.locataires, '') || ' parti le ' || to_char(parti.fin, 'DD/MM/YYYY') ||
              ', dépôt de ' || replace(to_char(parti.depot_garantie, 'FM999999990.00'), '.', ',') || ' € non restitué. ' ||
              case when j > (parti.fin + interval '2 months')::date
                     then 'Hors délai légal depuis le ' || to_char((parti.fin + interval '2 months')::date, 'DD/MM/YYYY') || ' (2 mois dépassés), majoration de 10 % du loyer par mois de retard.'
                   when j > (parti.fin + interval '1 month')::date
                     then 'Délai d''un mois dépassé depuis le ' || to_char((parti.fin + interval '1 month')::date, 'DD/MM/YYYY') || ' : en retard si l''état des lieux de sortie était conforme, limite au ' || to_char((parti.fin + interval '2 months')::date, 'DD/MM/YYYY') || ' sinon.'
                   else 'Dans le délai : au plus tard le ' || to_char((parti.fin + interval '1 month')::date, 'DD/MM/YYYY') || ' si l''état des lieux de sortie est conforme, le ' || to_char((parti.fin + interval '2 months')::date, 'DD/MM/YYYY') || ' sinon.' end,
    'gravite', case when j > (parti.fin + interval '2 months')::date then 'critique' when j > (parti.fin + interval '1 month')::date then 'haute' else 'normale' end,
    'bail', parti.reference, 'fin', parti.fin,
    'limite_1_mois', (parti.fin + interval '1 month')::date, 'limite_2_mois', (parti.fin + interval '2 months')::date);
end $$;
revoke all on function pilotage.situation_lot(text) from public, anon, authenticated;

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
        'situation', pilotage.situation_lot(i.data->>'asset_id'),
        'mandat_statut', case (select m.statut from pilotage.v_mandats m where m.id = l.mandat_id)
                           when 'active' then 'Mandat actif' when 'lost' then 'Mandat perdu'
                           else case when i.data->>'asset_id' is null then null else 'Lot sans mandat' end end,
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

