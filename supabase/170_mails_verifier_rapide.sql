-- 170 : « Mails à vérifier » trop lent (« canceling statement due to statement timeout », limite de 8 s) depuis les 168-169.
-- Cause : niveaux bailleur / mandat (168) et sociétés (169) recalculés pour chaque mail et chaque lot candidat en relisant
-- tous les mandats et profils Rivage (38 s pour 47 mails le 14/11).
-- Correctif : index adresse → mandats, profil → mandats et fiches courtes (mandat, société, bailleur) tenus en table, recalculés par bailleurs_maj()
-- (au passage du script, puis toutes les heures, et à chaque recherche ou classement). Compteur léger pour Ma journée.
-- Aucune suppression de données.

create table if not exists pilotage.bailleurs_mandats (
  email text not null,
  mandat_id text not null,
  primary key (email, mandat_id)
);
create index if not exists bailleurs_mandats_mandat on pilotage.bailleurs_mandats (mandat_id);
create table if not exists pilotage.mandats_fiche (
  mandat_id text primary key,
  info jsonb not null
);
alter table pilotage.bailleurs add column if not exists info jsonb;
create table if not exists pilotage.profils_mandats (
  profil_id text not null,
  mandat_id text not null,
  email text,
  primary key (profil_id, mandat_id)
);
create index if not exists profils_mandats_mandat on pilotage.profils_mandats (mandat_id);
create index if not exists profils_mandats_email on pilotage.profils_mandats (email);
create table if not exists pilotage.societes_fiche (
  profil_id text primary key,
  info jsonb not null
);
revoke all on pilotage.bailleurs_mandats, pilotage.mandats_fiche, pilotage.profils_mandats, pilotage.societes_fiche from public, anon, authenticated;

create or replace function pilotage.bailleurs_maj() returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  -- profil propriétaire → mandat (non supprimé), avec l'adresse du profil
  create temp table if not exists _pm (profil_id text, mandat_id text, email text) on commit drop;
  truncate _pm;
  insert into _pm
  select distinct pr.id, m.id, nullif(lower(trim(pr.data->>'email')), '')
    from pilotage.objets m cross join jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = p->>'profile_id'
   where m.type = 'ManagementContract' and m.supprime_le is null;
  delete from pilotage.profils_mandats x where not exists (select 1 from _pm b where b.profil_id = x.profil_id and b.mandat_id = x.mandat_id);
  insert into pilotage.profils_mandats select * from _pm on conflict (profil_id, mandat_id) do update set email = excluded.email;
  -- adresse → mandats
  insert into pilotage.bailleurs (email) select distinct email from _pm where email is not null and email !~ '@udi-immo\.com$' on conflict (email) do nothing;
  delete from pilotage.bailleurs_mandats x where not exists (select 1 from _pm b where b.email = x.email and b.mandat_id = x.mandat_id);
  insert into pilotage.bailleurs_mandats select distinct email, mandat_id from _pm where email is not null and email !~ '@udi-immo\.com$' on conflict do nothing;
  -- fiches des mandats
  with n as (select id, trim(reference) reference, (regexp_match(reference, '^\s*(\d+)'))[1] num, statut from pilotage.v_mandats),
  u as (select num from n where num is not null group by num having count(*) = 1),
  l as (select mandat_id, count(*) lots from pilotage.v_lots group by mandat_id)
  insert into pilotage.mandats_fiche (mandat_id, info)
  select n.id, jsonb_build_object('niveau', 'mandat', 'mandat_id', n.id, 'code', case when n.num in (select num from u) then n.num else n.id end,
           'reference', n.reference, 'nom', pilotage.bailleurs_mandat(n.id), 'lots', coalesce(l.lots, 0), 'statut', n.statut)
    from n left join l on l.mandat_id = n.id
  on conflict (mandat_id) do update set info = excluded.info;
  delete from pilotage.mandats_fiche f where not exists (select 1 from pilotage.v_mandats v where v.id = f.mandat_id);
  -- fiches des sociétés (profils propriétaires)
  insert into pilotage.societes_fiche (profil_id, info)
  select pm.profil_id, jsonb_build_object('niveau', 'societe', 'profil_id', pm.profil_id, 'nom', pilotage.nom_profil(pm.profil_id), 'email', min(pm.email),
           'mandats', count(*), 'lots', coalesce(sum((f.info->>'lots')::int), 0))
    from pilotage.profils_mandats pm left join pilotage.mandats_fiche f using (mandat_id) group by pm.profil_id
  on conflict (profil_id) do update set info = excluded.info;
  delete from pilotage.societes_fiche f where not exists (select 1 from pilotage.profils_mandats pm where pm.profil_id = f.profil_id);
  -- fiches des adresses (bailleurs)
  update pilotage.bailleurs b set info = jsonb_build_object('niveau', 'bailleur', 'email', b.email, 'numero', b.numero,
      'nom', (select string_agg(distinct f.info->>'nom', ', ') from pilotage.profils_mandats pm join pilotage.societes_fiche f using (profil_id) where pm.email = b.email),
      'mandats', (select count(*) from pilotage.bailleurs_mandats bm where bm.email = b.email),
      'lots', (select coalesce(sum((f.info->>'lots')::int), 0) from pilotage.bailleurs_mandats bm join pilotage.mandats_fiche f using (mandat_id) where bm.email = b.email));
