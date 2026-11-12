-- 155 : contrôle d'entrée, pièce reconnue = la plus récente déposée dans Rivage (constat de Nicolas du 12/11/2026, bail 532 DIMA)
--  L'attestation d'assurance déposée dans Rivage le 12/11 (catégorie « Attestation d'assurance habitation », sans date d'émission)
--  n'était pas retenue : le contrôle prenait d'abord la pièce qui a une date d'émission (tri « date d'émission, les vides en dernier »),
--  ici l'ancienne « Assurance habitation — date reprise sans justificatif », expirée le 31/01/2026. Le point restait « à traiter »,
--  le dossier restait chez le commercial et le GO n'était pas proposé.
--  Désormais, à catégorie égale, la pièce retenue est la plus récente : date d'émission, à défaut date de mise à jour dans Rivage.
--  Fonction complétée sur place (pilotage.controle_bail) ; le bloc s'arrête sans rien modifier si le texte attendu manque.
--  Bloc unique.

begin;

do $bloc$
declare f text; d text; n int := 0;
  a constant text := 'nullif(u.issued_on, '''')::date desc nulls last, u.maj_le desc';
  b constant text := 'coalesce(nullif(u.issued_on, '''')::date, u.maj_le::date) desc, u.maj_le desc';
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace s on s.oid = p.pronamespace
            where s.nspname = 'pilotage' and p.prokind = 'f' and position(a in pg_get_functiondef(p.oid)) > 0 loop
    d := replace(pg_get_functiondef(f::regprocedure), E'\r\n', E'\n');
    execute replace(d, a, b);
    n := n + 1;
    raise notice '155 : % corrigée', f;
  end loop;
  if n = 0 then raise exception '155 : tri des pièces introuvable, rien n''est modifié'; end if;
end $bloc$;

select pilotage.executer_controles();

commit;

-- Vérification : select jsonb_path_query_array(pilotage.controle_bail(id)->'items', '$[*] ? (@.cle == "h_doc_assurance")') from pilotage.v_baux where reference = '532';
