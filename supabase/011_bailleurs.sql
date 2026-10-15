-- Nom des propriétaires sur toutes les cartes.
-- 1) Reprise des fiches propriétaires depuis l'API Rivage (GET /api/v1/profiles/{id}), en ne gardant que
--    l'identité utile à l'affichage : civilité, nom, prénom, raison sociale, nature, référence (pas d'e-mail,
--    téléphone, date de naissance ni adresse). Insertion avec source = 'api', sans écraser une fiche reçue par webhook.
-- 2) pilotage.nom_profil : raison sociale, sinon NOM Prénom ; pilotage.bailleurs_mandat : propriétaires d'un mandat.
-- 3) Ajout d'un champ 'bailleur' dans pilotage_sinistres, _dg, _compta, _agence, _journee et 'bailleur' dans _mandats
--    (migration pilotage_bailleurs_cartes, appliquée par remplacement ciblé dans les définitions existantes).
create or replace function pilotage.nom_profil(p_id text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(nullif(trim(data->>'company_name'), ''),
                  nullif(trim(concat_ws(' ', upper(nullif(trim(data->>'last_name'), '')), initcap(nullif(trim(data->>'first_name'), '')))), ''))
  from pilotage.objets where type = 'Profile' and id = p_id
$$;

create or replace function pilotage.bailleurs_mandat(p_mandat text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select string_agg(coalesce(pilotage.nom_profil(p->>'profile_id'), 'Propriétaire non transmis par Rivage'), ', ' order by (p->>'share')::numeric desc nulls last)
  from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
  where m.type = 'ManagementContract' and m.id = p_mandat
$$;
revoke all on function pilotage.bailleurs_mandat(text) from public, anon, authenticated;
