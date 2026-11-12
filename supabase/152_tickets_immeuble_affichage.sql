-- 152 : tickets d'immeuble dans le pilotage (constat de Nicolas du 12/11/2026 : ticket n°42 affiché à l'ancienne, mails non vus)
--  - pilotage_tickets_immeubles() : pour chaque ticket créé sur un immeuble sans lot, l'immeuble et ses lots (page Tickets : ligne et
--    fiche de l'immeuble au lieu de « Immeuble, pas de lot précis ») ;
--  - règle de Nicolas (12/11) : un ticket d'immeuble ne concerne aucun lot en particulier (parties communes) ; les lots de l'immeuble
--    ne sont pas concernés. Un mail de prestataire va au ticket du LOT dont il est prestataire (ouvert d'abord, sinon le plus récent,
--    même clos : cas des deux bons 2PCJ du lot 188, ticket n°44, laissés tels quels) ; le ticket d'immeuble n'est retenu que si le
--    prestataire n'a aucun ticket sur le lot, et le mail est alors rangé sur l'immeuble, sans lot ;
--    Un ticket de lot trouvé ainsi range le mail sur le lot de ce ticket, même avec plusieurs lots candidats, si le prestataire n'a
--    de tickets (ouverts, sinon tous) que sur ce lot ;
--  - les mails rattachés à un ticket d'immeuble ne sont plus montrés dans les échanges des lots de l'immeuble (ils restent dans le
--    fil du ticket) : retour sur le 151.
--  Bloc unique.

begin;

create or replace function public.pilotage_tickets_immeubles() returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_object_agg(i.id, jsonb_build_object('immeuble_id', i.data->>'asset_group_id',
      'libelle', pilotage.immeuble_libelle(i.data->>'asset_group_id'),
      'lots', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'lot', l.reference, 'adresse', l.adresse) order by l.reference), '[]'::jsonb)
                 from pilotage.v_lots l where l.id = any(pilotage.immeuble_lots(i.data->>'asset_group_id')))))
    from pilotage.objets i where i.type = 'Incident' and i.supprime_le is null and coalesce(i.data->>'asset_id', '') = '' and i.data->>'asset_group_id' is not null), '{}'::jsonb);
end $$;
revoke all on function public.pilotage_tickets_immeubles() from public, anon;
grant execute on function public.pilotage_tickets_immeubles() to authenticated;

