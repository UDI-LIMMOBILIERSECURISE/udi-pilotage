-- 037 : lots et immeubles au contrôle d'entrée du mandat (décisions de Nicolas, 17/10/2026). À exécuter après 036.
--   1. Champs Rivage des lots contrôlés au mandat :
--        année ou période de construction (tous les lots bâtis : hors parking, box et cave) — champ vide = blocage ;
--        chauffage, type (individuel ou collectif) et énergie, pour chaque logement — champ vide = blocage ;
--        syndic renseigné pour les lots en copropriété — point à justifier (sans objet pour une maison ou un immeuble
--        en monopropriété géré en entier), pas un blocage, car son absence peut être normale.
--   2. Diagnostics exigés d'après l'année, ou à défaut la période de construction donnée par Rivage :
--        plomb (CREP) pour les logements construits avant 1949 ; amiante pour les lots dont le permis est antérieur au 01/07/1997.
--        Une période à cheval (1946-1970 pour le plomb, 1991-2005 pour l'amiante) laisse la pièce exigée.
--   3. Immeuble (groupe de lots « immeuble » dans Rivage, monopropriété gérée en entier) : contrats d'entretien communs et
--      assurance de l'immeuble. Entretiens suivis tous les ans (règle de Nicolas : tous les entretiens à un an) ;
--      ascenseur : en plus, contrôle technique tous les 5 ans.
--   4. Lecture des états des lieux par l'IA : elle PROPOSE les équipements à entretenir et les compteurs (numéro, index d'entrée)
--      trouvés dans l'état des lieux du lot ; rien n'est créé tant que la gestion ou le commercial n'a pas confirmé d'un clic.

-- ========== 1 et 2. Contrôle du mandat ==========

-- Construit avant une année donnée : vrai, faux, ou inconnu (null) d'après l'année ou la période Rivage
create or replace function pilotage.lot_construit_avant(p_lot jsonb, p_annee integer) returns boolean
language sql immutable as $$
  select case
    when nullif(p_lot->>'construction_year', '') is not null then (p_lot->>'construction_year')::integer < p_annee
    else case p_lot->>'construction_period'
      when 'before_1946' then true
      when 'from_1946_to_1970' then case when p_annee <= 1946 then false when p_annee > 1970 then true end
      when 'from_1971_to_1990' then case when p_annee <= 1971 then false when p_annee > 1990 then true end
      when 'from_1991_to_2005' then case when p_annee <= 1991 then false when p_annee > 2005 then true end
      when 'after_2005' then case when p_annee <= 2006 then false end
    end end
$$;

create or replace function pilotage.periode_construction(p_lot jsonb) returns text
language sql immutable as $$
  select coalesce(nullif(p_lot->>'construction_year', ''),
    case p_lot->>'construction_period' when 'before_1946' then 'avant 1946' when 'from_1946_to_1970' then '1946-1970'
      when 'from_1971_to_1990' then '1971-1990' when 'from_1991_to_2005' then '1991-2005' when 'after_2005' then 'après 2005' end)
$$;

