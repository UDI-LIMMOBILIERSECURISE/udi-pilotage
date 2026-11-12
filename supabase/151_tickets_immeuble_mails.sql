-- 151 : tickets rattachés à un immeuble (sans lot) proposés pour les mails (constat de Nicolas du 12/11/2026)
--  Un incident Rivage peut être créé sur un immeuble (asset_group_id) sans lot (asset_id vide) : au 12/11, n°42 « rénovation multiple »
--  (immeuble de 8 lots) et n°35 « mise à jour diag ». Le module Gmail et le classement des mails ne cherchaient les tickets que par lot :
--  ces tickets n'étaient ni proposés ni acceptés.
--  Désormais un ticket « concerne » un lot s'il est sur ce lot, ou s'il est sur un immeuble dont le lot fait partie (rattachement Rivage
--  asset_group_memberships). Fonctions complétées sur place : pilotage.addon_lot (tickets proposés dans Gmail), pilotage_addon_chercher,
--  pilotage_addon_classer (classement depuis Gmail), pilotage_mails_preparer (référence [UDI L.. T..] et candidats), pilotage_mail_classer
--  (classement dans le pilotage). Le bloc s'arrête sans rien modifier si un texte attendu manque.
-- Retour arrière : create or replace function pilotage.ticket_du_lot(p jsonb, p_lot text) returns boolean language sql immutable
--   as $$ select coalesce(p->>'asset_id' = p_lot, false) $$;

begin;

create or replace function pilotage.ticket_du_lot(p jsonb, p_lot text) returns boolean
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce(p->>'asset_id' = p_lot, false)
      or (coalesce(p->>'asset_id', '') = '' and p->>'asset_group_id' is not null
          and exists (select 1 from pilotage.objets a where a.type = 'Asset' and a.id = p_lot and a.supprime_le is null
                        and coalesce(a.data->'asset_group_memberships', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('asset_group_id', p->>'asset_group_id'))))
$$;
revoke all on function pilotage.ticket_du_lot(jsonb, text) from public, anon, authenticated;

do $bloc$
declare f text; d text; n int;
begin
  foreach f in array array['pilotage.addon_lot(text)', 'public.pilotage_addon_chercher(text, text)', 'public.pilotage_addon_classer(text, bigint, text, text)',
                           'public.pilotage_mails_preparer(text[], timestamptz, text, text)', 'public.pilotage_mail_classer(bigint, text, text, boolean)'] loop
    d := replace(pg_get_functiondef(f::regprocedure), E'\r\n', E'\n');
    continue when position('ticket_du_lot' in d) > 0;
    n := (select count(*) from regexp_matches(d, '(i\.)?data->>''asset_id'' = (v_lot|l\.id|p_lot)\M', 'g'));
    if n = 0 then raise exception '151 : rattachement des tickets introuvable dans %, rien n''est modifié', f; end if;
    d := regexp_replace(d, '(i\.)?data->>''asset_id'' = (v_lot|l\.id|p_lot)\M', 'pilotage.ticket_du_lot(\1data, \2)', 'g');
    execute d;
    raise notice '151 : % modifiée (% endroit(s))', f, n;
  end loop;
end $bloc$;

commit;

-- Vérification : tickets proposés pour un lot de l'immeuble du ticket n°42
-- select x->'tickets' from (select pilotage.addon_lot(a.id) x from pilotage.objets a, pilotage.objets i
--   where i.type = 'Incident' and i.data->>'number' = '42' and a.type = 'Asset'
--     and a.data->'asset_group_memberships' @> jsonb_build_array(jsonb_build_object('asset_group_id', i.data->>'asset_group_id')) limit 1) z;
