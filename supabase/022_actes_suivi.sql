-- 022 : clauses et actes déduits du suivi plutôt que demandés (décision de Nicolas, 16/10/2026).
--   Questions supprimées du contrôle d'entrée : date d'origine du bail (Rivage a les dates du bail en vigueur), situation
--   (calculée par l'échéance : en cours ou tacite prolongation) et actes en cours (enregistrés au fil des actions).
--   Congé : après la décision du bailleur, 10 jours sans alerte, puis relance tant que l'acte n'est pas enregistré ou déposé
--   dans Rivage ; l'enregistrement du congé crée l'acte dans « Actes et notifications ».
-- Remplace pilotage.echeance_bail (018) et public.pilotage_echeance_decision (016).

delete from pilotage.baux_reponses where cle in ('c_cl_origine', 'c_cl_situation', 'c_cl_actes');
delete from pilotage.controle_questions where cle in ('c_cl_origine', 'c_cl_situation', 'c_cl_actes');

create or replace function pilotage.echeance_bail(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  o jsonb; lot record; f pilotage.baux_fiche; e pilotage.baux_echeance;
  typ text; sugg text; s date; d integer; r integer; k integer := 0; t date; t_manque date; mode text := 'terme';
  cal interval[]; info date; rel date; dec date; lim date; j date := current_date;
  v_cle text; informe date; relance date; lrar date; vu date;
  act text; act_lib text; v65 boolean; r65 jsonb; grav text := 'normale'; etat text; blocages jsonb := '[]'::jsonb; options jsonb; douze date; alerte_derog text; depot date; relance_conge date;
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
    -- 022 : après la décision de congé, l'acte est en cours chez le commissaire de justice (ou en préparation) :
    -- pas d'alerte pendant 10 jours ; ensuite relance tant que l'acte n'est ni enregistré ni déposé dans Rivage.
    -- Un document dont le libellé contient « congé », déposé dans Rivage sur ce bail ou ce lot après la décision, est repéré.
    if e.conge_le is null then
      select min(u.maj_le::date) into depot from pilotage.objets u
       where u.type = 'Upload' and u.supprime_le is null and (u.data->>'label') ilike any (array['%congé%', '%conge%'])
         and u.maj_le >= coalesce(e.decision_le, '-infinity'::timestamptz)
         and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr where rr->>'id' in (p_bail, o->>'asset_id'));
      relance_conge := (e.decision_le::date + 10);
    end if;
    if e.conge_le is null and depot is not null then
      act := 'enregistrer_conge'; act_lib := 'Congé déposé dans Rivage le ' || to_char(depot, 'DD/MM/YYYY') || ' : indiquer la date de délivrance et le mode';
      etat := 'conge_depose'; grav := case when lim is not null and lim - j <= 30 then 'haute' else 'normale' end;
    elsif e.conge_le is null and j < relance_conge and (lim is null or lim - j > 30) then
      etat := 'conge_en_cours';
    elsif e.conge_le is null then
      if lim is null or j <= lim then act := 'delivrer_conge';
        act_lib := 'Relance : congé décidé le ' || to_char(e.decision_le, 'DD/MM/YYYY') || ', acte toujours pas enregistré. '
          || case when typ in ('commercial','derogatoire') then 'Faire délivrer l''acte par commissaire de justice' else 'Délivrer le congé (LRAR, commissaire de justice ou remise contre émargement)' end
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
    'choix', e.decision, 'choix_le', e.decision_le, 'relance_conge', relance_conge, 'conge_depose_le', depot, 'proposition_le', e.proposition_le, 'conge_le', e.conge_le, 'conge_mode', e.conge_mode,
    'etat', etat, 'action', act, 'action_libelle', act_lib, 'gravite', grav, 'blocages', blocages, 'options', options,
    'douze_ans', douze, 'alerte_derogatoire', alerte_derog,
    'effet_conge_au_plus_tot', case when mode = 'prolongation' then (date_trunc('quarter', j + interval '6 months') + interval '3 months' - interval '1 day')::date end,
    'triennale', case when typ = 'commercial' then (select min(pilotage.ajouter_mois(s, 36 * n) - 1) from generate_series(1, 30) n where pilotage.ajouter_mois(s, 36 * n) - 1 > j) end
  );
end $$;

revoke all on all functions in schema pilotage from public, anon, authenticated;

create or replace function public.pilotage_echeance_decision(p_bail text, p_decision text, p_proposition date, p_conge date, p_conge_mode text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare ech jsonb; t date;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  ech := pilotage.echeance_bail(p_bail);
  t := (ech->>'cycle')::date;
  if t is null then raise exception 'Échéance non calculable : complétez la fiche du bail'; end if;
  if p_decision is not null and not (ech->'options') ? p_decision then raise exception 'Choix non prévu pour ce type de bail'; end if;
  if p_conge is not null and jsonb_array_length(ech->'blocages') > 0 and (ech->'blocages'->>0) like 'Vérifier%' then raise exception '%', ech->'blocages'->>0; end if;
  insert into pilotage.baux_echeance (bail_id, cycle) values (p_bail, t) on conflict do nothing;
  update pilotage.baux_echeance set
    decision = case when p_decision = '' then null else coalesce(p_decision, decision) end,
    decision_le = case when p_decision is not null then now() else decision_le end, decision_par = case when p_decision is not null then auth.uid() else decision_par end,
    proposition_le = coalesce(p_proposition, proposition_le), conge_le = coalesce(p_conge, conge_le), conge_mode = coalesce(p_conge_mode, conge_mode)
  where bail_id = p_bail and cycle = t;
  -- Le congé délivré devient un acte du bail (une seule fois par date).
  if p_conge is not null and not exists (select 1 from pilotage.baux_actes where bail_id = p_bail and nature in ('conge', 'refus_renouvellement') and auteur = 'bailleur' and signifie_le = p_conge) then
    insert into pilotage.baux_actes (bail_id, nature, auteur, signifie_le, forme, effet_le, commentaire, par)
    values (p_bail, case when ech->>'choix' in ('refus_indemnite', 'refus_motif_grave') then 'refus_renouvellement' else 'conge' end, 'bailleur', p_conge,
            case p_conge_mode when 'commissaire' then 'acte' when 'lrar' then 'lrar' when 'remise' then 'remise' else 'autre' end,
            case when ech->>'mode' = 'prolongation' then (ech->>'effet_conge_au_plus_tot')::date else t end, 'Enregistré depuis l''échéance du bail (' || coalesce(ech->>'choix', '') || ')', auth.uid());
  end if;
end $$;
