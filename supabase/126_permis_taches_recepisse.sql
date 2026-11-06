-- 126 : permis de louer, accusé de réception des déclarations, tâches et mises à jour par lot (bloc 1 sur 3)
--  Demandes de Nicolas du 06/11/2026 :
--   - éditer une déclaration de mise en location pour y noter la date de l'accusé de réception de la mairie (lot 443, 14 rue Jean Piestre,
--     bail 517) ; la date de dépôt et le n° de dossier se corrigent au même endroit ;
--   - ajouter des tâches et des mises à jour aux déclarations et permis de louer. Choix de Nicolas : la tâche (libellé, échéance, personne)
--     remonte dans Ma journée de la personne choisie à son échéance ; les mises à jour (commentaires de l'équipe) forment un fil par lot,
--     commun à toutes ses démarches de permis, visible partout où le permis du lot s'affiche (fiches mandat et bail, À louer).
--  Bloc 1 : tables et fonctions des fiches. Bloc 2 : la tâche dans Ma journée. Bloc 3 : vérification.

-- Déclaration : accusé de réception
alter table pilotage.permis_demandes add column if not exists recepisse_le date;

create or replace function public.pilotage_permis_demande_maj(p_demande bigint, p_depot_le date, p_numero text, p_recepisse_le date)
returns bigint language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare d pilotage.permis_demandes;
begin
  select * into d from pilotage.permis_demandes where id = p_demande;
  if d.id is null then raise exception 'Demande introuvable'; end if;
  if not pilotage.peut_traiter_lot(d.asset_id) then raise exception 'Accès refusé'; end if;
  if d.close_le is not null then raise exception 'Demande close : plus modifiable'; end if;
  -- déclarations seulement : pour une autorisation, la date de dépôt fixe l'échéance de la réponse (suivi J+30), à ne pas décaler ici
  if d.regime <> 'declaration' then raise exception 'Seule une déclaration de mise en location se modifie ici'; end if;
  if p_depot_le is null then raise exception 'La date de dépôt est obligatoire'; end if;
  if p_depot_le > current_date or p_recepisse_le > current_date then raise exception 'Une date ne peut pas être dans le futur'; end if;
  if p_recepisse_le < p_depot_le then raise exception 'L''accusé de réception ne peut pas précéder le dépôt'; end if;
  update pilotage.permis_demandes set depot_le = p_depot_le, numero = nullif(trim(p_numero), ''), recepisse_le = p_recepisse_le where id = d.id;
  return d.id;
end $$;

-- Mises à jour (fil par lot) et tâches
create table if not exists pilotage.permis_notes (
  id bigserial primary key,
  asset_id text not null,
  contenu text not null check (nullif(trim(contenu), '') is not null),
  auteur_id uuid,
  le timestamptz not null default now(),
  supprime_le timestamptz
);
create index if not exists permis_notes_lot on pilotage.permis_notes (asset_id, le desc) where supprime_le is null;

create table if not exists pilotage.permis_taches (
  id bigserial primary key,
  asset_id text not null,
  demande_id bigint references pilotage.permis_demandes (id),
  libelle text not null check (nullif(trim(libelle), '') is not null),
  echeance date not null,
  assigne uuid not null,                   -- pilotage.membres.user_id : reçoit la tâche dans Ma journée à l'échéance
  cree_par uuid,
  cree_le timestamptz not null default now(),
  faite_le timestamptz,
  faite_par uuid,
  supprime_le timestamptz
);
create index if not exists permis_taches_lot on pilotage.permis_taches (asset_id) where supprime_le is null;

do $$
declare t text;
begin
  foreach t in array array['permis_notes', 'permis_taches'] loop
    execute format('alter table pilotage.%I enable row level security', t);
    execute format('revoke all on pilotage.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- Une tâche créée, faite ou supprimée met Ma journée à jour dans la minute (mécanisme du 124)
drop trigger if exists controles_demande on pilotage.permis_taches;
create trigger controles_demande after insert or update or delete on pilotage.permis_taches
  for each statement execute function pilotage.controles_demander();

-- Fil et tâches d'un lot (mêmes droits que les démarches du permis : pilotage.peut_traiter_lot)
create or replace function public.pilotage_permis_fil(p_asset text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if not pilotage.peut_traiter_lot(p_asset) then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'moi', auth.uid(),
    'membres', coalesce((select jsonb_agg(jsonb_build_object('id', user_id, 'prenom', prenom) order by prenom) from pilotage.membres where actif), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'contenu', n.contenu, 'le', n.le, 'auteur_id', n.auteur_id,
        'auteur', (select m.prenom from pilotage.membres m where m.user_id = n.auteur_id)) order by n.le desc)
      from pilotage.permis_notes n where n.asset_id = p_asset and n.supprime_le is null), '[]'::jsonb),
    'taches', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'libelle', t.libelle, 'echeance', t.echeance, 'demande_id', t.demande_id,
        'assigne', t.assigne, 'assigne_prenom', (select m.prenom from pilotage.membres m where m.user_id = t.assigne),
        'cree_par', (select m.prenom from pilotage.membres m where m.user_id = t.cree_par), 'cree_le', t.cree_le,
        'faite_le', t.faite_le, 'faite_par', (select m.prenom from pilotage.membres m where m.user_id = t.faite_par))
        order by (t.faite_le is not null), t.echeance, t.id)
      from pilotage.permis_taches t where t.asset_id = p_asset and t.supprime_le is null), '[]'::jsonb));
