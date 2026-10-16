-- 018 : contrôles affinés avec ce que Rivage envoie (16/10/2026). Remplace aussi le 017 (inutile de l'exécuter).
--  1. Indice : le contrôle lit l'indice de référence de l'indexation (quarter_revision_index) et non la « valeur initiale
--     informative » (signing_quarter_revision_index) ; une différence de nature entre les deux est signalée pour information.
--  2. Âge du locataire : calculé à l'échéance depuis la date de naissance transmise par Rivage (seul l'âge est affiché,
--     jamais la date) ; la saisie de la fiche reste prioritaire ; une société locataire n'est pas concernée.
--  3. Paliers : une ligne d'appel « Loyer » programmée dans Rivage à la date et au montant du palier vaut mise à jour faite.
--  4. Refacturations : l'étape « appeler la taxe sur les bureaux / la surprime » est considérée faite dès qu'une ligne d'appel
--     correspondante existe dans Rivage sur le bail.
--  5. Fiche du bail : équipements du lot (chauffage, eau chaude) et dernier entretien de chaudière pour pré-remplir les questions.

create or replace function pilotage.locataire_65_rivage(p_bail text, p_date date) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when count(*) = 0 then null else jsonb_build_object(
      'plus_65', bool_or(age_ech >= 65),
      'connu', bool_and(age_ech is not null or morale),
      'detail', string_agg(case when morale then nom || ' (société, non concernée)'
                                when age_ech is null then nom || ' (date de naissance non renseignée)'
                                else nom || ' : ' || age_ech || ' ans à l''échéance' end, ', ')) end
  from (select coalesce(nullif(t->>'company_name', ''), concat_ws(' ', t->>'first_name', t->>'last_name')) nom,
               coalesce(t->>'nature', '') = 'moral_tenant' or nullif(t->>'company_name', '') is not null morale,
               case when nullif(t->>'birth_date', '') is not null then extract(year from age(coalesce(p_date, current_date), (t->>'birth_date')::date))::int end age_ech
        from pilotage.objets b, jsonb_array_elements(coalesce(b.data->'tenants', '[]'::jsonb)) t
        where b.type = 'LeasingContract' and b.id = p_bail) x
$$;

create or replace function pilotage.palier_programme(p_id bigint) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select exists (select 1 from pilotage.baux_paliers p, pilotage.objets bl
    where p.id = p_id and bl.type = 'BillingLine' and bl.supprime_le is null and bl.data->>'leasing_contract_id' = p.bail_id
      and (bl.data->>'name') ilike 'loyer%' and coalesce(bl.data->>'type', 'tenant') = 'tenant'
      and (bl.data->>'start_date')::date = p.debut
      and (p.loyer_rivage is null or round((bl.data->>'amount_in_cents')::numeric / 100, 2) = p.loyer_rivage))
$$;

