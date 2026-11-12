-- 145 : historique des mails Gmail rattaché aux lots, baux et tickets (décisions de Nicolas du 12/11/2026)
--  Boîtes lues : votrecomptable@, votregestionnaire@, nvedrines@, mgatti@, nsleman@ (udi-immo.com, Google Workspace).
--  Chaque boîte reste INACTIVE tant qu'elle n'est pas ouverte à la main (actif = true) : les boîtes nominatives seulement après
--  l'information des personnes concernées.
--  Lecture par la fonction pilotage-mails (compte de service Google, délégation sur le domaine, secret GOOGLE_SA_JSON), toutes les 5 min.
--  Règles :
--   - un mail n'est gardé que si un correspondant extérieur (hors @udi-immo.com) est un contact Rivage : locataire, garant, bailleur,
--     prestataire d'un ticket, syndic. Sinon il est ignoré et rien n'est stocké. Le libellé Gmail « Privé » l'exclut toujours ;
--   - rattachement, par ordre de certitude : référence [UDI L<lot> T<ticket>] dans l'objet, conversation déjà classée, choix déjà fait
--     pour ce correspondant, contact rattaché à un seul lot à la date du mail, sinon l'IA ; en dessous de 0,8 de confiance : « à vérifier »,
--     jamais de rattachement au hasard ;
--   - texte du mail en base (recherche, résumé), pièces jointes sur Cloudflare R2 (dossier mails/) ;
--   - libellés Gmail posés en retour : « Pilotage/Classé » ou « Pilotage/À vérifier ».

begin;

create table if not exists pilotage.mails_boites (
  adresse text primary key,
  actif boolean not null default false,
  import_jours integer not null default 0,      -- historique repris à l'ouverture de la boîte (0 = à partir de maintenant)
  history_id text,                              -- curseur Gmail
  derniere_synchro timestamptz,
  erreur text,
  maj_le timestamptz not null default now()
);
insert into pilotage.mails_boites (adresse) values
  ('votrecomptable@udi-immo.com'), ('votregestionnaire@udi-immo.com'), ('nvedrines@udi-immo.com'), ('mgatti@udi-immo.com'), ('nsleman@udi-immo.com')
on conflict do nothing;

create table if not exists pilotage.mails (
  id bigint generated always as identity primary key,
  message_id text not null unique,               -- en-tête Message-ID : un mail présent dans deux boîtes n'est gardé qu'une fois
  thread_id text,
  boites jsonb not null default '{}'::jsonb,     -- { boîte : identifiant Gmail du message }
  sens text not null check (sens in ('recu', 'envoye')),
  de text, a text[] not null default '{}', cc text[] not null default '{}',
  objet text, le timestamptz not null,
  extrait text, corps text,
  pj jsonb not null default '[]'::jsonb,         -- [{ nom, type, taille, cle (R2) }]
  parties jsonb not null default '[]'::jsonb,    -- correspondants reconnus { email, nom, role }
  statut text not null check (statut in ('classe', 'a_verifier', 'ignore')),  -- ignore : « pas un dossier », gardé sans contenu pour ne pas revenir
  methode text, confiance numeric, resume text,
  lot_id text, bail_id text, mandat_id text, ticket_id text,
  candidats jsonb,
  classe_par uuid, classe_le timestamptz,
  cree_le timestamptz not null default now()
);
create index if not exists mails_lot on pilotage.mails (lot_id, le desc);
create index if not exists mails_ticket on pilotage.mails (ticket_id);
create index if not exists mails_thread on pilotage.mails (thread_id);
create index if not exists mails_statut on pilotage.mails (statut) where statut = 'a_verifier';

