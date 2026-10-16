-- 034 : suivis complétés (décision de Nicolas, 16/10/2026). À exécuter après 033.
--   1. Relances automatiques d'UDIGESTION mises en veille (doublon avec le pilotage ; elles partaient sans validation).
--      La relance automatique des impayés (seule réellement active) n'est PAS coupée : voir la ligne en commentaire.
--   2. Calendriers complétés : compteurs (3 relances puis bailleur), DPE (relance + commande), garantie (bailleur + mise en demeure),
--      état des travaux (envoi au preneur), décret tertiaire (relance), nouvel ajustement du dépôt de garantie à la révision.
--   3. Suivis rattachés au mandat : PNO, échéance du mandat (créée d'après Rivage), entretien des équipements d'un lot vacant
--      (créé d'après les équipements saisis au contrôle du mandat), DPE d'un lot ; alertes au tableau de bord.

-- ===== 1. Veille UDIGESTION (réversible : remettre active := true) =====
select cron.alter_job(job_id := j.jobid, active := false)
from cron.job j
where j.jobname in ('cron-relances-assurances-quotidien', 'cron-rappels-baux-quotidien', 'cron-rappel-releves-compteurs-quotidien', 'cron-echeances-equipements-quotidien');
-- Relances SMS et mail des impayés (UDIGESTION) : toujours actives. Pour les couper aussi, exécuter :
-- select cron.alter_job(job_id := jobid, active := false) from cron.job where jobname = 'relance-impayes-auto-quotidien';

-- ===== 2. Calendriers complétés (les numéros d'étapes existants sont conservés : les étapes déjà faites restent faites) =====
-- Compteurs : mail J0, SMS J+5, mail J+10, SMS J+15 (3 relances), puis relevé sur place et information du bailleur à J+20
update pilotage.calendriers set jours = 20, libelle = 'Organiser le relevé sur place (gestionnaire ou prestataire)' where nature = 'compteur' and ordre = 4;
insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele) values
  ('compteur', 5, 15, '3e relance : SMS depuis Rivage', 'sms_rivage', 'compteur_sms3'),
  ('compteur', 6, 20, 'Informer le bailleur : relevé sur place', 'mail_bailleur', 'compteur_bailleur'),
  ('dpe', 2, -60, 'Relancer le bailleur', 'mail_bailleur', 'dpe_relance'),
  ('dpe', 3, -30, 'Commander le DPE au diagnostiqueur (accord du bailleur) : sans DPE valide, pas de nouvelle location', 'tache', null),
  ('garantie', 4, -45, 'Prévenir le bailleur : garantie non renouvelée', 'mail_bailleur', 'garantie_bailleur'),
  ('garantie', 5, -30, 'Mise en demeure du preneur en recommandé (15 jours)', 'lrar', 'garantie_md'),
  ('etat_travaux', 2, 0, 'Transmettre l''état des travaux au preneur (dans les 2 mois de l''échéance triennale)', 'mail_locataire', 'etat_travaux_preneur'),
  ('tertiaire', 2, -15, 'Relancer le bailleur', 'mail_bailleur', 'tertiaire_relance'),
  ('dg_ajust', 1, 0, 'Calculer le complément de dépôt de garantie au nouveau loyer et l''appeler dans Rivage (appel ponctuel)', 'tache', null),
  ('dg_ajust', 2, 0, 'Informer le preneur du complément de dépôt de garantie', 'mail_locataire', 'dg_ajust'),
  -- Suivis du mandat
  ('pno', 1, -30, 'Demander au bailleur la nouvelle attestation PNO', 'mail_bailleur', 'pno_1'),
  ('pno', 2, 1, 'Relancer le bailleur (PNO obligatoire en copropriété)', 'mail_bailleur', 'pno_2'),
  ('pno', 3, 15, 'Appeler le bailleur et noter sa réponse', 'tache', null),
  ('mandat_echeance', 1, -75, 'Informer le mandant de la reconduction et de sa faculté de ne pas reconduire (entre 3 mois et 1 mois avant)', 'mail_bailleur', 'mandat_echeance'),
  ('mandat_echeance', 2, 1, 'Vérifier la nouvelle date de fin du mandat dans Rivage', 'tache', null),
  ('entretien_lot', 1, -30, 'Lot vacant : proposer au bailleur de commander l''entretien', 'mail_bailleur', 'entretien_lot'),
  ('entretien_lot', 2, 0, 'Faire réaliser l''entretien (accord du bailleur reçu)', 'tache', null)
on conflict (nature, ordre) do update set jours = excluded.jours, libelle = excluded.libelle, canal = excluded.canal, modele = excluded.modele;
update pilotage.calendriers set jours = -15, libelle = 'Décider avec le bailleur : mise en jeu de la garantie avant son expiration' where nature = 'garantie' and ordre = 3;

-- Ajustement du dépôt de garantie : la clause du bail commercial crée désormais son suivi
update pilotage.controle_questions set genere = 'dg_ajust' where cle = 'c_cl_dg_ajust';

-- ===== 3. Suivis rattachés au mandat =====
create table if not exists pilotage.mandats_obligations (
  id bigserial primary key, mandat_id text not null, asset_id text, equipement_id bigint,
  nature text not null, libelle text not null, periodicite_mois integer, prochaine date not null, derniere_le date,
  actif boolean not null default true, auto boolean not null default false,
  par uuid, cree_le timestamptz not null default now()
);
create index if not exists mandats_obligations_mandat on pilotage.mandats_obligations (mandat_id);
create unique index if not exists mandats_obligations_echeance on pilotage.mandats_obligations (mandat_id) where nature = 'mandat_echeance';
create unique index if not exists mandats_obligations_equipement on pilotage.mandats_obligations (equipement_id) where nature = 'entretien_lot';
create table if not exists pilotage.mandats_justificatifs (upload_id text not null, obligation_id bigint not null, applique_le timestamptz not null default now(), primary key (upload_id, obligation_id));
alter table pilotage.mandats_obligations enable row level security;
alter table pilotage.mandats_justificatifs enable row level security;
revoke all on pilotage.mandats_obligations, pilotage.mandats_justificatifs from public, anon, authenticated;

-- Étapes : clé m:<obligation>:<échéance> en plus de e: (échéance du bail) et o: (suivi du bail)
create or replace function public.pilotage_suivi_etape(p_cle text, p_etape text, p_detail text, p_annuler boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_cle !~ '^(e|o|m):' then raise exception 'Clé de suivi invalide'; end if;
  if p_annuler then delete from pilotage.suivis_etapes where cle = p_cle and etape = p_etape; return; end if;
  insert into pilotage.suivis_etapes (cle, etape, par, detail) values (p_cle, p_etape, auth.uid(), p_detail)
  on conflict (cle, etape) do update set fait_le = now(), par = auth.uid(), detail = excluded.detail;
end $$;

-- État d'un suivi de mandat : étapes du calendrier, étape à faire, prochaine étape
create or replace function pilotage.obligation_mandat_etat(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare ob pilotage.mandats_obligations; v_cle text; etapes jsonb; afaire jsonb; suivante jsonb; j date := current_date;
begin
  select * into ob from pilotage.mandats_obligations where id = p_id;
  if not found then return null; end if;
  v_cle := 'm:' || ob.id || ':' || ob.prochaine;
  select coalesce(jsonb_agg(jsonb_build_object('ordre', c.ordre, 'date', ob.prochaine + c.jours, 'libelle', c.libelle, 'canal', c.canal, 'modele', c.modele,
           'fait_le', se.fait_le, 'du', (ob.prochaine + c.jours) <= j) order by c.jours, c.ordre), '[]'::jsonb)
    into etapes
  from pilotage.calendriers c left join pilotage.suivis_etapes se on se.cle = v_cle and se.etape = c.ordre::text
  where c.nature = ob.nature;
  select x into afaire from jsonb_array_elements(etapes) x where (x->>'du')::boolean and x->>'fait_le' is null order by (x->>'date')::date limit 1;
  select x into suivante from jsonb_array_elements(etapes) x where not (x->>'du')::boolean order by (x->>'date')::date limit 1;
  return jsonb_build_object('id', ob.id, 'nature', ob.nature, 'libelle', ob.libelle, 'periodicite_mois', ob.periodicite_mois, 'asset_id', ob.asset_id,
    'lot', (select coalesce(a.data->>'reference', a.data->>'name') from pilotage.objets a where a.type = 'Asset' and a.id = ob.asset_id),
    'prochaine', ob.prochaine, 'derniere_le', ob.derniere_le, 'actif', ob.actif, 'auto', ob.auto, 'cle', v_cle,
    'etapes', etapes, 'a_faire', afaire, 'suivante', suivante,
    'en_retard', ob.actif and j > ob.prochaine + 30,
    'gravite', case when not ob.actif then 'normale' when j > ob.prochaine + 30 then 'critique'
                    when afaire is not null and (afaire->>'canal') = 'lrar' then 'haute' else 'normale' end);
end $$;

-- Lot occupé : un bail en cours (créé, entrée, en cours, non terminé)
create or replace function pilotage.lot_occupe(p_asset text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select exists (select 1 from pilotage.v_baux b where b.lot_id = p_asset and b.statut in ('created','move_in','in_progress') and (b.fin is null or b.fin > current_date))
$$;

-- Création et mise à jour automatiques (cron) :
--   échéance du mandat d'après Rivage (date de fin, durée de reconduction) ;
--   entretien des équipements d'un lot vacant (le suivi du bail prend le relais dès qu'un bail est en cours) ;
--   justificatif PNO ou DPE déposé dans Rivage sur le mandat, un lot ou un mandant : le suivi passe à l'échéance suivante.
create or replace function pilotage.mandats_suivis_auto() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer := 0; k integer; r record; suivante date;
begin
  -- Échéance du mandat
  insert into pilotage.mandats_obligations (mandat_id, nature, libelle, periodicite_mois, prochaine, auto)
  select m.id, 'mandat_echeance',
         case when m.data->>'renewal_type' = 'tacit' then 'Échéance du mandat (reconduction tacite)' else 'Échéance du mandat' end,
         nullif(m.data->>'renewal_duration_years', '')::integer * 12, (m.data->>'end_date')::date, true
  from pilotage.objets m
  where m.type = 'ManagementContract' and m.supprime_le is null and m.data->>'status' = 'active' and nullif(m.data->>'end_date', '') is not null
  on conflict (mandat_id) where nature = 'mandat_echeance' do nothing;
  get diagnostics k = row_count; n := n + k;
  -- Date de fin modifiée dans Rivage (reconduction saisie) : le suivi repart sur la nouvelle date ; mandat terminé : suivi clos
  update pilotage.mandats_obligations o set prochaine = (m.data->>'end_date')::date, actif = true
  from pilotage.objets m
  where o.nature = 'mandat_echeance' and m.type = 'ManagementContract' and m.id = o.mandat_id and m.supprime_le is null and m.data->>'status' = 'active'
    and (m.data->>'end_date')::date > o.prochaine;
  update pilotage.mandats_obligations o set actif = false
  where o.nature = 'mandat_echeance' and o.actif
    and not exists (select 1 from pilotage.objets m where m.type = 'ManagementContract' and m.id = o.mandat_id and m.supprime_le is null and m.data->>'status' = 'active');

  -- Entretien des équipements d'un lot vacant
  insert into pilotage.mandats_obligations (mandat_id, asset_id, equipement_id, nature, libelle, periodicite_mois, prochaine, auto)
  select a.data->>'management_contract_id', e.asset_id, e.id, 'entretien_lot', 'Entretien ' || lower(e.libelle) || ' (lot vacant)', 12,
         case when e.dernier_entretien is not null then greatest(pilotage.ajouter_mois(e.dernier_entretien, 12), current_date) else current_date + 30 end, true
  from pilotage.lots_equipements e
  join pilotage.objets a on a.type = 'Asset' and a.id = e.asset_id and a.supprime_le is null and a.data->>'management_contract_id' is not null
  where e.nature = 'equipement' and not pilotage.lot_occupe(e.asset_id)
  on conflict (equipement_id) where nature = 'entretien_lot' do nothing;
  get diagnostics k = row_count; n := n + k;
  update pilotage.mandats_obligations o set actif = not pilotage.lot_occupe(o.asset_id)
  where o.nature = 'entretien_lot' and o.actif = pilotage.lot_occupe(o.asset_id)
    and exists (select 1 from pilotage.lots_equipements e where e.id = o.equipement_id);
  update pilotage.mandats_obligations o set actif = false
  where o.nature = 'entretien_lot' and o.actif and not exists (select 1 from pilotage.lots_equipements e where e.id = o.equipement_id);

  -- Justificatifs déposés dans Rivage (catégorie Rivage), après la création du suivi
  for r in select o.id, o.nature, o.prochaine, o.periodicite_mois, u.id upload_id, u.maj_le::date depose
           from pilotage.mandats_obligations o
           cross join lateral pilotage.uploads_mandat(o.mandat_id) u
           where o.actif and o.nature in ('pno', 'dpe')
             and u.data->>'nature' = case o.nature when 'pno' then 'property_insurance_contracts' else 'energy_performance_diagnosis' end
             and (o.asset_id is null or o.nature = 'pno' or u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', o.asset_id))
                  or u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', o.mandat_id)))
             and u.maj_le > o.cree_le
             and not exists (select 1 from pilotage.mandats_justificatifs mj where mj.upload_id = u.id and mj.obligation_id = o.id)
           order by u.maj_le loop
    insert into pilotage.mandats_justificatifs (upload_id, obligation_id) values (r.upload_id, r.id) on conflict do nothing;
    -- PNO : nouvelle échéance un an après l'échéance précédente (ou après le dépôt s'il est postérieur) ;
    -- DPE : nouveau diagnostic, validité 10 ans à compter du dépôt (date de réalisation à vérifier sur le document)
    suivante := case when r.nature = 'pno' then pilotage.ajouter_mois(greatest(r.prochaine, r.depose), coalesce(r.periodicite_mois, 12))
                     else pilotage.ajouter_mois(r.depose, 120) end;
    insert into pilotage.suivis_etapes (cle, etape, detail) values ('m:' || r.id || ':' || r.prochaine, 'realise',
      'Justificatif déposé dans Rivage le ' || to_char(r.depose, 'DD/MM/YYYY') || ' : prochaine échéance le ' || to_char(suivante, 'DD/MM/YYYY') || ' (à vérifier sur le document)')
    on conflict (cle, etape) do nothing;
    update pilotage.mandats_obligations set derniere_le = r.depose, prochaine = suivante where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Saisie manuelle d'un suivi de mandat (PNO, DPE d'un lot, ou tout suivi du calendrier)
create or replace function public.pilotage_mandat_obligation(p_mandat text, p_id bigint, p_nature text, p_libelle text, p_periodicite integer, p_prochaine date, p_actif boolean, p_asset text)
returns bigint language plpgsql security definer set search_path = pilotage, public as $$
declare nid bigint;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_id is null then
    if p_nature not in (select distinct nature from pilotage.calendriers) then raise exception 'Nature de suivi inconnue'; end if;
    if p_nature in ('mandat_echeance', 'entretien_lot') then raise exception 'Ce suivi est créé automatiquement'; end if;
    if p_prochaine is null then raise exception 'Date d''échéance obligatoire'; end if;
    insert into pilotage.mandats_obligations (mandat_id, asset_id, nature, libelle, periodicite_mois, prochaine, par)
    values (p_mandat, nullif(p_asset, ''), p_nature, coalesce(nullif(p_libelle, ''), p_nature), p_periodicite, p_prochaine, auth.uid()) returning id into nid;
  else
    update pilotage.mandats_obligations set libelle = coalesce(nullif(p_libelle, ''), libelle), periodicite_mois = coalesce(p_periodicite, periodicite_mois),
      prochaine = coalesce(p_prochaine, prochaine), actif = coalesce(p_actif, actif)
    where id = p_id and mandat_id = p_mandat returning id into nid;
  end if;
  return nid;
end $$;

-- Suivi réalisé (justificatif reçu, entretien fait, reconduction vérifiée) : échéance suivante, les étapes repartent de zéro
create or replace function public.pilotage_mandat_obligation_realisee(p_id bigint, p_le date, p_prochaine date) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare ob pilotage.mandats_obligations;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  select * into ob from pilotage.mandats_obligations where id = p_id;
  if not found then raise exception 'Suivi introuvable'; end if;
  insert into pilotage.suivis_etapes (cle, etape, par, detail) values ('m:' || ob.id || ':' || ob.prochaine, 'realise', auth.uid(), 'Réalisé le ' || to_char(coalesce(p_le, current_date), 'DD/MM/YYYY'))
  on conflict (cle, etape) do nothing;
  update pilotage.mandats_obligations set derniere_le = coalesce(p_le, current_date),
    prochaine = coalesce(p_prochaine, case when periodicite_mois is not null then pilotage.ajouter_mois(case when nature = 'mandat_echeance' then prochaine else coalesce(p_le, current_date) end, periodicite_mois) end, prochaine),
    actif = (p_prochaine is not null or periodicite_mois is not null)
  where id = p_id;
end $$;

-- Interlocuteurs du mandat (mandants) pour les mails préparés
create or replace function pilotage.contacts_mandat(p_mandat text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('locataires', '[]'::jsonb, 'bailleurs', coalesce((select jsonb_agg(jsonb_build_object('nom', pilotage.nom_profil(p->>'profile_id'), 'email', pr.data->>'email', 'telephone', pr.data->>'phone_number'))
    from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes','[]'::jsonb)) p
    left join pilotage.objets pr on pr.type = 'Profile' and pr.id = p->>'profile_id'
    where m.type = 'ManagementContract' and m.id = p_mandat), '[]'::jsonb))
$$;

-- Dossier du mandat : + suivis, interlocuteurs, journal des suivis
create or replace function public.pilotage_mandat_dossier(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'controle', pilotage.controle_mandat(p_mandat),
    'lots', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'reference', coalesce(a.data->>'reference', a.data->>'name'), 'nature', a.data->>'nature',
              'adresse', concat_ws(' ', a.data->'address'->>'number', a.data->'address'->>'street', a.data->'address'->>'zip_code', a.data->'address'->>'city'),
              'construction', a.data->>'construction_year', 'chauffage', a.data->'equipment'->>'heating_method', 'chauffage_type', a.data->'equipment'->>'heating_type',
              'eau_chaude', a.data->'equipment'->>'hot_water_method', 'syndic', a.data->>'syndic_id' is not null, 'occupe', pilotage.lot_occupe(a.id),
              'equipements', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nature', e.nature, 'libelle', e.libelle, 'contrat_entretien', e.contrat_entretien,
                             'prestataire', e.prestataire, 'dernier_entretien', e.dernier_entretien, 'commentaire', e.commentaire, 'situation', e.situation) order by e.nature, e.libelle)
                             from pilotage.lots_equipements e where e.asset_id = a.id), '[]'::jsonb),
              'compteurs', pilotage.compteurs_lot(a.id)) order by a.data->>'reference')
             from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat), '[]'::jsonb),
    'lecture', (select jsonb_build_object('le', l.le, 'source', l.source, 'modele', l.modele, 'resultat', l.resultat) from pilotage.baux_lectures l where l.bail_id = p_mandat order by l.le desc limit 1),
    'obligations', coalesce((select jsonb_agg(pilotage.obligation_mandat_etat(o.id) order by o.actif desc, o.prochaine) from pilotage.mandats_obligations o where o.mandat_id = p_mandat), '[]'::jsonb),
    'contacts', pilotage.contacts_mandat(p_mandat),
    'mandat', (select jsonb_build_object('reference', m.data->>'reference', 'fin', m.data->>'end_date', 'reconduction', m.data->>'renewal_type', 'duree_reconduction', m.data->>'renewal_duration_years')
               from pilotage.objets m where m.type = 'ManagementContract' and m.id = p_mandat),
    'journal', coalesce((select jsonb_agg(jsonb_build_object('le', se.fait_le, 'etape', se.etape, 'detail', se.detail, 'par', pilotage.prenom_membre(se.par)) order by se.fait_le desc)
                         from pilotage.suivis_etapes se where se.cle like any (array(select 'm:' || o.id || ':%' from pilotage.mandats_obligations o where o.mandat_id = p_mandat))), '[]'::jsonb),
    'lien', 'https://rivage.immo/landlords/profiles/' || coalesce((select p->>'profile_id' from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
                                                                 where m.type = 'ManagementContract' and m.id = p_mandat limit 1), '')
  );
