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

-- Échéance du bail : le mail d'information (ou de relance) au bailleur part aussi depuis l'envoi groupé de Ma journée.
--  Une fois l'étape « informé » / « relancé » faite, l'alerte d'échéance du bail se résout tout de suite, comme le suivi (143) ;
--  le contrôle suivant la rouvre si une autre action d'échéance reste due.
create or replace function pilotage.resoudre_suivi_bail(p_cle text)
returns void language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_bail text;
begin
  v_bail := case when p_cle like 'e:%' then split_part(p_cle, ':', 2)
                 when p_cle like 'o:%' then (select o.bail_id from pilotage.baux_obligations o
                                              where o.id::text = split_part(p_cle, ':', 2)) end;
  if v_bail is null then return; end if;
  if p_cle ~ '^e:[^:]+:\d{4}-\d{2}-\d{2}$' then  -- étape de l'échéance du bail (clé de cycle)
    insert into pilotage.baux_cache (bail_id, ligne, calcule_le) values (v_bail, pilotage.ligne_bail(v_bail), now())
    on conflict (bail_id) do update set ligne = excluded.ligne, calcule_le = now();  -- échéance recalculée (sans contrôle de rôle : appelé aussi par la fonction d'envoi)
    update pilotage.alertes set statut = 'resolue', resolue_le = now()
     where regle in ('bail_echeance', 'bail_echeance_urgente') and objet_type = 'LeasingContract'
       and objet_id = v_bail and statut = 'ouverte';
    return;
  end if;
  if exists (select 1 from pilotage.baux_obligations o, lateral pilotage.obligation_etat(o.id) e
              where o.bail_id = v_bail and (e->>'actif')::boolean is not false
                and jsonb_typeof(e->'a_faire') = 'object') then return; end if;
  update pilotage.alertes set statut = 'resolue', resolue_le = now()
   where regle in ('bail_suivi', 'bail_suivi_retard') and objet_type = 'LeasingContract'
     and objet_id = v_bail and statut = 'ouverte';
end $$;
revoke all on function pilotage.resoudre_suivi_bail(text) from public, anon, authenticated;
