-- 120 — Les 14 types de contrat de Rivage dans le pilotage, chacun avec son régime (Nicolas, 02/11/2026).
-- Liste relevée dans Rivage (formulaire « Modifier la location », 02/11) : unfurnished, furnished, student, mobility,
-- secondary_residence, parking, seasonal, civil_code, commercial, professionnal, short_term, rural, law_48, other.
-- Règles vérifiées sur Légifrance (texte en vigueur au 01-02/11/2026) :
--   - vide : 3 ans (6 si bailleur personne morale), reconduction ; congé du bailleur 6 mois (loi 89-462 art. 10 et 15-I) ;
--     dépôt 1 mois de loyer hors charges, interdit si loyer payable d'avance pour plus de 2 mois (art. 22).
--   - meublé : 1 an, reconduction 1 an ; congé du bailleur 3 mois (art. 25-7, 25-8) ; dépôt 2 mois (art. 25-6, non relu : page
--     Légifrance indisponible le 02/11, plafond déjà appliqué par le pilotage).
--   - étudiant : meublé de 9 mois, sans reconduction (art. 25-7) ; bail étudiant d'un an ou plus : régime du meublé (calendrier,
--     reconduction, décisions).
--   - mobilité : 1 à 10 mois, ni renouvellement ni reconduction (art. 25-14, version du 28/11/2025) ; aucun dépôt (art. 25-17).
--   - commercial : 9 ans au moins, triennale ; congé du bailleur 6 mois par acte extrajudiciaire, au dernier jour du trimestre
--     civil en tacite prolongation ; déplafonnement au-delà de 12 ans (C. com. L145-4, L145-9, L145-34) : inchangé.
--   - dérogatoire : 3 ans au plus, nouveau bail commercial si le preneur est laissé en possession plus d'un mois après l'échéance
--     (C. com. L145-5) : inchangé.
--   - professionnel : 6 ans au moins, reconduction pour la même durée ; refus de renouvellement par chaque partie avec un préavis
--     de 6 mois, par LRAR ou commissaire de justice (loi 86-1290 art. 57 A). Avant : calendrier du bail vide, remise en main
--     propre proposée à tort.
--   - saisonnier : 90 jours consécutifs au plus, non renouvelable (loi 70-9 art. 1-1, 2°) : fin automatique.
--   - loi 1948 : maintien dans les lieux de plein droit des occupants de bonne foi (loi 48-1360 art. 4) : pas d'échéance.
--   - rural : 9 ans, congé 18 mois avant l'échéance par acte extrajudiciaire (C. rural L411-5, L411-47) : NON RELU, les pages
--     Légifrance du code rural n'ont pas pu être ouvertes le 02/11 ; à vérifier avant le premier bail rural (aucun au 02/11).
--   - résidence secondaire, code civil, parking, autre : régime du contrat (code civil) : échéance signalée 3 mois avant,
--     préavis à vérifier dans le bail.
-- Dépôt de garantie : plafond par type (vide 1 mois, meublé et étudiant 2 mois, mobilité aucun, autres types libres) ; le contrôle
-- automatique prend désormais le type de la fiche s'il est saisi (avant : seulement le type Rivage).
-- Portée du contrôle d'entrée : habitation pour vide, meublé, étudiant, mobilité, mixte, résidence secondaire, saisonnier, loi 1948 ;
-- commercial pour les autres (inchangé pour commercial, dérogatoire, professionnel, parking, code civil, autre).
-- Au 02/11, baux en cours : 335 vide, 103 meublé, 24 commercial, 6 dérogatoires, 9 code civil, 2 parking ; les 11 derniers passent
-- de « autre » à « code civil » et « parking », même régime. 6 baux « commercial » de 12 et 36 mois restent dérogatoires (durée).
-- Modifications ciblées et contrôlées de echeance_bail, controle_bail et executer_controles. Un seul bloc.

begin;

-- 1. Types acceptés dans la fiche du bail
alter table pilotage.baux_fiche drop constraint if exists baux_fiche_type_bail_check;
alter table pilotage.baux_fiche add constraint baux_fiche_type_bail_check check (type_bail = any (array[
  'vide', 'meuble', 'etudiant', 'mobilite', 'mixte', 'residence_secondaire', 'saisonnier', 'loi_1948',
  'commercial', 'derogatoire', 'professionnel', 'rural', 'code_civil', 'parking', 'autre']));

