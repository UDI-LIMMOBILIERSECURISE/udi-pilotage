-- 059 : circuit des dossiers en trois temps (Nicolas, 20/10/2026)
--   Commercial (complète) → Gestionnaire (contrôle et valide) → Direction (valide la rémunération).
--   1. Tout mandat ou bail arrivé dans Rivage après le départ du contrôle entre dans le circuit, même ancien.
--   2. Un dossier sans commercial apparaît chez tous les commerciaux, qui se l'attribuent (« Je le prends »).
--   3. La comptable voit les dossiers en cours comme la gestion, en lecture.
--   4. La direction valide la commission calculée de chaque dossier (vue récap), avec correction possible du montant.

-- Dossier arrivé dans Rivage après la date de départ du contrôle d'entrée
create or replace function pilotage.dossier_recu(p_type text, p_id text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce((select o.recu_le >= (select valeur::date from pilotage.parametres where cle = 'controle_entree_depuis')
                     from pilotage.objets o where o.type = p_type and o.id = p_id), false)
$$;

do $$
declare
  rempl jsonb := '[
    ["pilotage.controle_mandat(text)", "''soumis'', (o->>''start_date'')::date >= date ''2026-01-01'',", "''soumis'', ((o->>''start_date'')::date >= date ''2026-01-01'' or pilotage.dossier_recu(''ManagementContract'', p_mandat)),", 1],
    ["pilotage.ligne_bail(text)", "or coalesce(b.debut >= date ''2026-10-16'', false),", "or coalesce(b.debut >= date ''2026-10-16'', false) or pilotage.dossier_recu(''LeasingContract'', b.id),", 1],
    ["pilotage.bail_soumis(text)", "or coalesce(b.debut >= date ''2026-10-16'', false)", "or coalesce(b.debut >= date ''2026-10-16'', false) or pilotage.dossier_recu(''LeasingContract'', b.id)", 1],
    ["public.pilotage_mes_dossiers()", "gestion := r in (''direction'', ''superviseur'', ''gestionnaire'');", "gestion := r in (''direction'', ''superviseur'', ''gestionnaire'', ''comptable'');", 1],
    ["public.pilotage_mes_dossiers()", "where m.debut >= date ''2026-01-01'' and s.retire_le is null and s.valide_le is null", "where (m.debut >= date ''2026-01-01'' or pilotage.dossier_recu(''ManagementContract'', m.id)) and s.retire_le is null and s.valide_le is null", 1],
    ["public.pilotage_mes_dossiers()", "and (gestion or s.negociateur = moi) loop", "and (gestion or s.negociateur = moi or s.negociateur is null) loop", 1],
    ["public.pilotage_mes_dossiers()", "''commercial'', e->>''commercial_prenom'');", "''commercial'', e->>''commercial_prenom'', ''a_attribuer'', e->>''commercial'' is null);", 1],
    ["public.pilotage_mes_dossiers()", "and (gestion or (c.ligne->>''commercial'')::uuid = moi) loop", "and (gestion or (c.ligne->>''commercial'')::uuid = moi or c.ligne->>''commercial'' is null) loop", 1],
    ["public.pilotage_mes_dossiers()", "''commercial'', pilotage.prenom_membre((x.l->>''commercial'')::uuid), ''ligne'', x.l);", "''commercial'', pilotage.prenom_membre((x.l->>''commercial'')::uuid), ''a_attribuer'', x.l->>''commercial'' is null, ''ligne'', x.l);", 1],
    ["public.pilotage_mes_dossiers()", "return jsonb_build_object(''role'', r, ''gestion'', gestion, ''dossiers'', res);", "return jsonb_build_object(''role'', r, ''gestion'', gestion, ''lecture'', r = ''comptable'', ''dossiers'', res);", 1]
  ]';
  fns text[]; f text; def text; x jsonb; n int;