end $$;

create or replace function public.pilotage_permis_note(p_asset text, p_contenu text, p_supprimer bigint default null) returns bigint
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v bigint;
begin
  if not pilotage.peut_traiter_lot(p_asset) then raise exception 'Accès refusé'; end if;
  if p_supprimer is not null then  -- son propre message seulement ; la ligne reste en base
    update pilotage.permis_notes set supprime_le = now() where id = p_supprimer and asset_id = p_asset and auteur_id = auth.uid() and supprime_le is null returning id into v;
    if v is null then raise exception 'Seul l''auteur peut retirer son message'; end if;
    return v;
  end if;
  if nullif(trim(p_contenu), '') is null then raise exception 'Message vide'; end if;
  if not exists (select 1 from pilotage.objets where type = 'Asset' and id = p_asset) then raise exception 'Lot inconnu dans Rivage'; end if;
  insert into pilotage.permis_notes (asset_id, contenu, auteur_id) values (p_asset, trim(p_contenu), auth.uid()) returning id into v;
  return v;
end $$;

-- p_action : creer, modifier, faite, rouvrir, supprimer
create or replace function public.pilotage_permis_tache(p_action text, p_id bigint, p_asset text, p_demande bigint, p_libelle text, p_echeance date, p_assigne uuid)
returns bigint language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare t pilotage.permis_taches; v bigint;
begin
  if p_action = 'creer' then
    if not pilotage.peut_traiter_lot(p_asset) then raise exception 'Accès refusé'; end if;
    if not exists (select 1 from pilotage.objets where type = 'Asset' and id = p_asset) then raise exception 'Lot inconnu dans Rivage'; end if;
    if p_demande is not null and not exists (select 1 from pilotage.permis_demandes where id = p_demande and asset_id = p_asset) then raise exception 'Démarche introuvable'; end if;
  else
    select * into t from pilotage.permis_taches where id = p_id and supprime_le is null;
    if t.id is null then raise exception 'Tâche introuvable'; end if;
    if not pilotage.peut_traiter_lot(t.asset_id) then raise exception 'Accès refusé'; end if;
  end if;
  if p_action in ('creer', 'modifier') then
    if nullif(trim(p_libelle), '') is null then raise exception 'Indiquer la tâche'; end if;
    if p_echeance is null then raise exception 'Indiquer l''échéance'; end if;
    if not exists (select 1 from pilotage.membres where user_id = p_assigne and actif) then raise exception 'Choisir la personne'; end if;
  end if;
  if p_action = 'creer' then
    insert into pilotage.permis_taches (asset_id, demande_id, libelle, echeance, assigne, cree_par)
    values (p_asset, p_demande, trim(p_libelle), p_echeance, p_assigne, auth.uid()) returning id into v;
    return v;
  elsif p_action = 'modifier' then
    update pilotage.permis_taches set libelle = trim(p_libelle), echeance = p_echeance, assigne = p_assigne where id = t.id;
  elsif p_action = 'faite' then
    update pilotage.permis_taches set faite_le = now(), faite_par = auth.uid() where id = t.id;
  elsif p_action = 'rouvrir' then
    update pilotage.permis_taches set faite_le = null, faite_par = null where id = t.id;
  elsif p_action = 'supprimer' then
    update pilotage.permis_taches set supprime_le = now() where id = t.id;
  else raise exception 'Action inconnue'; end if;
  return t.id;
end $$;

do $$
declare f text;
begin
  foreach f in array array['pilotage_permis_demande_maj(bigint, date, text, date)', 'pilotage_permis_fil(text)',
    'pilotage_permis_note(text, text, bigint)', 'pilotage_permis_tache(text, bigint, text, bigint, text, date, uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- 126 : permis de louer, accusé de réception des déclarations, tâches et mises à jour par lot (bloc 2 sur 3)
--  La tâche dans Ma journée : règle « permis_tache », destinataire nouveau « personne » (celle choisie dans la tâche),
--  alerte ouverte le jour de l'échéance, fermée quand la tâche est faite ou supprimée. Objet de l'alerte : la tâche (type PermisTache),
--  rattachée au mandat du lot (« Ouvrir la fiche » ouvre le mandat, où se trouve le permis du lot).

alter table pilotage.regles drop constraint if exists regles_destinataire_check;
alter table pilotage.regles add constraint regles_destinataire_check check (destinataire = any (array['gestion', 'compta', 'direction', 'commercial', 'personne']));

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire)
values ('permis_tache', 'Tâche du permis de louer', 'Lots', 'haute', 'tache', true,
  'Tâche créée dans le suivi du permis de louer d''un lot (déclaration ou autorisation) : elle arrive dans Ma journée de la personne choisie le jour de son échéance et disparaît quand elle est cochée « faite » ou supprimée.',
  '[]'::jsonb, 'personne')
