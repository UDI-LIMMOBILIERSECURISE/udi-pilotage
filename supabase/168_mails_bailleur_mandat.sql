-- 168 : rattachement des mails au niveau d'un mandat ou d'un bailleur (tous ses biens).
-- Un bailleur = une adresse mail de propriétaire Rivage, qui peut couvrir plusieurs profils (SCI, nom propre) et plusieurs mandats.
-- Niveaux d'un mail classé :
--   lot      : lot_id renseigné (inchangé)
--   immeuble : ticket d'immeuble, immeuble_id sans lot (inchangé, 151)
--   mandat   : mandat_id seul (tous les lots du mandat)
--   bailleur : bailleur_email seul (tous les mandats de cette adresse)
-- Références insérées par le module Gmail : [UDI M<n° de mandat>] et [UDI B<n° de bailleur>].
-- Aucune suppression de données. Seul DROP : l'ancienne contrainte de format de mails_choix, recréée aussitôt.

-- ---------- 1. Bailleurs et mandats ----------
create table if not exists pilotage.bailleurs (
  numero serial primary key,
  email text not null unique,
  cree_le timestamptz not null default now()
);
revoke all on pilotage.bailleurs from public, anon, authenticated;

alter table pilotage.mails add column if not exists bailleur_email text;
create index if not exists mails_bailleur on pilotage.mails (bailleur_email) where bailleur_email is not null;
create index if not exists mails_mandat on pilotage.mails (mandat_id) where mandat_id is not null;

-- Mandats (non supprimés) dont un propriétaire a cette adresse
create or replace function pilotage.bailleur_mandats(p_email text) returns setof text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select distinct m.id
    from pilotage.objets m cross join jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = p->>'profile_id'
   where m.type = 'ManagementContract' and m.supprime_le is null
     and lower(trim(pr.data->>'email')) = lower(trim(p_email)) and nullif(trim(p_email), '') is not null
$$;

-- Numérote les adresses de propriétaires pas encore connues (appelée par le script, la recherche et le classement)
create or replace function pilotage.bailleurs_maj() returns void
language sql security definer set search_path to 'pilotage', 'public' as $$
  insert into pilotage.bailleurs (email)
  select distinct lower(trim(pr.data->>'email'))
    from pilotage.objets m cross join jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = p->>'profile_id'
   where m.type = 'ManagementContract' and m.supprime_le is null and nullif(trim(pr.data->>'email'), '') is not null
     and lower(trim(pr.data->>'email')) !~ '@udi-immo\.com$'
  on conflict (email) do nothing
$$;

-- Code court d'un mandat pour la référence : le n° en tête de la référence Rivage s'il est unique, sinon l'identifiant Rivage
create or replace function pilotage.mandat_code(p_mandat text) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select case when n is not null and (select count(*) from pilotage.v_mandats x where (regexp_match(x.reference, '^\s*(\d+)'))[1] = n) = 1 then n else p_mandat end
    from (select (regexp_match(reference, '^\s*(\d+)'))[1] n from pilotage.v_mandats where id = p_mandat) t
$$;

create or replace function pilotage.mandat_par_code(p_code text) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce((select id from pilotage.v_mandats where id = p_code),
                  (select min(id) from pilotage.v_mandats where (regexp_match(reference, '^\s*(\d+)'))[1] = p_code
                    having count(*) = 1))
$$;

