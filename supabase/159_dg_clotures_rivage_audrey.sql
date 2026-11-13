-- 159 : report dans le pilotage des baux clôturés dans Rivage par Audrey le 12/11/2026 au soir (demande de Nicolas du 13/11)
--  Le 12/11 entre 21 h et 21 h 35, Audrey a passé environ 150 baux au statut « clôturé » dans Rivage (webhooks reçus).
--  Le pilotage ne les comptait pas comme clôturés : l'onglet « Clôturés » des sorties et DG ne lit que la clôture faite dans le
--  pilotage (dg_suivi.clos_le, script 154), et la frise du bien n'y voyait pas le dépôt comme réglé.
--  Ce script les clôture dans le pilotage, au nom d'Audrey, motif « autre », avec une note qui dit d'où vient la clôture.
--  Constat honnête : pour presque tous, Rivage n'enregistre aucune restitution du dépôt (détenu par le bailleur) ; la note le dit.
--  Réversible bail par bail : « Rouvrir » dans la fiche (pilotage_dg_clore avec motif vide).
--  Périmètre : baux au statut « closed » dans Rivage dont la clôture est arrivée par webhook le 12/11/2026, pas déjà clos dans le pilotage.
--  Aucune donnée Rivage modifiée. Bloc unique.

begin;

with clos_hier as (
  select distinct e.object_id bail_id
    from public.rivage_webhook_events e
    join pilotage.v_baux b on b.id = e.object_id
   where e.model_name ilike '%leasing%'
     and e.received_at >= '2026-11-12' and e.received_at < '2026-11-13'
     and b.statut = 'closed'),
ins as (
  insert into pilotage.dg_suivi (bail_id, par)
  select c.bail_id, 'b3ce328a-11d4-445c-be6f-1479e46bfa28'::uuid from clos_hier c
  on conflict (bail_id) do nothing)
update pilotage.dg_suivi s
   set clos_le = '2026-11-12 21:35:00+01', clos_par = 'b3ce328a-11d4-445c-be6f-1479e46bfa28'::uuid, clos_motif = 'autre',
       clos_note = 'Bail clôturé dans Rivage par Audrey le 12/11/2026 (report dans le pilotage, script 159)'
         || case when coalesce((select (g.data->>'deposit_refunded')::boolean from pilotage.objets g where g.id = s.bail_id), false)
                 then '' else ' — aucune restitution du dépôt enregistrée dans Rivage' end,
       maj_le = now()
 where s.bail_id in (select bail_id from clos_hier) and s.clos_le is null;

-- Les baux sans ligne dg_suivi avant ce script (insérés ci-dessus dans la même instruction ne sont pas visibles de l'update) :
update pilotage.dg_suivi s
   set clos_le = '2026-11-12 21:35:00+01', clos_par = 'b3ce328a-11d4-445c-be6f-1479e46bfa28'::uuid, clos_motif = 'autre',
       clos_note = 'Bail clôturé dans Rivage par Audrey le 12/11/2026 (report dans le pilotage, script 159)'
         || case when coalesce((select (g.data->>'deposit_refunded')::boolean from pilotage.objets g where g.id = s.bail_id), false)
                 then '' else ' — aucune restitution du dépôt enregistrée dans Rivage' end,
       maj_le = now()
 where s.clos_le is null
   and s.bail_id in (select distinct e.object_id from public.rivage_webhook_events e join pilotage.v_baux b on b.id = e.object_id
                      where e.model_name ilike '%leasing%' and e.received_at >= '2026-11-12' and e.received_at < '2026-11-13' and b.statut = 'closed');

select pilotage.executer_controles();

select count(*) filter (where clos_note like '%script 159%') clotures_159 from pilotage.dg_suivi;

commit;