end $$;

-- Alertes du tableau de bord pour les suivis de mandat
create or replace function pilotage.suivi_detections_mandats() returns table (regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  select case when bool_or(e->>'gravite' = 'critique') then 'mandat_suivi_retard' else 'mandat_suivi' end, 'ManagementContract', o.mandat_id,
         'Mandat ' || coalesce(max(m.data->>'reference'), '') || ' : ' || string_agg(coalesce(e->'a_faire'->>'libelle', 'en retard') || ' (' || (e->>'libelle') || ')', ' ; '),
         string_agg((e->>'libelle') || ' : échéance le ' || to_char((e->>'prochaine')::date, 'DD/MM/YYYY'), ' ; '),
         'https://rivage.immo/landlords/profiles/' || coalesce(max(m.data->'profile_contracts_attributes'->0->>'profile_id'), '')
  from pilotage.mandats_obligations o
  join pilotage.objets m on m.type = 'ManagementContract' and m.id = o.mandat_id and m.supprime_le is null,
  lateral (select pilotage.obligation_mandat_etat(o.id) e) x
  where o.actif and (jsonb_typeof(e->'a_faire') = 'object' or (e->>'en_retard')::boolean)
  group by o.mandat_id
$$;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication) values
 ('mandat_suivi', 'Suivi du mandat : relance à faire', 'baux', 'haute', 'courrier', true, 'Suivis rattachés au mandat (PNO, échéance du mandat, entretien d''un lot vacant, DPE) selon leur calendrier.'),
 ('mandat_suivi_retard', 'Suivi du mandat : en retard', 'baux', 'critique', 'oblig', true, 'Suivi de mandat non réalisé plus de 30 jours après son échéance.')
