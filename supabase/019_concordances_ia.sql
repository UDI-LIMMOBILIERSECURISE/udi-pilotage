-- 019 : contrôle d'entrée, les valeurs lues dans le bail par l'IA et identiques à Rivage sont validées d'office
-- (loyer, provisions sur charges, TVA, indice, périodicité de révision, en plus des dates et du dépôt de garantie).
-- Les baux déjà lus avant cette version doivent être relus pour en profiter (bouton « Lire le bail »).
create or replace function pilotage.controle_bail(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  o jsonb; lot record; f pilotage.baux_fiche; typ text; v_portee text; items jsonb := '[]'::jsonb; q record; rep pilotage.baux_reponses;
  auto text; detail text; valeur_ia jsonb; lecture jsonb; docs text[]; loyer numeric; dg numeric; idx jsonb; restant integer := 0; anomalies integer := 0;
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
      case q.ref
        when 'parties' then
          detail := 'Preneur : ' || coalesce((select string_agg(coalesce(nullif(t->>'company_name',''), concat_ws(' ', t->>'last_name', t->>'first_name')), ', ') from jsonb_array_elements(o->'tenants') t), '—')
                 || ' · Bailleur : ' || coalesce(pilotage.bailleurs_mandat(lot.mandat_id), '—');
          if jsonb_array_length(coalesce(o->'tenants','[]'::jsonb)) = 0 then auto := 'anomalie'; end if;
        when 'dates' then
          detail := 'Début ' || coalesce(to_char((o->>'start_date')::date, 'DD/MM/YYYY'), '—') || ', durée ' || coalesce(o->>'duration_in_months', '—') || ' mois';
          if o->>'start_date' is null or coalesce(nullif(o->>'duration_in_months','')::integer, 0) = 0 then auto := 'anomalie'; end if;
          if valeur_ia is not null and valeur_ia->>'debut' = o->>'start_date' and (valeur_ia->>'duree_mois')::text = o->>'duration_in_months' then auto := 'ok'; end if;
        when 'loyer' then
          detail := 'Loyer ' || coalesce(replace(to_char(loyer, 'FM999G999G990D00'), ',', ' '), '—') || ' € HC, appelé tous les ' || coalesce(o->>'frequency_in_months', '1') || ' mois'
                 || case when (o->>'rent_supplement_in_cents') is not null then ', complément ' || round((o->>'rent_supplement_in_cents')::numeric / 100, 2) || ' €' else '' end;
          if coalesce(loyer, 0) = 0 then auto := 'anomalie'; end if;
          if valeur_ia is not null and nullif(valeur_ia->>'montant_mensuel', '') is not null and loyer > 0
             and (abs((valeur_ia->>'montant_mensuel')::numeric - loyer) < 0.5
                  or abs((valeur_ia->>'montant_mensuel')::numeric * coalesce(nullif(o->>'frequency_in_months','')::numeric, 1) - loyer) < 0.5) then auto := 'ok'; end if;
        when 'tva' then detail := case when (o->>'vat_applicable')::boolean then 'TVA oui, taux ' || coalesce(o->>'vat_rate', '?') else 'Pas de TVA' end;
          if valeur_ia is not null and nullif(valeur_ia->>'taux', '') is not null
             and (valeur_ia->>'taux')::numeric = (case when (o->>'vat_applicable')::boolean then coalesce(nullif(o->>'vat_rate','')::numeric, -1) else 0 end) then auto := 'ok'; end if;
        when 'indice' then
          detail := coalesce(upper(idx->>'nature'), 'aucun') || coalesce(' ' || upper(idx->>'quarter') || ' ' || (idx->>'year') || ' = ' || (idx->>'value'), '')
                 || case when (o->>'indexation_enabled')::boolean then '' else ' (indexation désactivée)' end
                 || case when coalesce(o->'signing_quarter_revision_index'->>'nature', idx->>'nature') <> idx->>'nature'
                         then ' (valeur initiale informative en ' || upper(o->'signing_quarter_revision_index'->>'nature') || ', sans effet sur la révision)' else '' end;
          if v_portee = 'commercial' and coalesce(idx->>'nature', '') not in ('ilc','ilat','icc') and (o->>'indexation_enabled')::boolean then auto := 'anomalie'; detail := detail || ' : indice d''habitation sur un bail commercial'; end if;
          if v_portee = 'habitation' and coalesce(idx->>'nature', '') not in ('irl','irl_outre_mer') and (o->>'indexation_enabled')::boolean then auto := 'anomalie'; end if;
          if auto is null and valeur_ia is not null and lower(valeur_ia->>'code') = lower(idx->>'nature') then auto := 'ok'; end if;
        when 'revision' then detail := 'Tous les ' || coalesce(o->>'revision_frequency_in_years', '?') || ' an(s), prochaine le ' || coalesce(to_char((o->>'next_revision_date')::date, 'DD/MM/YYYY'), '—');
          if valeur_ia is not null and nullif(valeur_ia->>'annees', '') is not null and (valeur_ia->>'annees')::text = o->>'revision_frequency_in_years' then auto := 'ok'; end if;
        when 'dg' then
          detail := coalesce(dg::text, '—') || ' €' || case when loyer > 0 and dg is not null then ' (' || round(dg / loyer, 1) || ' fois le loyer appelé)' else '' end;
          if v_portee = 'habitation' and loyer > 0 and dg > loyer * (case when typ = 'meuble' then 2 else 1 end) then auto := 'anomalie'; detail := detail || ' : au-delà du plafond légal'; end if;
          if valeur_ia is not null and (valeur_ia->>'montant')::numeric = dg and auto is null then auto := 'ok'; end if;
        when 'charges' then detail := coalesce(round((o->>'charges_in_cents')::numeric / 100, 2)::text, '0') || ' € par appel';
          if valeur_ia is not null and nullif(valeur_ia->>'montant_mensuel', '') is not null
             and (abs((valeur_ia->>'montant_mensuel')::numeric - coalesce((o->>'charges_in_cents')::numeric / 100, 0)) < 0.5
                  or abs((valeur_ia->>'montant_mensuel')::numeric * coalesce(nullif(o->>'frequency_in_months','')::numeric, 1) - coalesce((o->>'charges_in_cents')::numeric / 100, 0)) < 0.5) then auto := 'ok'; end if;
        else null;
      end case;
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
