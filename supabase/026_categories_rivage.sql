-- 026 : pièces reconnues par les catégories de documents de Rivage (relevées dans l'écran « Ajouter un document » de Rivage le 16/10/2026,
-- 95 catégories). Rivage envoie souvent un document sans libellé : la catégorie choisie au dépôt est la façon fiable de reconnaître une pièce ;
-- le nom du fichier reste un secours. Une pièce peut correspondre à plusieurs catégories (colonne natures).
-- Remplace pilotage.controle_bail (023), pilotage.controle_mandat (024) et public.pilotage_mandat_source (024). À exécuter après 024 et 025.

create or replace function pilotage.categorie_rivage(t text) returns text language sql immutable as $$
  select coalesce((select l from (values ('lease_contract','Contrat de bail'),('amendment','Avenant'),('lease_renewal','Renouvellement de bail'),
    ('move_in_inventory','État des lieux d''entrée'),('energy_performance_diagnosis','DPE'),('natural_risks_and_pollution_state','État des risques et pollutions'),
    ('asbestos_diagnosis_private_parts','Diagnostic amiante'),('lead_exposure_risk_assessment','Constat plomb'),('internal_electricity_installations_state','État de l''installation électrique'),
    ('internal_gas_installations_state','État de l''installation gaz'),('habitable_surface_attestation','Attestation de surface habitable'),
    ('home_insurance_certificate','Attestation d''assurance habitation'),('guarantee_act','Acte de caution'),('guarantor_documents','Documents de caution'),
    ('management_mandate','Mandat de gestion'),('identity_document','Document d''identité'),('landlord_identity_and_residence_proof','Justificatif d''identité et de domicile'),
    ('property_title','Titre de propriété'),('property_ownership_certificate','Attestation de propriété foncière'),('property_tax','Taxe foncière'),
    ('landlord_bank_details','RIB du bailleur'),('property_insurance_contracts','Contrat d''assurance du bien')) v(c, l) where c = t), t)
$$;

alter table pilotage.controle_questions add column if not exists natures text[];
update pilotage.controle_questions set natures = v.n
from (values
  ('c_doc_bail', array['lease_contract']), ('h_doc_bail', array['lease_contract']),
  ('c_doc_actes', array['amendment', 'lease_renewal']),
  ('c_doc_edl', array['move_in_inventory']), ('h_doc_edl', array['move_in_inventory']),
  ('c_doc_dpe', array['energy_performance_diagnosis']), ('h_doc_dpe', array['energy_performance_diagnosis']), ('m_doc_dpe', array['energy_performance_diagnosis']),
  ('c_doc_erp', array['natural_risks_and_pollution_state']), ('h_doc_erp', array['natural_risks_and_pollution_state']), ('m_doc_erp', array['natural_risks_and_pollution_state']),
  ('c_doc_amiante', array['asbestos_diagnosis_private_parts']), ('m_doc_amiante', array['asbestos_diagnosis_private_parts']),
  ('h_doc_plomb', array['lead_exposure_risk_assessment']), ('m_doc_plomb', array['lead_exposure_risk_assessment']),
  ('h_doc_elec_gaz', array['internal_electricity_installations_state', 'internal_gas_installations_state']),
  ('h_doc_surface', array['habitable_surface_attestation']),
  ('c_doc_assurance', array['home_insurance_certificate']), ('h_doc_assurance', array['home_insurance_certificate']),
  ('c_doc_garantie', array['guarantee_act', 'guarantor_documents']), ('h_doc_caution', array['guarantee_act', 'guarantor_documents']),
  ('m_doc_mandat', array['management_mandate']),
  ('m_doc_identite', array['identity_document', 'landlord_identity_and_residence_proof']),
  ('m_doc_propriete', array['property_title', 'property_ownership_certificate', 'property_tax']),
  ('m_doc_rib', array['landlord_bank_details']),
  ('m_doc_pno', array['property_insurance_contracts'])
) v(c, n) where cle = v.c;
-- Aide affichée : la catégorie à choisir dans Rivage au dépôt
update pilotage.controle_questions set aide = concat_ws(' ', nullif(aide, ''), 'Catégorie Rivage : ' || v.l || '.')
from (values
  ('c_doc_bail', '« Contrat de bail »'), ('h_doc_bail', '« Contrat de bail »'), ('c_doc_actes', '« Avenant » ou « Renouvellement de bail »'),
  ('c_doc_edl', '« Rapport d''état des lieux d''entrée »'), ('h_doc_edl', '« Rapport d''état des lieux d''entrée »'),
  ('c_doc_dpe', '« Diagnostic de Performance Énergétique »'), ('h_doc_dpe', '« Diagnostic de Performance Énergétique »'), ('m_doc_dpe', '« Diagnostic de Performance Énergétique »'),
  ('c_doc_erp', '« État des Risques et Pollutions »'), ('h_doc_erp', '« État des Risques et Pollutions »'), ('m_doc_erp', '« État des Risques et Pollutions »'),
  ('c_doc_amiante', '« Diagnostic Amiante Parties Privatives »'), ('m_doc_amiante', '« Diagnostic Amiante Parties Privatives »'),
  ('h_doc_plomb', '« Constat de Risque d''Exposition au Plomb »'), ('m_doc_plomb', '« Constat de Risque d''Exposition au Plomb »'),
  ('h_doc_elec_gaz', '« État des installations intérieures d''électricité » / « … de gaz »'), ('h_doc_surface', '« Attestation de la surface habitable réelle »'),
  ('c_doc_assurance', '« Attestation d''assurance habitation »'), ('h_doc_assurance', '« Attestation d''assurance habitation »'),
  ('c_doc_garantie', '« Acte de caution » ou « Documents de caution »'), ('h_doc_caution', '« Acte de caution » ou « Documents de caution »'),
  ('m_doc_mandat', '« Mandat de gestion »'), ('m_doc_identite', '« Document d''identité »'), ('m_doc_propriete', '« Titre de propriété », « Attestation de propriété foncière » ou « Taxe Foncière »'),
  ('m_doc_rib', '« RIB du bailleur »'), ('m_doc_pno', '« Contrats d''assurance du bien »'),
  ('c_doc_inventaire', 'aucune dédiée, nommer le fichier « inventaire des charges »'), ('c_doc_travaux', 'aucune dédiée, nommer le fichier « état des travaux »'),
  ('c_doc_annexe_env', 'aucune dédiée, nommer le fichier « annexe environnementale »'), ('m_doc_copro', 'aucune dédiée, nommer le fichier « règlement de copropriété »')
) v(c, l) where cle = v.c and coalesce(aide, '') not like '%Catégorie Rivage%';

