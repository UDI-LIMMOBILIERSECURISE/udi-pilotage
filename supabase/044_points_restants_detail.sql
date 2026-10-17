-- 044 : détail des « points à traiter » d'un dossier (mandat ou bail)
-- Constat du 17/10 (bail 32, 2 rue Charles Drezet) : « 4 point(s) à traiter dans le questionnaire » alors que les 4 points étaient
-- des pièces manquantes. L'état du dossier donne désormais la liste des points restants, avec leur nature (pièce, champ Rivage, clause),
-- pour que l'écran dise exactement quoi faire. Ajout dans la fonction en place (rien d'autre ne change).

do $$
declare d text; n text;
begin
  d := pg_get_functiondef('pilotage.etat_dossier(text, text)'::regprocedure);
  if position('''restants''' in d) = 0 then
    n := replace(d, '''questions'', coalesce(',
      '''restants'', coalesce((select jsonb_agg(jsonb_build_object(''cle'', i->>''cle'', ''libelle'', i->>''libelle'', ''bloc'', i->>''bloc'', ''mode'', i->>''mode''))
                    from jsonb_array_elements(coalesce(c->''items'', ''[]''::jsonb)) i where coalesce((i->>''a_traiter'')::boolean, false)), ''[]''::jsonb),
    ''questions'', coalesce(');
    if n = d then raise exception '044 : emplacement introuvable dans pilotage.etat_dossier'; end if;
    execute n;
  end if;
end $$;

-- Contrôle : bail 32 du test (doit lister les 4 pièces manquantes, bloc « pieces »)
select x->>'libelle' libelle, x->>'bloc' bloc from jsonb_array_elements(pilotage.etat_dossier('bail', 'lc_b4dd3202975949c1c6645e45')->'restants') x;