-- Choix faits à la main : le même correspondant sera rattaché au même lot la fois suivante (s'il n'a qu'un choix mémorisé)
create table if not exists pilotage.mails_memoire (
  email text not null, lot_id text not null, le timestamptz not null default now(), primary key (email, lot_id)
);

alter table pilotage.mails_boites enable row level security;
alter table pilotage.mails enable row level security;
alter table pilotage.mails_memoire enable row level security;
revoke all on pilotage.mails_boites, pilotage.mails, pilotage.mails_memoire from public, anon, authenticated;

-- Annuaire des contacts Rivage par adresse e-mail, avec le lot, le bail, le mandat ou le ticket et la période concernée
create or replace function pilotage.mails_annuaire(p_emails text[])
returns table(email text, role text, nom text, bail_id text, lot_id text, mandat_id text, ticket_id text, debut date, fin date)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with e as (select lower(trim(x)) x from unnest(p_emails) x)
  select lower(trim(t->>'email')), 'locataire', coalesce(nullif(t->>'company_name', ''), concat_ws(' ', t->>'first_name', t->>'last_name')),
         b.id, b.data->>'asset_id', a.data->>'management_contract_id', null,
         coalesce((t->>'entry_date')::date, (b.data->>'start_date')::date), coalesce((t->>'exit_date')::date, (b.data->>'end_date')::date)
    from pilotage.objets b cross join jsonb_array_elements(coalesce(b.data->'tenants', '[]'::jsonb)) t
    left join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id'
   where b.type = 'LeasingContract' and b.supprime_le is null and lower(trim(t->>'email')) in (select x from e)
  union all
  select lower(trim(pr.data->>'email')), 'garant', pilotage.nom_profil(pr.id), b.id, b.data->>'asset_id', a.data->>'management_contract_id', null,
         coalesce((g->>'entry_date')::date, (b.data->>'start_date')::date), coalesce((g->>'exit_date')::date, (b.data->>'end_date')::date)
    from pilotage.objets b cross join jsonb_array_elements(coalesce(b.data->'guarantors', '[]'::jsonb)) g
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = g->>'id'
    left join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id'
   where b.type = 'LeasingContract' and b.supprime_le is null and lower(trim(pr.data->>'email')) in (select x from e)
  union all
  select lower(trim(pr.data->>'email')), 'bailleur', pilotage.nom_profil(pr.id), null, a.id, m.id, null, vm.debut, vm.fin
    from pilotage.objets m cross join jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = p->>'profile_id'
    join pilotage.objets a on a.type = 'Asset' and a.data->>'management_contract_id' = m.id and a.supprime_le is null
    left join pilotage.v_mandats vm on vm.id = m.id
   where m.type = 'ManagementContract' and m.supprime_le is null and lower(trim(pr.data->>'email')) in (select x from e)
  union all
  select lower(trim(pr.data->>'email')), 'prestataire', pilotage.nom_profil(pr.id), i.data->>'leasing_contract_id', i.data->>'asset_id', null, i.id,
         (i.data->>'declared_at')::date - 15, coalesce((i.data->>'resolved_at')::date + 90, null)
    from pilotage.objets i cross join jsonb_array_elements_text(coalesce(i.data->'contractor_ids', '[]'::jsonb)) c
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = c
   where i.type = 'Incident' and i.supprime_le is null and lower(trim(pr.data->>'email')) in (select x from e)
  union all
  select lower(trim(pr.data->>'email')), 'syndic', pilotage.nom_profil(pr.id), null, a.id, a.data->>'management_contract_id', null, null, null
    from pilotage.objets a join pilotage.objets pr on pr.type = 'Profile' and pr.id = a.data->>'syndic_id'
   where a.type = 'Asset' and a.supprime_le is null and lower(trim(pr.data->>'email')) in (select x from e)
$$;
revoke all on function pilotage.mails_annuaire(text[]) from public, anon, authenticated;

-- Pour la fonction pilotage-mails : correspondants reconnus, rattachement certain s'il y en a un, sinon candidats pour l'IA
create or replace function public.pilotage_mails_preparer(p_emails text[], p_le timestamptz, p_objet text, p_thread text)
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare j date := p_le::date; corr jsonb; lots text[]; ref text[]; v_lot text; v_ticket text; v_bail text; t record; cand jsonb; mem text[];
begin
  select coalesce(jsonb_agg(distinct jsonb_build_object('email', a.email, 'nom', a.nom, 'role', a.role)), '[]'::jsonb),
         array_agg(distinct a.lot_id) filter (where a.lot_id is not null)
    into corr, lots
    from pilotage.mails_annuaire(p_emails) a
   where (a.debut is null or a.debut <= j + 30) and (a.fin is null or a.fin >= j - 180);
  if corr = '[]'::jsonb then
    -- contact connu hors période (ancien locataire, ancien bailleur) : gardé quand même, rattachement à vérifier
    select coalesce(jsonb_agg(distinct jsonb_build_object('email', a.email, 'nom', a.nom, 'role', a.role)), '[]'::jsonb),
           array_agg(distinct a.lot_id) filter (where a.lot_id is not null)
      into corr, lots from pilotage.mails_annuaire(p_emails) a;
  end if;
  if corr = '[]'::jsonb then return jsonb_build_object('garder', false); end if;

  -- 1. Référence dans l'objet : [UDI L27] ou [UDI L27 T145]
  ref := regexp_match(coalesce(p_objet, ''), '\[UDI\s+L([A-Za-z0-9-]+)(?:\s+T(\d+))?\]');
  if ref is not null then
    select id into v_lot from pilotage.v_lots where reference = ref[1] limit 1;
    if ref[2] is not null then
      select id into v_ticket from pilotage.objets where type = 'Incident' and data->>'number' = ref[2] and data->>'asset_id' = v_lot limit 1;
    end if;
    if v_lot is not null then
      return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', 'reference', 'lot_id', v_lot, 'ticket_id', v_ticket,
        'bail_id', pilotage.mails_bail_a(v_lot, j), 'mandat_id', (select mandat_id from pilotage.v_lots where id = v_lot));
    end if;
  end if;
  -- 2. Conversation déjà classée
  select m.lot_id, m.ticket_id, m.bail_id into t from pilotage.mails m
   where p_thread is not null and m.thread_id = p_thread and m.statut = 'classe' and m.lot_id is not null order by m.le desc limit 1;
  if t.lot_id is not null then
    return jsonb_build_object('garder', true, 'parties', corr, 'certain', true, 'methode', 'conversation', 'lot_id', t.lot_id, 'ticket_id', t.ticket_id,
      'bail_id', t.bail_id, 'mandat_id', (select mandat_id from pilotage.v_lots where id = t.lot_id));
  end if;
  -- 3. Choix déjà fait à la main pour ce correspondant (un seul lot mémorisé)
  select array_agg(distinct mm.lot_id) into mem from pilotage.mails_memoire mm where mm.email = any(select lower(trim(x)) from unnest(p_emails) x);
  if cardinality(mem) = 1 then lots := mem; end if;

  -- Candidats : lots du correspondant, bail en cours à la date du mail, tickets ouverts à cette date
  select coalesce(jsonb_agg(jsonb_build_object(
      'lot_id', l.id, 'lot', l.reference, 'adresse', l.adresse, 'mandat_id', l.mandat_id,
      'bail_id', pilotage.mails_bail_a(l.id, j),
      'locataires', (select vb.locataires from pilotage.v_baux vb where vb.id = pilotage.mails_bail_a(l.id, j)),
      'tickets', (select coalesce(jsonb_agg(jsonb_build_object('ticket_id', i.id, 'numero', i.data->>'number', 'titre', i.data->>'title')), '[]'::jsonb)
                    from pilotage.objets i where i.type = 'Incident' and i.supprime_le is null and i.data->>'asset_id' = l.id
                     and (i.data->>'declared_at')::date <= j + 1
                     and (i.data->>'resolved_at' is null or (i.data->>'resolved_at')::date >= j - 30)))), '[]'::jsonb)
    into cand from pilotage.v_lots l where l.id = any(coalesce(lots, '{}'));

  -- 4. Un seul lot et au plus un ticket ouvert (ou un ticket dont le correspondant est le prestataire) : rattachement certain
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
        'bail_id', cand->0->>'bail_id', 'mandat_id', cand->0->>'mandat_id', 'candidats', cand);
    end if;
  end if;
  -- 5. Sinon : l'IA choisit parmi les candidats (lot, et ticket s'il y en a d'ouverts)
  return jsonb_build_object('garder', true, 'parties', corr, 'certain', false, 'candidats', cand);