-- Le diagnostic est-il exigé pour ce mandat ? false seulement si tous les lots concernés sont construits après le seuil
create or replace function pilotage.mandat_exige_diag(p_mandat text, p_diag text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(bool_or(coalesce(case p_diag when 'plomb' then pilotage.lot_construit_avant(a.data, 1949)
                                               else pilotage.lot_construit_avant(a.data, 1998) end, true)), false)
  from pilotage.objets a
  where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
    and case p_diag when 'plomb' then a.data->>'nature' in ('flat', 'room', 'house')
                    else a.data->>'nature' not in ('parking', 'box') end
$$;

-- Lot rattaché à un immeuble géré en entier (groupe « building » dans Rivage)
create or replace function pilotage.lot_dans_immeuble(p_asset text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select exists (select 1 from pilotage.objets m join pilotage.objets g on g.type = 'AssetGroup' and g.id = m.data->>'asset_group_id' and g.supprime_le is null
                 where m.type = 'AssetGroupMembership' and m.supprime_le is null and m.data->>'asset_id' = p_asset
                   and nullif(m.data->>'end_date', '') is null and g.data->>'nature' = 'building')
$$;

-- Nouveaux points du croisement Rivage
insert into pilotage.controle_questions (cle, portee, bloc, ordre, libelle, aide, mode, ref) values
('m_rv_construction', 'mandat', 'rivage', 80, 'Année ou période de construction de chaque lot',
  'Détermine les diagnostics exigés (plomb avant 1949, amiante avant juillet 1997). À saisir dans Rivage, fiche du lot.', 'rivage', 'lots_construction'),
('m_rv_chauffage', 'mandat', 'rivage', 90, 'Chauffage et eau chaude de chaque logement (individuel ou collectif, énergie)',
  'Détermine les entretiens à suivre. À saisir dans Rivage, fiche du lot, rubrique équipements.', 'rivage', 'lots_chauffage'),
('m_rv_syndic', 'mandat', 'rivage', 100, 'Syndic de copropriété renseigné',
  'Fiche du lot dans Rivage. Sans objet pour une maison ou un immeuble en monopropriété géré en entier (à justifier).', 'rivage', 'lots_syndic')
on conflict (cle) do update set portee = excluded.portee, bloc = excluded.bloc, ordre = excluded.ordre, libelle = excluded.libelle, aide = excluded.aide,
  mode = excluded.mode, ref = excluded.ref;

-- Ces points ne se lisent pas dans le mandat : ils ne sont pas envoyés à l'IA
create or replace function public.pilotage_questions_mandat(p_mandat text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('cle', cle, 'libelle', libelle, 'aide', aide) order by bloc, ordre), '[]'::jsonb)
  from pilotage.controle_questions where portee = 'mandat' and mode <> 'document' and coalesce(ref, '') not like 'lots\_%'
    and exists (select 1 from pilotage.objets where type = 'ManagementContract' and id = p_mandat)
$$;

-- Branchement dans le contrôle du mandat (même méthode que 032 et 034 : la fonction en place est complétée, pas réécrite)
do $do$
declare def text; n text;
begin
  def := pg_get_functiondef('pilotage.controle_mandat(text)'::regprocedure);
  if position('lots_construction' in def) > 0 then return; end if;
  -- a) Trois nouveaux points du croisement Rivage
  n := regexp_replace(def, '(\s)else null;(\s+)end case;', $r$\1when 'lots_construction' then
          detail := coalesce((select string_agg('lot ' || coalesce(nullif(a.data->>'reference', ''), a.id) || ' : ' || coalesce(pilotage.periode_construction(a.data), 'non renseignée'), ', ' order by a.data->>'reference')
                              from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
                                and a.data->>'nature' not in ('parking', 'box', 'basement')), 'Aucun lot bâti');
          vide := exists (select 1 from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
                            and a.data->>'nature' not in ('parking', 'box', 'basement') and pilotage.periode_construction(a.data) is null);
          if not vide then auto := 'ok'; end if;
        when 'lots_chauffage' then
          detail := (select string_agg('lot ' || coalesce(nullif(a.data->>'reference', ''), a.id) || ' : '
                       || coalesce(case a.data->'equipment'->>'heating_type' when 'individual' then 'individuel' when 'collective' then 'collectif' end, 'type ?') || ' '
                       || coalesce(case a.data->'equipment'->>'heating_method' when 'electric' then 'électrique' when 'gas' then 'gaz' when 'other' then 'autre énergie' end, 'énergie ?')
                       || ', eau chaude ' || coalesce(case a.data->'equipment'->>'hot_water_method' when 'electric' then 'électrique' when 'gas' then 'gaz' when 'other' then 'autre énergie' end, '?'),
                       ', ' order by a.data->>'reference')
                     from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
                       and a.data->>'nature' in ('flat', 'room', 'house'));
          if detail is null then auto := 'sans_objet'; detail := 'Aucun logement dans ce mandat.';
          else
            vide := exists (select 1 from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
                              and a.data->>'nature' in ('flat', 'room', 'house')
                              and (nullif(a.data->'equipment'->>'heating_type', '') is null or nullif(a.data->'equipment'->>'heating_method', '') is null
                                   or nullif(a.data->'equipment'->>'hot_water_method', '') is null));
            if not vide then auto := 'ok'; end if;
          end if;
        when 'lots_syndic' then
          detail := coalesce((select 'Syndic non renseigné dans Rivage pour : ' || string_agg('lot ' || coalesce(nullif(a.data->>'reference', ''), a.id), ', ' order by a.data->>'reference')
                              from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
                                and a.data->>'nature' <> 'house' and nullif(a.data->>'syndic_id', '') is null and not pilotage.lot_dans_immeuble(a.id)
                              having count(*) > 0), '');
          if detail = '' then
            auto := 'ok';
            detail := coalesce((select 'Syndic : ' || string_agg(distinct coalesce(pilotage.nom_profil(a.data->>'syndic_id'), 'renseigné'), ', ')
                                from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
                                  and nullif(a.data->>'syndic_id', '') is not null), 'Pas de copropriété (maison ou immeuble géré en entier)');
          else
            auto := 'anomalie';
            detail := detail || ' (sans objet si monopropriété : justifier)';
          end if;
        else null;\2end case;$r$);
  if n = def then raise exception '037 : point d''insertion introuvable dans controle_mandat'; end if;
  -- b) Diagnostics plomb et amiante d'après l'année ou la période de construction (Rivage)
  def := n;
  n := replace(def, $o$detail := 'Absent dans Rivage.';$o$, $r$detail := 'Absent dans Rivage.';
        if q.cle = 'm_doc_plomb' and not pilotage.mandat_exige_diag(p_mandat, 'plomb') then
          auto := 'sans_objet'; detail := 'Non exigé : aucun logement construit avant 1949 d''après Rivage (année ou période de construction).';
        elsif q.cle = 'm_doc_amiante' and not pilotage.mandat_exige_diag(p_mandat, 'amiante') then
          auto := 'sans_objet'; detail := 'Non exigé : lots construits après le 1er juillet 1997 d''après Rivage (permis à confirmer).';
        end if;$r$);
  if n = def then raise exception '037 : point d''insertion des diagnostics introuvable dans controle_mandat'; end if;
  execute n;
