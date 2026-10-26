-- 087 — Rattachement des 21 dossiers en cours repris de Monday et WeRoof aux incidents créés dans Rivage le 26/10 (demande de Nicolas du 26/10).
--
-- Les 21 dossiers en cours rattachés à un bail ont été recréés à la main dans Rivage (incidents n° 3 à 23, assignés à Marion BRENOT).
-- Chaque dossier repris est relié à son incident (même lot, même date de déclaration) :
--   - il disparaît de la liste des sinistres, pour n'apparaître qu'une fois, sous l'incident Rivage ;
--   - son fil de mises à jour (Monday, WeRoof, équipe) s'affiche sous l'incident Rivage, avec les commentaires publiés depuis,
--     et sert au résumé IA de l'incident ;
--   - le dossier repris n'est ni supprimé ni modifié (clos, statut et dates restent ceux de Monday ou WeRoof) : il suffit de vider incident_id pour revenir en arrière.
-- Rivage reste la source de vérité de l'incident (statut, prestataires). Rien n'est écrit dans Rivage, Monday ou WeRoof. Rejouable sans doublon.

begin;

alter table pilotage.travaux_monday add column if not exists incident_id text unique;
comment on column pilotage.travaux_monday.incident_id is 'Incident Rivage qui reprend ce dossier (087) : le dossier n''apparaît plus seul dans les sinistres, son fil s''affiche sous l''incident.';

update pilotage.travaux_monday t set incident_id = x.incident_id
from (values
  (18040759682, 'inc_4032566823484846c44caaad'),
  (18041112136, 'inc_7351fdbaf7c0a31435272a93'),
  (18178507811, 'inc_126a327c98b38c3d227a9515'),
  (18181341837, 'inc_355323a4899d4710d6970d03'),
  (11131248675, 'inc_034e44a56de9d6d609980104'),
  (11172142105, 'inc_77b374ae5acb8867e28f5dcb'),
  (11478050868, 'inc_c8c13bd8da2bc356944a4eb3'),
  (11544662629, 'inc_b9bc856909db5228ac0d68cf'),
  (11742827058, 'inc_d45d415b44b5484e9a3d8b73'),
  (11857828869, 'inc_31e9943326613d383705e185'),
  (11867692920, 'inc_bc5c673d39b61baf4e6ab934'),
  (11975267134, 'inc_525dc26014df056c9ce1a810'),
  (12586272278, 'inc_6b5abf93caaaaecf08990b10'),
  (12658418429, 'inc_89d6904141ec9b8ef9b50e69'),
  (12680181690, 'inc_3190f89893cfaf1b45aa939a'),
  (-60, 'inc_311635b8da7000f000d8cb12'),
  (-10, 'inc_36dc648b59cad7e4a5f99ffd'),
  (-62, 'inc_a93524b6e1e54d22d01d1b94'),
  (-63, 'inc_c1f8b9898e2a3c610dffd99c'),
  (-34, 'inc_1dfc5b4c3dc5bd0e406697b0'),
  (-37, 'inc_87ae0659808f3a35a5f78d23')
) as x(monday_id, incident_id)
where t.monday_id = x.monday_id
  and exists (select 1 from pilotage.objets i where i.type = 'Incident' and i.id = x.incident_id and i.supprime_le is null
              and i.data->>'asset_id' = t.lot_id and (i.data->>'declared_at')::date = t.cree_le::date);

do $$ begin
  if (select count(*) from pilotage.travaux_monday where incident_id is not null) <> 21 then
    raise exception '21 rattachements attendus, % trouvés : rien n''est modifié', (select count(*) from pilotage.travaux_monday where incident_id is not null);
  end if;
end $$;

