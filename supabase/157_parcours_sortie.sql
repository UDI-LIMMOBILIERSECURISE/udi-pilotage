-- 157 : parcours de sortie en étapes, alertes enchaînées, comparaison des EDL, notes et tâches du lot (décisions de Nicolas du 12/11/2026)
--  Parcours (écran Sorties et DG) : 1 congé reçu (accusé au locataire, information du bailleur et demande du dépôt) → 2 décision du
--  bailleur (relouer, travaux, reprendre, vendre) → 3 pré-visite (si relocation) → 4 état des lieux de sortie → 5 départ et clés
--  → 6 comparaison des EDL d'entrée et de sortie → 7 dépôt de garantie. Une seule étape ouverte, les suivantes s'enchaînent dans la fiche.
--  Alertes :
--   - « Congé reçu » : fermée quand le locataire (mail OU SMS) et le bailleur (mail ou SMS) sont prévenus, ou marqués « pas nécessaire »
--     (avant : mail au locataire exigé) ;
--   - « EDL de sortie à commander » : seulement à partir du lendemain de l'étape 1 (si la gestionnaire enchaîne dans la fiche, elle ne la
--     voit pas), ou d'office si le départ est dans 21 jours ou moins (paramètre « jours_avant_depart » de la règle) ;
--   - nouvelle « Réponse du bailleur à obtenir » : 7 jours après l'étape 1 sans suite choisie (paramètre « jours ») ;
--   - nouvelle « Comparer les EDL d'entrée et de sortie » : 10 jours après l'EDL de sortie (paramètre « jours_apres_edl »), case « fait »
--     dans la fiche ; dossiers sortis depuis la date de reprise seulement, pas sur un dossier clôturé dans le pilotage.
--  Décision du bailleur : choisie par la gestionnaire (appel, mail) ; colonnes prêtes pour la proposition de l'IA à partir des mails
--  reçus du bailleur (lot suivant), toujours confirmée par la gestionnaire.
--  Notes et tâches : celles du lot (tables du permis de louer, 126), avec un contexte « sortie » ; une tâche arrive dans Ma journée de la
--  personne choisie à son échéance (gestion ou commerciaux).
--  Les fonctions pilotage.etapes_detections et pilotage.permis_taches_detections sont complétées sur place ; le bloc s'arrête sans rien
--  modifier si un texte attendu manque. Bloc unique.

begin;

-- 1. Données du parcours
alter table pilotage.fiches_conge
  add column if not exists suite_source text, add column if not exists suite_le timestamptz, add column if not exists suite_par uuid,
  add column if not exists suite_proposee text, add column if not exists suite_proposee_mail bigint, add column if not exists suite_proposee_le timestamptz,
  add column if not exists edl_compare_le timestamptz, add column if not exists edl_compare_par uuid;
alter table pilotage.fiches_conge drop constraint if exists fiches_conge_suite_source_check;
alter table pilotage.fiches_conge add constraint fiches_conge_suite_source_check check (suite_source is null or suite_source in ('gestion', 'ia_confirmee'));

alter table pilotage.permis_taches add column if not exists contexte text not null default 'permis';
alter table pilotage.permis_notes add column if not exists contexte text not null default 'permis';

-- Étape 1 faite le : locataire (mail ou SMS) ET bailleur (mail ou SMS) prévenus, ou marqués « pas nécessaire »
create or replace function pilotage.conge_accuse_le(p_bail text) returns date
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select case when x.l is not null and x.b is not null then greatest(x.l, x.b)::date end
    from (select max(j.le) filter (where j.code in ('cg_locataire_email', 'cg_locataire_sms')) l,
                 max(j.le) filter (where j.code in ('cg_bailleur_email', 'cg_bailleur_sms')) b
            from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = p_bail) x
$$;
revoke all on function pilotage.conge_accuse_le(text) from public, anon, authenticated;