end $do$;

-- ========== 3. Immeubles ==========

-- Équipements d'un immeuble : même table que ceux des lots, rattachés au groupe Rivage (ag_…)
create or replace function pilotage.peut_traiter_lot(p_asset text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select pilotage.peut_suivre_baux()
      or (pilotage.mon_role() = 'negociateur' and (
            exists (select 1 from pilotage.objets a join pilotage.mandats_suivi s on s.mandat_id = a.data->>'management_contract_id'
                    where a.type in ('Asset', 'AssetGroup') and a.id = p_asset and s.negociateur = auth.uid())
         or exists (select 1 from pilotage.objets b join pilotage.baux_suivi s on s.bail_id = b.id
                    where b.type = 'LeasingContract' and b.data->>'asset_id' = p_asset and s.loue_par = auth.uid())))
$$;

create or replace function public.pilotage_lot_equipement(p_asset text, p_id bigint, p_nature text, p_libelle text, p_contrat boolean, p_prestataire text, p_dernier date,
  p_commentaire text, p_supprimer boolean, p_situation text default null, p_numero text default null, p_unite text default null, p_prix numeric default null)
returns bigint language plpgsql security definer set search_path = pilotage, public as $$
declare nid bigint;
begin
  if not pilotage.peut_traiter_lot(p_asset) then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.objets where type in ('Asset', 'AssetGroup') and id = p_asset) then raise exception 'Lot ou immeuble inconnu'; end if;
  if p_supprimer then delete from pilotage.lots_equipements where id = p_id and asset_id = p_asset; return p_id; end if;
  if nullif(trim(coalesce(p_libelle, '')), '') is null then raise exception 'Nom de l''équipement obligatoire'; end if;
  if p_id is null then
    insert into pilotage.lots_equipements (asset_id, nature, libelle, contrat_entretien, prestataire, dernier_entretien, commentaire, situation, numero, unite, prix_unitaire, par)
    values (p_asset, p_nature, trim(p_libelle), p_contrat, nullif(p_prestataire, ''), p_dernier, nullif(p_commentaire, ''), nullif(p_situation, ''), nullif(p_numero, ''),
            nullif(p_unite, ''), p_prix, auth.uid()) returning id into nid;
  else
    update pilotage.lots_equipements set libelle = trim(p_libelle), contrat_entretien = p_contrat, prestataire = nullif(p_prestataire, ''), dernier_entretien = p_dernier,
      commentaire = nullif(p_commentaire, ''), situation = nullif(p_situation, ''), numero = nullif(p_numero, ''), unite = coalesce(nullif(p_unite, ''), unite),
      prix_unitaire = p_prix, par = auth.uid(), le = now() where id = p_id and asset_id = p_asset;
    nid := p_id;
  end if;
  return nid;
