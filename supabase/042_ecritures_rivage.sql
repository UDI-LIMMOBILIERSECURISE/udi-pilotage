-- 042 : journal des écritures faites dans Rivage depuis le pilotage (test du 17/10 : dépôt de pièces dans un mandat)
-- Pièces WeRoof : la fonction serveur peut aussi envoyer directement une pièce de la GED WeRoof (stockage R2) vers le mandat Rivage.
-- Toute écriture passe par la fonction serveur pilotage-ecriture-rivage, réservée à la direction pour l'instant,
-- et laisse une ligne ici : qui, quand, quoi, et la réponse de Rivage. Rien n'est écrit dans Rivage par ce script.
-- À passer après le 041 (indépendant de lui).

create table if not exists pilotage.rivage_ecritures (
  id bigserial primary key,
  le timestamptz not null default now(),
  par uuid,
  action text not null,                -- 'upload' pour l'instant
  cible_type text, cible_id text,      -- ManagementContract / LeasingContract et son identifiant Rivage
  nature text, libelle text,           -- nature Rivage du document et nom du fichier
  statut_http integer, ok boolean not null default false,
  rivage_id text,                      -- identifiant de l'objet créé dans Rivage
  reponse jsonb                        -- réponse de Rivage (tronquée)
);
create index if not exists rivage_ecritures_cible on pilotage.rivage_ecritures (cible_id);
alter table pilotage.rivage_ecritures enable row level security;
revoke all on pilotage.rivage_ecritures from public, anon, authenticated;
revoke all on sequence pilotage.rivage_ecritures_id_seq from public, anon, authenticated;

-- Droit d'écrire dans Rivage depuis le pilotage : direction seulement (à élargir plus tard, par exemple au commercial sur ses dossiers)
create or replace function public.pilotage_peut_ecrire_rivage() returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(pilotage.mon_role() = 'direction', false)
$$;

-- Journal (appelé par la fonction serveur)
create or replace function public.pilotage_ecriture_rivage_noter(p_par uuid, p_action text, p_cible_type text, p_cible_id text, p_nature text,
  p_libelle text, p_statut integer, p_ok boolean, p_rivage_id text, p_reponse jsonb) returns bigint
language sql security definer set search_path = pilotage, public as $$
  insert into pilotage.rivage_ecritures (par, action, cible_type, cible_id, nature, libelle, statut_http, ok, rivage_id, reponse)
  values (p_par, p_action, p_cible_type, p_cible_id, p_nature, left(p_libelle, 200), p_statut, p_ok, p_rivage_id, p_reponse)
  returning id
$$;

-- Écritures d'un dossier, pour l'écran
create or replace function public.pilotage_ecritures_rivage(p_cible text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('le', e.le, 'par', pilotage.prenom_membre(e.par), 'nature', e.nature, 'libelle', e.libelle,
            'ok', e.ok, 'statut', e.statut_http, 'message', e.reponse->>'message') order by e.le desc)
    from pilotage.rivage_ecritures e where e.cible_id = p_cible), '[]'::jsonb);
end $$;

revoke all on function public.pilotage_ecriture_rivage_noter(uuid, text, text, text, text, text, integer, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.pilotage_ecriture_rivage_noter(uuid, text, text, text, text, text, integer, boolean, text, jsonb) to service_role;
revoke all on function public.pilotage_peut_ecrire_rivage(), public.pilotage_ecritures_rivage(text) from public, anon;
grant execute on function public.pilotage_peut_ecrire_rivage(), public.pilotage_ecritures_rivage(text) to authenticated;

-- ========== Pièces WeRoof (UDIGESTION) disponibles pour un mandat Rivage ==========
-- Correspondance faute d'identifiant commun : même adresse de lot (numéro + voie + code postal) ET même propriétaire
-- (raison sociale pour une société, nom et prénom pour une personne). Les deux conditions sont exigées : à une même adresse
-- en copropriété, plusieurs propriétaires coexistent (cas du 2 rue Charles Drezet : trois biens WeRoof).
-- Un mandant société est rapproché par sa seule raison sociale (Rivage y joint le nom du gérant, qui peut être aussi propriétaire en direct).
create or replace function pilotage.nature_rivage_weroof(p_type text) returns text
language sql immutable as $$
  select case p_type
    when 'mandat_gestion' then 'management_mandate'
    when 'rib' then 'landlord_bank_details'
    when 'titre_propriete' then 'property_title'
    when 'taxe_fonciere' then 'property_tax_declaration'
    when 'cni_bailleur' then 'landlord_identity_and_residence_proof'
    when 'kbis' then 'landlord_identity_and_residence_proof'
    when 'statuts_societe' then 'landlord_identity_and_residence_proof'
    when 'attestation_assurance_pno' then 'property_insurance_contracts'
    when 'ddt' then 'technical_diagnostic_reports' when 'dpe' then 'technical_diagnostic_reports' when 'erp' then 'technical_diagnostic_reports'
    when 'diagnostic_electricite' then 'technical_diagnostic_reports' when 'diagnostic_gaz' then 'technical_diagnostic_reports'
    when 'diagnostic_plomb' then 'technical_diagnostic_reports' when 'diagnostic_amiante' then 'technical_diagnostic_reports'
    when 'mesurage_carrez' then 'technical_diagnostic_reports'
    else null end
$$;

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
           'envoye', exists (select 1 from pilotage.rivage_ecritures e where e.cible_id = p_mandat and e.ok and e.reponse->>'document_weroof' = d.id::text))
           order by d.type_document, d.created_at desc), '[]'::jsonb)
  from public.documents d
  where (d.bien_id in (select id from biens) or d.bailleur_id in (select bailleur_id from biens))
    and d.storage_path is not null and pilotage.nature_rivage_weroof(d.type_document) is not null
$$;

create or replace function public.pilotage_documents_weroof(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not public.pilotage_peut_ecrire_rivage() then return '[]'::jsonb; end if;
  return pilotage.documents_weroof_mandat(p_mandat);
end $$;

-- Pour la fonction serveur : la pièce demandée doit faire partie des pièces proposées pour ce mandat
create or replace function public.pilotage_document_weroof_source(p_mandat text, p_document uuid) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('storage_path', d.storage_path, 'nom', d.nom_original, 'type_mime', d.type_mime, 'nature', pilotage.nature_rivage_weroof(d.type_document))
  from public.documents d
  where d.id = p_document and exists (select 1 from jsonb_array_elements(pilotage.documents_weroof_mandat(p_mandat)) x where x->>'id' = p_document::text)
$$;

revoke all on function pilotage.documents_weroof_mandat(text), public.pilotage_document_weroof_source(text, uuid) from public, anon, authenticated;
grant execute on function public.pilotage_document_weroof_source(text, uuid) to service_role;
revoke all on function public.pilotage_documents_weroof(text) from public, anon;
grant execute on function public.pilotage_documents_weroof(text) to authenticated;

-- Contrôle : doit renvoyer true
select to_regclass('pilotage.rivage_ecritures') is not null
   and jsonb_array_length(pilotage.documents_weroof_mandat('mc_940f0f67b439e70f734a6be8')) >= 0 as ok;

-- Pièces WeRoof trouvées pour le mandat DREZET (test du 17/10) : la liste doit contenir les statuts et le Kbis de la SCI ITTEA
select x->>'type' type, x->>'nom' nom, x->>'nature' nature_rivage from jsonb_array_elements(pilotage.documents_weroof_mandat('mc_940f0f67b439e70f734a6be8')) x;
