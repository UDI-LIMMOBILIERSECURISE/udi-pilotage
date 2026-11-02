-- 121 — À louer : propositions sur les mandats actifs, annexes comprises (Nicolas, 02/11/2026).
-- Constat du 02/11 : l'onglet À louer ne proposait plus aucun lot depuis la bascule. La fonction a_louer_propositions (038)
-- ne retenait que les mandats au statut « active », alors que Rivage envoie « created » pour un mandat actif
-- (328 created, 2 active, 48 lost au 02/11). Les mandats perdus (lost) restent exclus.
-- Décision de Nicolas (02/11) : les annexes (box, caves, parkings) sont proposées aussi, à valider comme les autres lots.
-- Le principe ne change pas : le pilotage propose, la gestion confirme d'un clic ; rien n'entre seul dans la liste.
-- Calcul à blanc sur la production le 02/11 : 67 propositions (41 appartements, 5 maisons, 5 locaux commerciaux,
-- 4 parkings sans bail ; 12 lots dont le bail est en congé ou finit dans les 90 jours).
-- Un seul bloc. Retour arrière : remettre « mc.data->>'status' = 'active' » et le filtre sur la nature.

-- ===== 121 — bloc 1 sur 1 =====
create or replace function pilotage.a_louer_propositions()
 returns table(asset_id text, motif text, disponible_le date)
 language sql
 stable security definer
 set search_path to 'pilotage', 'public'
as $function$
  select a.id,
         case when b.id is not null then 'Fin de bail le ' || to_char(b.fin, 'DD/MM/YYYY') || coalesce(' (' || b.statut || ')', '')
              when (select m.debut from pilotage.v_mandats m where m.id = a.data->>'management_contract_id') >= current_date - 365 then 'Nouveau mandat : lot sans bail'
              else 'Lot vacant (aucun bail en cours)' end,
         coalesce(b.fin + 1, current_date)
  from pilotage.objets a
  join pilotage.objets mc on mc.type = 'ManagementContract' and mc.id = a.data->>'management_contract_id' and mc.supprime_le is null
                         and mc.data->>'status' in ('created', 'active')
  left join lateral (select x.id, x.fin, x.statut from pilotage.v_baux x
                     where x.lot_id = a.id and x.statut in ('created', 'move_in', 'in_progress', 'move_out') and (x.fin is null or x.fin >= current_date)
                     order by x.debut desc limit 1) b on true
  where a.type = 'Asset' and a.supprime_le is null
    and (b.id is null or b.statut = 'move_out' or b.fin <= current_date + 90)
    and not exists (select 1 from pilotage.lots_a_louer l where l.asset_id = a.id and l.sorti_le is null)
    and not exists (select 1 from pilotage.v_baux y where y.lot_id = a.id and y.statut in ('created', 'move_in', 'in_progress')
                    and y.debut > coalesce(b.fin, current_date - 1) and y.id is distinct from b.id)
$function$;

-- Contrôle (doit renvoyer 67 environ au 02/11) :
-- select count(*) from pilotage.a_louer_propositions();