-- 2. Règles
insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, destinataire, explication, parametres) values
 ('conge_suite_bailleur', 'Congé : réponse du bailleur à obtenir', 'Baux habitation', 'haute', 'tache', true, 'gestion',
  'Le bailleur a été prévenu du départ de son locataire et n''a pas dit ce qu''il veut faire du bien (relouer, travaux, reprendre, vendre). Le relancer ; sa réponse, par mail ou par téléphone, se note dans le parcours de sortie.',
  '[{"nom": "jours", "unite": "jours", "valeur": 7, "libelle": "Après l''information du bailleur"}]'::jsonb),
 ('edl_comparer', 'Comparer les états des lieux d''entrée et de sortie', 'Baux habitation', 'haute', 'tache', true, 'gestion',
  'L''état des lieux de sortie est passé : comparer avec celui d''entrée pour décider des retenues sur le dépôt de garantie (restitution sous 1 mois si conforme, 2 mois sinon). Cocher « Comparaison faite » dans le parcours de sortie.',
  '[{"nom": "jours_apres_edl", "unite": "jours", "valeur": 10, "libelle": "Après l''état des lieux de sortie"}]'::jsonb)
on conflict (cle) do nothing;
update pilotage.regles set parametres = coalesce(parametres, '[]'::jsonb)
  || '[{"nom": "jours_avant_depart", "unite": "jours", "valeur": 21, "libelle": "D''office quand le départ est dans"}]'::jsonb
 where cle = 'edl_sortie_a_commander' and not coalesce(parametres, '[]'::jsonb) @> '[{"nom": "jours_avant_depart"}]'::jsonb;

-- 3. Alertes enchaînées (complément sur place de pilotage.etapes_detections)
do $bloc$
declare d text; a text; b text;
begin
  d := replace(pg_get_functiondef('pilotage.etapes_detections()'::regprocedure), E'\r\n', E'\n');
  if position('conge_accuse_le' in d) = 0 then
    a := $t$     and not (exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = s.id and j.code = 'cg_locataire_email')
          and exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = s.id and j.code = 'cg_bailleur_email'))$t$;
    if position(a in d) = 0 then raise exception '157 : condition « congé reçu » introuvable, rien n''est modifié'; end if;
    d := replace(d, a, '     and pilotage.conge_accuse_le(s.id) is null');
    a := 'where s.sortie >= current_date and s.edl_commande_le is null and not (s.edl_le is not null and s.edl_heure is not null)';
    if position(a in d) = 0 then raise exception '157 : condition « EDL à commander » introuvable, rien n''est modifié'; end if;
    d := replace(d, a, a || E'\n     and (s.sortie <= current_date + pilotage.param(''edl_sortie_a_commander'', ''jours_avant_depart'', 21)::int'
                         || E'\n          or pilotage.conge_accuse_le(s.id) < current_date)');
    b := $t$
  union all
  -- 157 : réponse du bailleur à obtenir (7 jours après son information, aucune suite choisie)
  select 'conge_suite_bailleur', 'LeasingContract', s.id,
         'Congé : réponse du bailleur à obtenir (bail ' || coalesce(s.reference, '') || ', départ le ' || to_char(s.sortie, 'DD/MM/YYYY') || ')',
         'Locataires : ' || coalesce(s.locataires, '?') || ' — bailleur prévenu le ' || to_char(pilotage.conge_accuse_le(s.id), 'DD/MM/YYYY')
           || ' : le relancer pour savoir s''il reloue, fait des travaux, reprend ou vend le bien ; noter sa réponse dans le parcours de sortie', s.lien
    from s
   where s.sortie >= current_date - 30
     and pilotage.conge_accuse_le(s.id) <= current_date - pilotage.param('conge_suite_bailleur', 'jours', 7)::int
     and not exists (select 1 from pilotage.fiches_conge f where f.bail_id = s.id and f.suite is not null)
  union all
  -- 157 : comparer les états des lieux d'entrée et de sortie, 10 jours après l'EDL de sortie
  select 'edl_comparer', 'LeasingContract', b.id,
         'Comparer les états des lieux d''entrée et de sortie (bail ' || coalesce(b.reference, '') || ', EDL de sortie du ' || to_char(pilotage.edl_sortie_le(b.id), 'DD/MM/YYYY') || ')',
         'Locataires : ' || coalesce(b.locataires, '?') || ' — décider des retenues sur le dépôt de garantie, puis cocher « Comparaison faite » dans le parcours de sortie',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
    from pilotage.v_baux b
   where b.statut in ('move_out', 'closed')
     and pilotage.edl_sortie_le(b.id) between pilotage.date_reference()
         and current_date - pilotage.param('edl_comparer', 'jours_apres_edl', 10)::int
     and not exists (select 1 from pilotage.fiches_conge f where f.bail_id = b.id and f.edl_compare_le is not null)
     and not exists (select 1 from pilotage.dg_suivi z where z.bail_id = b.id and z.clos_le is not null)