create or replace function pilotage.mandat_info(p_mandat text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('niveau', 'mandat', 'mandat_id', vm.id, 'code', pilotage.mandat_code(vm.id), 'reference', trim(vm.reference),
           'nom', pilotage.bailleurs_mandat(vm.id), 'lots', (select count(*) from pilotage.v_lots l where l.mandat_id = vm.id), 'statut', vm.statut)
    from pilotage.v_mandats vm where vm.id = p_mandat
$$;

create or replace function pilotage.bailleur_info(p_email text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('niveau', 'bailleur', 'email', lower(trim(p_email)),
           'numero', (select numero from pilotage.bailleurs where email = lower(trim(p_email))),
           'nom', (select string_agg(distinct pilotage.nom_profil(pr.id), ', ') from pilotage.objets pr
                    where pr.type = 'Profile' and lower(trim(pr.data->>'email')) = lower(trim(p_email))
                      and exists (select 1 from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
                                   where m.type = 'ManagementContract' and m.supprime_le is null and p->>'profile_id' = pr.id)),
           'mandats', (select count(*) from pilotage.bailleur_mandats(p_email)),
           'lots', (select count(*) from pilotage.v_lots l where l.mandat_id in (select pilotage.bailleur_mandats(p_email))))
$$;

-- Niveaux proposés pour un mail d'après ses correspondants : le bailleur s'il a au moins 2 mandats, puis ses mandats d'au moins 2 lots
create or replace function pilotage.mails_niveaux(p_emails text[]) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with e as (select distinct lower(trim(x)) x from unnest(coalesce(p_emails, '{}')) x where x ~ '@' and lower(x) !~ '@udi-immo\.com$'),
  b as (select e.x, pilotage.bailleur_info(e.x) i from e where exists (select 1 from pilotage.bailleur_mandats(e.x))),
  md as (select distinct mid from b, pilotage.bailleur_mandats(b.x) mid),
  mi as (select pilotage.mandat_info(mid) i from md)
  select coalesce((select jsonb_agg(i order by (i->>'lots')::int desc) from b where (i->>'mandats')::int >= 2), '[]'::jsonb)
      || coalesce((select jsonb_agg(i order by (i->>'lots')::int desc, i->>'reference') from mi where (i->>'lots')::int >= 2), '[]'::jsonb)
$$;

revoke all on function pilotage.bailleur_mandats(text), pilotage.bailleurs_maj(), pilotage.mandat_code(text), pilotage.mandat_par_code(text),
  pilotage.mandat_info(text), pilotage.bailleur_info(text), pilotage.mails_niveaux(text[]) from public, anon, authenticated;

select pilotage.bailleurs_maj();

-- ---------- 2. Format des références gardées par le module Gmail ----------
alter table pilotage.mails_choix drop constraint if exists mails_choix_ref_check;
alter table pilotage.mails_choix add constraint mails_choix_ref_check
  check (ref ~ '^\[UDI (L[A-Za-z0-9-]+( T\d+)?|T\d+|M[A-Za-z0-9_-]+|B\d+)\]$');

-- ---------- 3. Ligne d'un mail : niveau de rattachement ----------
create or replace function pilotage.mails_ligne(m pilotage.mails) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('id', m.id, 'thread_id', m.thread_id, 'sens', m.sens, 'de', m.de, 'a', m.a, 'cc', m.cc, 'objet', m.objet, 'le', m.le,
    'resume', m.resume, 'extrait', m.extrait, 'pj', (select coalesce(jsonb_agg(jsonb_build_object('nom', x->>'nom', 'taille', x->>'taille', 'cle', x->>'cle')), '[]'::jsonb) from jsonb_array_elements(m.pj) x),
    'parties', m.parties, 'statut', m.statut, 'methode', m.methode, 'lot_id', m.lot_id, 'bail_id', m.bail_id, 'ticket_id', m.ticket_id,
    'lot', (select reference from pilotage.v_lots where id = m.lot_id), 'adresse', (select adresse from pilotage.v_lots where id = m.lot_id),
    'bail', (select reference from pilotage.v_baux where id = m.bail_id),
    'ticket', (select jsonb_build_object('numero', i.data->>'number', 'titre', i.data->>'title') from pilotage.objets i where i.type = 'Incident' and i.id = m.ticket_id),
    'immeuble_id', m.immeuble_id, 'immeuble', case when m.immeuble_id is not null then pilotage.immeuble_libelle(m.immeuble_id) end,
    'boites', (select array_agg(k) from jsonb_object_keys(m.boites) k),
    'mandat_id', m.mandat_id, 'bailleur_email', m.bailleur_email,
    'niveau', case when m.statut <> 'classe' then null when m.lot_id is not null then 'lot' when m.immeuble_id is not null then 'immeuble'
                   when m.bailleur_email is not null then 'bailleur' when m.mandat_id is not null then 'mandat' end,
    'mandat', case when m.lot_id is null and m.immeuble_id is null and m.mandat_id is not null then pilotage.mandat_info(m.mandat_id) end,
    'bailleur', case when m.bailleur_email is not null then pilotage.bailleur_info(m.bailleur_email) end)
$$;

-- ---------- 4. Lecture et rangement automatique ----------
-- L'ancienne fonction (152) devient l'étape « lots » ; la nouvelle traite d'abord les références M/B et les conversations
-- déjà rangées au niveau mandat ou bailleur, et ajoute les niveaux proposés à l'IA.
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'pilotage_mails_preparer_lots') then
    alter function public.pilotage_mails_preparer(text[], timestamptz, text, text) rename to pilotage_mails_preparer_lots;
  end if;
end $$;
revoke all on function public.pilotage_mails_preparer_lots(text[], timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_mails_preparer_lots(text[], timestamptz, text, text) to service_role;

create or replace function public.pilotage_mails_preparer(p_emails text[], p_le timestamptz, p_objet text, p_thread text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare r jsonb := public.pilotage_mails_preparer_lots(p_emails, p_le, p_objet, p_thread); ref text[]; v_m text; v_b text; t record; niv jsonb;
begin
  if not coalesce((r->>'garder')::boolean, false) then return r; end if;
  -- Références posées par le module Gmail
  ref := regexp_match(coalesce(p_objet, ''), '\[UDI\s+B(\d+)\]');
  if ref is not null then
    select email into v_b from pilotage.bailleurs where numero = ref[1]::int;
    if v_b is not null then
      return jsonb_build_object('garder', true, 'parties', r->'parties', 'certain', true, 'methode', 'reference', 'bailleur_email', v_b);
    end if;
  end if;
  ref := regexp_match(coalesce(p_objet, ''), '\[UDI\s+M([A-Za-z0-9_-]+)\]');
  if ref is not null then
    v_m := pilotage.mandat_par_code(ref[1]);
    if v_m is not null then
      return jsonb_build_object('garder', true, 'parties', r->'parties', 'certain', true, 'methode', 'reference', 'mandat_id', v_m);
    end if;
  end if;
  niv := pilotage.mails_niveaux(p_emails);
  -- Bailleur de plusieurs biens : la mémoire (dernier lot choisi pour cette adresse) ou un contact sur un seul lot ne suffisent plus,
  -- l'IA choisit entre ce lot et le niveau bailleur / mandat (sinon : à vérifier)
  if jsonb_array_length(niv) > 0 and coalesce((r->>'certain')::boolean, false) and r->>'methode' in ('memoire', 'contact') then
    r := r || jsonb_build_object('certain', false);
  end if;
  -- Réponse dans une conversation rangée au niveau mandat ou bailleur (une conversation rangée sur un lot reste prioritaire)
  if not coalesce((r->>'certain')::boolean, false) and p_thread is not null then
    select m.mandat_id, m.bailleur_email into t from pilotage.mails m
     where m.thread_id = p_thread and m.statut = 'classe' and m.lot_id is null and m.immeuble_id is null
       and (m.mandat_id is not null or m.bailleur_email is not null) order by m.le desc limit 1;
    if t.bailleur_email is not null or t.mandat_id is not null then
      return jsonb_build_object('garder', true, 'parties', r->'parties', 'certain', true, 'methode', 'conversation',
        'bailleur_email', t.bailleur_email, 'mandat_id', case when t.bailleur_email is null then t.mandat_id end);
    end if;
  end if;
  return r || jsonb_build_object('niveaux', niv);
end $$;
revoke all on function public.pilotage_mails_preparer(text[], timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_mails_preparer(text[], timestamptz, text, text) to service_role;

create or replace function public.pilotage_mails_enregistrer(p jsonb) returns bigint
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare nid bigint;
begin
  insert into pilotage.mails (message_id, thread_id, boites, sens, de, a, cc, objet, le, extrait, corps, pj, parties, statut, methode, confiance, resume,
                              lot_id, bail_id, mandat_id, ticket_id, candidats, immeuble_id, bailleur_email)
  values (p->>'message_id', p->>'thread_id', coalesce(p->'boites', '{}'::jsonb), p->>'sens', p->>'de',
          coalesce((select array_agg(x) from jsonb_array_elements_text(p->'a') x), '{}'), coalesce((select array_agg(x) from jsonb_array_elements_text(p->'cc') x), '{}'),
          p->>'objet', (p->>'le')::timestamptz, p->>'extrait', p->>'corps', coalesce(p->'pj', '[]'::jsonb), coalesce(p->'parties', '[]'::jsonb),
          p->>'statut', p->>'methode', (p->>'confiance')::numeric, p->>'resume', p->>'lot_id', p->>'bail_id', p->>'mandat_id', p->>'ticket_id', p->'candidats',
          coalesce(p->>'immeuble_id', pilotage.ticket_immeuble(p->>'ticket_id')), nullif(lower(trim(p->>'bailleur_email')), ''))
  on conflict (message_id) do update set boites = pilotage.mails.boites || excluded.boites
  returning id into nid;
  return nid;
end $$;
revoke all on function public.pilotage_mails_enregistrer(jsonb) from public, anon, authenticated;
grant execute on function public.pilotage_mails_enregistrer(jsonb) to service_role;

-- ---------- 5. Classement à la main (pilotage et module Gmail) ----------
create or replace function pilotage.mail_classer_niveau(p_id bigint, p_mandat text, p_bailleur text, p_par uuid) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_m text := nullif(trim(coalesce(p_mandat, '')), ''); v_b text := nullif(lower(trim(coalesce(p_bailleur, ''))), '');
begin
  if not exists (select 1 from pilotage.mails where id = p_id) then raise exception 'Mail introuvable'; end if;
  if (v_m is null) = (v_b is null) then raise exception 'Choisir un mandat ou un bailleur'; end if;
  if v_m is not null and not exists (select 1 from pilotage.v_mandats where id = v_m) then raise exception 'Mandat introuvable'; end if;
  if v_b is not null and not exists (select 1 from pilotage.bailleur_mandats(v_b)) then raise exception 'Aucun mandat Rivage pour l''adresse %', v_b; end if;
  perform pilotage.bailleurs_maj();
  update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = null, bail_id = null, ticket_id = null, immeuble_id = null,
         mandat_id = v_m, bailleur_email = v_b, classe_par = p_par, classe_le = now() where id = p_id;
end $$;
revoke all on function pilotage.mail_classer_niveau(bigint, text, text, uuid) from public, anon, authenticated;

create or replace function public.pilotage_mail_classer_niveau(p_id bigint, p_mandat text, p_bailleur text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  perform pilotage.mail_classer_niveau(p_id, p_mandat, p_bailleur, auth.uid());
  return jsonb_build_object('ignore', false);
end $$;
revoke all on function public.pilotage_mail_classer_niveau(bigint, text, text) from public, anon;
grant execute on function public.pilotage_mail_classer_niveau(bigint, text, text) to authenticated;

create or replace function public.pilotage_addon_classer_niveau(p_email text, p_mail bigint, p_mandat text, p_bailleur text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare r text := pilotage.addon_role(p_email); uid uuid;
begin
  if r is null or r not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Classement réservé à la gestion'; end if;
  select u.id into uid from auth.users u where lower(u.email) = pilotage.addon_adresse(p_email);
  perform pilotage.mail_classer_niveau(p_mail, p_mandat, p_bailleur, uid);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.pilotage_addon_classer_niveau(text, bigint, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_addon_classer_niveau(text, bigint, text, text) to service_role;

-- Un classement sur un lot ou un ticket efface le niveau bailleur éventuel
create or replace function pilotage.mails_niveau_coherent() returns trigger
language plpgsql as $$
begin
  if new.lot_id is not null or new.immeuble_id is not null or new.statut <> 'classe' then new.bailleur_email := null; end if;
  return new;
end $$;
drop trigger if exists mails_niveau_coherent on pilotage.mails;
create trigger mails_niveau_coherent before insert or update on pilotage.mails for each row execute function pilotage.mails_niveau_coherent();

-- ---------- 6. Écrans ----------
-- Mails à vérifier : niveaux proposés (bailleur, mandats) avant les lots
create or replace function public.pilotage_mails_a_verifier() returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(pilotage.mails_ligne(m) || jsonb_build_object('candidats', m.candidats, 'confiance', m.confiance,
                     'niveaux', pilotage.mails_niveaux(array[m.de] || m.a || m.cc)) order by m.le desc)
                     from pilotage.mails m where m.statut = 'a_verifier'), '[]'::jsonb);
end $$;

-- Échanges d'un lot : mails du lot, plus ceux rangés au niveau de son mandat ou de son bailleur
create or replace function public.pilotage_mails_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare v_m text := (select mandat_id from pilotage.v_lots where id = p_asset);
begin
  if pilotage.mon_role() is null or not pilotage.voit_tableau('sinistres', v_m) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(pilotage.mails_ligne(m) order by m.le desc) from pilotage.mails m
     where m.statut = 'classe' and (m.lot_id = p_asset
        or (m.lot_id is null and m.immeuble_id is null and m.bailleur_email is null and m.mandat_id = v_m)
        or (m.lot_id is null and m.immeuble_id is null and m.bailleur_email is not null
            and v_m in (select pilotage.bailleur_mandats(m.bailleur_email))))), '[]'::jsonb);
end $$;

-- Fiche bailleur : recherche puis détail (mandats, lots, tickets ouverts, impayés Rivage, tous les échanges)
create or replace function public.pilotage_bailleurs_chercher(p_q text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare q text := trim(coalesce(p_q, ''));
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  perform pilotage.bailleurs_maj();
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(pilotage.bailleur_info(b.email) order by b.email) from (
    select b.email from pilotage.bailleurs b
     where b.email ilike '%' || q || '%' or b.numero::text = q
        or exists (select 1 from pilotage.objets pr where pr.type = 'Profile' and lower(trim(pr.data->>'email')) = b.email
                    and pilotage.nom_profil(pr.id) ilike '%' || q || '%')
        or exists (select 1 from pilotage.bailleur_mandats(b.email) mid join pilotage.v_mandats vm on vm.id = mid
                    where trim(vm.reference) ilike q || '%')
     limit 20) b), '[]'::jsonb);
end $$;

create or replace function public.pilotage_bailleur(p_email text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare e text := lower(trim(coalesce(p_email, ''))); md text[];
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  select array_agg(x) into md from pilotage.bailleur_mandats(e) x;
  if md is null then raise exception 'Aucun mandat Rivage pour l''adresse %', e; end if;
  return pilotage.bailleur_info(e) || jsonb_build_object(
    'mandats', (select jsonb_agg(pilotage.mandat_info(vm.id) || jsonb_build_object('lots_detail',
                   (select coalesce(jsonb_agg(jsonb_build_object('lot_id', l.id, 'lot', l.reference, 'adresse', l.adresse,
                            'bail', vb.reference, 'locataires', vb.locataires, 'impaye', vb.impaye) order by l.reference), '[]'::jsonb)
                      from pilotage.v_lots l left join pilotage.v_baux vb on vb.id = pilotage.mails_bail_a(l.id, current_date)
                     where l.mandat_id = vm.id)) order by trim(vm.reference))
                  from pilotage.v_mandats vm where vm.id = any(md)),
    'tickets', (select coalesce(jsonb_agg(jsonb_build_object('ticket_id', i.id, 'numero', i.data->>'number', 'titre', i.data->>'title',
                   'lot', l.reference, 'declare_le', (i.data->>'declared_at')::date) order by i.data->>'declared_at' desc), '[]'::jsonb)
                  from pilotage.objets i join pilotage.v_lots l on l.id = i.data->>'asset_id'
                 where i.type = 'Incident' and i.supprime_le is null and l.mandat_id = any(md)
                   and coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') and i.data->>'archived_at' is null),
    'mails', (select coalesce(jsonb_agg(pilotage.mails_ligne(m) order by m.le desc), '[]'::jsonb) from (
                select * from pilotage.mails m where m.statut = 'classe' and (m.bailleur_email = e or m.mandat_id = any(md))
                 order by m.le desc limit 300) m));
end $$;

revoke all on function public.pilotage_bailleurs_chercher(text), public.pilotage_bailleur(text) from public, anon;
grant execute on function public.pilotage_bailleurs_chercher(text), public.pilotage_bailleur(text) to authenticated;

-- ---------- 7. Module Gmail ----------
create or replace function public.pilotage_addon_contexte(p_email text, p_message_id text, p_emails text[]) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare r text := pilotage.addon_role(p_email); m pilotage.mails; lots text[]; ext text[];
begin
  if r is null then raise exception 'Adresse % : pas d''accès au pilotage', p_email; end if;
  select * into m from pilotage.mails where message_id = p_message_id;
  ext := (select array_agg(x) from unnest(p_emails) x where x !~* '@udi-immo\.com$');
  select array_agg(distinct a.lot_id) filter (where a.lot_id is not null) into lots from pilotage.mails_annuaire(ext) a;
  return jsonb_build_object(
    'peut_classer', r in ('direction', 'superviseur', 'gestionnaire', 'comptable'),
    'mail', case when m.id is null then null else pilotage.mails_ligne(m) || jsonb_build_object('candidats', m.candidats) end,
    'parties', (select coalesce(jsonb_agg(distinct jsonb_build_object('email', a.email, 'nom', a.nom, 'role', a.role)), '[]'::jsonb)
                  from pilotage.mails_annuaire(ext) a),
    'niveaux', pilotage.mails_niveaux(ext),
    -- au-delà de 15 lots (bailleur de nombreux biens), seuls le lot rattaché et la recherche sont proposés
    'lots', (select coalesce(jsonb_agg(pilotage.addon_lot(x)), '[]'::jsonb)
               from unnest(coalesce(case when m.lot_id is not null then array[m.lot_id] end,
                                    case when cardinality(lots) <= 15 then lots end, '{}')) x),
    'nb_lots', coalesce(cardinality(lots), 0),
    'echanges', (select coalesce(jsonb_agg(jsonb_build_object('le', e.le, 'sens', e.sens, 'objet', e.objet, 'resume', coalesce(e.resume, e.extrait)) order by e.le desc), '[]'::jsonb)
                   from (select * from pilotage.mails e where e.statut = 'classe' and e.lot_id = coalesce(m.lot_id, case when cardinality(lots) = 1 then lots[1] end)
                           and e.message_id is distinct from p_message_id order by e.le desc limit 5) e));
end $$;

create or replace function public.pilotage_addon_chercher_niveaux(p_email text, p_q text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare q text := trim(coalesce(p_q, ''));
begin
  if pilotage.addon_role(p_email) is null then raise exception 'Adresse % : pas d''accès au pilotage', p_email; end if;
  perform pilotage.bailleurs_maj();
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(i) from (
      select pilotage.bailleur_info(b.email) i from pilotage.bailleurs b
       where (select count(*) from pilotage.bailleur_mandats(b.email)) >= 2
         and (b.email ilike '%' || q || '%' or exists (select 1 from pilotage.objets pr where pr.type = 'Profile'
               and lower(trim(pr.data->>'email')) = b.email and pilotage.nom_profil(pr.id) ilike '%' || q || '%'))
      union all
      select pilotage.mandat_info(vm.id) from pilotage.v_mandats vm
       where (select count(*) from pilotage.v_lots l where l.mandat_id = vm.id) >= 2
         and (trim(vm.reference) ilike q || '%' or pilotage.bailleurs_mandat(vm.id) ilike '%' || q || '%')
      limit 10) t), '[]'::jsonb);
end $$;
revoke all on function public.pilotage_addon_contexte(text, text, text[]), public.pilotage_addon_chercher_niveaux(text, text) from public, anon, authenticated;
grant execute on function public.pilotage_addon_contexte(text, text, text[]), public.pilotage_addon_chercher_niveaux(text, text) to service_role;