-- Liste des sinistres : le dossier rattaché n'apparaît plus seul ; l'incident Rivage compte ses mises à jour et indique d'où il est repris
do $$
declare
  def text; n int; r text[]; i int;
  remplacements text[][] := array[
    [$a$'nb_notes', (select count(*) from pilotage.sinistres_notes sn where sn.incident_id = i.id),$a$,
     $a$'nb_notes', (select count(*) from pilotage.sinistres_notes sn where sn.incident_id = i.id)
          + (select count(*) from pilotage.travaux_monday_notes n join pilotage.travaux_monday r on r.monday_id = n.monday_id where r.incident_id = i.id),$a$],
    [$a$'derniere_note', (select max(sn.le) from pilotage.sinistres_notes sn where sn.incident_id = i.id),$a$,
     $a$'derniere_note', greatest((select max(sn.le) from pilotage.sinistres_notes sn where sn.incident_id = i.id),
          (select max(n.le) from pilotage.travaux_monday_notes n join pilotage.travaux_monday r on r.monday_id = n.monday_id where r.incident_id = i.id)),$a$],
    [$a$'lien', 'https://rivage.immo/incidents/' || i.id$a$,
     $a$'lien', 'https://rivage.immo/incidents/' || i.id,
        'repris', (select jsonb_build_object('monday_id', r.monday_id, 'origine', r.origine, 'reference', r.reference, 'lien', r.url, 'ouvert_le', r.cree_le)
                   from pilotage.travaux_monday r where r.incident_id = i.id)$a$],
    [$a$where pilotage.voit_tableau('sinistres', mm.id)$a$,
     $a$where t.incident_id is null and pilotage.voit_tableau('sinistres', mm.id)$a$]
  ];
begin
  select pg_get_functiondef('public.pilotage_sinistres'::regproc) into def;
  for i in 1 .. array_length(remplacements, 1) loop
    n := (length(def) - length(replace(def, remplacements[i][1], ''))) / length(remplacements[i][1]);
    if n <> 1 then raise exception 'Critère % trouvé % fois dans pilotage_sinistres (1 attendu) : rien n''est modifié', i, n; end if;
    def := replace(def, remplacements[i][1], remplacements[i][2]);
  end loop;
  execute def;
end $$;

-- Fil d'un incident Rivage : commentaires de l'équipe + historique du dossier repris (Monday ou WeRoof), le plus récent d'abord
create or replace function public.pilotage_sinistre_notes(p_incident text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(x order by x->>'le' desc) from (
      select jsonb_build_object('id', n.id, 'parent_id', null, 'auteur', n.auteur, 'le', n.le,
               'contenu', n.contenu, 'tronque', false, 'monday', false, 'origine', null) x
        from pilotage.sinistres_notes n where n.incident_id = p_incident
      union all
      -- identifiants préfixés : pas de collision avec les commentaires de l'incident
      select jsonb_build_object('id', 'm' || n.id, 'parent_id', case when n.parent_id is not null then 'm' || n.parent_id end, 'auteur', n.auteur, 'le', n.le,
               'contenu', n.contenu, 'tronque', n.tronque, 'monday', n.monday_post_id is not null,
               'origine', case when n.monday_post_id is not null then 'Monday' when n.weroof_id is not null then 'WeRoof' end)
        from pilotage.travaux_monday_notes n join pilotage.travaux_monday r on r.monday_id = n.monday_id
       where r.incident_id = p_incident
    ) t), '[]'::jsonb);
end $$;

commit;

-- Contrôles (attendu : 21 rattachés ; 21 incidents Rivage portant un dossier repris ; aucun dossier rattaché encore listé seul)
select count(*) filter (where incident_id is not null) rattaches,
       count(*) filter (where incident_id is not null and origine = 'monday') depuis_monday,
       count(*) filter (where incident_id is not null and origine = 'weroof') depuis_weroof,
       (select count(*) from pilotage.travaux_monday_notes n join pilotage.travaux_monday r on r.monday_id = n.monday_id where r.incident_id is not null) mises_a_jour_reprises
from pilotage.travaux_monday;
