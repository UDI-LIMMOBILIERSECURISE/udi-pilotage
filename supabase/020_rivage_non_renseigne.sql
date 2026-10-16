-- 020 : croisement avec Rivage (décision de Nicolas, 16/10/2026). Rivage n'est jamais conforme par défaut :
--   champ non renseigné dans Rivage            -> alerte ;
--   valeur différente de celle lue dans le bail -> alerte, avec la valeur du bail ;
--   valeur identique à celle lue dans le bail   -> conforme d'office, replié ;
--   bail non lu ou information non trouvée      -> à confirmer par la gestionnaire.
-- Les incohérences légales (indice, plafond du dépôt) restent signalées. Les informations absentes de Rivage restent dans les
-- blocs pièces et clauses.
-- Remplace pilotage.controle_bail (019).
create or replace function pilotage.controle_bail(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  o jsonb; lot record; f pilotage.baux_fiche; typ text; v_portee text; items jsonb := '[]'::jsonb; q record; rep pilotage.baux_reponses;
  auto text; detail text; valeur_ia jsonb; lecture jsonb; docs text[]; loyer numeric; dg numeric; idx jsonb; restant integer := 0; anomalies integer := 0; ia_diff text; vide boolean; ia_ok boolean;
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
  loyer := round((o->>'rent_in_cents')::numeric / 100, 2); dg := round((o->>'deposit_in_cents')::numeric / 100, 2); idx := coalesce(o->'quarter_revision_index', o->'signing_quarter_revision_index');

  for q in select * from pilotage.controle_questions where controle_questions.portee = v_portee order by case bloc when 'pieces' then 1 when 'rivage' then 2 else 3 end, ordre loop
    select * into rep from pilotage.baux_reponses where bail_id = p_bail and cle = q.cle;
    auto := null; detail := null; valeur_ia := lecture->q.cle;
    if q.mode = 'document' then
      if q.ref = any(coalesce(docs, '{}')) then auto := 'ok'; detail := 'Déposé dans Rivage.'; else detail := 'Absent dans Rivage.'; end if;
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
          detail := 'Début ' || coalesce(to_char((o->>'start_date')::date, 'DD/MM/YYYY'), '—') || ', durée ' || coalesce(o->>'duration_in_months', '—') || ' mois';
          vide := o->>'start_date' is null or coalesce(nullif(o->>'duration_in_months','')::integer, 0) = 0;
          if valeur_ia is not null and nullif(valeur_ia->>'debut','') is not null and valeur_ia->>'debut' <> coalesce(o->>'start_date','') then
            ia_diff := 'date d''effet du ' || to_char((valeur_ia->>'debut')::date, 'DD/MM/YYYY'); end if;
          if valeur_ia is not null and nullif(valeur_ia->>'duree_mois','') is not null and valeur_ia->>'duree_mois' <> coalesce(o->>'duration_in_months','') then
            ia_diff := concat_ws(', ', ia_diff, 'durée de ' || (valeur_ia->>'duree_mois') || ' mois'); end if;
          ia_ok := valeur_ia->>'debut' = o->>'start_date' and valeur_ia->>'duree_mois' = o->>'duration_in_months';
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
    if rep.statut is null then
      if coalesce(auto, '') <> 'ok' then restant := restant + 1; end if;
    end if;
    if coalesce(rep.statut, auto) = 'anomalie' then anomalies := anomalies + 1; end if;
    items := items || jsonb_build_object('cle', q.cle, 'bloc', q.bloc, 'libelle', q.libelle, 'aide', q.aide, 'mode', q.mode, 'ref', q.ref, 'genere', q.genere,
      'auto', auto, 'detail', detail, 'ia', valeur_ia,
      'statut', coalesce(rep.statut, case when auto = 'ok' then 'ok' end), 'repondu', rep.statut is not null,
      'suivi', rep.suivi, 'valeur', rep.valeur, 'commentaire', rep.commentaire, 'par', pilotage.prenom_membre(rep.par), 'le', rep.le,
      'a_traiter', rep.statut is null and coalesce(auto, '') <> 'ok');
  end loop;
  return jsonb_build_object('portee', v_portee, 'items', items, 'restant', restant, 'anomalies', anomalies,
    'go_le', f.go_le, 'go_par', pilotage.prenom_membre(f.go_par), 'lecture_le', (select max(le) from pilotage.baux_lectures where bail_id = p_bail));
end $$;

revoke all on all functions in schema pilotage from public, anon, authenticated;
