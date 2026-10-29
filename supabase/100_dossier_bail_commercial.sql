-- 100 — Nouveau bail : le dossier reste chez le commercial tant qu'il n'est pas complet ; la gestionnaire est prévenue au plus tard
-- le jour de la date d'effet (Nicolas, 30/10/2026).
-- Constat sur le bail 509 : l'alerte « contrôle d'entrée à valider » est partie chez Marion dès la création, avec 19 points dont la
-- plupart relèvent du commercial (pièces absentes de Rivage, choix du dossier).
-- Décisions de Nicolas (30/10) :
--   1. Chaque point du contrôle d'entrée appartient au commercial ou à la gestion (nouvelle colonne controle_questions.qui).
--      Gestion : les pièces établies par l'agence (bail signé, déposé une fois signé ; état des lieux d'entrée ; actes) et les
--      clauses qui demandent de lire le bail (clause résolutoire, exécution substitutive ; en commercial, les clauses du bail).
--      Commercial : tout le reste (pièces du bailleur et du locataire, écarts Rivage, choix : entretien, compteurs, assurance,
--      caution ; type, DPE et plus de 65 ans se règlent seuls depuis Rivage).
--   2. Alerte « Dossier à compléter » au commercial du bail (sinon à tous les commerciaux) tant que sa partie n'est pas complète.
--   3. Alerte « Nouveau bail commencé, dossier incomplet » à la gestionnaire à partir de la date d'effet, pour vérifier ce qui
--      manque ; la complétion reste au commercial. Elle disparaît quand le commercial a fini.
--   4. « Contrôle d'entrée à valider » ne part chez la gestionnaire qu'une fois la partie du commercial complète (ou forcée).
--      Le circuit (À finaliser → En attente de validation) suit la même règle ; le GO exige toujours tous les points.
-- Aussi : alerte « DG au-delà du plafond » calculée avec le type de bail de Rivage (meublé et étudiant : 2 mois ; mobilité :
-- aucun dépôt autorisé ; vide : 1 mois). Le bail 509 (meublé dans Rivage, 2 mois) sort de l'alerte.
-- Fonctions modifiées : restants_par_qui, bail_restants (nouvelles), controle_bail, etat_dossier, suivi_detections,
-- executer_controles (remplacements ciblés, contrôlés), etapes_detections (remplacée).
-- Pré-requis : script 099 passé. Un seul bloc.

begin;

do $do$ begin
  if to_regprocedure('pilotage.type_bail_rivage(text)') is null then raise exception 'Passer d''abord le script 099'; end if;
end $do$;

alter table pilotage.controle_questions add column if not exists qui text not null default 'commercial';
alter table pilotage.controle_questions drop constraint if exists controle_questions_qui_check;
alter table pilotage.controle_questions add constraint controle_questions_qui_check check (qui in ('commercial', 'gestion'));
update pilotage.controle_questions set qui = 'gestion'
 where portee in ('habitation', 'commercial')
   and ((bloc = 'pieces' and fournisseur = 'agence')
        or cle in ('h_cl_resolutoire', 'h_cl_exec')
        or (portee = 'commercial' and bloc = 'clauses' and cle not in ('c_cl_type', 'c_cl_dpe', 'c_cl_assurance', 'c_cl_entretien')));

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire) values
 ('bail_dossier_a_completer', 'Nouveau bail : dossier à compléter', 'Baux habitation', 'haute', 'controle', true,
  'Nouveau bail dont la partie du commercial n''est pas complète : pièces du bailleur et du locataire à déposer dans Rivage, écarts Rivage à corriger, choix du dossier (entretien, compteurs, assurance, caution). Le bail signé et l''état des lieux d''entrée sont attendus après la signature. Va au commercial du bail, sinon à tous les commerciaux.',
  '[]'::jsonb, 'commercial'),
 ('bail_incomplet_entree', 'Nouveau bail commencé, dossier incomplet chez le commercial', 'Baux habitation', 'haute', 'controle', true,
  'Date d''effet atteinte et dossier du commercial toujours incomplet : vérifier ce qui manque et relancer le commercial. La complétion reste au commercial ; l''alerte disparaît quand il a fini, le contrôle d''entrée arrive alors à la gestionnaire.',
  '[]'::jsonb, 'gestion')
on conflict (cle) do nothing;

-- Points restant à traiter, par responsable, à partir des points du contrôle d'entrée
create or replace function pilotage.restants_par_qui(p_items jsonb) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object(
    'commercial', count(*) filter (where coalesce(i->>'qui', q.qui, 'commercial') = 'commercial'),
    'gestion', count(*) filter (where coalesce(i->>'qui', q.qui, 'commercial') = 'gestion'),
    'liste_commercial', coalesce(jsonb_agg(i->>'libelle') filter (where coalesce(i->>'qui', q.qui, 'commercial') = 'commercial'), '[]'::jsonb),
    'liste_gestion', coalesce(jsonb_agg(i->>'libelle') filter (where coalesce(i->>'qui', q.qui, 'commercial') = 'gestion'), '[]'::jsonb))
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
  left join pilotage.controle_questions q on q.cle = i->>'cle'
  where coalesce((i->>'a_traiter')::boolean, false)
