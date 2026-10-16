-- 032 : tenue en charge pour un portefeuille de 2 000 lots (décision de Nicolas, 16/10/2026).
--   1. Documents Rivage retrouvés par index : la recherche des documents d'un bail, d'un lot ou d'un mandat passait par un
--      parcours de tous les documents ; elle passe désormais par un index (GIN) sur les objets rattachés.
--   2. Liste des baux servie depuis un cache : le calcul complet (échéance, contrôle d'entrée, suivis) est fait en tâche de fond
--      toutes les 30 minutes et après chaque action sur un bail, plus à chaque ouverture de la liste.
--   Rien ne change à l'écran ; le détail d'un bail reste calculé en direct à l'ouverture.

-- 1. Index et réécriture des recherches de documents
create index if not exists objets_upload_ressources on pilotage.objets using gin ((data->'resourceables') jsonb_path_ops) where type = 'Upload';
create index if not exists objets_bail_lot on pilotage.objets ((data->>'asset_id')) where type = 'LeasingContract';
create index if not exists objets_lot_mandat on pilotage.objets ((data->>'management_contract_id')) where type = 'Asset';

do $do$
declare f record; n text;
begin
  for f in select p.oid, pg_get_functiondef(p.oid) def from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname in ('pilotage', 'public') and p.prokind = 'f' and pg_get_functiondef(p.oid) like '%jsonb_array_elements(coalesce(u.data->''resourceables''%' loop
    n := regexp_replace(f.def,
      $re$exists \(select 1 from jsonb_array_elements\(coalesce\(u\.data->'resourceables',\s*'\[\]'::jsonb\)\) rr\s+where rr->>'id' in \(([^,()]+), ([^()]+?)\)\)$re$,
      $r$(u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', \1)) or u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', \2)))$r$, 'g');
    n := regexp_replace(n,
      $re$exists \(select 1 from jsonb_array_elements\(coalesce\(u\.data->'resourceables',\s*'\[\]'::jsonb\)\) rr\s+where rr->>'id' = ([a-z_.]+)\)$re$,
      $r$(u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', \1)))$r$, 'g');
    if n <> f.def then execute n; end if;
  end loop;
end $do$;

-- Documents d'un mandat : rattachés au mandat, à un de ses lots ou à un de ses mandants (une recherche indexée par identifiant)
create or replace function pilotage.uploads_mandat(p_mandat text) returns setof pilotage.objets
language sql stable security definer set search_path = pilotage, public as $$
  select distinct on (u.id) u.*
  from (select p_mandat as id
        union select a.id from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
        union select p->>'profile_id' from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
              where m.type = 'ManagementContract' and m.id = p_mandat) x
  cross join lateral (select * from pilotage.objets u where u.type = 'Upload' and u.supprime_le is null
                      and u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', x.id))) u
$$;

-- 2. Cache de la liste des baux
create table if not exists pilotage.baux_cache (bail_id text primary key, ligne jsonb not null, calcule_le timestamptz not null default now());
alter table pilotage.baux_cache enable row level security;
revoke all on pilotage.baux_cache from public, anon, authenticated;

create or replace function pilotage.ligne_bail(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object(
    'bail_id', b.id, 'reference', b.reference, 'statut', b.statut, 'locataires', b.locataires, 'debut', b.debut, 'loyer_hc', b.loyer_hc,
    'lot', l.reference, 'adresse', l.adresse, 'nature_lot', l.nature, 'mandat_id', l.mandat_id,
    'mandat', (select coalesce(nullif(m.nom,''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
    'bailleur', pilotage.bailleurs_mandat(l.mandat_id),
    'echeance', pilotage.echeance_bail(b.id),
    'controle', (select jsonb_build_object('restant', (c->>'restant')::int, 'anomalies', (c->>'anomalies')::int, 'go_le', c->'go_le', 'go_par', c->'go_par', 'portee', c->'portee')
                 from pilotage.controle_bail(b.id) c),
    'obligations', coalesce((select jsonb_agg(pilotage.obligation_etat(o.id) order by o.prochaine) from pilotage.baux_obligations o where o.bail_id = b.id and o.actif), '[]'::jsonb),
    'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id)
  from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id where b.id = p_bail
$$;

-- Recalcule les baux en cours (tous, ou ceux dont le calcul a plus de p_age) et retire les baux terminés
create or replace function pilotage.rafraichir_baux(p_age interval default '0 seconds') returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer := 0; r record;
begin
  delete from pilotage.baux_cache c where not exists (select 1 from pilotage.v_baux b where b.id = c.bail_id
    and b.statut in ('created','move_in','in_progress') and (b.fin is null or b.fin > current_date));
  for r in select x.id from pilotage.v_baux x left join pilotage.baux_cache c on c.bail_id = x.id
           where x.statut in ('created','move_in','in_progress') and (x.fin is null or x.fin > current_date)
             and (c.bail_id is null or c.calcule_le < now() - p_age or c.calcule_le::date < current_date) loop
    insert into pilotage.baux_cache (bail_id, ligne, calcule_le) values (r.id, pilotage.ligne_bail(r.id), now())
    on conflict (bail_id) do update set ligne = excluded.ligne, calcule_le = now();
    n := n + 1;
  end loop;
  return n;
end $$;

-- Liste des baux : depuis le cache (les baux nouveaux ou recalculés il y a plus de 30 minutes sont recalculés à la volée)
create or replace function public.pilotage_baux() returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  perform pilotage.rafraichir_baux('30 minutes');
  return jsonb_build_object('peut', pilotage.peut_suivre_baux(), 'baux',
    coalesce((select jsonb_agg(c.ligne order by (c.ligne->'echeance'->>'echeance') nulls last) from pilotage.baux_cache c), '[]'::jsonb));
end $$;

-- Après une action sur un bail : son calcul est refait tout de suite
create or replace function public.pilotage_bail_rafraichir(p_bail text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  if exists (select 1 from pilotage.v_baux b where b.id = p_bail) then
    insert into pilotage.baux_cache (bail_id, ligne, calcule_le) values (p_bail, pilotage.ligne_bail(p_bail), now())
    on conflict (bail_id) do update set ligne = excluded.ligne, calcule_le = now();
  end if;
end $$;

revoke all on all functions in schema pilotage from public, anon, authenticated;
revoke all on function public.pilotage_baux(), public.pilotage_bail_rafraichir(text) from public, anon;
grant execute on function public.pilotage_baux(), public.pilotage_bail_rafraichir(text) to authenticated;

select pilotage.rafraichir_baux();
select cron.unschedule('pilotage-cache-baux') where exists (select 1 from cron.job where jobname = 'pilotage-cache-baux');
select cron.schedule('pilotage-cache-baux', '5,35 * * * *', $$ select pilotage.rafraichir_baux('25 minutes') $$);

-- 3. Synchronisation Rivage espacée : les webhooks tiennent le reflet à jour en continu ; relecture complète de rattrapage
--    chaque semaine (dimanche 00 h 45, heure UTC) et des référentiels comptables le 1er du mois.
select cron.unschedule('pilotage-sync-rivage') where exists (select 1 from cron.job where jobname = 'pilotage-sync-rivage');
select cron.schedule('pilotage-sync-rivage', '45 0 * * 0', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-sync-rivage',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{}'::jsonb, timeout_milliseconds := 300000) $$);
select cron.unschedule('pilotage-sync-rivage-mensuel') where exists (select 1 from cron.job where jobname = 'pilotage-sync-rivage-mensuel');
select cron.schedule('pilotage-sync-rivage-mensuel', '30 1 1 * *', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-sync-rivage',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{"mode": "mensuel"}'::jsonb, timeout_milliseconds := 300000) $$);