end $$;

-- Bail en cours sur un lot à une date (le plus récent commencé avant la date)
create or replace function pilotage.mails_bail_a(p_lot text, p_le date) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select b.id from pilotage.v_baux b where b.lot_id = p_lot and (b.debut is null or b.debut <= p_le + 30)
   order by (b.fin is null or b.fin >= p_le) desc, b.debut desc nulls last limit 1
$$;
revoke all on function public.pilotage_mails_preparer(text[], timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_mails_preparer(text[], timestamptz, text, text) to service_role;

-- Enregistrement par la fonction pilotage-mails (un mail déjà vu dans une autre boîte : on ajoute la boîte)
create or replace function public.pilotage_mails_enregistrer(p jsonb) returns bigint
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare nid bigint;
begin
  insert into pilotage.mails (message_id, thread_id, boites, sens, de, a, cc, objet, le, extrait, corps, pj, parties, statut, methode, confiance, resume,
                              lot_id, bail_id, mandat_id, ticket_id, candidats)
  values (p->>'message_id', p->>'thread_id', coalesce(p->'boites', '{}'::jsonb), p->>'sens', p->>'de',
          coalesce((select array_agg(x) from jsonb_array_elements_text(p->'a') x), '{}'), coalesce((select array_agg(x) from jsonb_array_elements_text(p->'cc') x), '{}'),
          p->>'objet', (p->>'le')::timestamptz, p->>'extrait', p->>'corps', coalesce(p->'pj', '[]'::jsonb), coalesce(p->'parties', '[]'::jsonb),
          p->>'statut', p->>'methode', (p->>'confiance')::numeric, p->>'resume', p->>'lot_id', p->>'bail_id', p->>'mandat_id', p->>'ticket_id', p->'candidats')
  on conflict (message_id) do update set boites = pilotage.mails.boites || excluded.boites
  returning id into nid;
  return nid;
end $$;
revoke all on function public.pilotage_mails_enregistrer(jsonb) from public, anon, authenticated;
grant execute on function public.pilotage_mails_enregistrer(jsonb) to service_role;

create or replace function public.pilotage_mails_deja_vu(p_message_id text, p_boite text, p_gmail text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare m pilotage.mails;
begin
  update pilotage.mails set boites = boites || jsonb_build_object(p_boite, p_gmail) where message_id = p_message_id returning * into m;
  return case when m.id is null then null else jsonb_build_object('id', m.id, 'statut', m.statut) end;
end $$;
revoke all on function public.pilotage_mails_deja_vu(text, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_mails_deja_vu(text, text, text) to service_role;

create or replace function public.pilotage_mails_boites() returns setof pilotage.mails_boites
language sql security definer set search_path to 'pilotage', 'public' as $$ select * from pilotage.mails_boites where actif order by adresse $$;
create or replace function public.pilotage_mails_boite_maj(p_adresse text, p_history text, p_erreur text) returns void
language sql security definer set search_path to 'pilotage', 'public' as $$
  update pilotage.mails_boites set history_id = coalesce(p_history, history_id), erreur = p_erreur, derniere_synchro = now(), maj_le = now() where adresse = p_adresse
$$;
revoke all on function public.pilotage_mails_boites(), public.pilotage_mails_boite_maj(text, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_mails_boites(), public.pilotage_mails_boite_maj(text, text, text) to service_role;

-- Lecture côté écran : mails d'un lot, d'un ticket, à vérifier ; contenu d'un mail ; classement à la main
create or replace function pilotage.mails_ligne(m pilotage.mails) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('id', m.id, 'thread_id', m.thread_id, 'sens', m.sens, 'de', m.de, 'a', m.a, 'cc', m.cc, 'objet', m.objet, 'le', m.le,
    'resume', m.resume, 'extrait', m.extrait, 'pj', (select coalesce(jsonb_agg(jsonb_build_object('nom', x->>'nom', 'taille', x->>'taille', 'cle', x->>'cle')), '[]'::jsonb) from jsonb_array_elements(m.pj) x),
    'parties', m.parties, 'statut', m.statut, 'methode', m.methode, 'lot_id', m.lot_id, 'bail_id', m.bail_id, 'ticket_id', m.ticket_id,
    'lot', (select reference from pilotage.v_lots where id = m.lot_id), 'adresse', (select adresse from pilotage.v_lots where id = m.lot_id),
    'bail', (select reference from pilotage.v_baux where id = m.bail_id),
    'ticket', (select jsonb_build_object('numero', i.data->>'number', 'titre', i.data->>'title') from pilotage.objets i where i.type = 'Incident' and i.id = m.ticket_id),
    'boites', (select array_agg(k) from jsonb_object_keys(m.boites) k))
$$;

create or replace function public.pilotage_mails_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null or not pilotage.voit_tableau('sinistres', (select mandat_id from pilotage.v_lots where id = p_asset)) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(pilotage.mails_ligne(m) order by m.le desc) from pilotage.mails m where m.lot_id = p_asset and m.statut = 'classe'), '[]'::jsonb);
end $$;

create or replace function public.pilotage_mails_ticket(p_ticket text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(pilotage.mails_ligne(m) order by m.le desc) from pilotage.mails m
                    where m.ticket_id = p_ticket and m.statut = 'classe' and pilotage.voit_tableau('sinistres', m.mandat_id)), '[]'::jsonb);
end $$;

create or replace function public.pilotage_mails_a_verifier() returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(pilotage.mails_ligne(m) || jsonb_build_object('candidats', m.candidats, 'confiance', m.confiance) order by m.le desc)
                     from pilotage.mails m where m.statut = 'a_verifier'), '[]'::jsonb);
