-- 154 : clôturer un dossier de sortie / dépôt de garantie dans le pilotage sans remplir la fiche du congé (demande de Nicolas du 12/11/2026)
--  Pour le stock (départs anciens, bail resté « en sortie » dans Rivage, dépôt réglé hors Rivage) : bouton « Clôturer le dossier » dans
--  Sorties et DG, avec un motif obligatoire (dépôt restitué hors Rivage, pas de dépôt à restituer, dépôt imputé sur la dette du locataire,
--  autre avec précision), tracé (date, personne). Réversible (« Rouvrir »).
--  Effets : le dossier sort des listes de Sorties et DG (filtre « Clôturés ») ; l'étape « Dépôt de garantie restitué » de la frise du bien
--  passe à fait ; plus d'alerte de dépôt pour ce bail. Inchangé : le badge et l'étape « Bail à clôturer dans Rivage » tant que le bail est
--  « en sortie » dans Rivage (donnée Rivage, à clôturer dans Rivage).
--  Droits : direction, superviseur, gestionnaire, comptable (comme le suivi du dépôt).
--  Les fonctions pilotage.suivi_detections_dg et pilotage.biens sont complétées sur place ; le bloc s'arrête sans rien modifier si un texte
--  attendu manque. Bloc unique.

begin;

alter table pilotage.dg_suivi add column if not exists clos_le timestamptz, add column if not exists clos_par uuid,
  add column if not exists clos_motif text, add column if not exists clos_note text;
alter table pilotage.dg_suivi drop constraint if exists dg_suivi_clos_motif_check;
alter table pilotage.dg_suivi add constraint dg_suivi_clos_motif_check
  check (clos_motif is null or clos_motif in ('restitue_hors_rivage', 'pas_de_depot', 'impute_dette', 'autre'));

create or replace function public.pilotage_dg_clore(p_bail text, p_motif text, p_note text) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.objets where type = 'LeasingContract' and id = p_bail) then raise exception 'Bail inconnu'; end if;
  insert into pilotage.dg_suivi (bail_id, par) values (p_bail, auth.uid()) on conflict (bail_id) do nothing;
  if nullif(p_motif, '') is null then  -- rouvrir
    update pilotage.dg_suivi set clos_le = null, clos_par = null, clos_motif = null, clos_note = null, par = auth.uid(), maj_le = now() where bail_id = p_bail;
    return;
  end if;
  if p_motif = 'autre' and nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'Préciser le motif'; end if;
  update pilotage.dg_suivi set clos_le = now(), clos_par = auth.uid(), clos_motif = p_motif, clos_note = nullif(trim(coalesce(p_note, '')), ''),
         par = auth.uid(), maj_le = now() where bail_id = p_bail;
end $$;
revoke all on function public.pilotage_dg_clore(text, text, text) from public, anon;
grant execute on function public.pilotage_dg_clore(text, text, text) to authenticated;

do $bloc$
declare d text; a text;
begin
  -- Alertes de dépôt : pas pour un dossier clos dans le pilotage
  d := replace(pg_get_functiondef('pilotage.suivi_detections_dg()'::regprocedure), E'\r\n', E'\n');
  if position('clos_le' in d) = 0 then
    a := 'with d as (select * from pilotage.dg_dossiers() where not remboursee and';
    if position(a in d) = 0 then raise exception '154 : texte attendu introuvable dans pilotage.suivi_detections_dg, rien n''est modifié'; end if;
    d := replace(d, a, 'with d as (select * from pilotage.dg_dossiers() x where not x.remboursee'
                       || ' and not exists (select 1 from pilotage.dg_suivi z where z.bail_id = x.bail_id and z.clos_le is not null) and');
    execute d;
  end if;
  -- Frise du bien : dépôt considéré comme restitué
  d := replace(pg_get_functiondef('pilotage.biens(uuid)'::regprocedure), E'\r\n', E'\n');
  if position('clos_le' in d) = 0 then
    a := 'and coalesce((g.data->>''deposit_refunded'')::boolean, false)) end dg_rendu';
    if position(a in d) = 0 then raise exception '154 : texte attendu introuvable dans pilotage.biens, rien n''est modifié'; end if;
    d := replace(d, a, 'and coalesce((g.data->>''deposit_refunded'')::boolean, false))'
                       || ' or exists (select 1 from pilotage.dg_suivi z where z.bail_id = q.bail_id and z.clos_le is not null) end dg_rendu');
    execute d;
  end if;
end $bloc$;

select pilotage.executer_controles();

commit;