end $$;

-- Calendriers des suivis d'immeuble (tâches de la gestionnaire)
insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele) values
  ('entretien_immeuble', 1, -30, 'Planifier l''entretien avec le prestataire', 'tache', null),
  ('entretien_immeuble', 2, 15, 'Entretien non justifié : relancer le prestataire et demander l''attestation', 'tache', null),
  ('ascenseur_ct', 1, -60, 'Commander le contrôle technique quinquennal de l''ascenseur', 'tache', null),
  ('ascenseur_ct', 2, 0, 'Contrôle technique de l''ascenseur dû : vérifier le rapport', 'tache', null),
  ('assurance_immeuble', 1, -30, 'Demander l''attestation de renouvellement de l''assurance de l''immeuble', 'tache', null),
  ('assurance_immeuble', 2, 1, 'Assurance de l''immeuble non justifiée : relancer l''assureur ou le bailleur', 'tache', null)
on conflict (nature, ordre) do update set jours = excluded.jours, libelle = excluded.libelle, canal = excluded.canal, modele = excluded.modele;

create unique index if not exists mandats_obligations_equipement_immeuble on pilotage.mandats_obligations (equipement_id) where nature = 'entretien_immeuble';
create unique index if not exists mandats_obligations_ascenseur on pilotage.mandats_obligations (equipement_id) where nature = 'ascenseur_ct';

-- Création automatique : un suivi d'entretien annuel par équipement d'immeuble (+ contrôle quinquennal pour un ascenseur)
create or replace function pilotage.immeubles_suivis_auto() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer := 0; k integer;
begin
  insert into pilotage.mandats_obligations (mandat_id, asset_id, equipement_id, nature, libelle, periodicite_mois, prochaine, auto)
  select g.data->>'management_contract_id', e.asset_id, e.id, 'entretien_immeuble', 'Entretien ' || lower(e.libelle) || ' (immeuble ' || coalesce(g.data->>'name', '') || ')', 12,
         case when e.dernier_entretien is not null then greatest(pilotage.ajouter_mois(e.dernier_entretien, 12), current_date) else current_date + 30 end, true
  from pilotage.lots_equipements e
  join pilotage.objets g on g.type = 'AssetGroup' and g.id = e.asset_id and g.supprime_le is null and g.data->>'management_contract_id' is not null
  where e.nature = 'equipement'
  on conflict (equipement_id) where nature = 'entretien_immeuble' do nothing;
  get diagnostics k = row_count; n := n + k;
  insert into pilotage.mandats_obligations (mandat_id, asset_id, equipement_id, nature, libelle, periodicite_mois, prochaine, auto)
  select g.data->>'management_contract_id', e.asset_id, e.id, 'ascenseur_ct', 'Contrôle technique de l''ascenseur (immeuble ' || coalesce(g.data->>'name', '') || ')', 60,
         current_date + 60, true
  from pilotage.lots_equipements e
  join pilotage.objets g on g.type = 'AssetGroup' and g.id = e.asset_id and g.supprime_le is null and g.data->>'management_contract_id' is not null
  where e.nature = 'equipement' and pilotage.sans_accents(e.libelle) ~* 'ascenseur'
  on conflict (equipement_id) where nature = 'ascenseur_ct' do nothing;
  get diagnostics k = row_count; n := n + k;
  update pilotage.mandats_obligations o set actif = false
  where o.nature in ('entretien_immeuble', 'ascenseur_ct') and o.actif and not exists (select 1 from pilotage.lots_equipements e where e.id = o.equipement_id);
  return n;
