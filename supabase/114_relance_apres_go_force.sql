-- 114 — Un GO ou un forçage n'arrête plus la relance des points restants d'un nouveau bail (Nicolas, 31/10/2026).
-- Avant : etapes_detections excluait tout bail avec GO ou forçage ; un dossier forcé avec des points restants n'était plus relancé.
-- Désormais :
--   - bail_dossier_a_completer (commercial) : continue tant qu'il reste des points du commercial, même après forçage ou GO ;
--     le titre précise « dossier forcé » ou « GO donné ».
--   - nouvelle règle bail_go_restants_gestion (gestion) : GO donné (forcé) avec des points de la gestion encore à traiter.
--   - bail_incomplet_entree (gestionnaire) : inchangée, s'arrête au forçage ou au GO (la gestion a décidé en connaissance de cause,
--     le commercial reste relancé par sa propre alerte).
-- Au 31/10, 22 h 40 : aucun bail concerné (509 et 511 ont le GO, plus aucun point restant).
-- Le reste de etapes_detections est repris à l'identique de la version en base (109). Un seul bloc.

begin;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire) values
 ('bail_go_restants_gestion', 'GO donné, points de la gestion encore à traiter', 'Baux habitation', 'haute', 'controle', true,
  'GO du contrôle d''entrée donné sur un dossier forcé alors que des points de la gestion restent à traiter (pièces de l''agence, clauses à lire). L''alerte disparaît quand ils sont traités.',
  '[]'::jsonb, 'gestion')
on conflict (cle) do nothing;

create or replace function pilotage.etapes_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $function$
  with s as (
    select b.id, b.reference, b.locataires, pilotage.sortie_prevue(b.id) sortie, f.edl_par, f.edl_commande_le,
           pilotage.edl_sortie_le(b.id) edl_le, f.edl_heure, f.edl_maj_le,
           'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id lien
      from pilotage.v_baux b left join pilotage.fiches_conge f on f.bail_id = b.id
     where b.statut = 'move_out'),
  nv as (
    select b.id, b.reference, b.locataires, b.debut, pilotage.bail_restants(b.id) r,
           f.go_le is not null go, (pilotage.forcage_actif('bail', b.id)).id is not null force,
           'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id lien
      from pilotage.v_baux b left join pilotage.baux_fiche f on f.bail_id = b.id
     where b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > current_date)
       and pilotage.dossier_nouveau('LeasingContract', b.id)),
  n as (select nv.*, (nv.r->>'commercial')::int nb,
               (select string_agg(x, ', ') from (select jsonb_array_elements_text(nv.r->'liste_commercial') x limit 6) z)
                 || case when (nv.r->>'commercial')::int > 6 then '…' else '' end manque
          from nv where (nv.r->>'commercial')::int > 0),
  g as (select nv.*, (nv.r->>'gestion')::int nb,
               (select string_agg(x, ', ') from (select jsonb_array_elements_text(nv.r->'liste_gestion') x limit 6) z)
                 || case when (nv.r->>'gestion')::int > 6 then '…' else '' end manque
          from nv where nv.go and (nv.r->>'gestion')::int > 0)
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
  -- 100 + 114 : dossier d'un nouveau bail incomplet côté commercial, relancé même après forçage ou GO
  select 'bail_dossier_a_completer', 'LeasingContract', n.id,
         'Bail ' || coalesce(n.reference, '') || ' : dossier à compléter (' || n.nb || ' point' || case when n.nb > 1 then 's' else '' end || ')'
           || case when n.go then ', GO donné' when n.force then ', dossier forcé' else '' end,
         'Entrée le ' || to_char(n.debut, 'DD/MM/YYYY') || ' · ' || coalesce(n.locataires, '?') || ' — manque : ' || n.manque, n.lien
    from n
  union all
  -- 100 : le jour de la date d'effet au plus tard, la gestionnaire est prévenue ; s'arrête au forçage ou au GO
  select 'bail_incomplet_entree', 'LeasingContract', n.id,
         'Bail ' || coalesce(n.reference, '') || ' commencé le ' || to_char(n.debut, 'DD/MM/YYYY') || ' : dossier incomplet chez le commercial',
         coalesce('Commercial : ' || pilotage.prenom_membre(pilotage.commercial_dossier('bail', n.id)), 'Aucun commercial rattaché')
           || ' · ' || coalesce(n.locataires, '?') || ' — manque : ' || n.manque, n.lien
    from n where n.debut <= current_date and not n.go and not n.force
  union all
  -- 114 : GO donné (forcé) avec des points de la gestion encore à traiter
  select 'bail_go_restants_gestion', 'LeasingContract', g.id,
         'Bail ' || coalesce(g.reference, '') || ' : GO donné, ' || g.nb || ' point' || case when g.nb > 1 then 's' else '' end || ' de la gestion à traiter',
         'Entrée le ' || to_char(g.debut, 'DD/MM/YYYY') || ' · ' || coalesce(g.locataires, '?') || ' — reste : ' || g.manque, g.lien
    from g
  union all
  -- 109 : EDL d'entrée le jour de l'entrée, heure à fixer, puis rendez-vous à confirmer au locataire
  select 'edl_entree_a_organiser', 'LeasingContract', b.id,
         case when e.edl_heure is null
              then 'État des lieux d''entrée à organiser : bail ' || coalesce(b.reference, '') || ', le ' || to_char(coalesce(e.edl_le, b.debut), 'DD/MM/YYYY') || ', heure à fixer'
              else 'État des lieux d''entrée le ' || to_char(coalesce(e.edl_le, b.debut), 'DD/MM/YYYY') || ' à ' || e.edl_heure
                   || ' : rendez-vous à confirmer au locataire (bail ' || coalesce(b.reference, '') || ')' end,
         'Locataires : ' || coalesce(b.locataires, '?')
           || case when e.edl_heure is null
                   then ' — le jour de l''entrée par défaut ; fixer l''heure dans les messages du bail (étape « État des lieux d''entrée »), puis envoyer la confirmation (mail) et le rappel (SMS)'
                   else ' — envoyer la confirmation (mail) et le rappel (SMS), étape « État des lieux d''entrée »' end,
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
    from pilotage.v_baux b left join pilotage.edl_entree e on e.bail_id = b.id
   where b.statut in ('created', 'move_in', 'in_progress') and pilotage.dossier_nouveau('LeasingContract', b.id)
     and coalesce(e.edl_le, b.debut) between current_date
         and current_date + coalesce((select k.jours_avant from pilotage.messages_categories k where k.cle = 'edl_entree'), 21)
     and not (e.edl_heure is not null
              and exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = b.id and j.code = 'ee_locataire_email'
                            and j.le >= coalesce(e.maj_le, '-infinity'::timestamptz)))
$function$;
revoke all on function pilotage.etapes_detections() from public, anon, authenticated;

select pilotage.executer_controles();

commit;

-- Vérification : la règle existe et la fonction contient le bloc 114 (vrai, vrai)
select exists (select 1 from pilotage.regles where cle = 'bail_go_restants_gestion') as regle_114,
       position('bail_go_restants_gestion' in pg_get_functiondef('pilotage.etapes_detections'::regproc)) > 0 as detection_114;
