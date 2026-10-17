-- 039 : chronologie mensuelle des impayés (process décrit par la gestionnaire comptable, validé par Nicolas le 17/10/2026). Après 038.
--   1. Organisme et procédure séparés : l'ancien champ « garantie » (repris de Monday) mélangeait les deux (« GLI ZELOK », « AVOCAT »,
--      « CDT VIA HUISSIER », « Fait »). Nouveau champ « organisme » ; la procédure reste dans « procédure ». L'ancien champ est conservé.
--   2. Statut d'impayé de Rivage (cycle : ouvert, relancé, mis en demeure, déclaré à la GLI, contentieux, clos) relu chaque jour pour
--      les baux qui ont une dette, et affiché tel quel : le pilotage ne refait pas ce suivi.
--   3. Déclarations Zelok : du 16 au 19 de chaque mois (le 19 inclus, Zelok refuse les dossiers au-delà), la liste des impayés à
--      déclarer sort dans les obligations ; alerte critique les 18 et 19. Pour chaque dossier, la liste des pièces est préparée :
--      mandat et bail (dans Rivage), extrait de compte (généré à la date du jour), preuve d'encaissement du dépôt de garantie
--      (compte 1651 du lot), RIB de l'agence (toujours le même).
--   4. Actualisation mensuelle : une tâche par organisme (Zelok, Mila, Smart Garant, Garantme, Visale, avocats), avec ses dossiers ouverts.
--   5. Règlement d'un locataire sur un dossier déclaré : tâche « prévenir l'organisme et lui envoyer l'extrait » ; si une indemnisation
--      a déjà été reçue, le montant à reverser est à calculer (solde du compte d'indemnisation GLI du bail affiché, à vérifier).
--   6. Relances d'impayés : celles de Rivage sont gardées, la relance automatique d'UDIGESTION est coupée (doublon).

-- ========== 1. Organisme ==========
alter table pilotage.impayes add column if not exists organisme text check (organisme in ('zelok', 'mila', 'smartgarant', 'garantme', 'visale', 'aucun'));
alter table pilotage.impayes add column if not exists reglement_signale_le date;
update pilotage.impayes set organisme = case
    when upper(coalesce(garantie, '') || ' ' || coalesce(groupe, '')) like '%ZELOK%' then 'zelok'
    when upper(coalesce(garantie, '') || ' ' || coalesce(groupe, '')) like '%MILA%' then 'mila'
    when upper(coalesce(garantie, '') || ' ' || coalesce(groupe, '')) like '%SMART%' then 'smartgarant'
    when upper(coalesce(garantie, '') || ' ' || coalesce(groupe, '')) like '%GARANTME%' then 'garantme'
    when upper(coalesce(garantie, '') || ' ' || coalesce(groupe, '')) like '%VISALE%' then 'visale'
    when upper(coalesce(garantie, '')) like '%PAS DE GARANTIE%' then 'aucun' end
  where organisme is null;
-- Procédures rangées dans l'ancien champ « garantie »
update pilotage.impayes set procedure = case when upper(garantie) like '%HUISSIER%' then 'Commandement de payer (commissaire de justice)'
                                             when upper(garantie) like '%AVOCAT%' then 'Confié à l''avocat' end
  where procedure is null and upper(coalesce(garantie, '')) similar to '%(HUISSIER|AVOCAT)%';

-- ========== 2. Statut d'impayé Rivage (objets « RentArrear », clé = identifiant du bail) ==========
create or replace function pilotage.cycle_impaye(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when o.id is null then null else jsonb_build_object(
    'statut', o.data->'rent_arrear'->>'status',
    'libelle', case o.data->'rent_arrear'->>'status' when 'opened' then 'Impayé détecté' when 'reminded' then 'Relancé' when 'formal_notice' then 'Mis en demeure'
                  when 'gli_reported' then 'Déclaré à la GLI' when 'long_contentious' then 'Contentieux' when 'closed' then 'Clos' else null end,
    'ouvert_le', (o.data->'rent_arrear'->>'opened_at')::timestamptz, 'jours', (o.data->'rent_arrear'->>'age_in_days')::integer,
    'ouvert', coalesce((o.data->'rent_arrear'->>'open')::boolean, false),
    'dette_initiale', round(coalesce((o.data->'rent_arrear'->>'initial_unpaid_amount')::numeric, 0) / 100, 2),
    'dette', round(coalesce((o.data->>'unpaid_amount')::numeric, 0) / 100, 2), 'lu_le', o.maj_le) end
  from (select 1) x left join pilotage.objets o on o.type = 'RentArrear' and o.id = p_bail
$$;

-- Baux à relire (la fonction serveur interroge Rivage pour chacun) : dette en cours ou cycle encore ouvert
create or replace function public.pilotage_cycles_a_lire() returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(b.id), '[]'::jsonb) from pilotage.objets b
  where b.type = 'LeasingContract' and b.supprime_le is null
    and (coalesce((b.data->>'unpaid_amount')::numeric, 0) > 0
         or exists (select 1 from pilotage.objets r where r.type = 'RentArrear' and r.id = b.id and coalesce((r.data->'rent_arrear'->>'open')::boolean, false)))
$$;

-- ========== 3 à 5. Le mois des impayés ==========
create table if not exists pilotage.impayes_actualisations (
  organisme text not null, mois date not null, fait_le timestamptz not null default now(), par uuid, note text,
  primary key (organisme, mois)
);
alter table pilotage.impayes_actualisations enable row level security;
revoke all on pilotage.impayes_actualisations from public, anon, authenticated;

create or replace function pilotage.jour_paris() returns integer language sql stable as $$ select extract(day from (now() at time zone 'Europe/Paris'))::integer $$;
create or replace function pilotage.mois_paris() returns date language sql stable as $$ select date_trunc('month', (now() at time zone 'Europe/Paris'))::date $$;

create or replace function pilotage.organisme_bail(p_bail text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select case when g.data->>'name' ilike '%zelok%' then 'zelok' when g.data->>'name' ilike '%mila%' then 'mila'
              when g.data->>'name' ilike '%smart%' then 'smartgarant' when g.data->>'name' ilike '%garantme%' then 'garantme'
              when g.data->>'name' ilike '%visale%' then 'visale' end
  from pilotage.objets b left join pilotage.objets g on g.type = 'GliProvider' and g.id = b.data->>'gli_provider_id'
  where b.type = 'LeasingContract' and b.id = p_bail
$$;

-- Pièces de la déclaration GLI d'un bail
create or replace function pilotage.pieces_declaration(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_array(
    jsonb_build_object('piece', 'Mandat de gestion', 'ok', public.pilotage_mandat_source(l.mandat_id) is not null,
                       'detail', coalesce(public.pilotage_mandat_source(l.mandat_id)->>'libelle', 'Absent dans Rivage')),
    jsonb_build_object('piece', 'Bail', 'ok', public.pilotage_lecture_source(p_bail) is not null,
                       'detail', coalesce(public.pilotage_lecture_source(p_bail)->>'libelle', 'Absent dans Rivage')),
    jsonb_build_object('piece', 'Extrait de compte locataire', 'ok', exists (select 1 from pilotage.objets c where c.type = 'AccountingAccount' and c.data->>'leasing_contract_id' = p_bail and c.data->>'holder_type' = 'tenant'),
                       'detail', 'Généré à la date du jour (bouton « Extrait de compte »)'),
    jsonb_build_object('piece', 'Preuve d''encaissement du dépôt de garantie',
                       'ok', exists (select 1 from pilotage.objets c where c.type = 'AccountingAccount' and c.data->>'asset_id' = l.id and c.data->>'general_number' = '1651'
                                     and coalesce((c.data->>'credit_in_cents')::numeric, 0) > 0),
                       'detail', 'Écriture au compte des dépôts de garantie du lot (avec l''extrait)'),
    jsonb_build_object('piece', 'RIB de l''agence', 'ok', true, 'detail', 'Toujours le même'))
  from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id where b.id = p_bail
$$;

-- Impayés à déclarer à Zelok : cycle ouvert dans Rivage (ou dette au-dessus du seuil), bail garanti par Zelok, pas déclaré depuis l'ouverture
create or replace function pilotage.impayes_a_declarer() returns table (bail_id text, dossier_id bigint, dette numeric, ouvert_le timestamptz)
language sql stable security definer set search_path = pilotage, public as $$
  select b.id, (select d.id from pilotage.impayes d where d.bail_id = b.id and d.groupe <> 'Clôturé' order by d.cree_le desc limit 1),
         round(coalesce((b.data->>'unpaid_amount')::numeric, 0) / 100, 2), (pilotage.cycle_impaye(b.id)->>'ouvert_le')::timestamptz
  from pilotage.objets b
  where b.type = 'LeasingContract' and b.supprime_le is null and pilotage.organisme_bail(b.id) = 'zelok'
    and (coalesce((pilotage.cycle_impaye(b.id)->>'ouvert')::boolean, false)
         or coalesce((b.data->>'unpaid_amount')::numeric, 0) > greatest(coalesce((b.data->>'unpaid_threshold_amount_in_cents')::numeric, 0), 0))
    and coalesce(pilotage.cycle_impaye(b.id)->>'statut', '') not in ('gli_reported', 'long_contentious')
    and not exists (select 1 from pilotage.impayes d where d.bail_id = b.id and d.groupe <> 'Clôturé' and d.declaration_le is not null
                    and d.declaration_le >= coalesce((pilotage.cycle_impaye(b.id)->>'ouvert_le')::date, d.declaration_le))
$$;

-- Règlements reçus sur un dossier déclaré, pas encore signalés à l'organisme
create or replace function pilotage.impayes_reglements() returns table (dossier_id bigint, bail_id text, organisme text, recu_le date, montant numeric, indemnisation_compte numeric)
language sql stable security definer set search_path = pilotage, public as $$
  select d.id, d.bail_id, d.organisme, (b.data->>'received_rent_date')::date, round(coalesce((b.data->>'received_rent_amount')::numeric, 0) / 100, 2),
         (select round(sum(coalesce((c.data->>'credit_in_cents')::numeric, 0) - coalesce((c.data->>'debit_in_cents')::numeric, 0)) / 100, 2)
          from pilotage.objets c where c.type = 'AccountingAccount' and c.data->>'leasing_contract_id' = d.bail_id and c.data->>'holder_type' = 'gli_provider')
  from pilotage.impayes d join pilotage.objets b on b.type = 'LeasingContract' and b.id = d.bail_id
  where d.groupe <> 'Clôturé' and d.declaration_le is not null and d.organisme is not null and d.organisme <> 'aucun'
    and nullif(b.data->>'received_rent_date', '') is not null
    and (b.data->>'received_rent_date')::date > greatest(d.declaration_le, coalesce(d.reglement_signale_le, d.declaration_le))
$$;

-- Détections pour le tableau de bord (ajoutées aux contrôles toutes les 30 minutes)
create or replace function pilotage.suivi_detections_impayes() returns table (regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  select case when pilotage.jour_paris() >= 18 then 'impaye_zelok_urgent' else 'impaye_zelok_declarer' end, 'LeasingContract', a.bail_id,
         'Impayé à déclarer à Zelok avant le 19 : ' || coalesce((select v.locataires from pilotage.v_baux v where v.id = a.bail_id), a.bail_id),
         'Dette ' || a.dette || ' €' || coalesce(', impayé ouvert le ' || to_char(a.ouvert_le, 'DD/MM/YYYY'), '') || '. Pièces : onglet Impayés, « Ce mois-ci ».',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || a.bail_id
  from pilotage.impayes_a_declarer() a where pilotage.jour_paris() between 16 and 19
  union all
  select 'impaye_actualisation', 'Organisme', o.organisme,
         'Actualiser les dossiers ' || initcap(o.organisme) || ' du mois (' || o.n || ' dossier(s))',
         'Extrait de compte à jour de chaque dossier ouvert à transmettre. Onglet Impayés, « Ce mois-ci ».', null
  from (select coalesce(case when procedure ilike '%avocat%' then 'avocats' end, organisme) organisme, count(*) n
        from pilotage.impayes where groupe <> 'Clôturé' and organisme is not null and organisme <> 'aucun' group by 1) o
  where pilotage.jour_paris() >= 16
    and not exists (select 1 from pilotage.impayes_actualisations x where x.organisme = o.organisme and x.mois = pilotage.mois_paris())
  union all
  select 'impaye_reglement', 'LeasingContract', r.bail_id,
         'Règlement reçu sur un impayé déclaré à ' || initcap(r.organisme) || ' : ' || coalesce((select v.locataires from pilotage.v_baux v where v.id = r.bail_id), ''),
         'Règlement de ' || r.montant || ' € le ' || to_char(r.recu_le, 'DD/MM/YYYY') || ' : prévenir l''organisme avec l''extrait de compte.'
           || case when coalesce(r.indemnisation_compte, 0) <> 0 then ' Indemnisation déjà reçue (compte GLI du bail : ' || r.indemnisation_compte || ' €) : calculer le montant à reverser.' else '' end,
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || r.bail_id
  from pilotage.impayes_reglements() r
$$;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication) values
 ('impaye_zelok_declarer', 'Impayé à déclarer à Zelok', 'impayes', 'haute', 'oblig', true, 'Du 16 au 19 de chaque mois : Zelok ne prend plus en charge un impayé déclaré après le 19.'),
 ('impaye_zelok_urgent', 'Impayé à déclarer à Zelok : dernier délai', 'impayes', 'critique', 'oblig', true, 'Les 18 et 19 du mois : dernier délai de déclaration à Zelok.'),
 ('impaye_actualisation', 'Actualisation mensuelle des dossiers d''impayés', 'impayes', 'haute', 'tache', true, 'Chaque mois, transmettre à chaque organisme (et aux avocats) l''extrait de compte à jour de ses dossiers ouverts.'),
 ('impaye_reglement', 'Règlement reçu sur un impayé déclaré', 'impayes', 'haute', 'tache', true, 'Tout règlement d''un locataire sur un dossier déclaré est signalé à l''organisme ; s''il a déjà indemnisé, la somme lui est reversée.')
on conflict (cle) do update set libelle = excluded.libelle, gravite = excluded.gravite, categorie = excluded.categorie, explication = excluded.explication;

do $do$
declare def text;
begin
  def := pg_get_functiondef('pilotage.suivi_detections'::regproc);
  if position('suivi_detections_impayes' in def) = 0 then
    execute regexp_replace(def, '\s*\$function\$\s*$', E'\n  union all\n  select * from pilotage.suivi_detections_impayes()\n$function$\n');
  end if;
end $do$;

-- Écran : le mois des impayés
create or replace function public.pilotage_impayes_mois() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return jsonb_build_object('jour', pilotage.jour_paris(), 'mois', pilotage.mois_paris(),
    'a_declarer', coalesce((select jsonb_agg(jsonb_build_object('bail_id', a.bail_id, 'dossier_id', a.dossier_id, 'dette', a.dette, 'ouvert_le', a.ouvert_le,
                     'locataires', v.locataires, 'adresse', l.adresse, 'bailleur', pilotage.bailleurs_mandat(l.mandat_id), 'cycle', pilotage.cycle_impaye(a.bail_id),
                     'pieces', pilotage.pieces_declaration(a.bail_id)) order by a.ouvert_le)
                   from pilotage.impayes_a_declarer() a left join pilotage.v_baux v on v.id = a.bail_id left join pilotage.v_lots l on l.id = v.lot_id), '[]'::jsonb),
    'actualisations', coalesce((select jsonb_agg(jsonb_build_object('organisme', o.organisme, 'dossiers', o.dossiers,
                     'fait_le', (select x.fait_le from pilotage.impayes_actualisations x where x.organisme = o.organisme and x.mois = pilotage.mois_paris()),
                     'fait_par', (select pilotage.prenom_membre(x.par) from pilotage.impayes_actualisations x where x.organisme = o.organisme and x.mois = pilotage.mois_paris())) order by o.organisme)
                   from (select coalesce(case when procedure ilike '%avocat%' then 'avocats' end, organisme) organisme,
                                jsonb_agg(jsonb_build_object('id', id, 'titre', coalesce(titre, locataire_nom), 'bail_id', bail_id, 'montant', montant_impaye) order by titre) dossiers
                         from pilotage.impayes where groupe <> 'Clôturé' and organisme is not null and organisme <> 'aucun' group by 1) o), '[]'::jsonb),
    'reglements', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('locataires', (select v.locataires from pilotage.v_baux v where v.id = r.bail_id)))
                   from pilotage.impayes_reglements() r), '[]'::jsonb),
    'sans_organisme', (select count(*) from pilotage.impayes where groupe <> 'Clôturé' and organisme is null));