on conflict (cle) do update set libelle = excluded.libelle, gravite = excluded.gravite, categorie = excluded.categorie, explication = excluded.explication;

-- Branchement des alertes de mandat dans le contrôle toutes les 30 minutes (ajout à la fin de suivi_detections)
do $do$
declare def text;
begin
  def := pg_get_functiondef('pilotage.suivi_detections'::regproc);
  if position('suivi_detections_mandats' in def) = 0 then
    execute regexp_replace(def, '\s*\$function\$\s*$', E'\n  union all\n  select * from pilotage.suivi_detections_mandats()\n$function$\n');
  end if;
end $do$;

revoke all on all functions in schema pilotage from public, anon, authenticated;
revoke all on function public.pilotage_mandat_obligation(text, bigint, text, text, integer, date, boolean, text), public.pilotage_mandat_obligation_realisee(bigint, date, date) from public, anon;
grant execute on function public.pilotage_mandat_obligation(text, bigint, text, text, integer, date, boolean, text), public.pilotage_mandat_obligation_realisee(bigint, date, date),
  public.pilotage_suivi_etape(text, text, text, boolean), public.pilotage_mandat_dossier(text) to authenticated;

select pilotage.mandats_suivis_auto();
select cron.unschedule('pilotage-suivis-mandats') where exists (select 1 from cron.job where jobname = 'pilotage-suivis-mandats');
select cron.schedule('pilotage-suivis-mandats', '20,50 * * * *', $$ select pilotage.mandats_suivis_auto() $$);
