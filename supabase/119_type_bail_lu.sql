-- 119 — Type de bail : le type Rivage n'est plus conforme d'office, il est comparé au type lu dans le bail (Nicolas, 02/11/2026).
-- Avant : dès que Rivage donnait un type (vide, meublé, commercial...), le point « Type de bail » du contrôle d'entrée était conforme,
-- même si le bail lu par l'IA disait autre chose (contraire à la règle : une donnée Rivage n'est conforme que si elle concorde avec le bail).
-- Désormais, quand le type vient de Rivage (pas de type saisi dans la fiche) et que le bail a été lu :
--   - même famille (vide / meublé / commercial / dérogatoire / professionnel) : conforme ;
--   - famille différente : anomalie « Rivage : meublé · le bail indique : vide », à corriger dans Rivage ou à trancher avec « Corriger »
--     (type saisi dans la fiche) ; tant qu'elle reste, elle compte dans les points du commercial (alerte « dossier à compléter »).
--   Étudiant et mobilité comptent comme meublé ; commercial, dérogatoire et professionnel sont trois types distincts (règle de Nicolas,
--   02/11 : régimes différents) ; mixte et autre ne sont pas comparés.
--   Bail pas encore lu : inchangé (Rivage fait foi en attendant).
-- Écarts réels au 02/11 : bail 510 (TEBLAOUI) et 513 : Rivage « meublé », bail « non meublé, 3 ans » (extrait lu page 2).
-- Conséquence d'un mauvais type dans Rivage : plafond du dépôt, durée et échéance du bail, délais de congé calculés à tort.
-- Types de Rivage (liste relevée dans le formulaire « Modifier la location » le 02/11, 14 valeurs) désormais tous traduits :
--   unfurnished → vide ; furnished → meublé ; student → étudiant ; mobility → mobilité ; commercial → commercial (dérogatoire si
--   36 mois ou moins : 6 baux saisis « commercial » au 02/11, à recoder « Bail dérogatoire » dans Rivage) ; short_term → dérogatoire ;
--   professionnal → professionnel ; civil_code, parking, secondary_residence, seasonal, rural, law_48, other → autre (non comparés).
--   Avant, « meublé » de 9 mois ou de 1 à 10 mois était déduit étudiant ou mobilité : Rivage a ses propres valeurs, la déduction est
--   retirée (aucun bail concerné au 02/11).
-- Modification ciblée de pilotage.controle_bail (remplacement contrôlé d'une ligne). Un seul bloc.

begin;

-- Traduction de tous les types de contrat de location de Rivage
create or replace function pilotage.type_bail_rivage(p_bail text) returns text
language sql stable security definer set search_path = pilotage, public as $function$
  select case coalesce(o.data->'edit_attributes'->>'nature', (select s.data->'lease'->'data'->'attributes'->>'nature' from pilotage.baux_situation s where s.bail_id = p_bail))
    when 'unfurnished' then 'vide'
    when 'furnished' then 'meuble'
    when 'student' then 'etudiant'
    when 'mobility' then 'mobilite'
    when 'commercial' then case when nullif(o.data->>'duration_in_months', '')::int between 1 and 36 then 'derogatoire' else 'commercial' end
    when 'short_term' then 'derogatoire'
    when 'professionnal' then 'professionnel'
    when 'professional' then 'professionnel'
    when 'civil_code' then 'autre' when 'parking' then 'autre' when 'secondary_residence' then 'autre' when 'seasonal' then 'autre'
    when 'rural' then 'autre' when 'law_48' then 'autre' when 'other' then 'autre' end
  from pilotage.objets o where o.type = 'LeasingContract' and o.id = p_bail
$function$;

create or replace function pilotage.famille_type_bail(p_type text) returns text
language sql immutable as $function$
  select case lower(coalesce(p_type, ''))
    when 'vide' then 'vide'
    when 'meuble' then 'meuble' when 'etudiant' then 'meuble' when 'mobilite' then 'meuble'
    when 'commercial' then 'commercial' when 'derogatoire' then 'derogatoire' when 'professionnel' then 'professionnel' end
$function$;

do $do$
declare d text; ancien text; nouveau text;
begin
  d := pg_get_functiondef('pilotage.controle_bail'::regproc);
  ancien := $r$      if detail is not null and not (q.ref = 'type_bail' and f.type_bail is null and pilotage.type_bail_rivage(p_bail) is null) then auto := 'ok'; end if;$r$;
  if position(ancien in d) = 0 then raise exception '119 : ligne du type de bail introuvable dans controle_bail (fonction modifiée depuis)'; end if;
  if position('119 : type Rivage' in d) > 0 then raise notice '119 déjà passé'; return; end if;
  nouveau := ancien || $r$
      -- 119 : type Rivage comparé au type lu dans le bail (vide / meublé / commercial / dérogatoire / professionnel)
      if q.ref = 'type_bail' and f.type_bail is null and pilotage.type_bail_rivage(p_bail) is not null
         and pilotage.famille_type_bail(valeur_ia->>'code') is not null
         and pilotage.famille_type_bail(valeur_ia->>'code') <> pilotage.famille_type_bail(pilotage.type_bail_rivage(p_bail)) then
        auto := 'anomalie';
        detail := detail || ' · le bail indique : ' || case pilotage.famille_type_bail(valeur_ia->>'code')
          when 'vide' then 'vide (non meublé)' when 'meuble' then 'meublé' when 'derogatoire' then 'dérogatoire'
          when 'professionnel' then 'professionnel' else 'commercial' end
          || coalesce(' (page ' || (valeur_ia->>'page') || ')', '');
      end if;$r$;
  execute replace(d, ancien, nouveau);
end $do$;

select pilotage.executer_controles();

commit;

-- Vérification : script passé (vrai) et point « Type de bail » des baux 510 et 513 (anomalie attendue)
select position('119 : type Rivage' in pg_get_functiondef('pilotage.controle_bail'::regproc)) > 0 as script_119_passe,
       (select jsonb_object_agg(b.reference, (select jsonb_build_object('statut', coalesce(i->>'statut', 'à traiter'), 'detail', i->>'detail')
                                                from jsonb_array_elements(pilotage.controle_bail(b.id)->'items') i where i->>'ref' = 'type_bail'))
          from pilotage.v_baux b where b.reference in ('510', '513')) as type_bail;
