-- 033 : suite de 032 (décision de Nicolas, 16/10/2026).
--   1. Les trois dernières recherches de documents (fiche du bail, bail à lire par l'IA, pièce à vérifier) passent par l'index.
--   2. Le contrôle automatique toutes les 30 minutes lit l'échéance et le contrôle d'entrée dans le cache des baux (032)
--      au lieu de tout recalculer ; recalcul en direct seulement pour un bail absent du cache.
-- À exécuter après 032.

do $do$
declare f record; n text;
begin
  for f in select p.oid, p.proname, pg_get_functiondef(p.oid) def from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname in ('pilotage', 'public') and p.prokind = 'f'
             and (pg_get_functiondef(p.oid) like '%jsonb_array_elements(coalesce(u.data->''resourceables''%'
               or p.proname = 'suivi_detections') loop
    n := regexp_replace(f.def,
      $re$exists \(select 1 from jsonb_array_elements\(coalesce\(u\.data->'resourceables',\s*'\[\]'::jsonb\)\) rr\s+where rr->>'id' in \(p_bail, \((select data->>'asset_id' from pilotage\.objets where type = 'LeasingContract' and id = p_bail)\)\)\)$re$,
      $r$(u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', p_bail)) or u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', (\1))))$r$, 'g');
    if f.proname = 'suivi_detections' then
      n := replace(n, 'pilotage.echeance_bail(b.id) ech',
        'coalesce((select c.ligne->''echeance'' from pilotage.baux_cache c where c.bail_id = b.id), pilotage.echeance_bail(b.id)) ech');
      n := replace(n, '(pilotage.controle_bail(b.id)->>''restant'')',
        'coalesce((select c.ligne->''controle''->>''restant'' from pilotage.baux_cache c where c.bail_id = b.id), pilotage.controle_bail(b.id)->>''restant'')');
    end if;
    if n <> f.def then execute n; end if;
  end loop;
end $do$;

revoke all on all functions in schema pilotage from public, anon, authenticated;
