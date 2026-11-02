-- 117 — Lecture de tous les documents de la section bail, jamais le bail d'un autre locataire (Nicolas, 02/11/2026).
-- Constats au 02/11 :
--   - un seul document était lu par bail (le plus récent) : bail sans son annexe, renouvellement sans le bail d'origine
--     (161, 311 dont l'« Annexe_2 » était lue à la place du bail, 312, 162, 188...) ;
--   - le document pouvait venir du lot et être le bail d'un ANCIEN locataire, rattaché dans Rivage à l'ancien bail :
--     7 baux lus sur le bail de leur prédécesseur (294, 302, 303, 334, 406, 502, 516, lectures de l'audit du stock),
--     4 autres l'auraient été (304, 373, 463, 509 : le 509 aurait lu le bail MARTINEZ PEREZ au lieu de DOSOL).
-- Désormais :
--   - documents retenus : ceux de la section bail (nature « bail » ou « annexe au bail ») rattachés au bail ou à son lot,
--     à l'exclusion de tout document rattaché dans Rivage à un AUTRE bail ; à défaut, les documents dont le nom contient « bail »
--     (même exclusion, 3 au plus). Le bail lui-même d'abord, les annexes après, puis les plus récents.
--   - la fonction de lecture (v24) lit ces documents ensemble (20 Mo au plus) et reçoit les locataires du bail dans Rivage :
--     si le document concerne d'autres personnes, rien n'est enregistré et la lecture est notée en échec.
--   - relecture (116) : dès qu'un document de la section bail est reçu après la dernière lecture.
--   - les 7 lectures faites sur le bail d'un ancien locataire sont supprimées (baux du stock, sans GO, hors contrôle d'entrée).
-- Un seul bloc.

begin;

-- Documents de la section bail d'un bail, dans l'ordre de lecture
create or replace function pilotage.lecture_documents(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $function$
  with b as (select p_bail id, (select data->>'asset_id' from pilotage.objets where type = 'LeasingContract' and id = p_bail) asset),
  u as (
    select u.id, u.data, u.recu_le, u.maj_le,
           u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', b.id)) sur_bail,
           u.data->>'nature' in ('lease_contract', 'lease_annex') section,
           lower(pilotage.sans_accents(coalesce(u.data->>'label', ''))) nom
      from pilotage.objets u, b
     where u.type = 'Upload' and u.supprime_le is null
       and (u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', b.id))
            or (b.asset is not null and u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', b.asset))))
       -- jamais un document rattaché à un autre bail (bail d'un ancien locataire du logement)
       and not exists (select 1 from jsonb_array_elements(u.data->'resourceables') r where r->>'id' like 'lc\_%' and r->>'id' <> b.id)),
  choisis as (
    select * from u where section
    union all
    (select * from u where not section and not exists (select 1 from u u2 where u2.section)
        and nom ~ '(^|[^a-z])bail([^a-z]|$)' and nom !~ '(avenant|conge|preavis|quittance|resiliation|caution|assurance|etat des lieux|edl|facture)'
      order by recu_le desc, maj_le desc limit 3))
  select coalesce(jsonb_agg(jsonb_build_object('upload_id', id, 'libelle', data->>'label', 'url', data->>'file_url', 'recu_le', recu_le)
                            order by sur_bail desc, (data->>'nature' = 'lease_contract') desc, (nom ~ 'annexe') asc, recu_le desc, maj_le desc), '[]'::jsonb)
    from choisis
$function$;
revoke all on function pilotage.lecture_documents(text) from public, anon, authenticated;

-- Pour la fonction de lecture : documents et locataires du bail dans Rivage
create or replace function public.pilotage_lecture_sources(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $function$
  select jsonb_build_object('documents', pilotage.lecture_documents(p_bail),
                            'locataires', (select b.locataires from pilotage.v_baux b where b.id = p_bail))
$function$;
revoke all on function public.pilotage_lecture_sources(text) from public, anon, authenticated;
grant execute on function public.pilotage_lecture_sources(text) to service_role;

-- Document principal (identité des locataires, pièces, audit) : le premier de la liste, même exclusion
create or replace function public.pilotage_lecture_source(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $function$
  select case when jsonb_array_length(d) > 0
              then jsonb_build_object('upload_id', d->0->>'upload_id', 'libelle', d->0->>'libelle', 'url', d->0->>'url') end
    from (select pilotage.lecture_documents(p_bail) d) x
$function$;

-- Baux à lire : premières lectures inchangées ; relecture dès qu'un document de la section bail est reçu après la dernière lecture
create or replace function public.pilotage_baux_a_lire(p_max integer)
returns jsonb language sql stable security definer set search_path = pilotage, public as $function$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (
    select b.id, s.recu
      from pilotage.v_baux b
      cross join lateral (select max((d->>'recu_le')::timestamptz) recu, count(*) n
                            from jsonb_array_elements(pilotage.lecture_documents(b.id)) d) s
      left join lateral (select max(x.le) lu from pilotage.baux_lectures x where x.bail_id = b.id) l on true
      left join pilotage.lectures_echecs e on e.cle = b.id
     where b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > current_date)
       and s.n > 0
       -- bloqué après 2 échecs, sauf si un nouveau document de la section bail est arrivé depuis le dernier échec (116)
       and (coalesce(e.nb, 0) < 2 or e.dernier_le < s.recu)
       and ((l.lu is null
             and ((pilotage.echeance_bail(b.id)->>'type') in ('commercial', 'derogatoire', 'professionnel')
                  or pilotage.bail_soumis(b.id)
                  or pilotage.dossier_nouveau('LeasingContract', b.id)))
            -- 116 + 117 : document de la section bail reçu après la dernière lecture
            or l.lu < s.recu)
     order by s.recu desc nulls last, b.debut desc
     limit p_max) t
$function$;
revoke all on function public.pilotage_baux_a_lire(integer) from public, anon, authenticated;
grant execute on function public.pilotage_baux_a_lire(integer) to service_role;

-- Lectures faites sur le bail d'un ancien locataire (audit du stock du 26 au 30/10) : supprimées
delete from pilotage.baux_lectures l
 using pilotage.v_baux b
 where b.id = l.bail_id
   and (b.reference, l.id) in (('294', 22), ('302', 20), ('303', 21), ('334', 16), ('406', 15), ('502', 75), ('516', 13));

commit;

-- Vérification : 0 lecture restante sur ces 7 baux, et documents retenus pour quelques baux à plusieurs documents
select (select count(*) from pilotage.baux_lectures where id in (13, 15, 16, 20, 21, 22, 75)) as lectures_erronees_restantes,
       (select jsonb_object_agg(b.reference, (select jsonb_agg(d->>'libelle') from jsonb_array_elements(pilotage.lecture_documents(b.id)) d))
          from pilotage.v_baux b where b.reference in ('161', '311', '312', '509', '516')) as exemples;
