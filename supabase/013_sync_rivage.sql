-- Mise à jour nocturne depuis l'API Rivage : journal des passages et fonctions appelées par la fonction serveur pilotage-sync-rivage.
create table if not exists pilotage.syncs (
  id bigserial primary key,
  declencheur text,
  debut timestamptz not null default now(),
  fin timestamptz,
  compteurs jsonb,
  erreur text
);
revoke all on pilotage.syncs from public, anon, authenticated;

create or replace function public.pilotage_sync_debut(p_declencheur text) returns bigint
language sql security definer set search_path = pilotage, public as $$
  insert into pilotage.syncs(declencheur) values (p_declencheur) returning id
$$;

-- Applique un lot d'objets ; la date de l'objet (updated_at s'il existe) évite d'écraser un webhook plus récent
create or replace function public.pilotage_sync_appliquer(p_modele text, p_objets jsonb) returns int
language plpgsql security definer set search_path = pilotage, public as $$
declare o jsonb; n int := 0;
begin
  for o in select * from jsonb_array_elements(p_objets) loop
    begin
      perform pilotage.appliquer(p_modele, o->>'id', 'updated', o,
        coalesce(nullif(o->>'updated_at', '')::timestamptz, now()), 'api');
      n := n + 1;
    exception when others then
      insert into pilotage.erreurs(source, message, contexte) values ('sync', sqlerrm, jsonb_build_object('model', p_modele, 'id', o->>'id'));
    end;
  end loop;
  return n;
end $$;

create or replace function public.pilotage_sync_fin(p_id bigint, p_compteurs jsonb, p_erreur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  update pilotage.syncs set fin = now(), compteurs = p_compteurs, erreur = p_erreur where id = p_id;
  if p_erreur is null then
    perform pilotage.executer_controles();
    perform pilotage.rattacher_alertes();
  end if;
end $$;

-- Dernier passage, pour l'affichage dans l'appli (tous les membres)
create or replace function public.pilotage_derniere_sync() returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when pilotage.mon_role() is null then null else
    (select jsonb_build_object('debut', debut, 'fin', fin, 'compteurs', compteurs, 'erreur', erreur, 'declencheur', declencheur)
     from pilotage.syncs order by id desc limit 1) end
$$;

revoke all on function public.pilotage_sync_debut(text), public.pilotage_sync_appliquer(text, jsonb), public.pilotage_sync_fin(bigint, jsonb, text) from public, anon, authenticated;
grant execute on function public.pilotage_sync_debut(text), public.pilotage_sync_appliquer(text, jsonb), public.pilotage_sync_fin(bigint, jsonb, text) to service_role;
revoke all on function public.pilotage_derniere_sync() from public, anon;
grant execute on function public.pilotage_derniere_sync() to authenticated;

-- Secret de la tâche planifiée : stocké dans Vault, comparé côté base
create or replace function public.pilotage_cron_valide(p_secret text) returns boolean
language sql stable security definer set search_path = public, vault as $$
  select exists (select 1 from vault.decrypted_secrets where name = 'pilotage_cron_secret' and decrypted_secret = p_secret)
$$;
revoke all on function public.pilotage_cron_valide(text) from public, anon, authenticated;
grant execute on function public.pilotage_cron_valide(text) to service_role;

-- Passage chaque nuit à 2 h 45 heure de Paris (00:45 UTC l'été, 01:45 l'hiver : planifié à 00:45 UTC)
-- select cron.schedule('pilotage-sync-rivage', '45 0 * * *', $$ select net.http_post(
--   url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-sync-rivage',
--   headers := jsonb_build_object('Content-Type', 'application/json',
--     'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
--   body := '{}'::jsonb, timeout_milliseconds := 300000) $$);
