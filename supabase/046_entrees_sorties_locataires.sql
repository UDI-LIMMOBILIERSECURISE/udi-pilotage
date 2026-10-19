-- 046 : dates d'entrée et de sortie des locataires et des garants (champs entry_date / exit_date ajoutés par Rivage le 19/10)
-- 1. Dépôt de garantie : le délai de restitution (1 mois si l'état des lieux de sortie est conforme, 2 mois sinon) part de la
--    sortie réelle du dernier locataire quand Rivage la donne, et non plus de la date de fin du bail.
-- 2. Ma journée : départ d'un colocataire alors que le bail continue ; fin d'engagement d'un garant ; date de sortie d'un
--    locataire postérieure à la fin du bail (incohérence à corriger dans Rivage).
-- Les diagnostics du lot (liste « diagnostics ») seront traités dans un script suivant, quand des diagnostics saisis dans
-- Rivage permettront de vérifier leur forme exacte (le compte de test n'en contient aucun au 19/10).

-- ========== Sortie des locataires d'un bail ==========
create or replace function pilotage.sortie_locataires(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object(
    'nb', count(*),
    'sortis', count(*) filter (where s <= current_date),
    'annonces', count(*) filter (where s > current_date),
    'tous_sortis', count(*) > 0 and count(*) filter (where s is null) = 0,
    'derniere_sortie', max(s) filter (where s is not null),
    'locataires', coalesce(jsonb_agg(jsonb_build_object('nom', nom, 'entree', e, 'sortie', s) order by e nulls last), '[]'::jsonb))
  from (select coalesce(nullif(trim(t->>'company_name'), ''), trim(concat_ws(' ', t->>'last_name', t->>'first_name'))) nom,
               nullif(t->>'entry_date', '')::date e, nullif(t->>'exit_date', '')::date s
        from pilotage.objets b, jsonb_array_elements(coalesce(b.data->'tenants', '[]'::jsonb)) t
        where b.type = 'LeasingContract' and b.id = p_bail) x
$$;

-- Date de sortie réelle d'un bail : dernière sortie quand tous les locataires sont sortis (sinon null)
create or replace function pilotage.date_sortie_reelle(p_bail text) returns date
language sql stable security definer set search_path = pilotage, public as $$
  select case when (x->>'tous_sortis')::boolean and (x->>'derniere_sortie')::date <= current_date then (x->>'derniere_sortie')::date end
  from (select pilotage.sortie_locataires(p_bail) x) y
$$;

-- ========== Dépôt de garantie : délai à partir de la sortie réelle ==========
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.pilotage_dg()'::regprocedure);
  if position('sortie_locataires' in d) = 0 then
    n := replace(d, '''limite_1_mois'', (b.fin + interval ''1 month'')::date, ''limite_2_mois'', (b.fin + interval ''2 months'')::date,',
      '''limite_1_mois'', (coalesce(pilotage.date_sortie_reelle(b.id), b.fin) + interval ''1 month'')::date,
        ''limite_2_mois'', (coalesce(pilotage.date_sortie_reelle(b.id), b.fin) + interval ''2 months'')::date,
        ''sortie_reelle'', pilotage.date_sortie_reelle(b.id), ''sortie_locataires'', pilotage.sortie_locataires(b.id),');
    if n = d then raise exception '046 : calcul des délais introuvable dans pilotage_dg'; end if;
    execute n;
  end if;
end $$;

-- ========== Détections pour Ma journée ==========
create or replace function pilotage.suivi_detections_sorties() returns table (regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  -- Départ d'un colocataire (sortie passée ou annoncée sous 30 jours) alors qu'au moins un locataire reste dans les lieux
  select 'colocataire_sorti', 'LeasingContract', b.id,
         'Départ d''un colocataire : ' || l.nom || ' le ' || to_char(l.s, 'DD/MM/YYYY'),
         'Le bail continue avec ' || r.restants || ' autre(s) locataire(s). Prévoir l''avenant ou l''arrivée d''un remplaçant. '
           || 'Bail d''habitation : la solidarité du sortant cesse à l''arrivée d''un nouveau colocataire au bail, et au plus tard 6 mois après la date d''effet de son congé (loi du 6 juillet 1989, art. 8-1).',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
  from pilotage.objets b
  cross join lateral (select coalesce(nullif(trim(t->>'company_name'), ''), trim(concat_ws(' ', t->>'last_name', t->>'first_name'))) nom, nullif(t->>'exit_date', '')::date s
                      from jsonb_array_elements(coalesce(b.data->'tenants', '[]'::jsonb)) t) l
  cross join lateral (select count(*) restants from jsonb_array_elements(coalesce(b.data->'tenants', '[]'::jsonb)) t where nullif(t->>'exit_date', '') is null) r
  where b.type = 'LeasingContract' and b.supprime_le is null and b.data->>'status' in ('move_in', 'in_progress')
    and l.s is not null and l.s <= current_date + 30 and r.restants > 0
  union all
  -- Fin d'engagement d'un garant alors que le bail continue
  select 'garant_sorti', 'LeasingContract', b.id,
         'Fin d''engagement d''un garant le ' || to_char(nullif(g->>'exit_date', '')::date, 'DD/MM/YYYY') || ' : ' || coalesce((select v.locataires from pilotage.v_baux v where v.id = b.id), b.id),
         'Le bail continue sans ce garant : vérifier la garantie restante (autre garant, GLI) et, si besoin, en demander une nouvelle.',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
  from pilotage.objets b, jsonb_array_elements(coalesce(b.data->'guarantors', '[]'::jsonb)) g
  where b.type = 'LeasingContract' and b.supprime_le is null and b.data->>'status' in ('move_in', 'in_progress')
    and nullif(g->>'exit_date', '')::date <= current_date
  union all
  -- Incohérence : date de sortie d'un locataire postérieure à la fin du bail
  select 'sortie_incoherente', 'LeasingContract', b.id,
         'Date de sortie après la fin du bail : ' || l.nom,
         'Sortie le ' || to_char(l.s, 'DD/MM/YYYY') || ' pour un bail terminé le ' || to_char((b.data->>'end_date')::date, 'DD/MM/YYYY') || ' : à corriger dans Rivage (fiche du bail, locataires).',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
  from pilotage.objets b
  cross join lateral (select coalesce(nullif(trim(t->>'company_name'), ''), trim(concat_ws(' ', t->>'last_name', t->>'first_name'))) nom, nullif(t->>'exit_date', '')::date s
                      from jsonb_array_elements(coalesce(b.data->'tenants', '[]'::jsonb)) t) l
  where b.type = 'LeasingContract' and b.supprime_le is null and nullif(b.data->>'end_date', '') is not null
    and b.data->>'status' in ('move_out', 'closed') and l.s > (b.data->>'end_date')::date
$$;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication) values
 ('colocataire_sorti', 'Départ d''un colocataire, bail en cours', 'Baux habitation', 'haute', 'tache', true,
  'Un locataire quitte le bail (date de sortie dans Rivage) alors que d''autres restent : avenant ou remplaçant, et suivi de la solidarité du sortant.'),
 ('garant_sorti', 'Fin d''engagement d''un garant', 'baux', 'haute', 'tache', true,
  'Un garant n''est plus engagé (date de sortie dans Rivage) alors que le bail continue : vérifier la garantie restante.'),
 ('sortie_incoherente', 'Date de sortie après la fin du bail', 'baux', 'normale', 'controle', true,
  'Un locataire a une date de sortie postérieure à la fin du bail : saisie à corriger dans Rivage.')
on conflict (cle) do update set libelle = excluded.libelle, domaine = excluded.domaine, gravite = excluded.gravite, categorie = excluded.categorie, explication = excluded.explication;

do $$
declare def text;
begin
  def := pg_get_functiondef('pilotage.suivi_detections'::regproc);
  if position('suivi_detections_sorties' in def) = 0 then
    execute regexp_replace(def, '\s*\$function\$\s*$', E'\n  union all\n  select * from pilotage.suivi_detections_sorties()\n$function$\n');
  end if;
end $$;

revoke all on function pilotage.sortie_locataires(text), pilotage.date_sortie_reelle(text), pilotage.suivi_detections_sorties() from public, anon, authenticated;

-- Contrôle : détections du compte de test (au 19/10 : un bail terminé avec une sortie au 13/03/2027 doit apparaître en incohérence)
select regle, titre from pilotage.suivi_detections_sorties();
