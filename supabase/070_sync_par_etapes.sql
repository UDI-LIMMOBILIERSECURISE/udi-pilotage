-- 070 — Synchronisation Rivage par étapes enchaînées.
-- Constat du 26/10 : la première relecture complète du compte de production (377 mandats, 475 baux, 419 lots,
-- 1 070 personnes, plus de 4 300 pièces, la comptabilité) a été arrêtée par la limite de temps de la fonction
-- (démarrée à 13 h 29, coupée à 13 h 32), avant les pièces restantes et la comptabilité. La relecture hebdomadaire
-- aurait le même sort.
-- Désormais la fonction pilotage-sync-rivage s'arrête d'elle-même avant la limite (120 s), clôt son passage
-- (« Partielle : suite à … page … ») et demande la suite à la base, qui la rappelle aussitôt (pg_net, appel asynchrone)
-- avec le secret des tâches planifiées. Chaque passage reprend là où le précédent s'est arrêté, jusqu'à la fin.

begin;

create or replace function public.pilotage_sync_suite(p_depuis jsonb) returns bigint
language sql security definer set search_path = public, extensions as $$
  select net.http_post(
    url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-sync-rivage',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
    body := jsonb_build_object('depuis', jsonb_build_object('modele', p_depuis->>'modele', 'page', (p_depuis->>'page')::int),
                               'mode', coalesce(p_depuis->>'mode', 'complet')),
    timeout_milliseconds := 300000)
$$;
-- Appel réservé à la fonction serveur (clé de service) : ni les utilisateurs ni le public ne peuvent déclencher de relecture
revoke all on function public.pilotage_sync_suite(jsonb) from public, anon, authenticated;
grant execute on function public.pilotage_sync_suite(jsonb) to service_role;

-- Clôture de la relecture coupée de 13 h 29 (restée sans fin)
update pilotage.syncs set fin = now(), erreur = 'Interrompue par la limite de temps de la fonction (13 h 32) ; reprise par étapes (070)'
where fin is null and debut < now() - interval '10 minutes';

commit;

select id, declencheur, debut, fin, erreur from pilotage.syncs order by id desc limit 3;
