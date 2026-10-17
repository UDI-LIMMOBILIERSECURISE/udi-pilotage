-- 043 : rattachement des pièces déposées dans Rivage depuis le pilotage
-- Constat du 17/10 : l'API Rivage crée la pièce mais ignore un rattachement à un mandat (ManagementContract) ; dans le compte de test,
-- les pièces Rivage ne sont rattachées qu'à des lots, des baux, des sinistres ou des écritures, jamais à un mandat.
-- Le pilotage reconnaît déjà les pièces rattachées au lot d'un mandat (pilotage.uploads_mandat) : la fonction serveur rattache donc
-- la pièce au lot. Ce script lui donne la liste des lots du mandat. Rien n'est écrit dans Rivage par ce script.

create or replace function public.pilotage_lots_mandat(p_mandat text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(a.id order by a.data->>'reference'), '[]'::jsonb)
  from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
$$;
revoke all on function public.pilotage_lots_mandat(text) from public, anon, authenticated;
grant execute on function public.pilotage_lots_mandat(text) to service_role;

-- Une pièce WeRoof n'est marquée « envoyée » que si Rivage l'a rattachée (les deux envois non rattachés du 17/10 redeviennent envoyables).
create or replace function pilotage.documents_weroof_mandat(p_mandat text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  with lots as (
    select pilotage.norm_voie(concat_ws(' ', a.data->'address'->>'number', a.data->'address'->>'street')) voie, a.data->'address'->>'zip_code' cp
    from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat),
  mandants as (
    select pilotage.sans_accents(trim(pr.data->>'company_name')) societe, pilotage.sans_accents(trim(pr.data->>'last_name')) nom,
           pilotage.sans_accents(trim(pr.data->>'first_name')) prenom
    from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) pc
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = pc->>'profile_id'
    where m.type = 'ManagementContract' and m.id = p_mandat),
  biens as (
    select distinct b.id, b.bailleur_id from public.biens b join lots l on pilotage.norm_voie(b.adresse) = l.voie and b.code_postal = l.cp
    join public.bailleurs bl on bl.id = b.bailleur_id
    join mandants mt on (nullif(mt.societe, '') is not null and pilotage.sans_accents(trim(bl.nom_societe)) = mt.societe)
                     or (nullif(mt.societe, '') is null and nullif(mt.nom, '') is not null and pilotage.sans_accents(trim(bl.nom)) = mt.nom
                         and (nullif(mt.prenom, '') is null or pilotage.sans_accents(coalesce(bl.prenom, '')) like mt.prenom || '%'))
    where b.archived is not true)
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'type', d.type_document, 'nom', d.nom_original, 'taille', d.taille, 'le', d.created_at,
           'nature', pilotage.nature_rivage_weroof(d.type_document),
           'envoye', exists (select 1 from pilotage.rivage_ecritures e where e.cible_id = p_mandat and e.ok and e.reponse->>'document_weroof' = d.id::text
                            and jsonb_array_length(coalesce(e.reponse->'resourceables', '[]'::jsonb)) > 0))
           order by d.type_document, d.created_at desc), '[]'::jsonb)
  from public.documents d
  where (d.bien_id in (select id from biens) or d.bailleur_id in (select bailleur_id from biens))
    and d.storage_path is not null and pilotage.nature_rivage_weroof(d.type_document) is not null
$$;


-- Contrôle : doit renvoyer le lot du mandat DREZET (a_0a1eb4c5…)
select public.pilotage_lots_mandat('mc_940f0f67b439e70f734a6be8') as lots;
