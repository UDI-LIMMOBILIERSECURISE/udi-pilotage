-- 064 : chaque pièce du contrôle d'entrée est demandée à celui qui doit la fournir (remarque de Nicolas, 20/10/2026)
--   bailleur  : diagnostics, titre de propriété, RIB, PNO, identité, règlement de copropriété, annexes du bail commercial…
--   locataire : attestation d'assurance, acte de caution ou garantie
--   agence    : bail signé, état des lieux d'entrée, avenants et actes, mandat signé — établis par UDI Gestion, jamais demandés
--   Les mails au bailleur ne listent que ses pièces ; un mail au locataire liste les siennes ; les pièces de l'agence
--   restent à déposer dans Rivage par l'équipe. Le suivi des pièces du mandat (063) ne relance le bailleur que pour ses pièces
--   et se ferme quand elles sont toutes arrivées.

alter table pilotage.controle_questions add column if not exists fournisseur text;
alter table pilotage.controle_questions drop constraint if exists controle_questions_fournisseur_check;
alter table pilotage.controle_questions add constraint controle_questions_fournisseur_check check (fournisseur in ('bailleur', 'locataire', 'agence'));
update pilotage.controle_questions set fournisseur = case
    when cle in ('h_doc_bail', 'c_doc_bail', 'h_doc_edl', 'c_doc_edl', 'c_doc_actes', 'm_doc_mandat') then 'agence'
    when cle in ('h_doc_assurance', 'c_doc_assurance', 'h_doc_caution', 'c_doc_garantie') then 'locataire'
    else 'bailleur' end
 where bloc = 'pieces';

-- Qui fournit chaque pièce : { cle: fournisseur }
create or replace function public.pilotage_pieces_fournisseurs() returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_object_agg(cle, coalesce(fournisseur, 'bailleur')), '{}'::jsonb) from pilotage.controle_questions where bloc = 'pieces'
$$;
revoke all on function public.pilotage_pieces_fournisseurs() from public, anon;
grant execute on function public.pilotage_pieces_fournisseurs() to authenticated;

-- Pièces manquantes d'un mandat à obtenir du bailleur (le mandat signé, pièce de l'agence, n'est plus compté)
create or replace function pilotage.mandat_pieces_manquantes(p_mandat text) returns integer
language sql stable security definer set search_path = pilotage, public as $$
  select count(*)::int from jsonb_array_elements(coalesce(pilotage.controle_mandat(p_mandat)->'items', '[]'::jsonb)) i
  join pilotage.controle_questions q on q.cle = i->>'cle'
  where i->>'bloc' = 'pieces' and coalesce(i->>'statut', '') not in ('ok', 'sans_objet') and coalesce(q.fournisseur, 'bailleur') = 'bailleur'
$$;

-- Contrôle
select fournisseur, string_agg(libelle, ' ; ' order by portee, ordre) from pilotage.controle_questions where bloc = 'pieces' group by fournisseur;
select pilotage.mandats_pieces_auto();
select o.mandat_id, o.actif, pilotage.mandat_pieces_manquantes(o.mandat_id) pieces_bailleur_manquantes from pilotage.mandats_obligations o where o.nature = 'mandat_pieces';
