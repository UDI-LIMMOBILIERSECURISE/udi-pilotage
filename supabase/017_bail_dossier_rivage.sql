-- 017 : la fiche d'un bail renvoie les équipements déclarés dans Rivage (chauffage, eau chaude) et la date du dernier
-- entretien de chaudière, pour pré-cocher les questions de suivi du contrôle d'entrée. Remplace pilotage_bail_dossier (016).
create or replace function public.pilotage_bail_dossier(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare f pilotage.baux_fiche;
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  select * into f from pilotage.baux_fiche where bail_id = p_bail;
  return jsonb_build_object(
    'fiche', to_jsonb(f) - 'go_par' - 'maj_par',
    'controle', pilotage.controle_bail(p_bail),
    'echeance', pilotage.echeance_bail(p_bail),
    'contacts', pilotage.contacts_bail(p_bail),
    -- Équipements déclarés dans Rivage (lot) et dernier entretien de chaudière (bail), pour pré-remplir les questions de suivi
    'rivage', (select jsonb_build_object('nature_lot', a.data->>'nature',
                 'chauffage', a.data->'equipment'->>'heating_method', 'type_chauffage', a.data->'equipment'->>'heating_type',
                 'eau_chaude', a.data->'equipment'->>'hot_water_method', 'type_eau_chaude', a.data->'equipment'->>'hot_water_type',
                 'entretien_chaudiere', b.data->>'last_boiler_maintenance_date')
               from pilotage.objets b left join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id'
               where b.type = 'LeasingContract' and b.id = p_bail),
    'paliers', coalesce((select jsonb_agg(to_jsonb(p) - 'par' order by p.debut) from pilotage.baux_paliers p where p.bail_id = p_bail), '[]'::jsonb),
    'actes', coalesce((select jsonb_agg(to_jsonb(a) - 'par' order by a.signifie_le desc) from pilotage.baux_actes a where a.bail_id = p_bail), '[]'::jsonb),
    'obligations', coalesce((select jsonb_agg(pilotage.obligation_etat(o.id) order by o.actif desc, o.prochaine) from pilotage.baux_obligations o where o.bail_id = p_bail), '[]'::jsonb),
    'journal', coalesce((select jsonb_agg(jsonb_build_object('le', se.fait_le, 'cle', se.cle, 'etape', se.etape, 'detail', se.detail, 'par', pilotage.prenom_membre(se.par)) order by se.fait_le desc)
                         from pilotage.suivis_etapes se where se.cle like 'e:' || p_bail || ':%'
                           or se.cle like any (array(select 'o:' || o.id || ':%' from pilotage.baux_obligations o where o.bail_id = p_bail))), '[]'::jsonb),
    'lecture', (select jsonb_build_object('le', le, 'source', source, 'modele', modele, 'resultat', resultat) from pilotage.baux_lectures where bail_id = p_bail order by le desc limit 1),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'nature', u.data->>'nature', 'libelle', u.data->>'label')) from pilotage.objets u
                   where u.type = 'Upload' and u.supprime_le is null and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables','[]'::jsonb)) rr
                     where rr->>'id' in (p_bail, (select data->>'asset_id' from pilotage.objets where type = 'LeasingContract' and id = p_bail)))), '[]'::jsonb));
end $$;