create or replace function pilotage.controle_bail(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  o jsonb; lot record; f pilotage.baux_fiche; typ text; v_portee text; items jsonb := '[]'::jsonb; q record; rep pilotage.baux_reponses;
  auto text; detail text; valeur_ia jsonb; lecture jsonb; docs text[]; loyer numeric; dg numeric; idx jsonb; restant integer := 0; anomalies integer := 0; ia_diff text; vide boolean; ia_ok boolean; v_date_bail date; up record; piece jsonb;
begin
  select data into o from pilotage.objets where type = 'LeasingContract' and id = p_bail;
  if o is null then return null; end if;
  select * into lot from pilotage.v_lots where id = o->>'asset_id';
  select * into f from pilotage.baux_fiche where bail_id = p_bail;
  typ := coalesce(f.type_bail, pilotage.type_bail_suggere(lot.nature, nullif(o->>'duration_in_months','')::integer));
  v_portee := coalesce(pilotage.portee_bail(typ), 'habitation');
  select resultat into lecture from pilotage.baux_lectures where bail_id = p_bail order by le desc limit 1;
  select array_agg(distinct u.data->>'nature') into docs from pilotage.objets u
   where u.type = 'Upload' and u.supprime_le is null
     and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr where rr->>'id' in (p_bail, o->>'asset_id'));
  -- Date du bail en vigueur (conclusion ou dernier renouvellement) : date de signature dans Rivage, à défaut date d'effet.
  v_date_bail := coalesce(nullif(o->>'signed_at','')::date, nullif(o->>'start_date','')::date);
  loyer := round((o->>'rent_in_cents')::numeric / 100, 2); dg := round((o->>'deposit_in_cents')::numeric / 100, 2); idx := coalesce(o->'quarter_revision_index', o->'signing_quarter_revision_index');

  for q in select * from pilotage.controle_questions where controle_questions.portee = v_portee order by case bloc when 'pieces' then 1 when 'rivage' then 2 else 3 end, ordre loop
    select * into rep from pilotage.baux_reponses where bail_id = p_bail and cle = q.cle;
    auto := null; detail := null; valeur_ia := lecture->q.cle; piece := null; up := null;
    if q.exige_depuis is not null and v_date_bail is not null and v_date_bail < q.exige_depuis then
      -- Obligation postérieure au bail : non exigée pour ce bail (tant qu'il n'est pas renouvelé).
      auto := 'sans_objet';
      detail := 'Non exigé pour ce bail signé le ' || to_char(v_date_bail, 'DD/MM/YYYY') || ' : ' || q.exige_note;
    elsif q.mode = 'document' then
      -- 023 : pièce reconnue par sa nature Rivage, sinon par son nom (sans accents ni majuscules, mots-clés de la question).
      select u.id, u.data->>'label' as label, u.data->>'nature' as nature, coalesce(u.data->>'nature' = any(coalesce(q.natures, array[q.ref])), false) as par_nature into up
        from pilotage.objets u
       where u.type = 'Upload' and u.supprime_le is null
         and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr where rr->>'id' in (p_bail, o->>'asset_id'))
         and ((coalesce(q.natures, array[q.ref]) is not null and u.data->>'nature' = any(coalesce(q.natures, array[q.ref])))
           or (q.mots is not null and pilotage.sans_accents(u.data->>'label') ~ ('\m(' || array_to_string(q.mots, '|') || ')')))
       order by coalesce(u.data->>'nature' = any(coalesce(q.natures, array[q.ref])), false) desc, u.maj_le desc limit 1;
      if up.id is not null then
        auto := 'ok';
        detail := case when up.label is null then 'Déposé dans Rivage (catégorie « ' || coalesce(pilotage.categorie_rivage(up.nature), '?') || ' »)' else 'Déposé dans Rivage : « ' || up.label || ' »' end || case when up.par_nature then '' else ' (reconnu par son nom)' end;
        piece := jsonb_build_object('id', up.id, 'libelle', up.label, 'par_nom', not up.par_nature);
      else detail := 'Absent dans Rivage.'; end if;
    elsif q.mode = 'fiche' then
      detail := case q.ref
        when 'type_bail' then coalesce(f.type_bail, 'Suggestion : ' || coalesce(pilotage.type_bail_suggere(lot.nature, nullif(o->>'duration_in_months','')::integer), 'aucune'))
        when 'date_origine' then to_char(f.date_origine, 'DD/MM/YYYY') when 'situation' then f.situation when 'terme' then f.terme
        when 'garantie_fin' then to_char(f.garantie_fin, 'DD/MM/YYYY') when 'exec_substitutive_jours' then f.exec_substitutive_jours || ' jours'
        when 'resolutoire' then f.resolutoire when 'destination' then f.destination when 'anomalies' then f.anomalies
        when 'locataire_65' then coalesce(case f.locataire_65 when true then 'Oui' when false then 'Non' end,
             (select 'Rivage : ' || (r->>'detail') from (select pilotage.locataire_65_rivage(p_bail, (pilotage.echeance_bail(p_bail)->>'echeance')::date) r) z where (r->>'connu')::boolean)) end;
      if detail is not null and not (q.ref = 'type_bail' and f.type_bail is null) then auto := 'ok'; end if;
    elsif q.mode = 'rivage' then
      -- Rivage : seuls les champs non renseignés, les incohérences légales et les divergences avec le bail lu sont signalés.
      -- Un champ renseigné et sans divergence est conforme d'office.
      ia_diff := null; vide := false; ia_ok := false;
      case q.ref
        when 'parties' then
          detail := 'Preneur : ' || coalesce((select string_agg(coalesce(nullif(t->>'company_name',''), concat_ws(' ', t->>'last_name', t->>'first_name')), ', ') from jsonb_array_elements(o->'tenants') t), '—')
                 || ' · Bailleur : ' || coalesce(pilotage.bailleurs_mandat(lot.mandat_id), '—');
          vide := jsonb_array_length(coalesce(o->'tenants','[]'::jsonb)) = 0;
        when 'dates' then
          detail := 'Signé le ' || coalesce(to_char((o->>'signed_at')::date, 'DD/MM/YYYY'), '—') || ', début ' || coalesce(to_char((o->>'start_date')::date, 'DD/MM/YYYY'), '—') || ', durée ' || coalesce(o->>'duration_in_months', '—') || ' mois';
          vide := o->>'signed_at' is null or o->>'start_date' is null or coalesce(nullif(o->>'duration_in_months','')::integer, 0) = 0;
          if valeur_ia is not null and nullif(valeur_ia->>'signature','') is not null and valeur_ia->>'signature' <> coalesce(o->>'signed_at','') then
            ia_diff := 'signé le ' || to_char((valeur_ia->>'signature')::date, 'DD/MM/YYYY'); end if;
          if valeur_ia is not null and nullif(valeur_ia->>'debut','') is not null and valeur_ia->>'debut' <> coalesce(o->>'start_date','') then
            ia_diff := concat_ws(', ', ia_diff, 'date d''effet du ' || to_char((valeur_ia->>'debut')::date, 'DD/MM/YYYY')); end if;
          if valeur_ia is not null and nullif(valeur_ia->>'duree_mois','') is not null and valeur_ia->>'duree_mois' <> coalesce(o->>'duration_in_months','') then
            ia_diff := concat_ws(', ', ia_diff, 'durée de ' || (valeur_ia->>'duree_mois') || ' mois'); end if;
          ia_ok := ia_diff is null and valeur_ia->>'debut' = o->>'start_date' and valeur_ia->>'duree_mois' = o->>'duration_in_months';
        when 'loyer' then
          detail := 'Loyer ' || coalesce(replace(to_char(loyer, 'FM999G999G990D00'), ',', ' '), '—') || ' € HC, appelé tous les ' || coalesce(o->>'frequency_in_months', '1') || ' mois'
                 || case when (o->>'rent_supplement_in_cents') is not null then ', complément ' || round((o->>'rent_supplement_in_cents')::numeric / 100, 2) || ' €' else '' end;
          vide := coalesce(loyer, 0) = 0;
          if valeur_ia is not null and nullif(valeur_ia->>'montant_mensuel', '') is not null and loyer > 0
             and abs((valeur_ia->>'montant_mensuel')::numeric - loyer) >= 0.5
             and abs((valeur_ia->>'montant_mensuel')::numeric * coalesce(nullif(o->>'frequency_in_months','')::numeric, 1) - loyer) >= 0.5 then
            ia_diff := 'loyer mensuel de ' || replace(to_char((valeur_ia->>'montant_mensuel')::numeric, 'FM999G999G990D00'), ',', ' ') || ' €'; end if;
          ia_ok := nullif(valeur_ia->>'montant_mensuel', '') is not null and ia_diff is null and loyer > 0;
        when 'tva' then
          detail := case when (o->>'vat_applicable')::boolean then 'TVA oui, taux ' || coalesce(o->>'vat_rate', '?') else 'Pas de TVA' end;
          vide := o->>'vat_applicable' is null;
          if valeur_ia is not null and nullif(valeur_ia->>'taux', '') is not null
             and (valeur_ia->>'taux')::numeric <> (case when (o->>'vat_applicable')::boolean then coalesce(nullif(o->>'vat_rate','')::numeric, -1) else 0 end) then
            ia_diff := case when (valeur_ia->>'taux')::numeric = 0 then 'pas de TVA' else 'TVA à ' || (valeur_ia->>'taux') || ' %' end; end if;
          ia_ok := nullif(valeur_ia->>'taux', '') is not null and ia_diff is null;
        when 'indice' then
          detail := coalesce(upper(idx->>'nature'), 'aucun') || coalesce(' ' || upper(idx->>'quarter') || ' ' || (idx->>'year') || ' = ' || (idx->>'value'), '')
                 || case when (o->>'indexation_enabled')::boolean then '' else ' (indexation désactivée)' end
                 || case when coalesce(o->'signing_quarter_revision_index'->>'nature', idx->>'nature') <> idx->>'nature'
                         then ' (valeur initiale informative en ' || upper(o->'signing_quarter_revision_index'->>'nature') || ', sans effet sur la révision)' else '' end;
          vide := (o->>'indexation_enabled')::boolean and idx->>'nature' is null;
          if v_portee = 'commercial' and coalesce(idx->>'nature', '') not in ('ilc','ilat','icc') and (o->>'indexation_enabled')::boolean then auto := 'anomalie'; detail := detail || ' : indice d''habitation sur un bail commercial'; end if;
          if v_portee = 'habitation' and coalesce(idx->>'nature', '') not in ('irl','irl_outre_mer') and (o->>'indexation_enabled')::boolean then auto := 'anomalie'; detail := detail || ' : l''IRL est attendu en habitation'; end if;
          if valeur_ia is not null and nullif(valeur_ia->>'code','') is not null and lower(valeur_ia->>'code') <> lower(coalesce(idx->>'nature','')) then
            ia_diff := 'indice ' || upper(valeur_ia->>'code'); end if;
          ia_ok := nullif(valeur_ia->>'code','') is not null and ia_diff is null;
        when 'revision' then
          detail := 'Tous les ' || coalesce(o->>'revision_frequency_in_years', '?') || ' an(s), prochaine le ' || coalesce(to_char((o->>'next_revision_date')::date, 'DD/MM/YYYY'), '—');
          vide := (o->>'indexation_enabled')::boolean and (o->>'revision_frequency_in_years' is null or o->>'next_revision_date' is null);
          if valeur_ia is not null and nullif(valeur_ia->>'annees', '') is not null and (valeur_ia->>'annees')::text <> coalesce(o->>'revision_frequency_in_years','') then
            ia_diff := 'révision tous les ' || (valeur_ia->>'annees') || ' an(s)'; end if;
          ia_ok := nullif(valeur_ia->>'annees', '') is not null and ia_diff is null;
        when 'dg' then
          detail := coalesce(dg::text || ' €', 'Dépôt de garantie') || case when loyer > 0 and dg is not null then ' (' || round(dg / loyer, 1) || ' fois le loyer appelé)' else '' end;
          vide := dg is null;
          if v_portee = 'habitation' and loyer > 0 and dg > loyer * (case when typ = 'meuble' then 2 else 1 end) then auto := 'anomalie'; detail := detail || ' : au-delà du plafond légal'; end if;
          if valeur_ia is not null and nullif(valeur_ia->>'montant','') is not null and (valeur_ia->>'montant')::numeric <> coalesce(dg, -1) then
            ia_diff := 'dépôt de ' || (valeur_ia->>'montant') || ' €'; end if;
          ia_ok := nullif(valeur_ia->>'montant','') is not null and ia_diff is null;
        when 'charges' then
          detail := coalesce(round((o->>'charges_in_cents')::numeric / 100, 2)::text || ' € par appel', 'Provisions');
          vide := o->>'charges_in_cents' is null;
          if valeur_ia is not null and nullif(valeur_ia->>'montant_mensuel', '') is not null
             and abs((valeur_ia->>'montant_mensuel')::numeric - coalesce((o->>'charges_in_cents')::numeric / 100, 0)) >= 0.5
             and abs((valeur_ia->>'montant_mensuel')::numeric * coalesce(nullif(o->>'frequency_in_months','')::numeric, 1) - coalesce((o->>'charges_in_cents')::numeric / 100, 0)) >= 0.5 then
            ia_diff := 'provisions de ' || (valeur_ia->>'montant_mensuel') || ' € par mois'; end if;
          ia_ok := nullif(valeur_ia->>'montant_mensuel', '') is not null and ia_diff is null;
        else null;
      end case;
      if vide then auto := 'anomalie'; detail := detail || ' : non renseigné dans Rivage';
      elsif ia_diff is not null then auto := 'anomalie'; detail := detail || ' · le bail indique : ' || ia_diff;
      elsif auto is null and ia_ok then auto := 'ok';
      elsif auto is null then detail := detail || ' · à confirmer : non vérifié dans le bail'; end if;
    end if;
    -- 021 : une réponse sur un champ Rivage vaut pour l'état constaté au moment de la réponse. Si Rivage a été corrigé
    -- ou si l'écart a changé, la réponse tombe : le point se replie s'il est désormais conforme, réapparaît sinon.
    if q.bloc in ('rivage', 'pieces') and rep.statut is not null and (
         (auto = 'anomalie' and rep.valeur is distinct from detail)
      or (coalesce(auto, '') <> 'anomalie' and rep.valeur is not null and rep.valeur is distinct from detail)) then
      rep := null;
    end if;
    if rep.statut is null then
      if coalesce(auto, '') not in ('ok', 'sans_objet') then restant := restant + 1; end if;
    end if;
    if coalesce(rep.statut, auto) = 'anomalie' then anomalies := anomalies + 1; end if;
    items := items || jsonb_build_object('cle', q.cle, 'bloc', q.bloc, 'libelle', q.libelle, 'aide', q.aide, 'mode', q.mode, 'ref', q.ref, 'genere', q.genere,
      'auto', auto, 'detail', detail, 'ia', valeur_ia, 'piece', piece,
      'statut', coalesce(rep.statut, case when auto in ('ok', 'sans_objet') then auto end), 'repondu', rep.statut is not null,
      'suivi', rep.suivi, 'valeur', rep.valeur, 'commentaire', rep.commentaire, 'par', pilotage.prenom_membre(rep.par), 'le', rep.le,
      'a_traiter', rep.statut is null and coalesce(auto, '') not in ('ok', 'sans_objet'));
  end loop;
  return jsonb_build_object('portee', v_portee, 'items', items, 'restant', restant, 'anomalies', anomalies,
    'go_le', f.go_le, 'go_par', pilotage.prenom_membre(f.go_par), 'lecture_le', (select max(le) from pilotage.baux_lectures where bail_id = p_bail));