$$;

create or replace function pilotage.bail_restants(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select pilotage.restants_par_qui(pilotage.controle_bail(p_bail)->'items')
$$;
revoke all on function pilotage.restants_par_qui(jsonb), pilotage.bail_restants(text) from public, anon, authenticated;

do $do$
declare d text;
begin
  -- controle_bail : chaque point indique son responsable
  d := pg_get_functiondef('pilotage.controle_bail(text)'::regprocedure);
  if position($r$'qui', q.qui$r$ in d) = 0 then
    if position($r$'auto', auto, 'detail', detail,$r$ in d) = 0 then raise exception 'controle_bail : point d''insertion introuvable'; end if;
    d := replace(d, $r$'auto', auto, 'detail', detail,$r$, $r$'qui', q.qui, 'auto', auto, 'detail', detail,$r$);
    execute d;
  end if;
  -- etat_dossier : pour un bail, « En attente de validation » dès que la partie du commercial est complète
  d := pg_get_functiondef('pilotage.etat_dossier(text,text)'::regprocedure);
  if position('restants_par_qui' in d) = 0 then
    if position($r$pilotage.etat_calcule(soumis, valide is not null, (c->>'restant')::integer,$r$ in d) = 0 then raise exception 'etat_dossier : calcul de l''état introuvable'; end if;
    d := replace(d, $r$pilotage.etat_calcule(soumis, valide is not null, (c->>'restant')::integer,$r$,
      $r$pilotage.etat_calcule(soumis, valide is not null, case when p_objet = 'bail' then (pilotage.restants_par_qui(c->'items')->>'commercial')::integer else (c->>'restant')::integer end,$r$);
    execute d;
  end if;
  -- suivi_detections : le contrôle d'entrée n'arrive à la gestionnaire qu'une fois la partie du commercial complète (ou forcée)
  d := pg_get_functiondef('pilotage.suivi_detections()'::regprocedure);
  if position('bail_restants' in d) = 0 then
    if position($r$where f.go_le is null and (pilotage.dossier_nouveau('LeasingContract', b.id))$r$ in d) = 0 then raise exception 'suivi_detections : contrôle d''entrée introuvable'; end if;
    d := replace(d, $r$where f.go_le is null and (pilotage.dossier_nouveau('LeasingContract', b.id))$r$,
      $r$where f.go_le is null and (pilotage.dossier_nouveau('LeasingContract', b.id))
    and ((pilotage.bail_restants(b.id)->>'commercial')::int = 0 or (pilotage.forcage_actif('bail', b.id)).id is not null)$r$);
    execute d;
  end if;
  -- executer_controles : plafond du dépôt selon le type de bail de Rivage
  d := pg_get_functiondef('pilotage.executer_controles()'::regprocedure);
  if position('type_bail_rivage' in d) = 0 then
    if position($r$and loyer_hc > 0 and depot_garantie > loyer_hc and pilotage.dossier_nouveau('LeasingContract', id)$r$ in d) = 0 then raise exception 'executer_controles : règle dg_plafond introuvable'; end if;
    d := replace(d, $r$and loyer_hc > 0 and depot_garantie > loyer_hc and pilotage.dossier_nouveau('LeasingContract', id)$r$,
      $r$and loyer_hc > 0 and pilotage.dossier_nouveau('LeasingContract', id)
    and depot_garantie > loyer_hc * (case pilotage.type_bail_rivage(id) when 'meuble' then 2 when 'etudiant' then 2 when 'mobilite' then 0 else 1 end)$r$);
    execute d;
  end if;
end $do$;

create or replace function pilotage.etapes_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  with s as (
    select b.id, b.reference, b.locataires, pilotage.sortie_prevue(b.id) sortie, f.edl_par, f.edl_commande_le,
           pilotage.edl_sortie_le(b.id) edl_le, f.edl_heure, f.edl_maj_le,
           'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id lien
      from pilotage.v_baux b left join pilotage.fiches_conge f on f.bail_id = b.id
     where b.statut = 'move_out'),
  nv as (
    select b.id, b.reference, b.locataires, b.debut, pilotage.bail_restants(b.id) r,
           'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id lien
      from pilotage.v_baux b left join pilotage.baux_fiche f on f.bail_id = b.id
     where b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > current_date)
       and f.go_le is null and pilotage.dossier_nouveau('LeasingContract', b.id)
       and (pilotage.forcage_actif('bail', b.id)).id is null),
  n as (select nv.*, (nv.r->>'commercial')::int nb,
               (select string_agg(x, ', ') from (select jsonb_array_elements_text(nv.r->'liste_commercial') x limit 6) z)
                 || case when (nv.r->>'commercial')::int > 6 then '…' else '' end manque
          from nv where (nv.r->>'commercial')::int > 0)
  select 'bail_a_signer'::text, 'LeasingContract'::text, b.id,
         'Bail ' || coalesce(b.reference, '') || ' à signer : entrée le ' || to_char(b.debut, 'DD/MM/YYYY'),
         'Locataires : ' || coalesce(b.locataires, '?') || ' — envoyer au locataire le récapitulatif et le virement d''entrée, prévenir le bailleur',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
    from pilotage.v_baux b
   where b.statut = 'created' and b.debut >= current_date - 5 and pilotage.dossier_nouveau('LeasingContract', b.id)
     and not (exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = b.id and j.code = 'nb_locataire_email')
          and exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = b.id and j.code = 'nb_bailleur_email'))
  union all
  select 'conge_recu', 'LeasingContract', s.id,
         'Congé reçu : bail ' || coalesce(s.reference, '') || ', départ le ' || to_char(s.sortie, 'DD/MM/YYYY'),
         'Locataires : ' || coalesce(s.locataires, '?') || ' — accuser réception au locataire, informer le bailleur'
           || case when pilotage.dg_detenteur(s.id) = 'bailleur' then ' et lui demander de reverser le dépôt de garantie' else '' end
           || ' ; décider s''il y a une pré-visite (fiche du congé)', s.lien
    from s
   where s.sortie >= current_date
     and not (exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = s.id and j.code = 'cg_locataire_email')
          and exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = s.id and j.code = 'cg_bailleur_email'))
  union all
  select 'edl_sortie_a_commander', 'LeasingContract', s.id,
         'État des lieux de sortie à commander : bail ' || coalesce(s.reference, '') || ', départ le ' || to_char(s.sortie, 'DD/MM/YYYY'),
         'Locataires : ' || coalesce(s.locataires, '?') || ' — commander l''EDL (prestataire ou interne), prévenir le locataire qu''il va être contacté '
           || '(logement vide, propre, électricité active), puis saisir l''heure du rendez-vous dans la fiche du congé', s.lien
    from s
   where s.sortie >= current_date and s.edl_commande_le is null and not (s.edl_le is not null and s.edl_heure is not null)
  union all
  select 'edl_sortie_a_confirmer', 'LeasingContract', s.id,
         'État des lieux de sortie le ' || to_char(s.edl_le, 'DD/MM/YYYY') || ' à ' || s.edl_heure || ' : rendez-vous à confirmer au locataire (bail ' || coalesce(s.reference, '') || ')',
         'Locataires : ' || coalesce(s.locataires, '?') || ' — envoyer la confirmation (mail) et le rappel (SMS)', s.lien
    from s
   where s.edl_le >= current_date and s.edl_heure is not null
     and not exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = s.id and j.code = 'es_locataire_email'
                       and j.le >= coalesce(s.edl_maj_le, '-infinity'::timestamptz))
  union all
  -- 100 : dossier d'un nouveau bail incomplet côté commercial (pièces, écarts Rivage, choix), hors bail signé et EDL d'entrée
  select 'bail_dossier_a_completer', 'LeasingContract', n.id,
         'Bail ' || coalesce(n.reference, '') || ' : dossier à compléter (' || n.nb || ' point' || case when n.nb > 1 then 's' else '' end || ')',
         'Entrée le ' || to_char(n.debut, 'DD/MM/YYYY') || ' · ' || coalesce(n.locataires, '?') || ' — manque : ' || n.manque, n.lien
    from n
  union all
  -- 100 : le jour de la date d'effet au plus tard, la gestionnaire est prévenue ; la complétion reste au commercial
  select 'bail_incomplet_entree', 'LeasingContract', n.id,
         'Bail ' || coalesce(n.reference, '') || ' commencé le ' || to_char(n.debut, 'DD/MM/YYYY') || ' : dossier incomplet chez le commercial',
         coalesce('Commercial : ' || pilotage.prenom_membre(pilotage.commercial_dossier('bail', n.id)), 'Aucun commercial rattaché')
           || ' · ' || coalesce(n.locataires, '?') || ' — manque : ' || n.manque, n.lien
    from n where n.debut <= current_date
$$;
revoke all on function pilotage.etapes_detections() from public, anon, authenticated;

select pilotage.executer_controles();

commit;

-- Vérification : alertes du bail 509
-- select regle, statut, titre, detail from pilotage.alertes where objet_id = (select id from pilotage.v_baux where reference = '509') order by statut, regle;