$function$$t$;
    if d !~ '\$function\$\s*$' then raise exception '157 : fin de pilotage.etapes_detections introuvable, rien n''est modifié'; end if;
    d := regexp_replace(d, '\n?\$function\$\s*$', b);
    execute d;
  end if;

  -- Tâches : le titre dit d'où vient la tâche (permis de louer ou sortie)
  d := replace(pg_get_functiondef('pilotage.permis_taches_detections()'::regprocedure), E'\r\n', E'\n');
  if position('contexte' in d) = 0 then
    a := $t$|| ' · permis de louer : ' || t.libelle$t$;
    if position(a in d) = 0 then raise exception '157 : titre des tâches introuvable, rien n''est modifié'; end if;
    d := replace(d, a, $t$|| case when t.contexte = 'sortie' then ' · sortie : ' else ' · permis de louer : ' end || t.libelle$t$);
    execute d;
  end if;
end $bloc$;

-- 4. Lecture et actions du parcours (gestion : pilotage.peut_suivre_baux ; lecture : membres)
create or replace function public.pilotage_parcours_sortie(p_bail text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare b record; f pilotage.fiches_conge;
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  select id, reference, lot_id, statut, debut, fin, locataires, depot_garantie into b from pilotage.v_baux where id = p_bail;
  if b.id is null then raise exception 'Bail inconnu'; end if;
  select * into f from pilotage.fiches_conge where bail_id = p_bail;
  return jsonb_build_object(
    'peut', pilotage.peut_suivre_baux(), 'bail', p_bail, 'lot_id', b.lot_id, 'statut', b.statut, 'depot', b.depot_garantie,
    'sortie', pilotage.sortie_prevue(p_bail), 'sortie_reelle', pilotage.date_sortie_reelle(p_bail),
    'edl_le', pilotage.edl_sortie_le(p_bail), 'accuse_le', pilotage.conge_accuse_le(p_bail),
    'fiche', case when f.bail_id is null then null else to_jsonb(f) - 'maj_par' - 'suite_par' - 'edl_compare_par'
      || jsonb_build_object('suite_par_prenom', (select prenom from pilotage.membres where user_id = f.suite_par),
                            'edl_compare_par_prenom', (select prenom from pilotage.membres where user_id = f.edl_compare_par)) end,
    'journal', coalesce((select jsonb_object_agg(x.code, jsonb_build_object('le', x.le, 'moyen', x.moyen)) from (
        select distinct on (j.code) j.code, j.le, j.moyen from pilotage.messages_journal j
         where j.objet = 'bail' and j.objet_id = p_bail order by j.code, j.le desc) x), '{}'::jsonb),
    'dg', (select to_jsonb(s) - 'par' - 'clos_par' from pilotage.dg_suivi s where s.bail_id = p_bail),
    'dg_detenu_rivage', pilotage.dg_detenteur_rivage(p_bail),
    'cles', (select count(*) from pilotage.cles_trousseaux t where t.asset_id = b.lot_id and t.supprime_le is null));
end $$;

-- p_action : suite (p_valeur = relouer | travaux | reprise | vente | vide), confirmer_suite, ecarter_suite, edl_compare, edl_compare_annuler
create or replace function public.pilotage_parcours_sortie_maj(p_bail text, p_action text, p_valeur text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare f pilotage.fiches_conge;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.v_baux where id = p_bail) then raise exception 'Bail inconnu'; end if;
  insert into pilotage.fiches_conge (bail_id, maj_par, maj_le) values (p_bail, auth.uid(), now()) on conflict (bail_id) do nothing;
  select * into f from pilotage.fiches_conge where bail_id = p_bail;
  if p_action = 'suite' then
    if nullif(p_valeur, '') is not null and p_valeur not in ('relouer', 'travaux', 'reprise', 'vente') then raise exception 'Suite inconnue'; end if;
    update pilotage.fiches_conge set suite = nullif(p_valeur, ''), suite_source = case when nullif(p_valeur, '') is null then null else 'gestion' end,
           suite_le = case when nullif(p_valeur, '') is null then null else now() end, suite_par = auth.uid(), maj_par = auth.uid(), maj_le = now()
     where bail_id = p_bail;
  elsif p_action = 'confirmer_suite' then
    if f.suite_proposee is null then raise exception 'Aucune proposition'; end if;
    update pilotage.fiches_conge set suite = f.suite_proposee, suite_source = 'ia_confirmee', suite_le = now(), suite_par = auth.uid(),
           suite_proposee = null, maj_par = auth.uid(), maj_le = now() where bail_id = p_bail;
  elsif p_action = 'ecarter_suite' then
    update pilotage.fiches_conge set suite_proposee = null, suite_proposee_mail = null, suite_proposee_le = null, maj_le = now() where bail_id = p_bail;
  elsif p_action = 'edl_compare' then
    update pilotage.fiches_conge set edl_compare_le = now(), edl_compare_par = auth.uid(), maj_par = auth.uid(), maj_le = now() where bail_id = p_bail;
  elsif p_action = 'edl_compare_annuler' then
    update pilotage.fiches_conge set edl_compare_le = null, edl_compare_par = null, maj_par = auth.uid(), maj_le = now() where bail_id = p_bail;
  else raise exception 'Action inconnue'; end if;
  return public.pilotage_parcours_sortie(p_bail);
end $$;

-- Notes et tâches du lot avec leur contexte (sortie), mêmes droits que le permis (pilotage.peut_traiter_lot)
create or replace function public.pilotage_lot_note(p_asset text, p_contenu text, p_supprimer bigint, p_contexte text) returns bigint
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v bigint;
begin
  v := public.pilotage_permis_note(p_asset, p_contenu, p_supprimer);
  if p_supprimer is null then update pilotage.permis_notes set contexte = coalesce(nullif(p_contexte, ''), 'permis') where id = v; end if;
  return v;
end $$;
create or replace function public.pilotage_lot_tache(p_action text, p_id bigint, p_asset text, p_libelle text, p_echeance date, p_assigne uuid, p_contexte text)
returns bigint language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v bigint;
begin
  v := public.pilotage_permis_tache(p_action, p_id, p_asset, null, p_libelle, p_echeance, p_assigne);
  if p_action = 'creer' then update pilotage.permis_taches set contexte = coalesce(nullif(p_contexte, ''), 'permis') where id = v; end if;
  return v;
end $$;

do $$
declare f text;
begin
  foreach f in array array['pilotage_parcours_sortie(text)', 'pilotage_parcours_sortie_maj(text, text, text)',
    'pilotage_lot_note(text, text, bigint, text)', 'pilotage_lot_tache(text, bigint, text, text, date, uuid, text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

select pilotage.executer_controles();

commit;

-- Vérification : select public.pilotage_parcours_sortie(id) from pilotage.v_baux where reference = '279';  (connecté)
--               select regle, count(*) from pilotage.alertes where regle in ('conge_recu','edl_sortie_a_commander','conge_suite_bailleur','edl_comparer') and statut = 'ouverte' group by 1;
