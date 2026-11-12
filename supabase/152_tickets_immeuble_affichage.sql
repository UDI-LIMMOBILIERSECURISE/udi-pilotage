-- 152 : tickets d'immeuble dans le pilotage (constat de Nicolas du 12/11/2026 : ticket n°42 affiché à l'ancienne, mails non vus)
--  - pilotage_tickets_immeubles() : pour chaque ticket créé sur un immeuble sans lot, l'immeuble et ses lots (page Tickets : ligne et
--    fiche de l'immeuble au lieu de « Immeuble, pas de lot précis ») ;
--  - lecture des mails : un mail d'un prestataire est rattaché d'abord au ticket OUVERT dont il est prestataire (sur le lot ou sur
--    l'immeuble du lot) ; avant, le premier ticket trouvé, même clos (au 12/11, deux bons d'intervention 2PCJ rangés sur le ticket n°44
--    clos du lot 188 alors que 2PCJ intervient sur le ticket d'immeuble n°42). Un ticket d'immeuble trouvé ainsi range le mail sur
--    l'immeuble, sans lot.
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
  -- 152 : prestataire d'un ticket ouvert d'abord (lot ou immeuble du lot), puis l'annuaire (ticket ouvert avant ticket clos)
  select i.id into v_ticket from pilotage.objets i
   where i.type = 'Incident' and i.supprime_le is null and coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') and i.data->>'archived_at' is null
     and exists (select 1 from unnest(coalesce(lots, '{}')) x where pilotage.ticket_du_lot(i.data, x))
     and exists (select 1 from jsonb_array_elements_text(coalesce(i.data->'contractor_ids', '[]'::jsonb)) c
                   join pilotage.objets pr on pr.type = 'Profile' and pr.id = c
                  where lower(pr.data->>'email') = any(select lower(trim(x)) from unnest(p_emails) x))
   order by coalesce(i.data->>'asset_id', '') = '', i.data->>'declared_at' desc limit 1;
  if v_ticket is null then
    select a.ticket_id into v_ticket from pilotage.mails_annuaire(p_emails) a where a.role = 'prestataire' and a.lot_id = any(coalesce(lots, '{}'))
       and (a.debut is null or a.debut <= j) and (a.fin is null or a.fin >= j)
     order by (select coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') from pilotage.objets i where i.id = a.ticket_id) desc nulls last limit 1;
  end if;
  -- 152 : ticket d'immeuble trouvé par le prestataire : rattachement à l'immeuble, sans lot
  grp := pilotage.ticket_immeuble(v_ticket);
  if grp is not null then
    return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', 'prestataire', 'lot_id', null, 'ticket_id', v_ticket,
      'immeuble_id', grp, 'bail_id', null, 'mandat_id', pilotage.immeuble_mandat(grp), 'candidats', cand);
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

commit;