end $$;

create or replace function pilotage.controle_mandat(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  o jsonb; s pilotage.mandats_suivi; items jsonb := '[]'::jsonb; q record; rep pilotage.baux_reponses; up record; piece jsonb;
  auto text; detail text; valeur_ia jsonb; lecture jsonb; restant integer := 0; anomalies integer := 0; ia_diff text; vide boolean; ia_ok boolean;
  nb_lots integer; annees integer[]; avant1949 boolean; inconnu boolean; mois integer; equip integer; compt integer;
begin
  select data into o from pilotage.objets where type = 'ManagementContract' and id = p_mandat and supprime_le is null;
  if o is null then return null; end if;
  select * into s from pilotage.mandats_suivi where mandat_id = p_mandat;
  select resultat into lecture from pilotage.baux_lectures where bail_id = p_mandat order by le desc limit 1;
  select count(*), array_agg(nullif(a.data->>'construction_year', '')::integer) into nb_lots, annees
    from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat;
  select count(*) filter (where e.nature = 'equipement'), count(*) filter (where e.nature = 'compteur') into equip, compt
    from pilotage.lots_equipements e where e.asset_id in (select a.id from pilotage.objets a where a.type = 'Asset' and a.data->>'management_contract_id' = p_mandat);

  for q in select * from pilotage.controle_questions where portee = 'mandat' order by case bloc when 'pieces' then 1 when 'rivage' then 2 else 3 end, ordre loop
    select * into rep from pilotage.baux_reponses where bail_id = p_mandat and cle = q.cle;
    auto := null; detail := null; valeur_ia := lecture->q.cle; piece := null; up := null; ia_diff := null; vide := false; ia_ok := false;

    if q.mode = 'document' then
      select u.id, u.data->>'label' as label, u.data->>'nature' as nature, coalesce(u.data->>'nature' = any(coalesce(q.natures, array[q.ref])), false) as par_nature into up
        from pilotage.uploads_mandat(p_mandat) u
       where (coalesce(q.natures, array[q.ref]) is not null and u.data->>'nature' = any(coalesce(q.natures, array[q.ref])))
          or (q.mots is not null and pilotage.sans_accents(u.data->>'label') ~ ('\m(' || array_to_string(q.mots, '|') || ')'))
       order by coalesce(u.data->>'nature' = any(coalesce(q.natures, array[q.ref])), false) desc, u.maj_le desc limit 1;
      if up.id is not null then
        auto := 'ok';
        detail := case when up.label is null then 'Déposé dans Rivage (catégorie « ' || coalesce(pilotage.categorie_rivage(up.nature), '?') || ' »)' else 'Déposé dans Rivage : « ' || up.label || ' »' end || case when up.par_nature then '' else ' (reconnu par son nom)' end;
        piece := jsonb_build_object('id', up.id, 'libelle', up.label, 'par_nom', not up.par_nature);
      else
        detail := 'Absent dans Rivage.';
        -- Diagnostics non exigés d'après l'année de construction des lots (quand Rivage la donne pour tous les lots)
        inconnu := annees is null or array_position(annees, null) is not null or nb_lots = 0;
        if q.cle = 'm_doc_amiante' and not inconnu and (select min(x) from unnest(annees) x) >= 1998 then
          auto := 'sans_objet'; detail := 'Non exigé : lots construits en 1998 ou après d''après Rivage (permis postérieur au 01/07/1997 à confirmer).';
        elsif q.cle = 'm_doc_plomb' and not inconnu and (select min(x) from unnest(annees) x) >= 1949 then
          auto := 'sans_objet'; detail := 'Non exigé : lots construits en 1949 ou après d''après Rivage.';
        end if;
      end if;

    elsif q.mode = 'rivage' then
      case q.ref
        when 'mandants' then
          detail := 'Mandants : ' || coalesce((select string_agg(coalesce(pilotage.nom_profil(p->>'profile_id'), 'propriétaire non transmis') || ' (' || coalesce(p->>'share', '?') || ' %)', ', ')
                                               from jsonb_array_elements(coalesce(o->'profile_contracts_attributes', '[]'::jsonb)) p), '—');
          vide := jsonb_array_length(coalesce(o->'profile_contracts_attributes', '[]'::jsonb)) = 0
               or coalesce((select sum((p->>'share')::numeric) from jsonb_array_elements(o->'profile_contracts_attributes') p), 0) <> 100;
          if vide and jsonb_array_length(coalesce(o->'profile_contracts_attributes', '[]'::jsonb)) > 0 then detail := detail || ' : total des quotes-parts différent de 100 %'; vide := false; auto := 'anomalie'; end if;
        when 'dates' then
          detail := 'Signé le ' || coalesce(to_char((o->>'signed_at')::date, 'DD/MM/YYYY'), '—') || ', début ' || coalesce(to_char((o->>'start_date')::date, 'DD/MM/YYYY'), '—')
                 || ', fin ' || coalesce(to_char((o->>'end_date')::date, 'DD/MM/YYYY'), '—');
          vide := o->>'signed_at' is null or o->>'start_date' is null;
          mois := case when o->>'end_date' is not null and o->>'start_date' is not null
                       then ((extract(year from age(((o->>'end_date')::date + 1), (o->>'start_date')::date)) * 12) + extract(month from age(((o->>'end_date')::date + 1), (o->>'start_date')::date)))::integer end;
          if valeur_ia is not null and nullif(valeur_ia->>'signature', '') is not null and valeur_ia->>'signature' <> coalesce(o->>'signed_at', '') then
            ia_diff := 'signé le ' || to_char((valeur_ia->>'signature')::date, 'DD/MM/YYYY'); end if;
          if valeur_ia is not null and nullif(valeur_ia->>'debut', '') is not null and valeur_ia->>'debut' <> coalesce(o->>'start_date', '') then
            ia_diff := concat_ws(', ', ia_diff, 'début le ' || to_char((valeur_ia->>'debut')::date, 'DD/MM/YYYY')); end if;
          if valeur_ia is not null and nullif(valeur_ia->>'duree_mois', '') is not null and mois is not null and (valeur_ia->>'duree_mois')::integer <> mois then
            ia_diff := concat_ws(', ', ia_diff, 'durée initiale de ' || (valeur_ia->>'duree_mois') || ' mois'); end if;
          ia_ok := ia_diff is null and nullif(valeur_ia->>'debut', '') is not null;
        when 'reconduction' then
          detail := case o->>'renewal_type' when 'tacit' then 'Tacite' when 'express' then 'Expresse' else coalesce(o->>'renewal_type', '—') end
                 || coalesce(', par périodes de ' || (o->>'renewal_duration_years') || ' an(s)', '');
          vide := o->>'renewal_type' is null;
          if valeur_ia is not null and nullif(valeur_ia->>'code', '') is not null
             and (case valeur_ia->>'code' when 'tacite' then 'tacit' when 'expresse' then 'express' else valeur_ia->>'code' end) <> coalesce(o->>'renewal_type', '') then
            ia_diff := 'reconduction ' || (valeur_ia->>'code'); end if;
          if valeur_ia is not null and nullif(valeur_ia->>'annees', '') is not null and valeur_ia->>'annees' <> coalesce(o->>'renewal_duration_years', '') then
            ia_diff := concat_ws(', ', ia_diff, 'par périodes de ' || (valeur_ia->>'annees') || ' an(s)'); end if;
          ia_ok := ia_diff is null and nullif(valeur_ia->>'code', '') is not null;
        when 'registre' then
          detail := 'N° ' || coalesce(o->>'register_number', '—');
          vide := o->>'register_number' is null;
          if valeur_ia is not null and nullif(valeur_ia->>'numero', '') is not null and valeur_ia->>'numero' <> coalesce(o->>'register_number', '') then
            ia_diff := 'n° ' || (valeur_ia->>'numero'); end if;
          ia_ok := ia_diff is null and nullif(valeur_ia->>'numero', '') is not null;
        when 'hono_gestion' then
          detail := coalesce(o->>'management_fees_rate', '—') || ' % TTC'
                 || case o->>'management_fees_base' when 'all_collections_except_deposit' then ' des encaissements hors dépôt de garantie' else coalesce(' (base : ' || (o->>'management_fees_base') || ')', '') end
                 || case when coalesce((o->>'minimal_management_fees_in_cents')::numeric, 0) > 0 then ', minimum ' || round((o->>'minimal_management_fees_in_cents')::numeric / 100, 2) || ' €' else '' end
                 || case when coalesce((o->>'fixed_management_fees_in_cents')::numeric, 0) > 0 then ', frais fixes ' || round((o->>'fixed_management_fees_in_cents')::numeric / 100, 2) || ' €' else '' end;
          vide := coalesce(nullif(o->>'management_fees_rate', '')::numeric, 0) = 0;
          if valeur_ia is not null and nullif(valeur_ia->>'taux', '') is not null
             and abs((valeur_ia->>'taux')::numeric - coalesce(nullif(o->>'management_fees_rate', '')::numeric, 0)) >= 0.01 then
            ia_diff := 'taux de ' || (valeur_ia->>'taux') || ' % TTC'; end if;
          ia_ok := ia_diff is null and nullif(valeur_ia->>'taux', '') is not null;
        when 'hono_location' then
          detail := 'Location : ' || coalesce(o->>'rental_fees_rate', '—') || ' %'
                 || case when coalesce((o->>'rental_fees_per_sqm_in_cents')::numeric, 0) > 0 then ', ' || round((o->>'rental_fees_per_sqm_in_cents')::numeric / 100, 2) || ' €/m²' else '' end
                 || case when coalesce((o->>'fixed_rental_fees_in_cents')::numeric, 0) > 0 then ', fixe ' || round((o->>'fixed_rental_fees_in_cents')::numeric / 100, 2) || ' €' else '' end
                 || case when coalesce((o->>'minimal_rental_fees_in_cents')::numeric, 0) > 0 then ', minimum ' || round((o->>'minimal_rental_fees_in_cents')::numeric / 100, 2) || ' €' else '' end
                 || ' · état des lieux : ' || coalesce(round((o->>'inventory_fees_per_sqm_in_cents')::numeric / 100, 2)::text, '—') || ' €/m²';
          vide := coalesce(nullif(o->>'rental_fees_rate', '')::numeric, 0) = 0 and coalesce((o->>'rental_fees_per_sqm_in_cents')::numeric, 0) = 0
              and coalesce((o->>'fixed_rental_fees_in_cents')::numeric, 0) = 0;
        when 'lots' then
          detail := nb_lots || ' lot(s)' || coalesce(' : ' || (select string_agg(coalesce(a.data->>'reference', a.data->>'name', a.id), ', ') from pilotage.objets a
                    where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat), '');
          vide := nb_lots = 0;
        else null;
      end case;
      if vide then auto := 'anomalie'; detail := detail || ' : non renseigné dans Rivage';
      elsif ia_diff is not null then auto := 'anomalie'; detail := detail || ' · le mandat indique : ' || ia_diff;
      elsif auto is null and ia_ok then auto := 'ok';
      elsif auto is null then detail := detail || ' · à confirmer : non vérifié dans le mandat'; end if;

    elsif q.ref = 'equipements' then
      detail := case when equip > 0 then equip || ' équipement(s) saisi(s)' end;
    elsif q.ref = 'compteurs' then
      detail := case when compt > 0 then compt || ' compteur(s) divisionnaire(s) saisi(s)' end;
    end if;

    -- Une réponse sur un champ Rivage ou une pièce vaut pour l'état constaté : si Rivage ou le document change, elle tombe.
    if q.bloc in ('rivage', 'pieces') and rep.statut is not null and (
         (auto = 'anomalie' and rep.valeur is distinct from detail)
      or (coalesce(auto, '') <> 'anomalie' and rep.valeur is not null and rep.valeur is distinct from detail)) then
      rep := null;
    end if;
    if rep.statut is null and coalesce(auto, '') not in ('ok', 'sans_objet') then restant := restant + 1; end if;
    if coalesce(rep.statut, auto) = 'anomalie' then anomalies := anomalies + 1; end if;
    items := items || jsonb_build_object('cle', q.cle, 'bloc', q.bloc, 'libelle', q.libelle, 'aide', q.aide, 'mode', q.mode, 'ref', q.ref, 'genere', q.genere,
      'auto', auto, 'detail', detail, 'ia', valeur_ia, 'piece', piece,
      'statut', coalesce(rep.statut, case when auto in ('ok', 'sans_objet') then auto end), 'repondu', rep.statut is not null,
      'suivi', rep.suivi, 'valeur', rep.valeur, 'commentaire', rep.commentaire, 'par', pilotage.prenom_membre(rep.par), 'le', rep.le,
      'a_traiter', rep.statut is null and coalesce(auto, '') not in ('ok', 'sans_objet'));
  end loop;
  return jsonb_build_object('portee', 'mandat', 'items', items, 'restant', restant, 'anomalies', anomalies,
    'soumis', (o->>'start_date')::date >= date '2026-01-01',
    'go_le', s.go_le, 'go_par', pilotage.prenom_membre(s.go_par), 'lecture_le', (select max(le) from pilotage.baux_lectures where bail_id = p_mandat));
end $$;

create or replace function public.pilotage_mandat_source(p_mandat text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('upload_id', u.id, 'libelle', coalesce(u.data->>'label', 'Mandat de gestion'), 'url', u.data->>'file_url')
  from pilotage.uploads_mandat(p_mandat) u
  where u.data->>'nature' = 'management_mandate' or pilotage.sans_accents(u.data->>'label') ~ '\m(mandat de gestion|mandat gestion|mandat signe)'
  order by (u.data->>'nature' = 'management_mandate') desc, u.maj_le desc limit 1
$$;
revoke all on function public.pilotage_mandat_source(text) from public, anon, authenticated;
grant execute on function public.pilotage_mandat_source(text) to service_role;
revoke all on all functions in schema pilotage from public, anon, authenticated;
