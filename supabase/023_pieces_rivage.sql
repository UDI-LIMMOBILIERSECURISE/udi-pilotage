-- 023 : toutes les pièces du dossier sont stockées dans Rivage (décision de Nicolas, 16/10/2026).
--   Chaque pièce est reconnue par sa nature Rivage quand elle existe, sinon par le nom du document (approximatif, sans accents
--   ni majuscules, mots-clés ci-dessous). En cas de doute, la gestionnaire fait vérifier le document par l'IA depuis la fiche.
--   Une réponse sur une pièce vaut pour le document constaté : un nouveau dépôt la fait retomber (recontrôle).
-- Remplace pilotage.controle_bail et public.pilotage_bail_repondre (021) ; ajoute public.pilotage_piece_source pour la vérification par l'IA.

create or replace function pilotage.sans_accents(t text) returns text language sql immutable as $$
  select lower(translate(coalesce(t, ''), 'àâäáãéèêëíìîïóòôöõúùûüçÀÂÄÁÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÇ''’_-.', 'aaaaaeeeeiiiiooooouuuucaaaaaeeeeiiiiooooouuuuc     '))
$$;

alter table pilotage.controle_questions add column if not exists mots text[];
update pilotage.controle_questions set mode = 'document' where bloc = 'pieces';
update pilotage.controle_questions set mots = v.m, aide = coalesce(v.a, aide)
from (values
  ('c_doc_bail', array['bail commercial', 'bail signe', 'contrat de bail'], null),
  ('h_doc_bail', array['bail d habitation', 'bail signe', 'contrat de location', 'bail meuble', 'bail vide', 'notice d information'], null),
  ('c_doc_actes', array['avenant', 'renouvellement', 'conge', 'acte de cession'], 'À déposer dans Rivage s''il y en a ; sinon « Sans objet ».'),
  ('c_doc_edl', array['etat des lieux', 'edl'], null), ('h_doc_edl', array['etat des lieux', 'edl'], null),
  ('c_doc_dpe', array['dpe', 'performance energetique'], null), ('h_doc_dpe', array['dpe', 'performance energetique'], null),
  ('c_doc_amiante', array['amiante', 'dta'], null),
  ('c_doc_erp', array['erp', 'etat des risques', 'risques et pollutions', 'ernmt', 'ernt', 'esris'], null),
  ('h_doc_erp', array['erp', 'etat des risques', 'risques et pollutions', 'ernmt', 'ernt', 'esris'], null),
  ('c_doc_inventaire', array['inventaire', 'repartition des charges'], null),
  ('c_doc_travaux', array['etat des travaux', 'travaux previsionnels', 'plan de travaux', 'travaux realises'], null),
  ('c_doc_assurance', array['assurance', 'responsabilite civile', 'multirisque'], null),
  ('h_doc_assurance', array['assurance', 'multirisque'], null),
  ('c_doc_garantie', array['caution', 'garantie bancaire', 'garantie a premiere demande', 'gapd'], 'À déposer dans Rivage s''il y en a une ; sinon « Sans objet ».'),
  ('c_doc_annexe_env', array['annexe environnementale', 'annexe verte'], null),
  ('h_doc_plomb', array['plomb', 'crep'], null),
  ('h_doc_elec_gaz', array['electricite', 'electrique', 'gaz'], null),
  ('h_doc_surface', array['surface', 'carrez', 'boutin', 'mesurage'], null),
  ('h_doc_caution', array['caution', 'cautionnement'], 'À déposer dans Rivage s''il y en a une ; sinon « Sans objet ».')
) v(c, m, a) where cle = v.c;

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
      select u.id, u.data->>'label' as label, coalesce(u.data->>'nature' = q.ref, false) as par_nature into up
        from pilotage.objets u
       where u.type = 'Upload' and u.supprime_le is null
         and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr where rr->>'id' in (p_bail, o->>'asset_id'))
         and ((q.ref is not null and u.data->>'nature' = q.ref)
           or (q.mots is not null and pilotage.sans_accents(u.data->>'label') ~ ('\m(' || array_to_string(q.mots, '|') || ')')))
       order by coalesce(u.data->>'nature' = q.ref, false) desc, u.maj_le desc limit 1;
      if up.id is not null then
        auto := 'ok';
        detail := 'Déposé dans Rivage : « ' || coalesce(up.label, 'sans nom') || ' »' || case when up.par_nature then '' else ' (reconnu par son nom)' end;
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

-- Document Rivage à faire vérifier par l'IA : seulement s'il est rattaché à ce bail ou à son lot (rôle service uniquement).
create or replace function public.pilotage_piece_source(p_bail text, p_upload text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('upload_id', u.id, 'libelle', u.data->>'label', 'url', u.data->>'file_url')
  from pilotage.objets u where u.type = 'Upload' and u.id = p_upload and u.supprime_le is null
    and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables','[]'::jsonb)) rr
                where rr->>'id' in (p_bail, (select data->>'asset_id' from pilotage.objets where type = 'LeasingContract' and id = p_bail)))
$$;
revoke all on function public.pilotage_piece_source(text, text) from public, anon, authenticated;
grant execute on function public.pilotage_piece_source(text, text) to service_role;
revoke all on all functions in schema pilotage from public, anon, authenticated;

create or replace function public.pilotage_bail_repondre(p_bail text, p_cle text, p_statut text, p_suivi text, p_valeur text, p_commentaire text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare it jsonb; v_valeur text := p_valeur;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_statut is null then delete from pilotage.baux_reponses where bail_id = p_bail and cle = p_cle; return; end if;
  if p_statut = 'anomalie' and nullif(trim(coalesce(p_commentaire, '')), '') is null then raise exception 'Décrivez l''anomalie en commentaire'; end if;
  select x into it from jsonb_array_elements(pilotage.controle_bail(p_bail)->'items') x where x->>'cle' = p_cle;
  if it->>'bloc' in ('rivage', 'pieces') then
    v_valeur := it->>'detail';
    if it->>'bloc' = 'rivage' and it->>'auto' = 'anomalie' and p_statut <> 'sans_objet' and nullif(trim(coalesce(p_commentaire, '')), '') is null then
      raise exception 'Écart détecté : justifiez la réponse en commentaire (avenant, indexation, mauvais document lu…) ou corrigez Rivage';
    end if;
  end if;
  insert into pilotage.baux_reponses (bail_id, cle, statut, suivi, valeur, commentaire, par) values (p_bail, p_cle, p_statut, p_suivi, v_valeur, p_commentaire, auth.uid())
  on conflict (bail_id, cle) do update set statut = excluded.statut, suivi = excluded.suivi, valeur = excluded.valeur, commentaire = excluded.commentaire, par = auth.uid(), le = now();
end $$;
revoke all on function public.pilotage_bail_repondre(text, text, text, text, text, text) from public, anon;
grant execute on function public.pilotage_bail_repondre(text, text, text, text, text, text) to authenticated;
