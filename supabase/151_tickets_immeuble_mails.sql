-- 151 : mails rattachés à un ticket d'immeuble (constat et décision de Nicolas du 12/11/2026)
--  Un incident Rivage peut être créé sur un immeuble (asset_group_id) sans lot (asset_id vide) : au 12/11, n°42 « rénovation multiple »
--  (immeuble de 8 lots) et n°35 « mise à jour diag ». Le module Gmail et le classement des mails ne cherchaient les tickets que par lot.
--  Désormais :
--   - un ticket d'immeuble est proposé sur chaque lot de l'immeuble (rattachement Rivage asset_group_memberships), marqué « immeuble » ;
--   - un mail peut être rattaché au ticket d'immeuble SANS lot : lot vide, ticket et immeuble renseignés (nouvelle colonne
--     pilotage.mails.immeuble_id), mandat = mandat d'un lot de l'immeuble (droits de lecture) ;
--   - référence courte [UDI T<n°>] insérée par le module Gmail pour un ticket d'immeuble (la référence [UDI L<lot> T<n°>] reste) ;
--   - un mail rattaché à l'immeuble apparaît dans les échanges de chaque lot de l'immeuble et dans le fil du ticket ;
--   - page « Mails à vérifier » : n° de lot facultatif quand le n° de ticket est celui d'un ticket d'immeuble.
--  Bloc unique.
-- Retour arrière (les mails rattachés à un immeuble restent avec lot vide) :
--   create or replace function pilotage.ticket_du_lot(p jsonb, p_lot text) returns boolean language sql immutable as $$ select coalesce(p->>'asset_id' = p_lot, false) $$;

begin;

alter table pilotage.mails add column if not exists immeuble_id text;
create index if not exists mails_immeuble on pilotage.mails (immeuble_id) where immeuble_id is not null;

alter table pilotage.mails_choix drop constraint if exists mails_choix_ref_check;
alter table pilotage.mails_choix add constraint mails_choix_ref_check check (ref ~ '^\[UDI (L[A-Za-z0-9-]+( T\d+)?|T\d+)\]$');

-- Le ticket concerne-t-il ce lot ? (sur le lot, ou sur un immeuble dont le lot fait partie)
create or replace function pilotage.ticket_du_lot(p jsonb, p_lot text) returns boolean
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce(p->>'asset_id' = p_lot, false)
      or (coalesce(p->>'asset_id', '') = '' and p->>'asset_group_id' is not null
          and exists (select 1 from pilotage.objets a where a.type = 'Asset' and a.id = p_lot and a.supprime_le is null
                        and coalesce(a.data->'asset_group_memberships', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('asset_group_id', p->>'asset_group_id'))))
$$;

-- Immeuble d'un ticket créé sans lot (null pour un ticket de lot)
create or replace function pilotage.ticket_immeuble(p_ticket text) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select i.data->>'asset_group_id' from pilotage.objets i
   where i.type = 'Incident' and i.id = p_ticket and coalesce(i.data->>'asset_id', '') = '' and i.data->>'asset_group_id' is not null
$$;

-- Lots d'un immeuble, mandat de référence et libellé
create or replace function pilotage.immeuble_lots(p_groupe text) returns text[]
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce(array_agg(a.id order by a.data->>'reference'), '{}') from pilotage.objets a
   where a.type = 'Asset' and a.supprime_le is null
     and coalesce(a.data->'asset_group_memberships', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('asset_group_id', p_groupe))
$$;
create or replace function pilotage.immeuble_mandat(p_groupe text) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select l.mandat_id from pilotage.v_lots l where l.id = any(pilotage.immeuble_lots(p_groupe)) and l.mandat_id is not null order by l.reference limit 1
$$;
create or replace function pilotage.immeuble_libelle(p_groupe text) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select 'Immeuble ' || coalesce(nullif(g.data->>'name', ''), g.data->>'reference', '')
         || coalesce(' · ' || nullif(concat_ws(' ', g.data->'address_attributes'->>'number', g.data->'address_attributes'->>'street',
                                               g.data->'address_attributes'->>'zip_code', g.data->'address_attributes'->>'city'), ''), '')
    from pilotage.objets g where g.type = 'AssetGroup' and g.id = p_groupe