end $$;
revoke all on function pilotage.bailleurs_maj() from public, anon, authenticated;

-- Lectures : depuis les tables
create or replace function pilotage.bailleur_mandats(p_email text) returns setof text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select mandat_id from pilotage.bailleurs_mandats where email = lower(trim(p_email))
$$;

create or replace function pilotage.mandat_info(p_mandat text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select info from pilotage.mandats_fiche where mandat_id = p_mandat
$$;

create or replace function pilotage.bailleur_info(p_email text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select info from pilotage.bailleurs where email = lower(trim(p_email))
$$;

-- 169 : sociétés lues dans l'index
create or replace function pilotage.profil_mandats(p_profil text) returns setof text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select mandat_id from pilotage.profils_mandats where profil_id = p_profil
$$;

create or replace function pilotage.mandat_profils(p_mandat text) returns text[]
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce(array_agg(profil_id order by profil_id), '{}') from pilotage.profils_mandats where mandat_id = p_mandat
$$;

create or replace function pilotage.societe_info(p_profil text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select info from pilotage.societes_fiche where profil_id = p_profil
$$;

create or replace function pilotage.mails_societes(p_emails text[]) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with e as (select distinct lower(trim(x)) x from unnest(coalesce(p_emails, '{}')) x where x ~ '@' and lower(x) !~ '@udi-immo\.com$'),
  s as (select distinct f.info i from pilotage.profils_mandats pm join e on e.x = pm.email join pilotage.societes_fiche f using (profil_id))
  select coalesce(jsonb_agg(i order by (i->>'lots')::int desc, i->>'nom'), '[]'::jsonb) from s
$$;

create or replace function pilotage.mails_niveaux(p_emails text[]) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with e as (select distinct lower(trim(x)) x from unnest(coalesce(p_emails, '{}')) x where x ~ '@' and lower(x) !~ '@udi-immo\.com$'),
  b as (select bl.info i from pilotage.bailleurs bl join e on e.x = bl.email where bl.info is not null),
  mi as (select distinct f.info i from pilotage.bailleurs_mandats bm join e on e.x = bm.email join pilotage.mandats_fiche f using (mandat_id))
  select coalesce((select jsonb_agg(i order by (i->>'lots')::int desc) from b where (i->>'mandats')::int >= 2), '[]'::jsonb)
      || coalesce((select jsonb_agg(i order by (i->>'lots')::int desc, i->>'reference') from mi where (i->>'lots')::int >= 2), '[]'::jsonb)
$$;

-- Compteur pour Ma journée
create or replace function public.pilotage_mails_a_verifier_compte() returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then return jsonb_build_object('total', 0); end if;
  return (select jsonb_build_object('total', count(*), 'plus_ancien', min(m.le),
            'bailleurs', count(*) filter (where exists (select 1 from pilotage.bailleurs bl
                                where bl.email = any(array[lower(m.de)] || m.a || m.cc) and (bl.info->>'mandats')::int >= 2)))
            from pilotage.mails m where m.statut = 'a_verifier');
end $$;
revoke all on function public.pilotage_mails_a_verifier_compte() from public, anon;
grant execute on function public.pilotage_mails_a_verifier_compte() to authenticated;

select pilotage.bailleurs_maj();

-- Recalcul toutes les heures (nouveaux mandats, profils modifiés)
select cron.unschedule(jobid) from cron.job where jobname = 'pilotage-bailleurs-maj';
select cron.schedule('pilotage-bailleurs-maj', '17 * * * *', 'select pilotage.bailleurs_maj()');
