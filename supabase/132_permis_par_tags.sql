-- 132 : permis de louer et déclaration de mise en location suivis à partir des tags des tickets (bloc 1 sur 1)
--  Décision de Nicolas du 06/11/2026, qui remplace en partie la règle validée « le régime du permis vient de la table des communes » :
--   - un ticket Rivage (incident non clos) tagué PL ouvre le suivi du permis de louer (autorisation préalable) du lot, tagué DMEL celui
--     de la déclaration de mise en location ; le tag prime sur la table des communes et sur le régime choisi pour le lot ;
--   - la déclaration de mise en location n'est plus ouverte d'office à la signature d'un bail : elle s'active avec le tag DMEL ;
--   - le passage d'un lot en « À louer » ne crée plus le rappel « Permis de louer à demander » : seul le tag PL déclenche le suivi.
--     Les 6 rappels ouverts de cette façon (lots 140, 272, 279, 342, 399, 400) sont fermés ;
--   - les lots déjà loués sont considérés comme autorisés ;
--   - conservé : l'alerte « Bail signé sans permis de louer » (baux signés depuis le 17/10 dans une commune à autorisation) ;
--   - « Qui dépose ? » (agence ou bailleur) proposé aussi pour la déclaration, sans montant affiché.
--  La table des communes reste l'information de référence (page Réglages) et sert quand aucun ticket n'est tagué.
--  Non touché : la déclaration déjà ouverte pour le bail 530 (lot 428, échéance 15/11), décidée avant cette règle.

create index if not exists objets_incident_asset on pilotage.objets ((data->>'asset_id')) where type = 'Incident';

