-- 097 — Fiche du congé : date du congé et date de fin de bail reprises de Rivage (Nicolas, 29/10/2026).
-- Ce que Rivage donne, vérifié en base le 29/10 :
--   - Date du congé : le document « Préavis » déposé par le parcours de sortie de Rivage (Upload, nature tenant_departure_notice)
--     porte la date dans son libellé (« PILLET Delfine, GUILLIOT Jérémy - Préavis - 29/10/2026 ») ; aucun champ daté dans l'API.
--     À défaut de document, on prend le jour où le bail est passé en sortie dans Rivage (webhook), signalé comme tel.
--     Au 29/10, seul le bail 86 a un préavis ; les baux 394, 356 et 416 sont passés en sortie avant les webhooks : rien à reprendre.
--   - Fin du bail : end_date du bail (Rivage la met à la fin du préavis) ; sortie annoncée des locataires si elle est saisie.
--   - Date d'EDL de sortie saisie dans Rivage (situation du bail, move_out_inventory_date) : affichée pour information.
-- La fiche reste modifiable : une date saisie par la gestionnaire passe avant celle de Rivage. Aucune donnée Rivage modifiée.
-- Un seul bloc.

begin;

create or replace function pilotage.conge_rivage(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  with pr as (
    select u.id, u.data->>'label' libelle,
           to_date(substring(u.data->>'label' from '(\d{2}/\d{2}/\d{4})\s*$'), 'DD/MM/YYYY') le
      from pilotage.objets u
     where u.type = 'Upload' and u.supprime_le is null and u.data->>'nature' = 'tenant_departure_notice'
       and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) r where r->>'id' = p_bail)
     order by (substring(u.data->>'label' from '(\d{2}/\d{2}/\d{4})\s*$') is null), u.recu_le desc
     limit 1),
  ws as (
    select min(e.received_at) le from public.rivage_webhook_events e
     where e.object_id = p_bail and e.payload->'payload'->>'status' = 'move_out'),
  b as (select v.fin, v.statut from pilotage.v_baux v where v.id = p_bail)
  select jsonb_build_object(
    'date_conge', coalesce((select le from pr), (select (le at time zone 'Europe/Paris')::date from ws)),
    'source_conge', case when (select le from pr) is not null then 'preavis'
                         when (select le from ws) is not null then 'passage_sortie' end,
    'document', (select libelle from pr),
    'fin_bail', (select fin from b),
    'sortie_locataires', (select max(nullif(t->>'exit_date', '')::date) from pilotage.objets o, jsonb_array_elements(o.data->'tenants') t
                           where o.type = 'LeasingContract' and o.id = p_bail),
    'edl_rivage', (select nullif(s.data->'move_out'->>'move_out_inventory_date', '')::date from pilotage.baux_situation s where s.bail_id = p_bail))
$$;
revoke all on function pilotage.conge_rivage(text) from public, anon, authenticated;

create or replace function public.pilotage_fiche_conge(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare f pilotage.fiches_conge;
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() = 'comptable') then raise exception 'Accès refusé'; end if;
  select * into f from pilotage.fiches_conge where bail_id = p_bail;
  return jsonb_build_object(
    'fiche', case when f.bail_id is null then null else to_jsonb(f) - 'maj_par' || jsonb_build_object('maj_par_prenom', pilotage.prenom_membre(f.maj_par)) end,
    'statut', (select v.statut from pilotage.v_baux v where v.id = p_bail),
    'sortie', pilotage.sortie_prevue(p_bail),
    'rivage', pilotage.conge_rivage(p_bail),
    'dg', jsonb_build_object('detenteur', pilotage.dg_detenteur(p_bail), 'rivage', pilotage.dg_detenteur_rivage(p_bail),
                             'demande_le', (select s.demande_le from pilotage.dg_suivi s where s.bail_id = p_bail)),
    'prestataire', jsonb_build_object('nom', (select nullif(valeur, '') from pilotage.parametres where cle = 'edl_prestataire_nom'),
                                      'email', (select nullif(valeur, '') from pilotage.parametres where cle = 'edl_prestataire_email')),
    'peut', pilotage.peut_suivre_baux());
end $$;

commit;

-- Vérification : bail 86, date du congé 29/10/2026 (préavis), fin du bail 28/11/2026
-- select v.reference, pilotage.conge_rivage(v.id) from pilotage.v_baux v where v.statut = 'move_out' and pilotage.sortie_prevue(v.id) >= current_date;
