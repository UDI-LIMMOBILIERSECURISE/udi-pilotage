-- Contrôles toutes les 30 minutes (pg_cron est déjà installé sur le projet)
select cron.schedule('pilotage-controles', '*/30 * * * *', $$select pilotage.executer_controles();$$);
-- Pour arrêter : select cron.unschedule('pilotage-controles');