end $$;

-- Immeubles d'un mandat pour l'écran : lots rattachés, équipements communs, suivis
create or replace function public.pilotage_mandat_immeubles(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_traiter_dossier('mandat', p_mandat) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'nom', g.data->>'name', 'reference', g.data->>'reference',
      'lots', coalesce((select jsonb_agg(coalesce(nullif(a.data->>'reference', ''), a.id) order by a.data->>'reference')
                        from pilotage.objets m join pilotage.objets a on a.type = 'Asset' and a.id = m.data->>'asset_id' and a.supprime_le is null
                        where m.type = 'AssetGroupMembership' and m.supprime_le is null and m.data->>'asset_group_id' = g.id and nullif(m.data->>'end_date', '') is null), '[]'::jsonb),
      'equipements', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nature', e.nature, 'libelle', e.libelle, 'contrat_entretien', e.contrat_entretien,
                       'prestataire', e.prestataire, 'dernier_entretien', e.dernier_entretien, 'commentaire', e.commentaire) order by e.libelle)
                       from pilotage.lots_equipements e where e.asset_id = g.id), '[]'::jsonb),
      'assurance', (select jsonb_build_object('id', o.id, 'prochaine', o.prochaine) from pilotage.mandats_obligations o
                    where o.asset_id = g.id and o.nature = 'assurance_immeuble' and o.actif order by o.prochaine limit 1))
    order by g.data->>'name')
    from pilotage.objets g where g.type = 'AssetGroup' and g.supprime_le is null and g.data->>'nature' = 'building'
      and g.data->>'management_contract_id' = p_mandat), '[]'::jsonb);
end $$;

-- Saisie de l'assurance de l'immeuble : ouverte aussi au commercial du mandat (contrôle d'entrée)
create or replace function public.pilotage_immeuble_assurance(p_mandat text, p_immeuble text, p_echeance date) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_traiter_dossier('mandat', p_mandat) then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.objets where type = 'AssetGroup' and id = p_immeuble and data->>'management_contract_id' = p_mandat) then raise exception 'Immeuble inconnu'; end if;
  if p_echeance is null then raise exception 'Date d''échéance de l''assurance obligatoire'; end if;
  update pilotage.mandats_obligations set prochaine = p_echeance, actif = true where asset_id = p_immeuble and nature = 'assurance_immeuble';
  if not found then
    insert into pilotage.mandats_obligations (mandat_id, asset_id, nature, libelle, periodicite_mois, prochaine, par)
    values (p_mandat, p_immeuble, 'assurance_immeuble', 'Assurance de l''immeuble ' || coalesce((select data->>'name' from pilotage.objets where id = p_immeuble and type = 'AssetGroup'), ''),
            12, p_echeance, auth.uid());
  end if;
end $$;

-- ========== 4. Lecture des états des lieux : propositions d'équipements et de compteurs ==========

create table if not exists pilotage.edl_lectures (
  upload_id text primary key, asset_id text not null, lu_le timestamptz not null default now(), modele text, resultat jsonb
);
create table if not exists pilotage.lots_propositions (
  id bigserial primary key, asset_id text not null, upload_id text not null,
  nature text not null check (nature in ('equipement', 'compteur')),
  libelle text not null, situation text, numero text, index_releve numeric(14,3), date_releve date, extrait text, page integer,
  statut text not null default 'propose' check (statut in ('propose', 'accepte', 'ignore')),
  traite_par uuid, traite_le timestamptz, cree_le timestamptz not null default now()
);
create index if not exists lots_propositions_lot on pilotage.lots_propositions (asset_id) where statut = 'propose';
alter table pilotage.edl_lectures enable row level security;
alter table pilotage.lots_propositions enable row level security;
revoke all on pilotage.edl_lectures, pilotage.lots_propositions from public, anon, authenticated;
revoke all on sequence pilotage.lots_propositions_id_seq from public, anon, authenticated;

