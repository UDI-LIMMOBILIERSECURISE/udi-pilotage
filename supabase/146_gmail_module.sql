-- 146 : module « Pilotage UDI » dans Gmail (décision de Nicolas du 12/11/2026)
--  À la lecture d'un mail : lot, bail, ticket reconnus, rattachement en un clic si le pilotage hésite, derniers échanges.
--  À l'écriture : recherche d'un lot / bail / ticket, référence [UDI L<lot> T<ticket>] et destinataires du dossier en un clic.
--  Le module (Apps Script, dossier gmail-addon/) appelle la fonction pilotage-gmail avec le jeton d'identité Google de la personne ;
--  la fonction vérifie le jeton (domaine udi-immo.com) puis appelle ces fonctions avec l'adresse : les droits sont ceux du membre
--  du pilotage qui a cette adresse (aucun accès pour une adresse qui n'est pas membre actif).

begin;

create or replace function pilotage.addon_role(p_email text) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select m.role from pilotage.membres m join auth.users u on u.id = m.user_id where lower(u.email) = lower(trim(p_email)) and m.actif limit 1
$$;
revoke all on function pilotage.addon_role(text) from public, anon, authenticated;

-- Fiche courte d'un lot pour le module : adresse, bail en cours, contacts (adresses mail), tickets ouverts
create or replace function pilotage.addon_lot(p_lot text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('lot_id', l.id, 'lot', l.reference, 'adresse', l.adresse,
    'bail', vb.reference, 'locataires', vb.locataires,
    'bailleur', pilotage.bailleurs_mandat(l.mandat_id),
    'contacts', coalesce(pilotage.contacts_bail(vb.id), pilotage.contacts_mandat(l.mandat_id)),
    'tickets', (select coalesce(jsonb_agg(jsonb_build_object('ticket_id', i.id, 'numero', i.data->>'number', 'titre', i.data->>'title') order by i.data->>'declared_at' desc), '[]'::jsonb)
                  from pilotage.objets i where i.type = 'Incident' and i.supprime_le is null and i.data->>'asset_id' = l.id
                   and coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') and i.data->>'archived_at' is null))
  from pilotage.v_lots l left join pilotage.v_baux vb on vb.id = pilotage.mails_bail_a(l.id, current_date)
  where l.id = p_lot
$$;
revoke all on function pilotage.addon_lot(text) from public, anon, authenticated;

create or replace function public.pilotage_addon_contexte(p_email text, p_message_id text, p_emails text[]) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare r text := pilotage.addon_role(p_email); m pilotage.mails; lots text[];
begin
  if r is null then raise exception 'Adresse % : pas d''accès au pilotage', p_email; end if;
  select * into m from pilotage.mails where message_id = p_message_id;
  select array_agg(distinct a.lot_id) filter (where a.lot_id is not null) into lots
    from pilotage.mails_annuaire((select array_agg(x) from unnest(p_emails) x where x !~* '@udi-immo\.com$')) a;
  return jsonb_build_object(
    'peut_classer', r in ('direction', 'superviseur', 'gestionnaire', 'comptable'),
    'mail', case when m.id is null then null else pilotage.mails_ligne(m) || jsonb_build_object('candidats', m.candidats) end,
    'parties', (select coalesce(jsonb_agg(distinct jsonb_build_object('email', a.email, 'nom', a.nom, 'role', a.role)), '[]'::jsonb)
                  from pilotage.mails_annuaire((select array_agg(x) from unnest(p_emails) x where x !~* '@udi-immo\.com$')) a),
    'lots', (select coalesce(jsonb_agg(pilotage.addon_lot(x)), '[]'::jsonb) from unnest(coalesce(case when m.lot_id is not null then array[m.lot_id] end, lots, '{}')) x),
    'echanges', (select coalesce(jsonb_agg(jsonb_build_object('le', e.le, 'sens', e.sens, 'objet', e.objet, 'resume', coalesce(e.resume, e.extrait)) order by e.le desc), '[]'::jsonb)
                   from (select * from pilotage.mails e where e.statut = 'classe' and e.lot_id = coalesce(m.lot_id, case when cardinality(lots) = 1 then lots[1] end)
                           and e.message_id is distinct from p_message_id order by e.le desc limit 5) e));
end $$;

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
          or exists (select 1 from pilotage.objets i where i.type = 'Incident' and i.data->>'asset_id' = l.id and (i.data->>'number' = q or i.data->>'title' ilike '%' || q || '%'))
       order by (l.reference = q) desc, l.adresse limit 12) t), '[]'::jsonb);
end $$;

create or replace function public.pilotage_addon_classer(p_email text, p_mail bigint, p_lot text, p_ticket text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare r text := pilotage.addon_role(p_email); m pilotage.mails; uid uuid;
begin
  if r is null or r not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Classement réservé à la gestion'; end if;
  select * into m from pilotage.mails where id = p_mail;
  if m.id is null then raise exception 'Mail introuvable dans le pilotage'; end if;
  if not exists (select 1 from pilotage.v_lots where id = p_lot) then raise exception 'Lot introuvable'; end if;
  if p_ticket is not null and not exists (select 1 from pilotage.objets where type = 'Incident' and id = p_ticket and data->>'asset_id' = p_lot) then raise exception 'Ticket introuvable sur ce lot'; end if;
  select u.id into uid from auth.users u where lower(u.email) = lower(trim(p_email));
  update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = p_lot, ticket_id = p_ticket,
         bail_id = pilotage.mails_bail_a(p_lot, le::date), mandat_id = (select mandat_id from pilotage.v_lots where id = p_lot),
         classe_par = uid, classe_le = now() where id = p_mail;
  insert into pilotage.mails_memoire (email, lot_id) select p->>'email', p_lot from jsonb_array_elements(m.parties) p on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.pilotage_addon_contexte(text, text, text[]), public.pilotage_addon_chercher(text, text),
  public.pilotage_addon_classer(text, bigint, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_addon_contexte(text, text, text[]), public.pilotage_addon_chercher(text, text),
  public.pilotage_addon_classer(text, bigint, text, text) to service_role;

commit;