begin
  select array_agg(distinct e->>0) into fns from jsonb_array_elements(rempl) e;
  foreach f in array fns loop
    def := pg_get_functiondef(f::regprocedure);
    for x in select e from jsonb_array_elements(rempl) e where e->>0 = f loop
      n := (length(def) - length(replace(def, x->>1, ''))) / length(x->>1);
      if n <> (x->>3)::int then raise exception 'Code inattendu dans % : « % » trouvé % fois au lieu de %', f, x->>1, n, x->>3; end if;
      def := replace(def, x->>1, x->>2);
    end loop;
    execute def;
  end loop;
end $$;

-- « Je le prends » : un commercial (ou la direction) s'attribue un dossier qui n'a pas encore de commercial
create or replace function public.pilotage_dossier_prendre(p_objet text, p_id text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare actuel uuid;
begin
  if pilotage.mon_role() not in ('negociateur', 'direction', 'superviseur') then raise exception 'Réservé aux commerciaux'; end if;
  actuel := pilotage.commercial_dossier(p_objet, p_id);
  if actuel is not null then raise exception 'Ce dossier est déjà attribué à %', pilotage.prenom_membre(actuel); end if;
  if p_objet = 'mandat' then
    if not exists (select 1 from pilotage.objets where type = 'ManagementContract' and id = p_id and supprime_le is null) then raise exception 'Mandat inconnu'; end if;
    insert into pilotage.mandats_suivi (mandat_id, negociateur, maj_par, maj_le) values (p_id, auth.uid(), auth.uid(), now())
    on conflict (mandat_id) do update set negociateur = auth.uid(), maj_par = auth.uid(), maj_le = now() where pilotage.mandats_suivi.negociateur is null;
  elsif p_objet = 'bail' then
    if not exists (select 1 from pilotage.objets where type = 'LeasingContract' and id = p_id and supprime_le is null) then raise exception 'Bail inconnu'; end if;
    insert into pilotage.baux_suivi (bail_id, loue_par, maj_par, maj_le) values (p_id, auth.uid(), auth.uid(), now())
    on conflict (bail_id) do update set loue_par = auth.uid(), maj_par = auth.uid(), maj_le = now() where pilotage.baux_suivi.loue_par is null;
    update pilotage.baux_cache set ligne = jsonb_set(ligne, '{commercial}', to_jsonb(auth.uid()::text)) where bail_id = p_id;
  else raise exception 'Objet inconnu'; end if;
end $$;

-- Validation de la rémunération par la direction : une ligne par dossier, règle et bénéficiaire
create table if not exists pilotage.commissions_validations (
  objet text not null, regle text not null, beneficiaire uuid not null,
  montant numeric(12,2) not null, montant_calcule numeric(12,2), note text,
  valide_le timestamptz not null default now(), valide_par uuid,
  primary key (objet, regle, beneficiaire)
);
alter table pilotage.commissions_validations enable row level security;
revoke all on pilotage.commissions_validations from public, anon, authenticated;

-- Vue récap de la direction : dossiers validés par la gestion dont la commission est à valider
create or replace function public.pilotage_remu_a_valider() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare res jsonb;
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  with l as (select x from jsonb_array_elements(pilotage.lignes_commissions()) x where x->>'beneficiaire' is not null),
  a as (
    select l.x, l.x->>'objet' objet,
           case when l.x->>'type' = 'bail' then (select f.go_le from pilotage.baux_fiche f where f.bail_id = l.x->>'objet')
                else (select s.valide_le from pilotage.mandats_suivi s where s.mandat_id = l.x->>'objet') end gestion_le
    from l
    where not exists (select 1 from pilotage.commissions_validations v where v.objet = l.x->>'objet' and v.regle = l.x->>'regle'
                        and v.beneficiaire = (l.x->>'beneficiaire')::uuid)
  )
  select coalesce(jsonb_agg(d order by d->>'gestion_le'), '[]'::jsonb) into res from (
    select jsonb_build_object('objet', objet, 'type', min(x->>'type'),
             'titre', case when min(x->>'type') = 'bail' then 'Bail ' || coalesce(min(x->>'bail_ref'), '') || ' · ' || coalesce(min(x->>'locataires'), '')
                           else 'Mandat n°' || coalesce(min(x->>'mandat_ref'), '') end,
             'bailleur', min(x->>'bailleur'), 'gestion_le', min(gestion_le),
             'bail_a_valider', bool_or(x->>'type' = 'bail' and not (x->>'du')::boolean and (x->>'condition') like '%à valider%'),
             'total', sum((x->>'montant')::numeric),
             'lignes', jsonb_agg(jsonb_build_object('regle', x->>'regle', 'beneficiaire', x->>'beneficiaire', 'prenom', x->>'prenom', 'phase', x->>'phase_libelle',
                         'base', x->>'base_libelle', 'montant', (x->>'montant')::numeric, 'condition', x->>'condition', 'du', (x->>'du')::boolean) order by x->>'prenom', x->>'phase_libelle')) d
    from a
    -- Dû (étape atteinte), ou bail validé par la gestion qui n'attend plus que la validation de la direction
    where (x->>'du')::boolean or (x->>'type' = 'bail' and gestion_le is not null)
    group by objet
  ) z;
  return jsonb_build_object('dossiers', res,
    'valides_30j', (select count(distinct objet) from pilotage.commissions_validations where valide_le > now() - interval '30 days'));
end $$;

-- Valider (ou annuler) la rémunération d'un dossier. p_lignes : [{regle, beneficiaire, montant, note}] ; un montant différent du calcul exige une note.
create or replace function public.pilotage_remu_valider(p_objet text, p_lignes jsonb, p_annuler boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare x jsonb; calc numeric; typ text;
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Validation réservée à la direction'; end if;
  if p_annuler then delete from pilotage.commissions_validations where objet = p_objet; return; end if;
  select min(l->>'type') into typ from jsonb_array_elements(pilotage.lignes_commissions()) l where l->>'objet' = p_objet;
  if typ is null then raise exception 'Dossier sans commission calculée'; end if;
  -- Bail : la validation de la direction rend aussi la commission « due » (comme la validation dans l'onglet Commissions)
  if typ = 'bail' then
    insert into pilotage.baux_suivi (bail_id, valide_le, valide_par, maj_par, maj_le) values (p_objet, current_date, auth.uid(), auth.uid(), now())
    on conflict (bail_id) do update set valide_le = coalesce(pilotage.baux_suivi.valide_le, current_date),
      valide_par = coalesce(pilotage.baux_suivi.valide_par, auth.uid()), maj_par = auth.uid(), maj_le = now();
  end if;
  for x in select * from jsonb_array_elements(coalesce(p_lignes, '[]'::jsonb)) loop
    select (l->>'montant')::numeric into calc from jsonb_array_elements(pilotage.lignes_commissions()) l
     where l->>'objet' = p_objet and l->>'regle' = x->>'regle' and l->>'beneficiaire' = x->>'beneficiaire';
    if calc is null then raise exception 'Ligne de commission introuvable (%)', x->>'regle'; end if;
    if (x->>'montant')::numeric is distinct from calc and nullif(trim(coalesce(x->>'note', '')), '') is null then
      raise exception 'Montant corrigé (% € au lieu de % €) : indiquer la raison', x->>'montant', calc;
    end if;
    insert into pilotage.commissions_validations (objet, regle, beneficiaire, montant, montant_calcule, note, valide_par)
    values (p_objet, x->>'regle', (x->>'beneficiaire')::uuid, coalesce((x->>'montant')::numeric, calc), calc, nullif(trim(coalesce(x->>'note', '')), ''), auth.uid())
    on conflict (objet, regle, beneficiaire) do update set montant = excluded.montant, montant_calcule = excluded.montant_calcule, note = excluded.note,
      valide_le = now(), valide_par = auth.uid();
  end loop;
end $$;

revoke all on function public.pilotage_dossier_prendre(text, text), public.pilotage_remu_a_valider(), public.pilotage_remu_valider(text, jsonb, boolean) from public, anon;
grant execute on function public.pilotage_dossier_prendre(text, text), public.pilotage_remu_a_valider(), public.pilotage_remu_valider(text, jsonb, boolean) to authenticated;

-- Recalcul immédiat du cache des baux (le bail 33 entre dans le circuit)
select pilotage.rafraichir_baux('0 minutes');