end $$;

create or replace function public.pilotage_impayes_actualisation(p_organisme text, p_fait boolean, p_note text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  if p_fait then
    insert into pilotage.impayes_actualisations (organisme, mois, par, note) values (p_organisme, pilotage.mois_paris(), auth.uid(), nullif(p_note, ''))
    on conflict (organisme, mois) do update set fait_le = now(), par = auth.uid(), note = excluded.note;
  else
    delete from pilotage.impayes_actualisations where organisme = p_organisme and mois = pilotage.mois_paris();
  end if;
end $$;

create or replace function public.pilotage_impaye_reglement_signale(p_dossier bigint) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  update pilotage.impayes set reglement_signale_le = current_date, maj_par = auth.uid(), maj_le = now() where id = p_dossier;
  insert into pilotage.impayes_notes (impaye_id, auteur, auteur_id, contenu)
  values (p_dossier, pilotage.prenom_membre(auth.uid()), auth.uid(), 'Règlement du locataire signalé à l''organisme avec l''extrait de compte.');
end $$;

create or replace function public.pilotage_impaye_organisme(p_dossier bigint, p_organisme text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  update pilotage.impayes set organisme = nullif(p_organisme, ''), maj_par = auth.uid(), maj_le = now() where id = p_dossier;
end $$;

-- Droit de générer un extrait de compte (vérifié par la fonction serveur)
create or replace function public.pilotage_peut_extrait() returns boolean
language sql stable security definer set search_path = pilotage, public as $$ select pilotage.mon_role() in ('direction', 'superviseur', 'gestionnaire', 'comptable') $$;
-- Comptes Rivage d'un bail pour l'extrait : compte du locataire et compte des dépôts de garantie du lot
create or replace function public.pilotage_comptes_bail(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object(
    'locataire', (select c.id from pilotage.objets c where c.type = 'AccountingAccount' and c.data->>'leasing_contract_id' = p_bail and c.data->>'holder_type' = 'tenant' limit 1),
    'depot', (select c.id from pilotage.objets c where c.type = 'AccountingAccount' and c.data->>'asset_id' = b.data->>'asset_id' and c.data->>'general_number' = '1651' limit 1),
    'locataires', (select v.locataires from pilotage.v_baux v where v.id = p_bail),
    'adresse', (select l.adresse from pilotage.v_baux v join pilotage.v_lots l on l.id = v.lot_id where v.id = p_bail),
    'reference', b.data->>'reference', 'depot_contrat', round(coalesce((b.data->>'deposit_in_cents')::numeric, 0) / 100, 2))
  from pilotage.objets b where b.type = 'LeasingContract' and b.id = p_bail
$$;

-- Les dossiers d'impayés affichent l'organisme et le statut Rivage
do $do$
declare def text; n text;
begin
  def := pg_get_functiondef('public.pilotage_impayes()'::regprocedure);
  if position('cycle_impaye' in def) > 0 then return; end if;
  n := replace(def, $o$'rivage', case when d.bail_id is not null then pilotage.impaye_rivage(d.bail_id) end,$o$,
                    $r$'rivage', case when d.bail_id is not null then pilotage.impaye_rivage(d.bail_id) end,
        'cycle', case when d.bail_id is not null then pilotage.cycle_impaye(d.bail_id) end,$r$);
  if n = def then raise exception '039 : point d''insertion introuvable dans pilotage_impayes'; end if;
  execute n;
end $do$;

-- ========== 6. Relances : Rivage seulement ==========
select cron.alter_job(job_id := j.jobid, active := false) from cron.job j where j.jobname = 'relance-impayes-auto-quotidien';

-- Relecture quotidienne des statuts d'impayé (6 h 15, heure UTC)
select cron.unschedule('pilotage-cycles-impayes') where exists (select 1 from cron.job where jobname = 'pilotage-cycles-impayes');
select cron.schedule('pilotage-cycles-impayes', '15 6 * * *', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-sync-rivage',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{"mode": "impayes"}'::jsonb, timeout_milliseconds := 300000) $$);

revoke all on all functions in schema pilotage from public, anon, authenticated;
revoke all on function public.pilotage_cycles_a_lire(), public.pilotage_comptes_bail(text) from public, anon, authenticated;
revoke all on function public.pilotage_impayes_mois(), public.pilotage_impayes_actualisation(text, boolean, text), public.pilotage_impaye_reglement_signale(bigint),
  public.pilotage_impaye_organisme(bigint, text), public.pilotage_peut_extrait() from public, anon;
grant execute on function public.pilotage_impayes_mois(), public.pilotage_impayes_actualisation(text, boolean, text), public.pilotage_impaye_reglement_signale(bigint),
  public.pilotage_impaye_organisme(bigint, text), public.pilotage_peut_extrait() to authenticated;