create or replace function pilotage.echeance_bail(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  o jsonb; lot record; f pilotage.baux_fiche; e pilotage.baux_echeance;
  typ text; sugg text; s date; d integer; r integer; k integer := 0; t date; t_manque date; mode text := 'terme';
  cal interval[]; info date; rel date; dec date; lim date; j date := current_date;
  v_cle text; informe date; relance date; lrar date; vu date;
  act text; act_lib text; v65 boolean; r65 jsonb; grav text := 'normale'; etat text; blocages jsonb := '[]'::jsonb; options jsonb; douze date; alerte_derog text;
begin
  select data into o from pilotage.objets where type = 'LeasingContract' and id = p_bail and supprime_le is null;
  if o is null then return null; end if;
  select * into lot from pilotage.v_lots where id = o->>'asset_id';
  select * into f from pilotage.baux_fiche where bail_id = p_bail;
  s := (o->>'start_date')::date; d := nullif(o->>'duration_in_months', '')::integer;
  sugg := pilotage.type_bail_suggere(lot.nature, d);
  typ := coalesce(f.type_bail, sugg);
  if typ is null or s is null or coalesce(d, 0) = 0 then
    return jsonb_build_object('type', typ, 'type_confirme', f.type_bail is not null, 'type_suggere', sugg, 'etat', 'incomplet',
      'raison', case when typ is null then 'Type de bail inconnu : à renseigner dans la fiche.' else 'Date de début ou durée absente dans Rivage.' end);
  end if;

  cal := case
    when typ = 'commercial' then array['12 months','10 months','8 months','6 months']::interval[]
    when typ = 'meuble' then array['5 months','4 months 15 days','4 months','3 months']::interval[]
    when typ = 'derogatoire' then array['3 months','2 months','1 month','0 days']::interval[]
    when typ in ('etudiant','mobilite') then array['2 months','2 months','2 months','0 days']::interval[]
    when typ = 'autre' then array['3 months','3 months','3 months','1 month']::interval[]
    else array['9 months','8 months','7 months','6 months']::interval[] end;

  if typ = 'commercial' then
    t := pilotage.ajouter_mois(s, d) - 1;
    douze := (s + interval '12 years')::date;
    if t <= j then mode := 'prolongation'; end if;
    lim := case when mode = 'terme' then (t - cal[4])::date end;
  elsif typ in ('derogatoire','etudiant','mobilite') then
    t := pilotage.ajouter_mois(s, d) - 1;
    lim := (t - cal[4])::date;
    if typ <> 'derogatoire' then mode := 'fin_auto'; end if;
  else
    r := coalesce(nullif(o->>'tacit_renewal_duration_years', '')::integer * 12, case when typ = 'meuble' then 12 else d end);
    t := pilotage.ajouter_mois(s, d) - 1;
    while t <= j loop k := k + 1; t := pilotage.ajouter_mois(s, d + k * r) - 1; end loop;
    lim := (t - cal[4])::date;
    if lim < j then t_manque := t; k := k + 1; t := pilotage.ajouter_mois(s, d + k * r) - 1; lim := (t - cal[4])::date; end if;
    if typ = 'autre' then mode := 'info'; t_manque := null; end if;
  end if;
  info := (t - cal[1])::date; rel := (t - cal[2])::date; dec := (t - cal[3])::date;

  v_cle := 'e:' || p_bail || ':' || t;
  select max(fait_le::date) filter (where etape = 'informe'), max(fait_le::date) filter (where etape = 'relance'),
         max(fait_le::date) filter (where etape = 'lrar'), max(fait_le::date) filter (where etape = 'vu')
    into informe, relance, lrar, vu from pilotage.suivis_etapes where suivis_etapes.cle = v_cle;
  select * into e from pilotage.baux_echeance where bail_id = p_bail and cycle = t;

  options := case
    when typ = 'vide' or typ = 'mixte' then '["reconduire","renouveler_loyer","conge_reprise","conge_vente","conge_motif"]'
    when typ = 'meuble' then '["reconduire","conge_reprise","conge_vente","conge_motif"]'
    when typ = 'commercial' then '["ne_rien_faire","conge_offre","refus_indemnite","refus_motif_grave"]'
    when typ = 'derogatoire' then '["opposition","laisser_commercial"]'
    when typ in ('etudiant','mobilite','autre') then '[]'
    else '["reconduire","conge"]' end::jsonb;

  if typ = 'derogatoire' and j > pilotage.ajouter_mois(t, 1) and coalesce(e.decision, '') <> 'opposition' then
    alerte_derog := 'Le preneur est dans les lieux plus d''un mois après la fin du bail dérogatoire sans opposition enregistrée : un bail commercial a pu naître (article L145-5).';
  end if;

  if mode in ('fin_auto','info') then
    if j >= info and vu is null then act := case when mode = 'info' then 'verifier_contrat' else 'fin_auto' end; etat := mode;
      act_lib := case when mode = 'info' then 'Échéance du contrat le ' || to_char(t, 'DD/MM/YYYY') || ' : vérifier le préavis prévu au contrat et informer le bailleur si besoin'
                      else 'Préparer la sortie : le bail prend fin le ' || to_char(t, 'DD/MM/YYYY') || ' sans congé' end;
    else etat := case when vu is null then 'a_venir' else mode end; end if;
  elsif typ = 'derogatoire' and e.decision is null and j > lim then
    if j <= pilotage.ajouter_mois(t, 1) then act := 'opposition_urgente'; grav := 'critique'; etat := 'derogatoire_terme';
      act_lib := 'Bail dérogatoire terminé le ' || to_char(t, 'DD/MM/YYYY') || ' : manifester l''opposition du bailleur au maintien du preneur avant le ' || to_char(pilotage.ajouter_mois(t, 1), 'DD/MM/YYYY');
    else etat := 'derogatoire_depasse'; end if;
  elsif e.decision is null then
    if j < info then etat := 'a_venir';
    elsif informe is null then act := 'informer'; act_lib := 'Informer le bailleur de l''échéance et de ses options'; etat := 'a_informer';
      if j >= rel then grav := 'haute'; end if;
    elsif relance is null and j >= greatest(rel, informe + 15) then act := 'relancer'; act_lib := 'Relancer le bailleur'; grav := 'haute'; etat := 'attente_bailleur';
    elsif lrar is null and j >= greatest(dec, coalesce(relance, informe) + 15) then act := 'lrar_silence'; act_lib := 'Envoyer une LRAR au bailleur pour acter son silence'; grav := 'haute'; etat := 'attente_bailleur';
    elsif mode = 'terme' and lim is not null and j > lim then etat := 'reconduit';
    else etat := 'attente_bailleur'; end if;
    if mode = 'terme' and lim is not null and j <= lim and lim - j <= 30 and etat in ('a_informer','attente_bailleur') then grav := 'critique';
      if act is null then act := 'decision_attendue'; act_lib := 'Décision du bailleur toujours attendue : date limite du congé le ' || to_char(lim, 'DD/MM/YYYY'); end if;
    end if;
  elsif e.decision in ('reconduire','ne_rien_faire','laisser_commercial') then etat := 'decide';
  elsif e.decision = 'renouveler_loyer' then
    if e.proposition_le is null and j <= lim then act := 'proposer_loyer'; act_lib := 'Adresser la proposition de nouveau loyer (au plus tard le ' || to_char(lim, 'DD/MM/YYYY') || ')';
      grav := case when lim - j <= 30 then 'critique' else 'haute' end; etat := 'decide';
    else etat := 'decide'; end if;
  else
    if typ in ('vide','meuble','mixte') and e.decision in ('conge_reprise','conge_vente','conge_motif') then
      r65 := pilotage.locataire_65_rivage(p_bail, t);
      v65 := coalesce(f.locataire_65, case when (r65->>'connu')::boolean then (r65->>'plus_65')::boolean end);
      if v65 is null then blocages := blocages || '"Vérifier l''âge du locataire (plus de 65 ans à l''échéance ?) avant le congé."'::jsonb;
      elsif v65 and f.ressources_sous_plafond is null then blocages := blocages || '"Locataire de plus de 65 ans : vérifier ses ressources (plafond logement conventionné)."'::jsonb;
      elsif v65 and f.ressources_sous_plafond then blocages := blocages || '"Locataire protégé : une offre de relogement est obligatoire, sauf si le bailleur remplit lui-même les conditions d''âge ou de ressources."'::jsonb; end if;
    end if;
    if e.conge_le is null then
      if lim is null or j <= lim then act := 'delivrer_conge';
        act_lib := case when typ in ('commercial','derogatoire') then 'Faire délivrer l''acte par commissaire de justice' else 'Délivrer le congé (LRAR, commissaire de justice ou remise contre émargement)' end
          || case when lim is not null then ' au plus tard le ' || to_char(lim, 'DD/MM/YYYY') else '' end;
        grav := case when lim is not null and lim - j <= 30 then 'critique' else 'haute' end; etat := 'conge_a_delivrer';
      else act := 'hors_delai'; act_lib := 'Délai du congé dépassé pour cette échéance : à revoir avec le bailleur'; grav := 'critique'; etat := 'hors_delai'; end if;
    else etat := 'conge_delivre'; end if;
  end if;

  return jsonb_build_object(
    'type', typ, 'type_confirme', f.type_bail is not null, 'type_suggere', sugg, 'mode', mode,
    'echeance', t, 'cycle', t, 'cle', v_cle, 'manquee', t_manque,
    'info', info, 'relance', rel, 'decision', dec, 'limite', lim,
    'informe_le', informe, 'relance_le', relance, 'lrar_le', lrar,
    'choix', e.decision, 'choix_le', e.decision_le, 'proposition_le', e.proposition_le, 'conge_le', e.conge_le, 'conge_mode', e.conge_mode,
    'etat', etat, 'action', act, 'action_libelle', act_lib, 'gravite', grav, 'blocages', blocages, 'options', options,
    'douze_ans', douze, 'alerte_derogatoire', alerte_derog,
    'effet_conge_au_plus_tot', case when mode = 'prolongation' then (date_trunc('quarter', j + interval '6 months') + interval '3 months' - interval '1 day')::date end,
    'triennale', case when typ = 'commercial' then (select min(pilotage.ajouter_mois(s, 36 * n) - 1) from generate_series(1, 30) n where pilotage.ajouter_mois(s, 36 * n) - 1 > j) end
  );
end $$;

create or replace function pilotage.obligation_etat(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare ob pilotage.baux_obligations; v_cle text; etapes jsonb; afaire jsonb; suivante jsonb; j date := current_date;
begin
  select * into ob from pilotage.baux_obligations where id = p_id;
  if not found then return null; end if;
  v_cle := 'o:' || ob.id || ':' || ob.prochaine;
  select coalesce(jsonb_agg(jsonb_build_object('ordre', c.ordre, 'date', ob.prochaine + c.jours, 'libelle', c.libelle, 'canal', c.canal, 'modele', c.modele,
           'fait_le', se.fait_le, 'du', (ob.prochaine + c.jours) <= j) order by c.jours, c.ordre), '[]'::jsonb)
    into etapes
  from pilotage.calendriers c left join lateral (
      select coalesce(se.fait_le, (select min(bl.maj_le) from pilotage.objets bl
                where c.canal = 'tache' and (c.libelle ilike 'appeler%' or c.libelle ilike '%refacturer%')
                  and bl.type = 'BillingLine' and bl.supprime_le is null and bl.data->>'leasing_contract_id' = ob.bail_id
                  and (bl.data->>'name') ilike any (case ob.nature when 'tsb' then array['%bureau%','%TSB%'] when 'surprime' then array['%surprime%'] else array['§'] end)
                  and coalesce((bl.data->>'start_date')::date, bl.maj_le::date) >= ob.prochaine - 120)) fait_le
      from (select 1) z left join pilotage.suivis_etapes se on se.cle = v_cle and se.etape = c.ordre::text) se on true
  where c.nature = ob.nature;
  select x into afaire from jsonb_array_elements(etapes) x where (x->>'du')::boolean and x->>'fait_le' is null order by (x->>'date')::date limit 1;
  select x into suivante from jsonb_array_elements(etapes) x where not (x->>'du')::boolean order by (x->>'date')::date limit 1;
  return jsonb_build_object('id', ob.id, 'nature', ob.nature, 'libelle', ob.libelle, 'periodicite_mois', ob.periodicite_mois,
    'prochaine', ob.prochaine, 'derniere_le', ob.derniere_le, 'actif', ob.actif, 'cle', v_cle,
    'etapes', etapes, 'a_faire', afaire, 'suivante', suivante,
    'en_retard', ob.actif and j > ob.prochaine + 30,
    'gravite', case when not ob.actif then 'normale' when j > ob.prochaine + 30 then 'critique' when afaire is not null and (afaire->>'canal') = 'lrar' then 'haute'
                    when afaire is not null then 'normale' else 'normale' end);
end $$;

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
        when 'tva' then detail := case when (o->>'vat_applicable')::boolean then 'TVA oui, taux ' || coalesce(o->>'vat_rate', '?') else 'Pas de TVA' end;
        when 'indice' then
          detail := coalesce(upper(idx->>'nature'), 'aucun') || coalesce(' ' || upper(idx->>'quarter') || ' ' || (idx->>'year') || ' = ' || (idx->>'value'), '')
                 || case when (o->>'indexation_enabled')::boolean then '' else ' (indexation désactivée)' end
                 || case when coalesce(o->'signing_quarter_revision_index'->>'nature', idx->>'nature') <> idx->>'nature'
                         then ' (valeur initiale informative en ' || upper(o->'signing_quarter_revision_index'->>'nature') || ', sans effet sur la révision)' else '' end;
          if v_portee = 'commercial' and coalesce(idx->>'nature', '') not in ('ilc','ilat','icc') and (o->>'indexation_enabled')::boolean then auto := 'anomalie'; detail := detail || ' : indice d''habitation sur un bail commercial'; end if;
          if v_portee = 'habitation' and coalesce(idx->>'nature', '') not in ('irl','irl_outre_mer') and (o->>'indexation_enabled')::boolean then auto := 'anomalie'; end if;
        when 'revision' then detail := 'Tous les ' || coalesce(o->>'revision_frequency_in_years', '?') || ' an(s), prochaine le ' || coalesce(to_char((o->>'next_revision_date')::date, 'DD/MM/YYYY'), '—');
        when 'dg' then
          detail := coalesce(dg::text, '—') || ' €' || case when loyer > 0 and dg is not null then ' (' || round(dg / loyer, 1) || ' fois le loyer appelé)' else '' end;
          if v_portee = 'habitation' and loyer > 0 and dg > loyer * (case when typ = 'meuble' then 2 else 1 end) then auto := 'anomalie'; detail := detail || ' : au-delà du plafond légal'; end if;
          if valeur_ia is not null and (valeur_ia->>'montant')::numeric = dg and auto is null then auto := 'ok'; end if;
        when 'charges' then detail := coalesce(round((o->>'charges_in_cents')::numeric / 100, 2)::text, '0') || ' € par appel';
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

create or replace function pilotage.suivi_detections() returns table (regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  with baux as (
    select b.id, b.reference, b.locataires, b.debut, pilotage.echeance_bail(b.id) ech
    from pilotage.v_baux b where b.statut in ('created','move_in','in_progress') and (b.fin is null or b.fin > current_date)
  ), lien as (select 'https://rivage.immo/leasing_contracts?leasing_contract_id=' l)
  select 'bail_controle_entree', 'LeasingContract', b.id, 'Bail ' || coalesce(b.reference,'') || ' : contrôle d''entrée à valider',
         coalesce((pilotage.controle_bail(b.id)->>'restant'), '?') || ' point(s) à traiter · ' || coalesce(b.locataires, ''), (select l from lien) || b.id
  from baux b left join pilotage.baux_fiche f on f.bail_id = b.id
  where f.go_le is null and ((b.ech->>'type') in ('commercial','derogatoire','professionnel') or b.debut >= (select valeur::date from pilotage.parametres where cle = 'controle_entree_depuis'))
  union all
  select case when b.ech->>'gravite' = 'critique' then 'bail_echeance_urgente' else 'bail_echeance' end, 'LeasingContract', b.id,
         'Bail ' || coalesce(b.reference,'') || ' : ' || (b.ech->>'action_libelle'),
         'Échéance le ' || to_char((b.ech->>'echeance')::date, 'DD/MM/YYYY') || coalesce(', date limite du congé le ' || to_char((b.ech->>'limite')::date, 'DD/MM/YYYY'), '') || ' · ' || coalesce(b.locataires, ''),
         (select l from lien) || b.id
  from baux b where b.ech->>'action' is not null
  union all
  select 'bail_derogatoire', 'LeasingContract', b.id, 'Bail ' || coalesce(b.reference,'') || ' : bail dérogatoire dépassé', b.ech->>'alerte_derogatoire', (select l from lien) || b.id
  from baux b where b.ech->>'alerte_derogatoire' is not null
  union all
  select 'bail_douze_ans', 'LeasingContract', b.id, 'Bail ' || coalesce(b.reference,'') || ' : 12 ans de durée le ' || to_char((b.ech->>'douze_ans')::date, 'DD/MM/YYYY'),
         'Au-delà, le loyer du bail renouvelé peut être déplafonné (L145-34) : à examiner avec le bailleur.', (select l from lien) || b.id
  from baux b where (b.ech->>'douze_ans')::date between current_date and current_date + 365 and b.ech->>'mode' = 'prolongation'
  union all
  select case when bool_or(e->>'gravite' = 'critique') then 'bail_suivi_retard' else 'bail_suivi' end, 'LeasingContract', o.bail_id,
         'Bail ' || coalesce(max(b.reference),'') || ' : ' || string_agg(coalesce(e->'a_faire'->>'libelle', 'en retard') || ' (' || (e->>'libelle') || ')', ' ; '),
         string_agg((e->>'libelle') || ' : échéance le ' || to_char((e->>'prochaine')::date, 'DD/MM/YYYY'), ' ; '), (select l from lien) || o.bail_id
  from pilotage.baux_obligations o join baux b on b.id = o.bail_id, lateral (select pilotage.obligation_etat(o.id) e) x
  where o.actif and (jsonb_typeof(e->'a_faire') = 'object' or (e->>'en_retard')::boolean)
  group by o.bail_id
  union all
  select 'bail_palier', 'LeasingContract', p.bail_id,
         'Bail ' || coalesce(b.reference,'') || ' : ' || case when p.debut > current_date then (case p.nature when 'franchise' then 'franchise' else 'palier' end) || ' de loyer le ' || to_char(p.debut, 'DD/MM/YYYY') || ', mettre à jour Rivage'
                                                   else 'loyer Rivage différent du palier en cours' end,
         'Loyer attendu dans Rivage : ' || coalesce(p.loyer_rivage::text, '—') || ' € ; loyer actuel dans Rivage : ' || coalesce(vb.loyer_hc::text, '—') || ' €', (select l from lien) || p.bail_id
  from pilotage.baux_paliers p join baux b on b.id = p.bail_id join pilotage.v_baux vb on vb.id = p.bail_id
  where (p.debut between current_date and current_date + 30 and not pilotage.palier_programme(p.id))
     or (p.debut <= current_date and not pilotage.palier_programme(p.id) and (p.fin is null or p.fin >= current_date) and p.loyer_rivage is not null and vb.loyer_hc is distinct from p.loyer_rivage
         and not exists (select 1 from pilotage.baux_paliers p2 where p2.bail_id = p.bail_id and p2.debut > p.debut and p2.debut <= current_date))
  union all
  select 'bail_acte_delai', 'LeasingContract', a.bail_id,
         'Bail ' || coalesce(b.reference,'') || ' : demande de renouvellement du ' || to_char(a.signifie_le, 'DD/MM/YYYY') || ' sans réponse enregistrée',
         'Le bailleur doit répondre avant le ' || to_char(pilotage.ajouter_mois(a.signifie_le, 3), 'DD/MM/YYYY') || ', sinon il est réputé accepter le principe du renouvellement (L145-10).',
         (select l from lien) || a.bail_id
  from pilotage.baux_actes a join baux b on b.id = a.bail_id
  where a.nature = 'demande_renouvellement' and a.auteur = 'preneur' and a.reponse_le is null and current_date <= pilotage.ajouter_mois(a.signifie_le, 3) + 15
$$;

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
    'rivage', (select jsonb_build_object('nature_lot', a.data->>'nature',
                 'chauffage', a.data->'equipment'->>'heating_method', 'type_chauffage', a.data->'equipment'->>'heating_type',
                 'eau_chaude', a.data->'equipment'->>'hot_water_method', 'type_eau_chaude', a.data->'equipment'->>'hot_water_type',
                 'entretien_chaudiere', b.data->>'last_boiler_maintenance_date',
                 'locataire_65', pilotage.locataire_65_rivage(p_bail, (pilotage.echeance_bail(p_bail)->>'echeance')::date))
               from pilotage.objets b left join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id'
               where b.type = 'LeasingContract' and b.id = p_bail),
    'paliers', coalesce((select jsonb_agg(to_jsonb(p) - 'par' || jsonb_build_object('programme_rivage', pilotage.palier_programme(p.id)) order by p.debut)
                         from pilotage.baux_paliers p where p.bail_id = p_bail), '[]'::jsonb),
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

revoke all on all functions in schema pilotage from public, anon, authenticated;
