-- 158 : contrôle « Nom et prénom des locataires conformes au bail » — l'identité retenue est la plus récente (constat de Nicolas du 12/11/2026, bail 509 DOSOL)
--  Le 31/10, la lecture d'identité automatique (112) a lu le document alors déposé dans Rivage sur le bail 509 :
--  « Bail_d_habitation_MARTINEZ_PEREZ_ », le bail d'autres locataires, retiré depuis. Le 03/11, la lecture complète du vrai bail
--  (DOSOL Michael) a bien relevé DOSOL. Mais le contrôle prenait d'abord la table baux_occupants (lecture du 31/10) et ne regardait
--  la lecture du bail qu'à défaut : il comparait donc Rivage (DOSOL) au mauvais document et sortait « absent du bail lu ».
--  Conséquence : 1 point à revoir, alerte « dossier à compléter » chez le commercial (Nolhan) alors que tout est fait.
--  Désormais le contrôle prend l'identité la plus récente des deux, comme pilotage.occupants_bail (déclaration aux impôts) le fait déjà.
--  Fonction complétée sur place (pilotage.controle_rivage_bail) ; le bloc s'arrête sans rien modifier si le texte attendu manque.
--  Bloc unique.

begin;

do $bloc$
declare d text; a text;
begin
  d := replace(pg_get_functiondef('pilotage.controle_rivage_bail'::regproc), E'\r\n', E'\n');
  a := $t$occ := coalesce((select x2.occupants from pilotage.baux_occupants x2 where x2.bail_id = p_bail),
                    (select l.resultat->'occupants' from pilotage.baux_lectures l where l.bail_id = p_bail and l.resultat ? 'occupants' order by l.le desc limit 1));$t$;
  if position(a in d) = 0 then raise exception '158 : lecture de l''identité introuvable dans controle_rivage_bail, rien n''est modifié'; end if;
  d := replace(d, a, $t$occ := pilotage.occupants_bail(p_bail)->'occupants';  -- 158 : identité la plus récente (lecture d'identité ou lecture du bail)$t$);
  execute d;
end $bloc$;

select pilotage.executer_controles();

commit;

-- Vérification : le bail 509 ne doit plus avoir d'alerte « dossier à compléter »
-- select regle, titre from pilotage.alertes where objet_id = 'lc_adcae4daf5f6c4492092f904' and resolue_le is null;
