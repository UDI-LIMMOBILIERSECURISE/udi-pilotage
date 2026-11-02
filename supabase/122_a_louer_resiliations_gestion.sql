-- 122 — À louer : un lot dont la gestion est résiliée dans Rivage n'est plus proposé (Nicolas, 02/11/2026).
-- Rivage enregistre la fin de gestion dans une « résiliation de gestion » (objet ManagementTermination, reçu par webhook) :
-- statut (scheduled = programmée, effective, annulée si canceled_at), date de fin (termination_date), motif
-- (termination_reason : property_sold, other…, détail dans reason_details), lots (asset_ids) et mandats (management_contract_ids).
-- Constat du 02/11 : 2 résiliations en base (lot 135 vendu le 27/10 ; lot 423 repris par le bailleur le 02/11), mandats passés
-- en « lost » par Rivage, lots déjà sortis des propositions par le 121. Le statut du mandat ne suffit pas dans deux cas :
--   - résiliation programmée (date à venir) : le mandat reste actif jusqu'à la date ;
--   - résiliation d'une partie des lots d'un mandat qui en compte plusieurs : le mandat reste actif.
-- Règle : un lot visé par une résiliation non annulée (programmée ou effective) n'est pas proposé. La résiliation vise le lot
-- par sa liste de lots ; le mandat n'est retenu que si cette liste est vide.
-- Rien n'est saisi dans le pilotage : la fin de gestion se déclare dans Rivage (règle « Corriger dans Rivage »).
-- Calcul à blanc le 02/11 : aucun lot retiré en plus (les 2 cas sont déjà exclus par le 121) ; 67 propositions.
-- Un seul bloc. Retour arrière : repasser le 121.

-- ===== 122 — bloc 1 sur 1 =====
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
    -- Résiliation de gestion Rivage non annulée visant le lot ou son mandat
    and not exists (select 1 from pilotage.objets t
                    where t.type = 'ManagementTermination' and t.supprime_le is null
                      and t.data->>'canceled_at' is null and coalesce(t.data->>'status', '') <> 'canceled'
                      and (coalesce(t.data->'asset_ids', '[]'::jsonb) ? a.id
                           -- le mandat ne compte que si la résiliation ne liste aucun lot (sinon une résiliation partielle retirerait tous les lots)
                           or (jsonb_array_length(coalesce(t.data->'asset_ids', '[]'::jsonb)) = 0
                               and coalesce(t.data->'management_contract_ids', '[]'::jsonb) ? (a.data->>'management_contract_id'))))
$function$;

-- Contrôle (67 au 02/11) :
-- select count(*) from pilotage.a_louer_propositions();
