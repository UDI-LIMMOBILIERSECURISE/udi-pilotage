-- 099 — Type de bail repris de Rivage, croisement Rivage allégé, bail retrouvé par son nom pour la lecture IA (Nicolas, 29/10/2026).
-- 1. Type de bail : Rivage le donne (nature du bail : unfurnished, furnished, commercial, civil_code, parking ; vérifié en base,
--    480 baux). Il est repris automatiquement, sans confirmation : vide, meublé (étudiant si 9 mois, mobilité si 1 à 10 mois),
--    commercial (dérogatoire jusqu'à 36 mois, professionnel à 72 mois), autre (code civil, parking). Un type saisi dans la fiche
--    (3 baux au 29/10) reste prioritaire. Lu à chaque calcul : pas de copie à tenir à jour.
-- 2. Croisement avec Rivage (contrôle d'entrée) : un champ Rivage renseigné, sans écart avec le bail lu par l'IA et sans
--    incohérence légale, est conforme d'office (avant : « à confirmer : non vérifié dans le bail », à valider un par un).
--    Restent à traiter : champ vide dans Rivage, écart avec le bail lu, incohérence légale (plafond du dépôt, indice).
-- 3. Lecture IA du bail : le bail n'était cherché que dans la catégorie Rivage « Bail ». Constat sur le bail 86 : déposé en
--    « Correspondance » sous le nom « Bail_d_habitation_GUILLIOT_PILLET », d'où l'échec de « Lire le bail déposé dans Rivage ».
--    À défaut de catégorie « Bail », un document dont le nom contient le mot « bail » est pris (hors avenant, congé, quittance).
-- 4. Messages du dossier (mails et SMS préparés depuis le pilotage) ajoutés au journal de la fiche du bail ; constat du 29/10 :
--    les trois mails du bail 509 (locataire, garant, bailleur) étaient notés mais n'apparaissaient que dans le bloc « Messages ».
-- Fonctions modifiées : type_bail_rivage (nouvelle), echeance_bail, controle_bail, pilotage_bail_dossier (remplacements ciblés,
-- contrôlés), pilotage_lecture_source (remplacée). Aucune donnée modifiée. La liste des baux se met à jour au calcul suivant (toutes les 30 min).
-- Un seul bloc.

begin;

create or replace function pilotage.type_bail_rivage(p_bail text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select case coalesce(o.data->'edit_attributes'->>'nature', (select s.data->'lease'->'data'->'attributes'->>'nature' from pilotage.baux_situation s where s.bail_id = p_bail))
    when 'unfurnished' then 'vide'
    when 'furnished' then case when nullif(o.data->>'duration_in_months', '')::int = 9 then 'etudiant'
                               when nullif(o.data->>'duration_in_months', '')::int between 1 and 10 then 'mobilite' else 'meuble' end
    when 'commercial' then case when nullif(o.data->>'duration_in_months', '')::int between 1 and 36 then 'derogatoire'
                                when nullif(o.data->>'duration_in_months', '')::int = 72 then 'professionnel' else 'commercial' end
    when 'civil_code' then 'autre'
    when 'parking' then 'autre' end
  from pilotage.objets o where o.type = 'LeasingContract' and o.id = p_bail
$$;
revoke all on function pilotage.type_bail_rivage(text) from public, anon, authenticated;

-- Bail à lire par l'IA : catégorie Rivage « Bail », sinon document nommé « bail » sur le bail ou le lot
create or replace function public.pilotage_lecture_source(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('upload_id', u.id, 'libelle', u.data->>'label', 'url', u.data->>'file_url')
  from pilotage.objets u
  where u.type = 'Upload' and u.supprime_le is null
    and (u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', p_bail))
         or u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', (select data->>'asset_id' from pilotage.objets where type = 'LeasingContract' and id = p_bail))))
    and (u.data->>'nature' = 'lease_contract'
         or (lower(pilotage.sans_accents(coalesce(u.data->>'label', ''))) ~ '(^|[^a-z])bail([^a-z]|$)'
             and lower(pilotage.sans_accents(coalesce(u.data->>'label', ''))) !~ '(avenant|conge|preavis|quittance|resiliation|caution|assurance|etat des lieux|edl)'))
  order by (u.data->>'nature' = 'lease_contract') desc, u.maj_le desc
  limit 1
$$;

do $do$
declare d text; n int;
begin
  -- echeance_bail : type repris de Rivage avant la suggestion ; confirmé s'il vient de la fiche ou de Rivage
  d := pg_get_functiondef('pilotage.echeance_bail(text)'::regprocedure);
  if position('type_bail_rivage' in d) = 0 then
    if position($r$typ := coalesce(f.type_bail, sugg);$r$ in d) = 0 then raise exception 'echeance_bail : calcul du type introuvable'; end if;
    d := replace(d, $r$typ := coalesce(f.type_bail, sugg);$r$, $r$typ := coalesce(f.type_bail, pilotage.type_bail_rivage(p_bail), sugg);$r$);
    n := (length(d) - length(replace(d, $r$'type_confirme', f.type_bail is not null$r$, ''))) / length($r$'type_confirme', f.type_bail is not null$r$);
    if n <> 2 then raise exception 'echeance_bail : type_confirme trouvé % fois (2 attendues)', n; end if;
    d := replace(d, $r$'type_confirme', f.type_bail is not null$r$, $r$'type_confirme', (f.type_bail is not null or pilotage.type_bail_rivage(p_bail) is not null)$r$);
    execute d;
  end if;
  -- controle_bail : même type ; question « Type de bail » réglée par Rivage ; champs Rivage sans écart conformes d'office
  d := pg_get_functiondef('pilotage.controle_bail(text)'::regprocedure);
  if position('type_bail_rivage' in d) = 0 then
    if position($r$typ := coalesce(f.type_bail, pilotage.type_bail_suggere($r$ in d) = 0 then raise exception 'controle_bail : calcul du type introuvable'; end if;
    d := replace(d, $r$typ := coalesce(f.type_bail, pilotage.type_bail_suggere($r$, $r$typ := coalesce(f.type_bail, pilotage.type_bail_rivage(p_bail), pilotage.type_bail_suggere($r$);
    if position($r$when 'type_bail' then coalesce(f.type_bail, 'Suggestion : '$r$ in d) = 0 then raise exception 'controle_bail : question type_bail introuvable'; end if;
    d := replace(d, $r$when 'type_bail' then coalesce(f.type_bail, 'Suggestion : '$r$, $r$when 'type_bail' then coalesce(f.type_bail, 'Rivage : ' || pilotage.type_bail_rivage(p_bail), 'Suggestion : '$r$);
    if position($r$not (q.ref = 'type_bail' and f.type_bail is null)$r$ in d) = 0 then raise exception 'controle_bail : validation type_bail introuvable'; end if;
    d := replace(d, $r$not (q.ref = 'type_bail' and f.type_bail is null)$r$, $r$not (q.ref = 'type_bail' and f.type_bail is null and pilotage.type_bail_rivage(p_bail) is null)$r$);
    if position($r$elsif auto is null then detail := detail || ' · à confirmer : non vérifié dans le bail'; end if;$r$ in d) = 0 then raise exception 'controle_bail : « à confirmer » introuvable'; end if;
    d := replace(d, $r$elsif auto is null then detail := detail || ' · à confirmer : non vérifié dans le bail'; end if;$r$,
                    $r$elsif auto is null then auto := 'ok'; if lecture is null then detail := detail || ' · bail non lu par l''IA'; end if; end if;$r$);
    execute d;
  end if;
  -- pilotage_bail_dossier : messages du dossier pour le journal
  d := pg_get_functiondef('public.pilotage_bail_dossier(text)'::regprocedure);
  if position('messages_journal' in d) = 0 then
    if position($r$'lecture', (select jsonb_build_object('le', le, 'source', source$r$ in d) = 0 then raise exception 'pilotage_bail_dossier : point d''insertion introuvable'; end if;
    d := replace(d, $r$'lecture', (select jsonb_build_object('le', le, 'source', source$r$,
      $r$'messages', coalesce((select jsonb_agg(jsonb_build_object('le', mj.le, 'code', mj.code, 'libelle', coalesce(mm.libelle, mj.code), 'canal', mj.canal,
                                                    'moyen', mj.moyen, 'a', mj.a, 'par', pilotage.prenom_membre(mj.par)) order by mj.le desc)
                                from pilotage.messages_journal mj left join pilotage.messages_modeles mm on mm.code = mj.code
                               where mj.objet = 'bail' and mj.objet_id = p_bail), '[]'::jsonb),
    'lecture', (select jsonb_build_object('le', le, 'source', source$r$);
    execute d;
  end if;
end $do$;

commit;

-- Vérifications
-- select pilotage.type_bail_rivage(id) t, count(*) from pilotage.v_baux group by 1;
-- select public.pilotage_lecture_source('lc_e373e9b572d1c3420bd120f1')->>'libelle';   -- bail 86 : Bail_d_habitation_GUILLIOT_PILLET