on conflict (cle) do nothing;

create or replace function pilotage.permis_taches_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select 'permis_tache', 'PermisTache', t.id::text,
    'Lot ' || coalesce(nullif(l.reference, ''), l.id) || ' · permis de louer : ' || t.libelle,
    'Échéance le ' || to_char(t.echeance, 'DD/MM/YYYY') || case when t.echeance < current_date then ' (en retard de ' || (current_date - t.echeance) || ' j)' else '' end
      || ' · ' || coalesce(l.adresse, '') || coalesce(' · tâche créée par ' || (select m.prenom from pilotage.membres m where m.user_id = t.cree_par), ''),
    'https://rivage.immo/asset_list'
  from pilotage.permis_taches t join pilotage.v_lots l on l.id = t.asset_id
  where t.supprime_le is null and t.faite_le is null and t.echeance <= current_date
$$;
revoke all on function pilotage.permis_taches_detections() from public, anon, authenticated;

-- Le contrôle complet lit aussi les tâches : ajout d'une ligne à executer_controles, texte en place repris tel quel
do $$
declare def text; ancre text := 'from pilotage.factures_detections() x;';
begin
  def := pg_get_functiondef('pilotage.executer_controles()'::regprocedure);
  if position('permis_taches_detections' in def) > 0 then return; end if;  -- déjà fait
  if (length(def) - length(replace(def, ancre, ''))) / length(ancre) <> 1 then raise exception 'executer_controles : point d''insertion introuvable, rien n''est modifié'; end if;
  execute replace(def, ancre, 'from pilotage.factures_detections() x' || E'\n  union all\n  select k.regle, k.objet_type, k.objet_id, k.titre, k.detail, k.lien from pilotage.permis_taches_detections() k;');
end $$;

-- Visibilité : une alerte « personne » ne va qu'à la personne choisie ; le reste inchangé (texte du 094 repris)
create or replace function pilotage.alerte_visible_objet(p_regle text, p_mandat text, p_user uuid, p_type text, p_objet text)
returns boolean language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare c uuid;
begin
  if p_type = 'PermisTache' then
    return exists (select 1 from pilotage.permis_taches t where t.id::text = p_objet and t.assigne = p_user);
  end if;
  if coalesce((select r.destinataire from pilotage.regles r where r.cle = p_regle), 'gestion') <> 'commercial' then
    return pilotage.alerte_visible(p_regle, p_mandat, p_user);
  end if;
  c := case p_type when 'LeasingContract' then pilotage.commercial_dossier('bail', p_objet)
                   when 'ManagementContract' then pilotage.commercial_dossier('mandat', p_objet) end;
  if c is not null then return c = p_user; end if;
  return exists (select 1 from pilotage.membres m where m.user_id = p_user and m.actif and m.role = 'negociateur');
end $$;

-- Rattachement au mandat : la tâche suit le mandat de son lot (texte en place repris, une branche ajoutée)
create or replace function pilotage.mandat_de(p_type text, p_id text)
returns text language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select case p_type
    when 'ManagementContract' then p_id
    when 'Asset' then (select data->>'management_contract_id' from pilotage.objets where type = 'Asset' and id = p_id)
    when 'LeasingContract' then (select a.data->>'management_contract_id' from pilotage.objets b join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id' where b.type = 'LeasingContract' and b.id = p_id)
    when 'Upload' then (select a.data->>'management_contract_id' from pilotage.objets u join pilotage.objets a on a.type = 'Asset' and a.id = u.data->'resourceables'->0->>'id' where u.type = 'Upload' and u.id = p_id)
    when 'PermisTache' then (select a.data->>'management_contract_id' from pilotage.permis_taches t join pilotage.objets a on a.type = 'Asset' and a.id = t.asset_id where t.id::text = p_id)
  end
$$;

-- 126 : permis de louer, accusé de réception des déclarations, tâches et mises à jour par lot (bloc 3 sur 3)
select (select count(*) from information_schema.columns where table_schema = 'pilotage' and table_name = 'permis_demandes' and column_name = 'recepisse_le') as colonne_recepisse,
  to_regclass('pilotage.permis_notes') is not null as table_notes, to_regclass('pilotage.permis_taches') is not null as table_taches,
  (select destinataire from pilotage.regles where cle = 'permis_tache') as regle_permis_tache,
  position('permis_taches_detections' in pg_get_functiondef('pilotage.executer_controles()'::regprocedure)) > 0 as controle_branche,
  position('PermisTache' in pg_get_functiondef('pilotage.alerte_visible_objet(text,text,uuid,text,text)'::regprocedure)) > 0 as visibilite;
