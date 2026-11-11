-- 144 : une alerte « en retard » dit l'action à faire (retour de Nicolas du 11/11/2026)
--  Constat : quand toutes les relances prévues d'une obligation (assurance, entretien…) sont faites et que le justificatif manque
--  toujours, l'alerte s'affichait « Bail 367 : en retard (Entretien chaudière gaz) », comme une relance à envoyer.
--  Règle : le titre donne l'action. Relances terminées → « relances terminées sans justificatif : l'obtenir et le déposer dans la
--  fiche, ou décider de la suite avec le bailleur » ; relance suivante encore prévue → « en retard, prochaine relance le … : … ».
--  Seul le titre change (même règle bail_suivi_retard, mêmes alertes) ; il est mis à jour au prochain contrôle.

do $do$
declare d text; avant text := $a$coalesce(e->'a_faire'->>'libelle', 'en retard')$a$;
  apres text := $b$coalesce(e->'a_faire'->>'libelle', case when jsonb_typeof(e->'suivante') = 'object'
           then 'en retard, prochaine relance le ' || to_char((e->'suivante'->>'date')::date, 'DD/MM/YYYY') || ' : ' || (e->'suivante'->>'libelle')
           else 'relances terminées sans justificatif : l''obtenir et le déposer dans la fiche, ou décider de la suite avec le bailleur' end)$b$;
begin
  d := pg_get_functiondef('pilotage.suivi_detections()'::regprocedure);
  if position(avant in d) = 0 then raise exception '144 : texte attendu introuvable dans suivi_detections, rien n''est modifié'; end if;
  execute replace(d, avant, apres);
end $do$;

-- Titres mis à jour tout de suite (sans attendre le contrôle suivant)
update pilotage.alertes a set titre = s.titre, detail = s.detail
  from pilotage.suivi_detections() s
 where s.regle = a.regle and s.objet_type = a.objet_type and s.objet_id = a.objet_id
   and a.regle in ('bail_suivi', 'bail_suivi_retard') and a.statut <> 'resolue' and a.titre is distinct from s.titre;
