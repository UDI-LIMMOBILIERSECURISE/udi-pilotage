-- 049 : fiche sinistre
-- 1. Nom des prestataires (artisans) rattachés à l'incident dans Rivage, au lieu de leur seul nombre.
--    Le statut de l'artisan sur l'incident (« Programmée », etc.) n'est PAS transmis par Rivage : le webhook Incident
--    ne contient que contractor_ids (vérifié le 19/10 sur l'incident n°15). Question à poser à Rivage.
-- 2. Historique « Reçu de Rivage » : chaque modification indique les champs qui ont changé par rapport à l'envoi précédent.
--    Une modification sans champ changé signale un changement fait dans Rivage mais absent des données transmises
--    (cas du statut de l'artisan).
-- À passer après le 048.

-- 1. Prestataires nommés (injection dans pilotage_sinistres, une seule fois)
do $$
declare def text;
begin
  def := pg_get_functiondef('public.pilotage_sinistres()'::regprocedure);
  if position('prestataires_noms' in def) > 0 then raise notice 'déjà fait'; return; end if;
  def := replace(def,
    $a$'prestataires', jsonb_array_length(coalesce(i.data->'contractor_ids', '[]'::jsonb)),$a$,
    $b$'prestataires', jsonb_array_length(coalesce(i.data->'contractor_ids', '[]'::jsonb)),
        'prestataires_noms', (select coalesce(jsonb_agg(coalesce(pilotage.nom_profil(c), 'Prestataire inconnu du pilotage')), '[]'::jsonb)
                              from jsonb_array_elements_text(coalesce(i.data->'contractor_ids', '[]'::jsonb)) c),$b$);
  if position('prestataires_noms' in def) = 0 then raise exception 'pilotage_sinistres : point d''injection introuvable'; end if;
  execute def;
end $$;

-- 2. Historique avec les champs modifiés
create or replace function pilotage.historique(p_id text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  with e as (
    select received_at, event_type, payload->'payload' p,
           lag(payload->'payload') over (order by received_at) prec
    from public.rivage_webhook_events where object_id = p_id),
  d as (select * from e order by received_at desc limit 15)
  select coalesce(jsonb_agg(jsonb_build_object('le', d.received_at, 'evenement', d.event_type, 'statut', d.p->>'status',
           'champs', case when d.event_type = 'updated' and d.prec is not null then
             (select coalesce(jsonb_agg(k order by k), '[]'::jsonb) from jsonb_object_keys(d.p) k
               where k not in ('updated_at') and d.p->k is distinct from d.prec->k) end)
         order by d.received_at desc), '[]'::jsonb)
  from d
$$;

-- Contrôle : prestataire nommé et champs modifiés sur l'incident n°15 (Peinture chambre)
select position('prestataires_noms' in pg_get_functiondef('public.pilotage_sinistres()'::regprocedure)) > 0 as injection_ok,
       (select jsonb_agg(pilotage.nom_profil(c)) from pilotage.objets i, jsonb_array_elements_text(i.data->'contractor_ids') c
         where i.id = 'inc_a471b1a39ae8afd3a4f56f70') prestataires;
select h->>'le' le, h->>'evenement' evenement, h->'champs' champs from jsonb_array_elements(pilotage.historique('inc_a471b1a39ae8afd3a4f56f70')) h;
