-- 062 : saisie par lot dans le contrôle du mandat (retours de Nicolas du 20/10/2026)
--   1. « Aucun équipement » et « Pas de compteur » se disent lot par lot (en plus d'en ajouter autant qu'on veut par lot).
--   2. Permis de louer : le régime déduit de la table des communes peut être corrigé pour un lot
--      (autorisation préalable, déclaration de mise en location ou pas de permis). Le choix du lot prime sur la commune
--      partout où le permis est utilisé (fiche du mandat, À louer, alertes).

create table if not exists pilotage.lots_sans (
  asset_id text not null,
  nature text not null check (nature in ('equipement', 'compteur')),
  par uuid default auth.uid(),
  le timestamptz not null default now(),
  primary key (asset_id, nature)
);
alter table pilotage.lots_sans enable row level security;

create table if not exists pilotage.permis_lots (
  asset_id text primary key,
  regime text not null check (regime in ('autorisation', 'declaration', 'aucun')),
  par uuid default auth.uid(),
  le timestamptz not null default now()
);
alter table pilotage.permis_lots enable row level security;

-- Marquer (ou démarquer) un lot sans équipement / sans compteur
create or replace function public.pilotage_lot_sans(p_asset text, p_nature text, p_sans boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_traiter_lot(p_asset) then raise exception 'Accès refusé'; end if;
  if p_nature not in ('equipement', 'compteur') then raise exception 'Nature inconnue'; end if;
  if p_sans then
    if exists (select 1 from pilotage.lots_equipements where asset_id = p_asset and nature = p_nature) then
      raise exception '%', case p_nature when 'compteur' then 'Ce lot a déjà un compteur : le retirer d''abord' else 'Ce lot a déjà un équipement : le retirer d''abord' end;
    end if;
    insert into pilotage.lots_sans (asset_id, nature, par, le) values (p_asset, p_nature, auth.uid(), now())
    on conflict (asset_id, nature) do update set par = auth.uid(), le = now();
  else
    delete from pilotage.lots_sans where asset_id = p_asset and nature = p_nature;
  end if;
end $$;

-- Lots marqués « aucun » parmi une liste
create or replace function public.pilotage_lots_sans(p_assets text[]) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('asset_id', s.asset_id, 'nature', s.nature, 'le', s.le,
           'par', (select m.prenom from pilotage.membres m where m.user_id = s.par))), '[]'::jsonb)
  from pilotage.lots_sans s where s.asset_id = any(p_assets) and pilotage.peut_traiter_lot(s.asset_id)
$$;

-- Ajouter un équipement ou un compteur à un lot retire la mention « aucun »
create or replace function pilotage.lots_sans_retirer() returns trigger
language plpgsql security definer set search_path = pilotage, public as $$
begin
  delete from pilotage.lots_sans where asset_id = new.asset_id and nature = new.nature;
  return new;
end $$;
drop trigger if exists lots_sans_retirer on pilotage.lots_equipements;
create trigger lots_sans_retirer after insert on pilotage.lots_equipements for each row execute function pilotage.lots_sans_retirer();

-- Régime du permis de louer choisi pour un lot (null : revenir à la table des communes)
create or replace function public.pilotage_permis_lot_regime(p_asset text, p_regime text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_traiter_lot(p_asset) then raise exception 'Accès refusé'; end if;
  if p_regime is null or p_regime = '' then
    delete from pilotage.permis_lots where asset_id = p_asset;
  elsif p_regime in ('autorisation', 'declaration', 'aucun') then
    insert into pilotage.permis_lots (asset_id, regime, par, le) values (p_asset, p_regime, auth.uid(), now())
    on conflict (asset_id) do update set regime = excluded.regime, par = auth.uid(), le = now();
  else raise exception 'Régime inconnu'; end if;
end $$;

-- Le régime choisi pour le lot prime sur la commune
create or replace function pilotage.permis_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare a jsonb; c pilotage.permis_communes; num integer; v_voie text; rue record; dans boolean; regime text; detail text; force pilotage.permis_lots;
begin
  select data into a from pilotage.objets where type = 'Asset' and id = p_asset;
  if a is null then return null; end if;
  if coalesce(a->>'nature', '') not in ('flat', 'room', 'house') then
    return jsonb_build_object('regime', 'non_concerne', 'commune', a->'address'->>'city', 'detail', 'Pas un logement : permis de louer non applicable.');
  end if;
  select * into c from pilotage.permis_communes where commune = pilotage.norm_commune(a->'address'->>'city');
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

revoke all on function public.pilotage_lot_sans(text, text, boolean), public.pilotage_lots_sans(text[]), public.pilotage_permis_lot_regime(text, text) from public, anon;
grant execute on function public.pilotage_lot_sans(text, text, boolean), public.pilotage_lots_sans(text[]), public.pilotage_permis_lot_regime(text, text) to authenticated;

-- Contrôle
select count(*) lots_sans from pilotage.lots_sans;
select count(*) permis_forces from pilotage.permis_lots;
