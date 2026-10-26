-- 080 — Coordonnées des parties sur les sinistres et sur les congés / dépôts de garantie (demande de Nicolas du 26/10).
-- Sinistres : locataires et bailleurs du bail lié à l'incident ; sans bail lié, bailleurs du mandat du lot.
-- Congés et DG : locataires et bailleurs du bail. Nom, téléphone et e-mail repris de Rivage (mêmes fonctions que les cartes 079).

begin;

do $$
declare
  t record; def text; n int;
begin
  for t in select * from (values
    ('public', 'pilotage_sinistres',
     $a$'adresse', l.adresse, 'lot', l.reference, 'locataires', b.locataires, 'bail', b.reference,$a$,
     $a$'adresse', l.adresse, 'lot', l.reference, 'locataires', b.locataires, 'bail', b.reference,
        'parties', coalesce(pilotage.contacts_bail(b.id), pilotage.contacts_mandat(l.mandat_id)),$a$),
    ('public', 'pilotage_dg',
     $a$'bail_id', b.id, 'reference', b.reference, 'locataires', b.locataires,$a$,
     $a$'bail_id', b.id, 'reference', b.reference, 'locataires', b.locataires, 'parties', pilotage.contacts_bail(b.id),$a$)
  ) v(schema, fonction, ancien, nouveau) loop
    select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = t.schema and p.proname = t.fonction;
    if def is null then raise exception 'Fonction %.% introuvable', t.schema, t.fonction; end if;
    n := (length(def) - length(replace(def, t.ancien, ''))) / length(t.ancien);
    if n <> 1 then raise exception 'Critère attendu trouvé % fois dans %.% (1 attendu) : rien n''est modifié', n, t.schema, t.fonction; end if;
    execute replace(def, t.ancien, t.nouveau);
  end loop;
end $$;

commit;

select proname, prosrc like '%''parties''%' coordonnees from pg_proc where proname in ('pilotage_sinistres', 'pilotage_dg');
