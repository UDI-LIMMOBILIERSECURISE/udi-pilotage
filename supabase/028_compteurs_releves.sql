-- 028 : compteurs divisionnaires (décision de Nicolas, 16/10/2026) : situation du compteur, relevés datés et calcul des consommations
--   entre deux relevés (consommation, nombre de jours, moyenne par jour, montant si un prix unitaire est saisi).
--   Les compteurs sont rattachés au lot : saisis au mandat, repris et relevés dans le suivi de chaque bail.

alter table pilotage.lots_equipements add column if not exists situation text, add column if not exists numero text,
  add column if not exists unite text, add column if not exists prix_unitaire numeric(12,4);

create table if not exists pilotage.compteurs_releves (
  id bigserial primary key, equipement_id bigint not null references pilotage.lots_equipements(id) on delete cascade,
  releve_le date not null, index_releve numeric(14,3) not null,
  type text not null default 'periodique' check (type in ('mandat', 'entree', 'periodique', 'sortie')),
  bail_id text, commentaire text, par uuid, le timestamptz not null default now()
);
create index if not exists compteurs_releves_eq on pilotage.compteurs_releves (equipement_id, releve_le);
alter table pilotage.compteurs_releves enable row level security;
revoke all on pilotage.compteurs_releves from public, anon, authenticated;
revoke all on sequence pilotage.compteurs_releves_id_seq from public, anon, authenticated;

-- Compteurs d'un lot avec leurs relevés et la consommation entre chaque relevé
create or replace function pilotage.compteurs_lot(p_asset text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'libelle', e.libelle, 'situation', e.situation, 'numero', e.numero,
    'unite', coalesce(e.unite, case when e.libelle ~* 'eau|gaz' then 'm³' else 'kWh' end), 'prix_unitaire', e.prix_unitaire,
    'releves', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'le', r.releve_le, 'index', r.index_releve, 'type', r.type, 'bail_id', r.bail_id,
                  'commentaire', r.commentaire, 'par', pilotage.prenom_membre(r.par),
                  'conso', r.index_releve - r.prec, 'jours', r.releve_le - r.prec_le,
                  'par_jour', case when r.releve_le > r.prec_le then round((r.index_releve - r.prec) / (r.releve_le - r.prec_le), 3) end,
                  'montant', case when e.prix_unitaire is not null and r.prec is not null then round((r.index_releve - r.prec) * e.prix_unitaire, 2) end)
                  order by r.releve_le, r.id)
                from (select x.*, lag(x.index_releve) over w prec, lag(x.releve_le) over w prec_le
                      from pilotage.compteurs_releves x where x.equipement_id = e.id window w as (order by x.releve_le, x.id)) r), '[]'::jsonb))
    order by e.libelle), '[]'::jsonb)
  from pilotage.lots_equipements e where e.asset_id = p_asset and e.nature = 'compteur'
$$;

-- Équipement ou compteur d'un lot (remplace 024 : situation, numéro, unité, prix unitaire)
drop function if exists public.pilotage_lot_equipement(text, bigint, text, text, boolean, text, date, text, boolean);
create or replace function public.pilotage_lot_equipement(p_asset text, p_id bigint, p_nature text, p_libelle text, p_contrat boolean, p_prestataire text,
  p_dernier date, p_commentaire text, p_supprimer boolean, p_situation text default null, p_numero text default null, p_unite text default null, p_prix numeric default null)
returns bigint
language plpgsql security definer set search_path = pilotage, public as $$
declare nid bigint;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.objets where type = 'Asset' and id = p_asset) then raise exception 'Lot inconnu'; end if;
  if p_supprimer then delete from pilotage.lots_equipements where id = p_id and asset_id = p_asset; return p_id; end if;
  if nullif(trim(coalesce(p_libelle, '')), '') is null then raise exception 'Nom de l''équipement obligatoire'; end if;
  if p_id is null then
    insert into pilotage.lots_equipements (asset_id, nature, libelle, contrat_entretien, prestataire, dernier_entretien, commentaire, situation, numero, unite, prix_unitaire, par)
    values (p_asset, p_nature, trim(p_libelle), p_contrat, nullif(p_prestataire, ''), p_dernier, nullif(p_commentaire, ''), nullif(p_situation, ''), nullif(p_numero, ''),
            nullif(p_unite, ''), p_prix, auth.uid()) returning id into nid;
  else
    update pilotage.lots_equipements set libelle = trim(p_libelle), contrat_entretien = p_contrat, prestataire = nullif(p_prestataire, ''), dernier_entretien = p_dernier,
      commentaire = nullif(p_commentaire, ''), situation = nullif(p_situation, ''), numero = nullif(p_numero, ''), unite = coalesce(nullif(p_unite, ''), unite),
      prix_unitaire = p_prix, par = auth.uid(), le = now() where id = p_id and asset_id = p_asset;
    nid := p_id;
  end if;
  return nid;