end $$;

create or replace function public.pilotage_mail_lire(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare m pilotage.mails;
begin
  select * into m from pilotage.mails where id = p_id;
  if m.id is null or pilotage.mon_role() is null
     or not (pilotage.voit_tableau('sinistres', m.mandat_id) or (m.statut = 'a_verifier' and (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable'))))
  then raise exception 'Accès refusé'; end if;
  return pilotage.mails_ligne(m) || jsonb_build_object('corps', m.corps, 'pj_complet', m.pj);
end $$;

-- Classement à la main : lot (référence), ticket (numéro) facultatif ; ou « ce n'est pas un dossier » (le mail est retiré)
create or replace function public.pilotage_mail_classer(p_id bigint, p_lot_ref text, p_ticket_numero text, p_ignorer boolean) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare m pilotage.mails; v_lot text; v_ticket text;
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  select * into m from pilotage.mails where id = p_id;
  if m.id is null then raise exception 'Mail introuvable'; end if;
  if p_ignorer then
    update pilotage.mails set statut = 'ignore', corps = null, extrait = null, resume = null, pj = '[]'::jsonb, lot_id = null, bail_id = null, mandat_id = null,
           ticket_id = null, candidats = null, methode = 'manuel', classe_par = auth.uid(), classe_le = now() where id = p_id;
    return jsonb_build_object('ignore', true);
  end if;
  select id into v_lot from pilotage.v_lots where reference = trim(p_lot_ref) limit 1;
  if v_lot is null then raise exception 'Lot % introuvable', p_lot_ref; end if;
  if nullif(trim(coalesce(p_ticket_numero, '')), '') is not null then
    select id into v_ticket from pilotage.objets where type = 'Incident' and data->>'number' = trim(p_ticket_numero) and data->>'asset_id' = v_lot limit 1;
    if v_ticket is null then raise exception 'Ticket n°% introuvable sur le lot %', p_ticket_numero, p_lot_ref; end if;
  end if;
  update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = v_lot, ticket_id = v_ticket,
         bail_id = pilotage.mails_bail_a(v_lot, le::date), mandat_id = (select mandat_id from pilotage.v_lots where id = v_lot),
         classe_par = auth.uid(), classe_le = now()
   where id = p_id;
  insert into pilotage.mails_memoire (email, lot_id) select p->>'email', v_lot from jsonb_array_elements(m.parties) p on conflict do nothing;
  return jsonb_build_object('ignore', false);
end $$;

create or replace function public.pilotage_mails_peut_classer() returns boolean
language sql stable security definer set search_path to 'pilotage', 'public' as $$ select pilotage.peut_suivre_baux() or coalesce(pilotage.mon_role() in ('direction', 'comptable'), false) $$;
create or replace function public.pilotage_mail_gmail(p_id bigint) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$ select jsonb_build_object('boites', boites, 'statut', statut) from pilotage.mails where id = p_id $$;
revoke all on function public.pilotage_mail_gmail(bigint) from public, anon, authenticated;
grant execute on function public.pilotage_mail_gmail(bigint) to service_role;

revoke all on function public.pilotage_mails_peut_classer(), public.pilotage_mails_lot(text), public.pilotage_mails_ticket(text), public.pilotage_mails_a_verifier(),
  public.pilotage_mail_lire(bigint), public.pilotage_mail_classer(bigint, text, text, boolean) from public, anon;
grant execute on function public.pilotage_mails_peut_classer(), public.pilotage_mails_lot(text), public.pilotage_mails_ticket(text), public.pilotage_mails_a_verifier(),
  public.pilotage_mail_lire(bigint), public.pilotage_mail_classer(bigint, text, text, boolean) to authenticated;
revoke all on function pilotage.mails_ligne(pilotage.mails), pilotage.mails_bail_a(text, date) from public, anon, authenticated;

-- Référence dans l'objet des mails envoyés depuis le pilotage (142) : [UDI L<lot>] ; les réponses la gardent et sont rattachées avec certitude
create or replace function public.pilotage_mail_preparer(p_bail text, p_to text[], p_objet text, p_corps text, p_cle text, p_etape text)
returns jsonb language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare c jsonb := pilotage.contacts_bail(p_bail); connues text[]; a text; nid bigint; v_ref text;
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() = 'comptable') then raise exception 'Accès refusé'; end if;
  if nullif(trim(coalesce(p_objet, '')), '') is null or nullif(trim(coalesce(p_corps, '')), '') is null then raise exception 'Mail vide'; end if;
  if coalesce(cardinality(p_to), 0) = 0 then raise exception 'Aucun destinataire'; end if;
  if cardinality(p_to) > 10 then raise exception 'Trop de destinataires'; end if;
  select coalesce(array_agg(distinct lower(trim(x->>'email'))), '{}') into connues
    from jsonb_array_elements(coalesce(c->'locataires', '[]'::jsonb) || coalesce(c->'bailleurs', '[]'::jsonb)) x
   where nullif(trim(x->>'email'), '') is not null;
  foreach a in array p_to loop
    if not lower(trim(a)) = any(connues) then raise exception 'Adresse % absente des contacts du bail dans Rivage', a; end if;
  end loop;
  select '[UDI L' || l.reference || ']' into v_ref from pilotage.v_baux b join pilotage.v_lots l on l.id = b.lot_id where b.id = p_bail and l.reference is not null;
  insert into pilotage.mails_envois (bail_id, destinataires, objet, corps, cle, etape, par)
  values (p_bail, (select array_agg(lower(trim(x))) from unnest(p_to) x), trim(p_objet) || coalesce(' ' || v_ref, ''), p_corps, p_cle, p_etape, auth.uid())
  returning id into nid;
  return jsonb_build_object('id', nid, 'to', (select array_agg(lower(trim(x))) from unnest(p_to) x), 'objet', trim(p_objet) || coalesce(' ' || v_ref, ''));
end $$;

-- Lecture des boîtes toutes les 5 minutes (sans effet tant qu'aucune boîte n'est active ou que le secret Google manque)
select cron.unschedule('pilotage-mails') where exists (select 1 from cron.job where jobname = 'pilotage-mails');
select cron.schedule('pilotage-mails', '1-59/5 * * * *', $c$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-mails',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{}'::jsonb, timeout_milliseconds := 300000) $c$);

commit;

-- Ouverture d'une boîte (après l'accès Google, et pour une boîte nominative après l'information de la personne) :
-- update pilotage.mails_boites set actif = true, import_jours = 0 where adresse = 'votregestionnaire@udi-immo.com';