-- États des lieux déposés dans Rivage (catégorie « État des lieux d'entrée », ou nom du fichier) sur un lot ou un bail, pas encore lus.
-- Priorité aux lots des mandats et baux soumis au contrôle d'entrée, puis au plus récent.
create or replace function public.pilotage_edl_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(t.x order by t.prio, t.maj desc), '[]'::jsonb) from (
    select * from (
      select distinct on (u.id)
             jsonb_build_object('upload_id', u.id, 'asset_id', a.id, 'url', u.data->>'file_url', 'libelle', u.data->>'label') x,
             case when (select m.debut from pilotage.v_mandats m where m.id = a.data->>'management_contract_id') >= date '2026-01-01' then 0 else 1 end prio,
             u.maj_le maj
      from pilotage.objets u
      cross join lateral (select r->>'id' rid from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) r) rr
      join pilotage.objets a on a.type = 'Asset' and a.supprime_le is null
        and (a.id = rr.rid or a.id = (select b.data->>'asset_id' from pilotage.objets b where b.type = 'LeasingContract' and b.id = rr.rid))
      where u.type = 'Upload' and u.supprime_le is null and nullif(u.data->>'file_url', '') is not null
        and (u.data->>'nature' = 'move_in_inventory' or pilotage.sans_accents(coalesce(u.data->>'label', '')) ~* '(etat des lieux d.?entree|\medl\M)')
        and not exists (select 1 from pilotage.edl_lectures l where l.upload_id = u.id)
      order by u.id) d
    order by prio, maj desc limit p_max) t
$$;

-- Résultat de la lecture : une proposition par équipement ou compteur qui n'existe pas déjà sur le lot
create or replace function public.pilotage_edl_ecrire(p_upload text, p_asset text, p_modele text, p_resultat jsonb) returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer := 0; e jsonb;
begin
  insert into pilotage.edl_lectures (upload_id, asset_id, modele, resultat) values (p_upload, p_asset, p_modele, p_resultat)
  on conflict (upload_id) do update set lu_le = now(), modele = excluded.modele, resultat = excluded.resultat;
  for e in select * from jsonb_array_elements(coalesce(p_resultat->'equipements', '[]'::jsonb)) loop
    if nullif(trim(coalesce(e->>'libelle', '')), '') is null then continue; end if;
    if exists (select 1 from pilotage.lots_equipements x where x.asset_id = p_asset and x.nature = 'equipement'
               and pilotage.sans_accents(lower(x.libelle)) = pilotage.sans_accents(lower(e->>'libelle'))) then continue; end if;
    if exists (select 1 from pilotage.lots_propositions x where x.asset_id = p_asset and x.nature = 'equipement'
               and pilotage.sans_accents(lower(x.libelle)) = pilotage.sans_accents(lower(e->>'libelle'))) then continue; end if;
    insert into pilotage.lots_propositions (asset_id, upload_id, nature, libelle, extrait, page)
    values (p_asset, p_upload, 'equipement', trim(e->>'libelle'), left(e->>'extrait', 300), nullif(e->>'page', '')::integer);
    n := n + 1;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(p_resultat->'compteurs', '[]'::jsonb)) loop
    if nullif(trim(coalesce(e->>'libelle', '')), '') is null then continue; end if;
    if exists (select 1 from pilotage.lots_propositions x where x.asset_id = p_asset and x.nature = 'compteur' and x.upload_id = p_upload
               and lower(x.libelle) = lower(e->>'libelle') and coalesce(x.numero, '') = coalesce(e->>'numero', '')) then continue; end if;
    insert into pilotage.lots_propositions (asset_id, upload_id, nature, libelle, situation, numero, index_releve, date_releve, extrait, page)
    values (p_asset, p_upload, 'compteur', trim(e->>'libelle'), nullif(e->>'situation', ''), nullif(e->>'numero', ''),
            case when (e->>'index') ~ '^[0-9]+([.,][0-9]+)?$' then replace(e->>'index', ',', '.')::numeric end,
            case when (e->>'date') ~ '^\d{4}-\d{2}-\d{2}$' then (e->>'date')::date end, left(e->>'extrait', 300), nullif(e->>'page', '')::integer);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Propositions en attente pour les lots d'un mandat
