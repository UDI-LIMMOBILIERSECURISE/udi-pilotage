-- 124 : alertes recalculées dans la minute quand un dossier bouge dans le pilotage (Nicolas, 04/11/2026)
--  Constat du 04/11 (bail 530) : dernier point du commercial répondu à 10 h 00 min 17 s, juste après le contrôle de 10 h 00 ;
--  l'alerte « Contrôle d'entrée à valider » de la gestionnaire n'aurait été créée qu'à 10 h 30.
--  Le contrôle complet dure 12 s en moyenne (19 s au plus) : trop long pour être lancé depuis l'écran (limite de 8 s).
--  Désormais :
--   - toute réponse, suivi, équipement, fiche ou attribution enregistrés dans le pilotage, et toute pièce déposée dans Rivage,
--     laissent une demande de contrôle (une seule ligne, mise à jour) ;
--   - une tâche planifiée vérifie chaque minute s'il y a une demande et, seulement dans ce cas, lance le contrôle complet ;
--   - un verrou empêche deux contrôles de tourner en même temps (tâche de la minute, tâche des 30 minutes, fin de synchronisation) ;
--   - les écritures du contrôle lui-même (suivis et réponses automatiques) ne relancent pas de demande.
--  Les corrections de champs dans Rivage (fiche du bail ou du mandat) restent prises en compte au contrôle des 30 minutes.

create table if not exists pilotage.controles_demande (id integer primary key default 1 check (id = 1), le timestamptz not null default now());
alter table pilotage.controles_demande enable row level security;
revoke all on pilotage.controles_demande from public, anon, authenticated;

create or replace function pilotage.controles_demander() returns trigger
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  -- écritures faites par le contrôle lui-même (suivis d'assurance, réponses automatiques) : pas de nouvelle demande
  if coalesce(current_setting('pilotage.en_controle', true), '') = '1' then return null; end if;
  insert into pilotage.controles_demande (id, le) values (1, now()) on conflict (id) do update set le = excluded.le;
  return null;
end $$;

-- Tables du pilotage : déclencheur par instruction (une demande par enregistrement, quel que soit le nombre de lignes)
do $$
declare t text;
begin
  foreach t in array array['baux_reponses', 'baux_obligations', 'baux_fiche', 'mandats_obligations', 'mandats_suivi', 'lots_equipements'] loop
    execute format('drop trigger if exists controles_demande on pilotage.%I', t);
    execute format('create trigger controles_demande after insert or update or delete on pilotage.%I for each statement execute function pilotage.controles_demander()', t);
  end loop;
end $$;

-- Pièces déposées dans Rivage (arrivée par webhook) : seulement à l'arrivée d'une nouvelle pièce
drop trigger if exists controles_demande_upload on pilotage.objets;
create trigger controles_demande_upload after insert on pilotage.objets
  for each row when (new.type = 'Upload') execute function pilotage.controles_demander();

-- Contrôle à la demande (tâche de la minute)
create or replace function pilotage.controles_a_la_demande() returns integer
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare d timestamptz;
begin
  select le into d from pilotage.controles_demande where id = 1;
  if d is null then return 0; end if;
  if not pg_try_advisory_xact_lock(424201) then return 0; end if;   -- un contrôle tourne déjà : la demande reste pour la minute suivante
  delete from pilotage.controles_demande where id = 1 and le <= d;    -- une demande arrivée pendant le contrôle est gardée
  perform pilotage.executer_controles();
  perform pilotage.rattacher_alertes();
  return 1;
end $$;

-- Verrou dans le contrôle complet : les autres appels (30 minutes, fin de synchronisation) attendent la fin du contrôle en cours
do $$
declare def text := pg_get_functiondef('pilotage.executer_controles'::regproc);
        a text := 'perform pilotage.dg_recus_compta_maj();';
begin
  if position('424201' in def) = 0 then
    if position(a in def) = 0 then raise exception '124 : ancre introuvable dans executer_controles (scripts 122 et 123 passés ?)'; end if;
    execute replace(def, a, 'perform pg_advisory_xact_lock(424201);  -- 124 : un seul contrôle à la fois
  perform set_config(''pilotage.en_controle'', ''1'', true);  -- 124 : ses propres écritures ne relancent pas de demande
  ' || a);
  end if;
end $$;

select cron.schedule('pilotage-controles-demande', '* * * * *', $$ select pilotage.controles_a_la_demande() $$);

-- Vérification : tâche planifiée active et déclencheurs posés (7 attendus)
select (select active from cron.job where jobname = 'pilotage-controles-demande') tache_active,
       (select count(*) from pg_trigger where tgname in ('controles_demande', 'controles_demande_upload') and not tgisinternal) declencheurs;