-- 2. Traduction de tous les types de Rivage
create or replace function pilotage.type_bail_rivage(p_bail text) returns text
language sql stable security definer set search_path = pilotage, public as $function$
  select case coalesce(o.data->'edit_attributes'->>'nature', (select s.data->'lease'->'data'->'attributes'->>'nature' from pilotage.baux_situation s where s.bail_id = p_bail))
    when 'unfurnished' then 'vide'
    when 'furnished' then 'meuble'
    when 'student' then 'etudiant'
    when 'mobility' then 'mobilite'
    when 'secondary_residence' then 'residence_secondaire'
    when 'seasonal' then 'saisonnier'
    when 'law_48' then 'loi_1948'
    -- commercial de 36 mois ou moins : dérogatoire (6 baux au 02/11, à recoder « Bail dérogatoire » dans Rivage)
    when 'commercial' then case when nullif(o.data->>'duration_in_months', '')::int between 1 and 36 then 'derogatoire' else 'commercial' end
    when 'short_term' then 'derogatoire'
    when 'professionnal' then 'professionnel'
    when 'professional' then 'professionnel'
    when 'rural' then 'rural'
    when 'civil_code' then 'code_civil'
    when 'parking' then 'parking'
    when 'other' then 'autre' end
  from pilotage.objets o where o.type = 'LeasingContract' and o.id = p_bail
$function$;

-- 3. Portée du contrôle d'entrée (jeu de questions)
create or replace function pilotage.portee_bail(p_type text) returns text
language sql immutable as $function$
  select case when p_type in ('vide', 'meuble', 'etudiant', 'mobilite', 'mixte', 'residence_secondaire', 'saisonnier', 'loi_1948') then 'habitation'
              when p_type is null then null else 'commercial' end
$function$;

-- 4. Plafond du dépôt de garantie en mois de loyer hors charges (null : libre)
create or replace function pilotage.plafond_dg_mois(p_type text) returns numeric
language sql immutable as $function$
  select case p_type when 'vide' then 1 when 'mixte' then 1 when 'meuble' then 2 when 'etudiant' then 2 when 'mobilite' then 0 end::numeric
$function$;