create or replace function public.pilotage_mandat_propositions(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_traiter_dossier('mandat', p_mandat) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'asset_id', p.asset_id, 'nature', p.nature, 'libelle', p.libelle, 'situation', p.situation,
           'numero', p.numero, 'index', p.index_releve, 'date', p.date_releve, 'extrait', p.extrait, 'page', p.page,
           'document', (select u.data->>'label' from pilotage.objets u where u.type = 'Upload' and u.id = p.upload_id)) order by p.asset_id, p.nature, p.libelle)
    from pilotage.lots_propositions p join pilotage.objets a on a.type = 'Asset' and a.id = p.asset_id
    where p.statut = 'propose' and a.data->>'management_contract_id' = p_mandat), '[]'::jsonb);
end $$;

-- Confirmer (création de l'équipement ou du compteur, avec son relevé d'entrée) ou ignorer une proposition
create or replace function public.pilotage_lot_proposition(p_id bigint, p_accepter boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare p pilotage.lots_propositions; nid bigint;
begin
  select * into p from pilotage.lots_propositions where id = p_id;
  if p.id is null then raise exception 'Proposition introuvable'; end if;
  if not pilotage.peut_traiter_lot(p.asset_id) then raise exception 'Accès refusé'; end if;
  if p.statut <> 'propose' then raise exception 'Proposition déjà traitée'; end if;
  if p_accepter then
    insert into pilotage.lots_equipements (asset_id, nature, libelle, situation, numero, commentaire, unite, par)
    values (p.asset_id, p.nature, p.libelle, case when p.nature = 'compteur' then p.situation end, p.numero,
            'Repris de l''état des lieux' || coalesce(' (page ' || p.page || ')', ''),
            case when p.nature = 'compteur' then case when pilotage.sans_accents(lower(p.libelle)) ~ '(eau|gaz)' then 'm³' else 'kWh' end end, auth.uid())
    returning id into nid;
    if p.nature = 'compteur' and p.index_releve is not null and p.date_releve is not null then
      insert into pilotage.compteurs_releves (equipement_id, releve_le, index_releve, type, commentaire, par)
      values (nid, p.date_releve, p.index_releve, 'entree', 'Index de l''état des lieux d''entrée', auth.uid());
    end if;
  end if;
  update pilotage.lots_propositions set statut = case when p_accepter then 'accepte' else 'ignore' end, traite_par = auth.uid(), traite_le = now() where id = p_id;
end $$;

select cron.unschedule('pilotage-lecture-edl') where exists (select 1 from cron.job where jobname = 'pilotage-lecture-edl');
select cron.schedule('pilotage-lecture-edl', '40 * * * *', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-lecture-bail',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{"edl": true}'::jsonb, timeout_milliseconds := 300000) $$);

select cron.unschedule('pilotage-suivis-mandats') where exists (select 1 from cron.job where jobname = 'pilotage-suivis-mandats');
select cron.schedule('pilotage-suivis-mandats', '20,50 * * * *', $$ select pilotage.mandats_suivis_auto(); select pilotage.immeubles_suivis_auto(); $$);

revoke all on all functions in schema pilotage from public, anon, authenticated;
revoke all on function public.pilotage_questions_mandat(text), public.pilotage_edl_a_lire(integer), public.pilotage_edl_ecrire(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.pilotage_mandat_propositions(text), public.pilotage_lot_proposition(bigint, boolean) from public, anon;
grant execute on function public.pilotage_mandat_propositions(text), public.pilotage_lot_proposition(bigint, boolean) to authenticated;
revoke all on function public.pilotage_mandat_immeubles(text), public.pilotage_immeuble_assurance(text, text, date),
  public.pilotage_lot_equipement(text, bigint, text, text, boolean, text, date, text, boolean, text, text, text, numeric) from public, anon;
grant execute on function public.pilotage_mandat_immeubles(text), public.pilotage_immeuble_assurance(text, text, date),
  public.pilotage_lot_equipement(text, bigint, text, text, boolean, text, date, text, boolean, text, text, text, numeric) to authenticated;

select pilotage.immeubles_suivis_auto();
select pilotage.rafraichir_baux();