end $$;

-- Relevé d'un compteur (ou suppression) ; un index inférieur au relevé précédent est refusé (sauf commentaire : compteur changé)
create or replace function public.pilotage_releve(p_compteur bigint, p_id bigint, p_le date, p_index numeric, p_type text, p_bail text, p_commentaire text, p_supprimer boolean)
returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare prec numeric;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.lots_equipements where id = p_compteur and nature = 'compteur') then raise exception 'Compteur inconnu'; end if;
  if p_supprimer then delete from pilotage.compteurs_releves where id = p_id and equipement_id = p_compteur; return; end if;
  if p_le is null or p_index is null then raise exception 'Date et index du relevé obligatoires'; end if;
  select index_releve into prec from pilotage.compteurs_releves where equipement_id = p_compteur and releve_le <= p_le and id is distinct from p_id
   order by releve_le desc, id desc limit 1;
  if prec is not null and p_index < prec and nullif(trim(coalesce(p_commentaire, '')), '') is null then
    raise exception 'Index inférieur au relevé précédent (%) : vérifier, ou indiquer en commentaire que le compteur a été changé', prec;
  end if;
  if p_id is null then
    insert into pilotage.compteurs_releves (equipement_id, releve_le, index_releve, type, bail_id, commentaire, par)
    values (p_compteur, p_le, p_index, coalesce(p_type, 'periodique'), p_bail, nullif(p_commentaire, ''), auth.uid());
  else
    update pilotage.compteurs_releves set releve_le = p_le, index_releve = p_index, type = coalesce(p_type, type), commentaire = nullif(p_commentaire, ''), par = auth.uid(), le = now()
    where id = p_id and equipement_id = p_compteur;
  end if;
end $$;

-- Compteurs du lot d'un bail (pour le suivi des relevés du bail)
create or replace function public.pilotage_bail_compteurs(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare lot text;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  select data->>'asset_id' into lot from pilotage.objets where type = 'LeasingContract' and id = p_bail;
  return jsonb_build_object('lot', lot, 'compteurs', pilotage.compteurs_lot(lot));
end $$;

-- Dossier du mandat : lots avec leurs compteurs détaillés (remplace 024)
create or replace function public.pilotage_mandat_dossier(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'controle', pilotage.controle_mandat(p_mandat),
    'lots', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'reference', coalesce(a.data->>'reference', a.data->>'name'), 'nature', a.data->>'nature',
              'adresse', concat_ws(' ', a.data->'address'->>'number', a.data->'address'->>'street', a.data->'address'->>'zip_code', a.data->'address'->>'city'),
              'construction', a.data->>'construction_year', 'chauffage', a.data->'equipment'->>'heating_method', 'chauffage_type', a.data->'equipment'->>'heating_type',
              'eau_chaude', a.data->'equipment'->>'hot_water_method', 'syndic', a.data->>'syndic_id' is not null,
              'equipements', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nature', e.nature, 'libelle', e.libelle, 'contrat_entretien', e.contrat_entretien,
                             'prestataire', e.prestataire, 'dernier_entretien', e.dernier_entretien, 'commentaire', e.commentaire, 'situation', e.situation) order by e.nature, e.libelle)
                             from pilotage.lots_equipements e where e.asset_id = a.id), '[]'::jsonb),
              'compteurs', pilotage.compteurs_lot(a.id)) order by a.data->>'reference')
             from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat), '[]'::jsonb),
    'lecture', (select jsonb_build_object('le', l.le, 'source', l.source, 'modele', l.modele, 'resultat', l.resultat) from pilotage.baux_lectures l where l.bail_id = p_mandat order by l.le desc limit 1),
    'lien', 'https://rivage.immo/landlords/profiles/' || coalesce((select p->>'profile_id' from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
                                                                 where m.type = 'ManagementContract' and m.id = p_mandat limit 1), '')
  );
end $$;

revoke all on all functions in schema pilotage from public, anon, authenticated;
revoke all on function public.pilotage_lot_equipement(text, bigint, text, text, boolean, text, date, text, boolean, text, text, text, numeric),
  public.pilotage_releve(bigint, bigint, date, numeric, text, text, text, boolean), public.pilotage_bail_compteurs(text) from public, anon;
grant execute on function public.pilotage_lot_equipement(text, bigint, text, text, boolean, text, date, text, boolean, text, text, text, numeric),
  public.pilotage_releve(bigint, bigint, date, numeric, text, text, text, boolean), public.pilotage_bail_compteurs(text) to authenticated;
