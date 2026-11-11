-- 142 : alerte « Loyer modifié dans Rivage (révision) » réservée aux baux commerciaux et professionnels (bloc unique)
--  Décision de Nicolas du 11/11/2026 : la révision des baux d'habitation (vide, meublé) se fait automatiquement dans Rivage ;
--  l'alerte qui demande d'informer le bailleur n'a de sens que pour les baux commerciaux, dérogatoires et professionnels.
--  Bail gardé si son type (fiche du bail, sinon Rivage) est commercial, dérogatoire ou professionnel, ou si le lot est un local
--  commercial ou un bureau. Les alertes déjà ouvertes sur des baux d'habitation se ferment au contrôle lancé en fin de script.

create or replace function pilotage.suivi_detections_loyers()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $function$
  select distinct on (h.bail_id) 'loyer_modifie', 'LeasingContract', h.bail_id,
         'Loyer modifié dans Rivage : ' || to_char(h.ancien_cents / 100.0, 'FM999G990D00') || ' € → ' || to_char(h.nouveau_cents / 100.0, 'FM999G990D00') || ' € HC (' || coalesce(b.locataires, '') || ')',
         'Changement enregistré le ' || to_char(h.le at time zone 'Europe/Paris', 'DD/MM/YYYY') || coalesce(' ; indice ' || upper(h.indice->>'nature') || ' ' || (h.indice->>'year') || ' T' || (h.indice->>'quarter') || ' : ' || (h.indice->>'value'), '')
           || '. Informer le bailleur (mail proposé), et vérifier le calcul si c''est une révision.',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || h.bail_id
  from pilotage.baux_loyers_historique h
  join pilotage.v_baux b on b.id = h.bail_id
  left join pilotage.v_lots l on l.id = b.lot_id
  where h.le > now() - make_interval(days => pilotage.param('loyer_modifie','jours_affichage',45)::int) and b.statut in ('move_in', 'in_progress')
    -- 142 : habitation exclue (révision automatique dans Rivage)
    and (coalesce((select bf.type_bail from pilotage.baux_fiche bf where bf.bail_id = b.id), pilotage.type_bail_rivage(b.id)) in ('commercial', 'derogatoire', 'professionnel')
         or l.nature in ('commercial', 'office'))
  order by h.bail_id, h.le desc
$function$;

update pilotage.regles set libelle = 'Loyer modifié dans Rivage (bail commercial ou professionnel)',
  explication = 'Le loyer d''un bail commercial, dérogatoire ou professionnel a changé dans Rivage : informer le bailleur de l''ancien et du nouveau loyer. Les baux d''habitation sont révisés automatiquement par Rivage, sans alerte. L''alerte disparaît 45 jours après le changement.'
 where cle = 'loyer_modifie';

select pilotage.executer_controles() as alertes_ouvertes;
select count(*) as alertes_revision_restantes from pilotage.alertes where regle = 'loyer_modifie' and statut = 'ouverte';