-- Régime donné par les tags du ticket le plus récent du lot (incident non clos) : PL prime sur DMEL dans un même ticket
create or replace function pilotage.permis_tag(p_asset text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('regime', case when t.pl then 'autorisation' else 'declaration' end, 'ticket', t.numero, 'ticket_id', t.id)
  from (
    select o.id, o.data->>'number' as numero, coalesce(o.data->>'updated_at', o.data->>'created_at') as maj,
      exists (select 1 from jsonb_array_elements(case when jsonb_typeof(o.data->'tags') = 'array' then o.data->'tags' else '[]'::jsonb end) g
              where not coalesce((g->>'archived')::boolean, false) and lower(trim(coalesce(g->>'name', g #>> '{}'))) = 'pl') as pl,
      exists (select 1 from jsonb_array_elements(case when jsonb_typeof(o.data->'tags') = 'array' then o.data->'tags' else '[]'::jsonb end) g
              where not coalesce((g->>'archived')::boolean, false) and lower(trim(coalesce(g->>'name', g #>> '{}'))) = 'dmel') as dmel
    from pilotage.objets o
    where o.type = 'Incident' and o.supprime_le is null and o.data->>'asset_id' = p_asset
      and coalesce(o.data->>'status', '') not in ('closed', 'resolved', 'cancelled') and o.data->>'archived_at' is null
  ) t
  where t.pl or t.dmel
  order by t.maj desc nulls last
  limit 1
$$;

-- Texte du 062 repris, avec le régime du tag en premier
create or replace function pilotage.permis_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare a jsonb; c pilotage.permis_communes; num integer; v_voie text; rue record; dans boolean; regime text; detail text; force pilotage.permis_lots; tg jsonb;
begin
  select data into a from pilotage.objets where type = 'Asset' and id = p_asset;
  if a is null then return null; end if;
  if coalesce(a->>'nature', '') not in ('flat', 'room', 'house') then
    return jsonb_build_object('regime', 'non_concerne', 'commune', a->'address'->>'city', 'detail', 'Pas un logement : permis de louer non applicable.');
  end if;
  select * into c from pilotage.permis_communes where commune = pilotage.norm_commune(a->'address'->>'city');
  -- 132 : un ticket tagué PL ou DMEL décide du régime
  tg := pilotage.permis_tag(p_asset);
  if tg is not null then
    return jsonb_build_object('regime', tg->>'regime', 'commune', coalesce(c.libelle, a->'address'->>'city'), 'a_confirmer', false, 'tag', true,
      'detail', 'D''après le ticket' || coalesce(' n°' || (tg->>'ticket'), '') || ' tagué ' || case when tg->>'regime' = 'autorisation' then 'PL' else 'DMEL' end || '.',
      'email_depot', c.email_depot, 'adresse_depot', c.adresse_depot, 'source', c.source, 'verifie_le', c.verifie_le);
  end if;
  select * into force from pilotage.permis_lots where asset_id = p_asset;
  if force.asset_id is not null then
    return jsonb_build_object('regime', force.regime, 'commune', coalesce(c.libelle, a->'address'->>'city'), 'a_confirmer', false, 'force', true,
      'detail', 'Régime choisi pour ce lot par ' || coalesce((select m.prenom from pilotage.membres m where m.user_id = force.par), 'la gestion') || ' le ' || to_char(force.le, 'DD/MM/YYYY') || '.',
      'email_depot', c.email_depot, 'adresse_depot', c.adresse_depot, 'source', c.source, 'verifie_le', c.verifie_le);
  end if;
  if c.commune is null then
    return jsonb_build_object('regime', 'inconnu', 'commune', a->'address'->>'city', 'detail', 'Commune jamais vérifiée : recherche à faire.');
  end if;
  if c.perimetre = 'commune' then
    regime := c.regime; detail := 'Toute la commune.';
  else
    v_voie := pilotage.norm_voie(a->'address'->>'street');
    num := nullif(substring(coalesce(a->'address'->>'number', '') from '^\s*(\d+)'), '')::integer;
    dans := false;
    for rue in select * from pilotage.permis_rues r where r.commune = c.commune and r.voie = v_voie loop
      if rue.num_min is null then dans := true; detail := 'Voie du périmètre : ' || rue.libelle; exit; end if;
      if num is null then dans := null; detail := 'Voie partiellement dans le périmètre (' || rue.condition || ') : numéro absent dans Rivage, à vérifier.'; continue; end if;
      if num between rue.num_min and rue.num_max and (rue.parite is null or (rue.parite = 'pair') = (num % 2 = 0)) then
        dans := true; detail := 'Dans le périmètre : ' || rue.libelle || ' (' || rue.condition || ')'; exit;
      end if;
    end loop;
    if dans is null then regime := 'a_verifier';
    elsif dans then regime := c.regime;
    else regime := coalesce(c.regime_hors_perimetre, 'aucun');
      detail := 'Hors du périmètre (adresse : ' || coalesce(a->'address'->>'number', '') || ' ' || coalesce(a->'address'->>'street', '') || ').';
    end if;
  end if;
  return jsonb_build_object('regime', regime, 'commune', c.libelle, 'a_confirmer', c.statut = 'a_confirmer', 'detail', detail,
    'email_depot', c.email_depot, 'adresse_depot', c.adresse_depot, 'source', c.source, 'verifie_le', c.verifie_le);
end $$;

-- « Qui dépose ? » aussi pour la déclaration (sans montant) : patch du texte en place, ancres vérifiées
do $p$
declare f text := pg_get_functiondef('public.pilotage_permis_action(text, bigint, text, date, text, text)'::regprocedure); g text;
  a1 text := $a$if reg->>'regime' not in ('autorisation', 'a_verifier') then raise exception 'Ce lot n''est pas soumis à autorisation préalable d''après la table des communes'; end if;
    perform pilotage.permis_clore$a$;
  b1 text := $a$if reg->>'regime' not in ('autorisation', 'declaration', 'a_verifier') then raise exception 'Ce lot n''est pas soumis au permis de louer (ni tag PL ou DMEL, ni table des communes)'; end if;
    perform pilotage.permis_clore$a$;
  a2 text := $a$'Permis de louer du lot ' || lot || ' : dépôt par l''agence (90 € TTC)'$a$;
  b2 text := $a$case when reg->>'regime' = 'declaration' then 'Déclaration de mise en location du lot ' || lot || ' : dépôt par l''agence' else 'Permis de louer du lot ' || lot || ' : dépôt par l''agence (90 € TTC)' end$a$;
  a3 text := $a$'Permis de louer du lot ' || lot || ' : dépôt par le bailleur'$a$;
  b3 text := $a$case when reg->>'regime' = 'declaration' then 'Déclaration de mise en location du lot ' || lot || ' : dépôt par le bailleur' else 'Permis de louer du lot ' || lot || ' : dépôt par le bailleur' end$a$;
begin
  if position('Déclaration de mise en location du lot' in f) > 0 then raise notice 'pilotage_permis_action déjà modifiée'; return; end if;
  f := replace(f, chr(13), '');
  if (length(f) - length(replace(f, a1, ''))) / length(a1) <> 1 then raise exception 'Ancre 1 introuvable ou multiple'; end if;
  if (length(f) - length(replace(f, a2, ''))) / length(a2) <> 1 then raise exception 'Ancre 2 introuvable ou multiple'; end if;
  if (length(f) - length(replace(f, a3, ''))) / length(a3) <> 1 then raise exception 'Ancre 3 introuvable ou multiple'; end if;
  g := replace(replace(replace(f, a1, b1), a2, b2), a3, b3);
  execute g;
end $p$;

-- Mise en location : plus de rappel automatique « Permis de louer à demander » (texte du 038 sans ce bloc)
create or replace function public.pilotage_a_louer_maj(p_asset text, p_action text, p_disponible date, p_loyer numeric, p_motif text, p_note text) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare m text; lot text;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Réservé à la gestion'; end if;
  select data->>'management_contract_id', coalesce(nullif(data->>'reference', ''), id) into m, lot from pilotage.objets where type = 'Asset' and id = p_asset;
  if m is null then raise exception 'Lot inconnu ou sans mandat'; end if;
  if p_action = 'ajouter' then
    insert into pilotage.lots_a_louer (asset_id, disponible_le, loyer_prevu, motif, note, par) values (p_asset, p_disponible, p_loyer, p_motif, p_note, auth.uid())
    on conflict (asset_id) do update set depuis = current_date, disponible_le = excluded.disponible_le, loyer_prevu = excluded.loyer_prevu, motif = excluded.motif,
      note = excluded.note, par = auth.uid(), sorti_le = null, sorti_motif = null;
    -- 132 : le suivi du permis de louer s'ouvre avec le tag PL d'un ticket, plus à la mise en location
  elsif p_action = 'modifier' then
    update pilotage.lots_a_louer set disponible_le = p_disponible, loyer_prevu = p_loyer, note = p_note where asset_id = p_asset;
  elsif p_action = 'retirer' then
    update pilotage.lots_a_louer set sorti_le = current_date, sorti_motif = coalesce(nullif(p_motif, ''), 'Retiré de la location') where asset_id = p_asset and sorti_le is null;
    perform pilotage.permis_clore(p_asset, array['permis_a_demander']);
  else raise exception 'Action inconnue'; end if;
end $$;

-- Signature d'un bail : la déclaration n'est ouverte que si un ticket est tagué DMEL (patch en place)
do $p$
declare f text := pg_get_functiondef('pilotage.a_louer_auto()'::regprocedure);
  a1 text := $a$and pilotage.permis_lot(a.id)->>'regime' in ('autorisation', 'declaration')
$a$;
  b1 text := $a$and pilotage.permis_lot(a.id)->>'regime' in ('autorisation', 'declaration')
    and (pilotage.permis_lot(a.id)->>'regime' <> 'declaration' or pilotage.permis_tag(a.id) is not null) -- 132 : déclaration ouverte par le tag DMEL
$a$;
begin
  if position('132 : déclaration ouverte par le tag' in f) > 0 then raise notice 'a_louer_auto déjà modifiée'; return; end if;
  f := replace(f, chr(13), '');
  if (length(f) - length(replace(f, a1, ''))) / length(a1) <> 1 then raise exception 'Ancre a_louer_auto introuvable ou multiple'; end if;
  execute replace(f, a1, b1);
end $p$;

-- Les rappels « Permis de louer à demander » ouverts à la mise en location sont fermés
update pilotage.mandats_obligations set actif = false where nature = 'permis_a_demander' and actif;

select l.reference as lot, pilotage.permis_lot(l.id)->>'regime' as regime, pilotage.permis_lot(l.id)->>'detail' as detail
  from pilotage.v_lots l where l.id in (select o.data->>'asset_id' from pilotage.objets o where o.type = 'Incident' and o.supprime_le is null and pilotage.permis_tag(o.data->>'asset_id') is not null);