$$;
revoke all on function pilotage.ticket_du_lot(jsonb, text), pilotage.ticket_immeuble(text), pilotage.immeuble_lots(text),
  pilotage.immeuble_mandat(text), pilotage.immeuble_libelle(text) from public, anon, authenticated;

-- Module Gmail : lot avec ses tickets ouverts, tickets d'immeuble compris (marqués)
create or replace function pilotage.addon_lot(p_lot text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('lot_id', l.id, 'lot', l.reference, 'adresse', l.adresse,
    'bail', vb.reference, 'locataires', vb.locataires,
    'bailleur', pilotage.bailleurs_mandat(l.mandat_id),
    'contacts', coalesce(pilotage.contacts_bail(vb.id), pilotage.contacts_mandat(l.mandat_id)),
    'tickets', (select coalesce(jsonb_agg(jsonb_build_object('ticket_id', i.id, 'numero', i.data->>'number', 'titre', i.data->>'title',
                    'immeuble', coalesce(i.data->>'asset_id', '') = '', 'immeuble_libelle', case when coalesce(i.data->>'asset_id', '') = '' then pilotage.immeuble_libelle(i.data->>'asset_group_id') end,
                    'prestataires', (select coalesce(jsonb_agg(jsonb_build_object('nom', coalesce(pilotage.nom_profil(c), 'Prestataire'), 'email', pr.data->>'email')), '[]'::jsonb)
                                       from jsonb_array_elements_text(coalesce(i.data->'contractor_ids', '[]'::jsonb)) c
                                       left join pilotage.objets pr on pr.type = 'Profile' and pr.id = c)) order by i.data->>'declared_at' desc), '[]'::jsonb)
                  from pilotage.objets i where i.type = 'Incident' and i.supprime_le is null and pilotage.ticket_du_lot(i.data, l.id)
                   and coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') and i.data->>'archived_at' is null))
  from pilotage.v_lots l left join pilotage.v_baux vb on vb.id = pilotage.mails_bail_a(l.id, current_date)
  where l.id = p_lot
$$;
revoke all on function pilotage.addon_lot(text) from public, anon, authenticated;

create or replace function public.pilotage_addon_chercher(p_email text, p_q text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare q text := trim(coalesce(p_q, ''));
begin
  if pilotage.addon_role(p_email) is null then raise exception 'Adresse % : pas d''accès au pilotage', p_email; end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(pilotage.addon_lot(t.id)) from (
      select l.id from pilotage.v_lots l
        left join pilotage.v_baux vb on vb.id = pilotage.mails_bail_a(l.id, current_date)
       where l.reference = q or l.adresse ilike '%' || q || '%' or vb.locataires ilike '%' || q || '%' or pilotage.bailleurs_mandat(l.mandat_id) ilike '%' || q || '%'
          or vb.reference = q
          or exists (select 1 from pilotage.objets i where i.type = 'Incident' and pilotage.ticket_du_lot(i.data, l.id)
                      and coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') and i.data->>'archived_at' is null
                      and (i.data->>'number' = q or i.data->>'title' ilike '%' || q || '%'
                           or exists (select 1 from jsonb_array_elements_text(coalesce(i.data->'contractor_ids', '[]'::jsonb)) c
                                       where pilotage.nom_profil(c) ilike '%' || q || '%')))
       order by (l.reference = q) desc, l.adresse limit 12) t), '[]'::jsonb);
end $$;

-- Module Gmail : classement. Lot vide = rattachement au ticket d'immeuble seul.
create or replace function public.pilotage_addon_classer(p_email text, p_mail bigint, p_lot text, p_ticket text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare r text := pilotage.addon_role(p_email); m pilotage.mails; uid uuid; v_lot text := nullif(trim(coalesce(p_lot, '')), ''); v_ticket text := nullif(trim(coalesce(p_ticket, '')), ''); grp text;
begin
  if r is null or r not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Classement réservé à la gestion'; end if;
  select * into m from pilotage.mails where id = p_mail;
  if m.id is null then raise exception 'Mail introuvable dans le pilotage'; end if;
  select u.id into uid from auth.users u where lower(u.email) = pilotage.addon_adresse(p_email);  -- 149
  if v_lot is null then
    grp := pilotage.ticket_immeuble(v_ticket);
    if grp is null then raise exception 'Choisir un lot, ou un ticket d''immeuble'; end if;
    update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = null, bail_id = null, ticket_id = v_ticket, immeuble_id = grp,
           mandat_id = pilotage.immeuble_mandat(grp), classe_par = uid, classe_le = now() where id = p_mail;
    return jsonb_build_object('ok', true);
  end if;
  if not exists (select 1 from pilotage.v_lots where id = v_lot) then raise exception 'Lot introuvable'; end if;
  if v_ticket is not null and not exists (select 1 from pilotage.objets where type = 'Incident' and id = v_ticket and pilotage.ticket_du_lot(data, v_lot)) then
    raise exception 'Ticket introuvable sur ce lot'; end if;
  update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = v_lot, ticket_id = v_ticket, immeuble_id = pilotage.ticket_immeuble(v_ticket),
         bail_id = pilotage.mails_bail_a(v_lot, le::date), mandat_id = (select mandat_id from pilotage.v_lots where id = v_lot),
         classe_par = uid, classe_le = now() where id = p_mail;
  insert into pilotage.mails_memoire (email, lot_id) select p->>'email', v_lot from jsonb_array_elements(m.parties) p on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- Page « Mails à vérifier » : n° de lot facultatif pour un ticket d'immeuble
create or replace function public.pilotage_mail_classer(p_id bigint, p_lot_ref text, p_ticket_numero text, p_ignorer boolean) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare m pilotage.mails; v_lot text; v_ticket text; grp text; num text := nullif(trim(coalesce(p_ticket_numero, '')), '');
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  select * into m from pilotage.mails where id = p_id;
  if m.id is null then raise exception 'Mail introuvable'; end if;
  if p_ignorer then
    update pilotage.mails set statut = 'ignore', corps = null, extrait = null, resume = null, pj = '[]'::jsonb, lot_id = null, bail_id = null, mandat_id = null,
           ticket_id = null, immeuble_id = null, candidats = null, methode = 'manuel', classe_par = auth.uid(), classe_le = now() where id = p_id;
    return jsonb_build_object('ignore', true);
  end if;
  if nullif(trim(coalesce(p_lot_ref, '')), '') is null then
    if num is null then raise exception 'Indiquer un n° de lot, ou le n° d''un ticket d''immeuble'; end if;
    select id, data->>'asset_group_id' into v_ticket, grp from pilotage.objets
     where type = 'Incident' and supprime_le is null and data->>'number' = num and coalesce(data->>'asset_id', '') = '' and data->>'asset_group_id' is not null limit 1;
    if v_ticket is null then raise exception 'Ticket n°% : pas un ticket d''immeuble, indiquer aussi le n° de lot', num; end if;
    update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = null, bail_id = null, ticket_id = v_ticket, immeuble_id = grp,
           mandat_id = pilotage.immeuble_mandat(grp), classe_par = auth.uid(), classe_le = now() where id = p_id;
    return jsonb_build_object('ignore', false);
  end if;
  select id into v_lot from pilotage.v_lots where reference = trim(p_lot_ref) limit 1;
  if v_lot is null then raise exception 'Lot % introuvable', p_lot_ref; end if;
  if num is not null then
    select id into v_ticket from pilotage.objets where type = 'Incident' and data->>'number' = num and pilotage.ticket_du_lot(data, v_lot) limit 1;
    if v_ticket is null then raise exception 'Ticket n°% introuvable sur le lot %', p_ticket_numero, p_lot_ref; end if;
  end if;
  update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = v_lot, ticket_id = v_ticket, immeuble_id = pilotage.ticket_immeuble(v_ticket),
         bail_id = pilotage.mails_bail_a(v_lot, le::date), mandat_id = (select mandat_id from pilotage.v_lots where id = v_lot),
         classe_par = auth.uid(), classe_le = now()
   where id = p_id;
  insert into pilotage.mails_memoire (email, lot_id) select p->>'email', v_lot from jsonb_array_elements(m.parties) p on conflict do nothing;
  return jsonb_build_object('ignore', false);
end $$;

-- Lecture d'un mail par la fonction pilotage-mails : référence [UDI T<n°>] d'un ticket d'immeuble, conversation rattachée à un immeuble,
-- tickets d'immeuble parmi les candidats
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
  select a.ticket_id into v_ticket from pilotage.mails_annuaire(p_emails) a where a.role = 'prestataire' and a.lot_id = any(coalesce(lots, '{}'))
     and (a.debut is null or a.debut <= j) and (a.fin is null or a.fin >= j) limit 1;
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

create or replace function public.pilotage_mails_enregistrer(p jsonb) returns bigint
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare nid bigint;
begin
  insert into pilotage.mails (message_id, thread_id, boites, sens, de, a, cc, objet, le, extrait, corps, pj, parties, statut, methode, confiance, resume,
                              lot_id, bail_id, mandat_id, ticket_id, candidats, immeuble_id)
  values (p->>'message_id', p->>'thread_id', coalesce(p->'boites', '{}'::jsonb), p->>'sens', p->>'de',
          coalesce((select array_agg(x) from jsonb_array_elements_text(p->'a') x), '{}'), coalesce((select array_agg(x) from jsonb_array_elements_text(p->'cc') x), '{}'),
          p->>'objet', (p->>'le')::timestamptz, p->>'extrait', p->>'corps', coalesce(p->'pj', '[]'::jsonb), coalesce(p->'parties', '[]'::jsonb),
          p->>'statut', p->>'methode', (p->>'confiance')::numeric, p->>'resume', p->>'lot_id', p->>'bail_id', p->>'mandat_id', p->>'ticket_id', p->'candidats',
          coalesce(p->>'immeuble_id', pilotage.ticket_immeuble(p->>'ticket_id')))
  on conflict (message_id) do update set boites = pilotage.mails.boites || excluded.boites
  returning id into nid;
  return nid;
end $$;

-- Ligne d'un mail : libellé de l'immeuble pour un mail rattaché à un ticket d'immeuble
create or replace function pilotage.mails_ligne(m pilotage.mails) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('id', m.id, 'thread_id', m.thread_id, 'sens', m.sens, 'de', m.de, 'a', m.a, 'cc', m.cc, 'objet', m.objet, 'le', m.le,
    'resume', m.resume, 'extrait', m.extrait, 'pj', (select coalesce(jsonb_agg(jsonb_build_object('nom', x->>'nom', 'taille', x->>'taille', 'cle', x->>'cle')), '[]'::jsonb) from jsonb_array_elements(m.pj) x),
    'parties', m.parties, 'statut', m.statut, 'methode', m.methode, 'lot_id', m.lot_id, 'bail_id', m.bail_id, 'ticket_id', m.ticket_id,
    'lot', (select reference from pilotage.v_lots where id = m.lot_id), 'adresse', (select adresse from pilotage.v_lots where id = m.lot_id),
    'bail', (select reference from pilotage.v_baux where id = m.bail_id),
    'ticket', (select jsonb_build_object('numero', i.data->>'number', 'titre', i.data->>'title') from pilotage.objets i where i.type = 'Incident' and i.id = m.ticket_id),
    'immeuble_id', m.immeuble_id, 'immeuble', case when m.immeuble_id is not null then pilotage.immeuble_libelle(m.immeuble_id) end,
    'boites', (select array_agg(k) from jsonb_object_keys(m.boites) k))
$$;

-- Échanges d'un lot : ses mails et ceux rattachés à un ticket de son immeuble
create or replace function public.pilotage_mails_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null or not pilotage.voit_tableau('sinistres', (select mandat_id from pilotage.v_lots where id = p_asset)) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(pilotage.mails_ligne(m) order by m.le desc) from pilotage.mails m
                    where m.statut = 'classe'
                      and (m.lot_id = p_asset
                           or (m.lot_id is null and m.immeuble_id is not null and exists (
                                 select 1 from pilotage.objets a where a.type = 'Asset' and a.id = p_asset
                                    and coalesce(a.data->'asset_group_memberships', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('asset_group_id', m.immeuble_id)))))), '[]'::jsonb);
end $$;

commit;

-- Vérification : tickets proposés sur un lot de l'immeuble du ticket n°42
-- select x->'tickets' from (select pilotage.addon_lot(l) x from pilotage.objets i, unnest(pilotage.immeuble_lots(i.data->>'asset_group_id')) l
--   where i.type = 'Incident' and i.data->>'number' = '42' limit 1) z;