do $do$
declare d text; n text;
begin
  -- 5. Contrôle d'entrée : plafond du dépôt selon le type
  d := pg_get_functiondef('pilotage.controle_bail'::regproc);
  if position('120 : plafond' in d) = 0 then
    n := $r$          if v_portee = 'habitation' and loyer > 0 and dg > loyer * (case when typ = 'meuble' then 2 else 1 end) then auto := 'anomalie'; detail := detail || ' : au-delà du plafond légal'; end if;$r$;
    if position(n in d) = 0 then raise exception '120 : ligne du plafond du dépôt introuvable dans controle_bail'; end if;
    d := replace(d, n, $r$          -- 120 : plafond selon le type (vide 1 mois, meublé et étudiant 2 mois, mobilité aucun dépôt, autres libres)
          if loyer > 0 and pilotage.plafond_dg_mois(typ) is not null and dg > loyer * pilotage.plafond_dg_mois(typ) then auto := 'anomalie';
            detail := detail || case when pilotage.plafond_dg_mois(typ) = 0 then ' : aucun dépôt ne peut être demandé pour ce bail' else ' : au-delà du plafond légal' end; end if;$r$);
    execute d;
  end if;

  -- 6. Contrôle automatique « dg_plafond » : type de la fiche d'abord, plafond par type
  d := pg_get_functiondef('pilotage.executer_controles'::regproc);
  if position('120 : plafond' in d) = 0 then
    n := $r$    and depot_garantie > loyer_hc * (case pilotage.type_bail_rivage(id) when 'meuble' then 2 when 'etudiant' then 2 when 'mobilite' then 0 else 1 end)$r$;
    if position(n in d) = 0 then raise exception '120 : condition dg_plafond introuvable dans executer_controles'; end if;
    d := replace(d, n, $r$    -- 120 : plafond selon le type (fiche, sinon Rivage) ; types sans plafond légal exclus
    and pilotage.plafond_dg_mois(coalesce((select bf.type_bail from pilotage.baux_fiche bf where bf.bail_id = id), pilotage.type_bail_rivage(id))) is not null
    and depot_garantie > loyer_hc * pilotage.plafond_dg_mois(coalesce((select bf.type_bail from pilotage.baux_fiche bf where bf.bail_id = id), pilotage.type_bail_rivage(id)))$r$);
    execute d;
  end if;

  -- 7. Échéance du bail : régime de chaque type
  d := pg_get_functiondef('pilotage.echeance_bail'::regproc);
  if position('120 : régimes' in d) = 0 then
    -- calendrier (information, relance, décision, date limite du congé avant l'échéance)
    n := $r$    when typ = 'autre' then array['3 months','3 months','3 months','1 month']::interval[]$r$;
    if position(n in d) = 0 then raise exception '120 : calendrier « autre » introuvable dans echeance_bail'; end if;
    d := replace(d, n, $r$    -- 120 : régimes des types Rivage
    when typ in ('autre','code_civil','parking','residence_secondaire','loi_1948') then array['3 months','3 months','3 months','1 month']::interval[]
    when typ = 'saisonnier' then array['1 month','1 month','1 month','0 days']::interval[]
    when typ = 'rural' then array['24 months','22 months','20 months','18 months']::interval[]$r$);
    -- étudiant de plus de 9 mois : calendrier du meublé
    n := $r$    when typ = 'meuble' then array[$r$;
    if position(n in d) = 0 then raise exception '120 : calendrier du meublé introuvable dans echeance_bail'; end if;
    d := replace(d, n, $r$    when typ = 'meuble' or (typ = 'etudiant' and coalesce(d, 0) >= 12) then array[$r$);
    -- fin automatique : mobilité, saisonnier, étudiant de 9 mois (au-delà : régime du meublé)
    n := $r$  elsif typ in ('derogatoire','etudiant','mobilite') then$r$;
    if position(n in d) = 0 then raise exception '120 : branche de fin automatique introuvable dans echeance_bail'; end if;
    d := replace(d, n, $r$  elsif typ in ('derogatoire','mobilite','saisonnier') or (typ = 'etudiant' and coalesce(d, 0) < 12) then$r$);
    n := $r$    r := coalesce(nullif(o->>'tacit_renewal_duration_years', '')::integer * 12, case when typ = 'meuble' then 12 else d end);$r$;
    if position(n in d) = 0 then raise exception '120 : durée de reconduction introuvable dans echeance_bail'; end if;
    d := replace(d, n, $r$    r := coalesce(nullif(o->>'tacit_renewal_duration_years', '')::integer * 12, case when typ in ('meuble','etudiant') then 12 else d end);$r$);
    -- contrat sans régime légal propre : information ; loi 1948 : maintien dans les lieux, pas d'échéance
    n := $r$    if typ = 'autre' then mode := 'info'; t_manque := null; end if;$r$;
    if position(n in d) = 0 then raise exception '120 : mode info introuvable dans echeance_bail'; end if;
    d := replace(d, n, $r$    if typ in ('autre','code_civil','parking','residence_secondaire') then mode := 'info'; t_manque := null; end if;
    if typ = 'loi_1948' then mode := 'maintien'; t_manque := null; end if;$r$);
    n := $r$  if mode in ('fin_auto','info') then$r$;
    if position(n in d) = 0 then raise exception '120 : branche fin_auto/info introuvable dans echeance_bail'; end if;
    d := replace(d, n, $r$  if mode = 'maintien' then etat := 'maintien';
  elsif mode in ('fin_auto','info') then$r$);
    -- décisions proposées
    n := $r$    when typ in ('etudiant','mobilite','autre') then '[]'$r$;
    if position(n in d) = 0 then raise exception '120 : options introuvables dans echeance_bail'; end if;
    d := replace(d, n, $r$    when typ = 'etudiant' and coalesce(d, 0) >= 12 then '["reconduire","conge_reprise","conge_vente","conge_motif"]'
    when typ in ('etudiant','mobilite','autre','saisonnier','code_civil','parking','residence_secondaire','loi_1948') then '[]'$r$);
    -- forme du congé
    n := $r$          || case when typ in ('commercial','derogatoire') then 'Faire délivrer l''acte par commissaire de justice' else 'Délivrer le congé (LRAR, commissaire de justice ou remise contre émargement)' end$r$;
    if position(n in d) = 0 then raise exception '120 : forme du congé introuvable dans echeance_bail'; end if;
    d := replace(d, n, $r$          || case when typ in ('commercial','derogatoire','rural') then 'Faire délivrer l''acte par commissaire de justice'
                  when typ = 'professionnel' then 'Notifier le refus de renouvellement par LRAR ou commissaire de justice'
                  else 'Délivrer le congé (LRAR, commissaire de justice ou remise contre émargement)' end$r$);
    d := replace(d, $r$  cal := case$r$, $r$  -- 120 : régimes des 14 types Rivage (voir le script 120)
  cal := case$r$);
    execute d;
  end if;
end $do$;

select pilotage.executer_controles();

commit;

-- Vérification : script passé (vrai, vrai, vrai) et répartition des types des baux en cours
select position('120 : régimes' in pg_get_functiondef('pilotage.echeance_bail'::regproc)) > 0 as echeance_120,
       position('120 : plafond' in pg_get_functiondef('pilotage.controle_bail'::regproc)) > 0 as controle_120,
       position('120 : plafond' in pg_get_functiondef('pilotage.executer_controles'::regproc)) > 0 as alertes_120,
       (select jsonb_object_agg(t, n) from (select coalesce(pilotage.type_bail_rivage(id), '(aucun)') t, count(*) n from pilotage.v_baux
          where statut in ('created', 'move_in', 'in_progress', 'move_out') group by 1) x) as types_en_cours;