create or replace function public.pilotage_mails_preparer(p_emails text[], p_le timestamptz, p_objet text, p_thread text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare j date := p_le::date; corr jsonb; lots text[]; ref text[]; v_lot text; v_ticket text; v_bail text; t record; cand jsonb; mem text[]; grp text;
begin
  select coalesce(jsonb_agg(distinct jsonb_build_object('email', a.email, 'nom', a.nom, 'role', a.role)), '[]'::jsonb),
         array_agg(distinct a.lot_id) filter (where a.lot_id is not null)
    into corr, lots
    from pilotage.mails_annuaire(p_emails) a
   where (a.debut is null or a.debut <= j + 30) and (a.fin is null or a.fin >= j - 180);
  if corr = '[]'::jsonb then
    select coalesce(jsonb_agg(distinct jsonb_build_object('email', a.email, 'nom', a.nom, 'role', a.role)), '[]'::jsonb),
           array_agg(distinct a.lot_id) filter (where a.lot_id is not null)
      into corr, lots from pilotage.mails_annuaire(p_emails) a;
  end if;
  if corr = '[]'::jsonb then return jsonb_build_object('garder', false); end if;
  -- 151 : référence d'un ticket d'immeuble [UDI T<n°>]
  ref := regexp_match(coalesce(p_objet, ''), '\[UDI\s+T(\d+)\]');
  if ref is not null then
    select id, data->>'asset_group_id' into v_ticket, grp from pilotage.objets
     where type = 'Incident' and supprime_le is null and data->>'number' = ref[1] and coalesce(data->>'asset_id', '') = '' and data->>'asset_group_id' is not null limit 1;
    if v_ticket is not null then
      return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', 'reference', 'lot_id', null, 'ticket_id', v_ticket,
        'immeuble_id', grp, 'bail_id', null, 'mandat_id', pilotage.immeuble_mandat(grp));
    end if;
  end if;
  ref := regexp_match(coalesce(p_objet, ''), '\[UDI\s+L([A-Za-z0-9-]+)(?:\s+T(\d+))?\]');
  if ref is not null then
    select id into v_lot from pilotage.v_lots where reference = ref[1] limit 1;
    if ref[2] is not null then
      select id into v_ticket from pilotage.objets where type = 'Incident' and data->>'number' = ref[2] and pilotage.ticket_du_lot(data, v_lot) limit 1;
    end if;
    if v_lot is not null then
      return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', 'reference', 'lot_id', v_lot, 'ticket_id', v_ticket,
        'immeuble_id', pilotage.ticket_immeuble(v_ticket), 'bail_id', pilotage.mails_bail_a(v_lot, j), 'mandat_id', (select mandat_id from pilotage.v_lots where id = v_lot));
    end if;
  end if;
  select m.lot_id, m.ticket_id, m.bail_id, m.immeuble_id, m.mandat_id into t from pilotage.mails m
   where p_thread is not null and m.thread_id = p_thread and m.statut = 'classe' and (m.lot_id is not null or m.immeuble_id is not null) order by m.le desc limit 1;
  if t.lot_id is not null or t.immeuble_id is not null then
    return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', 'conversation', 'lot_id', t.lot_id, 'ticket_id', t.ticket_id,
      'immeuble_id', t.immeuble_id, 'bail_id', t.bail_id, 'mandat_id', coalesce((select mandat_id from pilotage.v_lots where id = t.lot_id), t.mandat_id));
  end if;
  select array_agg(distinct mm.lot_id) into mem from pilotage.mails_memoire mm where mm.email = any(select lower(trim(x)) from unnest(p_emails) x);
  if cardinality(mem) = 1 then lots := mem; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'lot_id', l.id, 'lot', l.reference, 'adresse', l.adresse, 'mandat_id', l.mandat_id,
      'bail_id', pilotage.mails_bail_a(l.id, j),
      'locataires', (select vb.locataires from pilotage.v_baux vb where vb.id = pilotage.mails_bail_a(l.id, j)),
      'tickets', (select coalesce(jsonb_agg(jsonb_build_object('ticket_id', i.id, 'numero', i.data->>'number', 'titre', i.data->>'title',
                         'immeuble', coalesce(i.data->>'asset_id', '') = '')), '[]'::jsonb)
                    from pilotage.objets i where i.type = 'Incident' and i.supprime_le is null and pilotage.ticket_du_lot(i.data, l.id)
                     and (i.data->>'declared_at')::date <= j + 1
                     and (i.data->>'resolved_at' is null or (i.data->>'resolved_at')::date >= j - 30)))), '[]'::jsonb)
    into cand from pilotage.v_lots l where l.id = any(coalesce(lots, '{}'));
  -- 152 : ticket du lot dont l'expéditeur est prestataire (ouvert d'abord, puis le plus récent même clos) ;
  -- le ticket d'immeuble seulement si le prestataire n'a aucun ticket sur le lot
  select i.id into v_ticket from pilotage.objets i
   where i.type = 'Incident' and i.supprime_le is null and i.data->>'asset_id' = any(coalesce(lots, '{}'))
     and exists (select 1 from jsonb_array_elements_text(coalesce(i.data->'contractor_ids', '[]'::jsonb)) c
                   join pilotage.objets pr on pr.type = 'Profile' and pr.id = c
                  where lower(pr.data->>'email') = any(select lower(trim(x)) from unnest(p_emails) x))
   order by coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') desc, i.data->>'declared_at' desc limit 1;
  if v_ticket is null then
    select a.ticket_id into v_ticket from pilotage.mails_annuaire(p_emails) a where a.role = 'prestataire' and a.lot_id = any(coalesce(lots, '{}'))
       and (a.debut is null or a.debut <= j) and (a.fin is null or a.fin >= j)
     order by (select coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') from pilotage.objets i where i.id = a.ticket_id) desc nulls last limit 1;
  end if;
  if v_ticket is null then
    select i.id into v_ticket from pilotage.objets i
     where i.type = 'Incident' and i.supprime_le is null and coalesce(i.data->>'asset_id', '') = ''
       and coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') and i.data->>'archived_at' is null
       and exists (select 1 from unnest(coalesce(lots, '{}')) x where pilotage.ticket_du_lot(i.data, x))
       and exists (select 1 from jsonb_array_elements_text(coalesce(i.data->'contractor_ids', '[]'::jsonb)) c
                     join pilotage.objets pr on pr.type = 'Profile' and pr.id = c
                    where lower(pr.data->>'email') = any(select lower(trim(x)) from unnest(p_emails) x))
     order by i.data->>'declared_at' desc limit 1;
  end if;
  -- 152 : ticket d'immeuble trouvé par le prestataire : rattachement à l'immeuble, sans lot
  grp := pilotage.ticket_immeuble(v_ticket);
  if grp is not null then
    return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', 'prestataire', 'lot_id', null, 'ticket_id', v_ticket,
      'immeuble_id', grp, 'bail_id', null, 'mandat_id', pilotage.immeuble_mandat(grp), 'candidats', cand);
  end if;
  -- 152 : ticket de lot trouvé par le prestataire : le mail va au lot de ce ticket, même s'il y a plusieurs lots candidats
  if v_ticket is not null then
    select i.data->>'asset_id' into v_lot from pilotage.objets i where i.id = v_ticket;
    -- seulement si ses tickets (ouverts, sinon tous) ne portent que sur ce lot : un prestataire de plusieurs lots passe par la vérification
    if v_lot is not null and v_lot = any(coalesce(lots, '{}')) and (
         select count(distinct i.data->>'asset_id') from pilotage.objets i
          where i.type = 'Incident' and i.supprime_le is null and i.data->>'asset_id' = any(coalesce(lots, '{}'))
            and (coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled'))
                = (select coalesce(t2.data->>'status', '') not in ('closed', 'resolved', 'cancelled') from pilotage.objets t2 where t2.id = v_ticket)
            and exists (select 1 from jsonb_array_elements_text(coalesce(i.data->'contractor_ids', '[]'::jsonb)) c
                          join pilotage.objets pr on pr.type = 'Profile' and pr.id = c
                         where lower(pr.data->>'email') = any(select lower(trim(x)) from unnest(p_emails) x))) <= 1 then
      return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', 'prestataire', 'lot_id', v_lot, 'ticket_id', v_ticket,
        'bail_id', pilotage.mails_bail_a(v_lot, j), 'mandat_id', (select mandat_id from pilotage.v_lots where id = v_lot), 'candidats', cand);
    end if;
  end if;
  if jsonb_array_length(cand) = 1 then
    v_lot := cand->0->>'lot_id';
    if v_ticket is null and jsonb_array_length(cand->0->'tickets') = 0 then
      return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', case when cardinality(mem) = 1 then 'memoire' else 'contact' end,
        'lot_id', v_lot, 'ticket_id', null, 'bail_id', cand->0->>'bail_id', 'mandat_id', cand->0->>'mandat_id', 'candidats', cand);
    end if;
    if v_ticket is not null then
      return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', 'prestataire', 'lot_id', v_lot, 'ticket_id', v_ticket,
        'immeuble_id', pilotage.ticket_immeuble(v_ticket), 'bail_id', cand->0->>'bail_id', 'mandat_id', cand->0->>'mandat_id', 'candidats', cand);
    end if;
  end if;
  return jsonb_build_object('garder', true, 'parties', corr, 'certain', false, 'candidats', cand);
end $$;

-- Échanges d'un lot : ses seuls mails (un mail rattaché à un ticket d'immeuble reste dans le fil du ticket)
create or replace function public.pilotage_mails_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null or not pilotage.voit_tableau('sinistres', (select mandat_id from pilotage.v_lots where id = p_asset)) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(pilotage.mails_ligne(m) order by m.le desc) from pilotage.mails m where m.lot_id = p_asset and m.statut = 'classe'), '[]'::jsonb);
end $$;

commit;
