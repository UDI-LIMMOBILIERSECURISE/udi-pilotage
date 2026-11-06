-- 127 : Tickets (ex-Sinistres) : tags Rivage des incidents, rappels et notifications vers Ma journée (bloc 1 sur 2)
--  Demandes de Nicolas du 06/11/2026 :
--   - le menu « Sinistres » devient « Tickets » : tous les incidents Rivage (et les dossiers repris de Monday et WeRoof), avec le pipeline
--     des statuts actuel et un filtre par tags. Rivage a ajouté un champ tags aux incidents (constat du 06/11 : présent dans les webhooks
--     depuis 17 h 28, vide sur les 46 incidents à cette heure ; forme des tags à confirmer quand le premier arrivera) ;
--   - dans la fiche d'un ticket : se mettre un rappel ou notifier un membre de l'équipe ; la notification arrive dans Ma journée
--     de la personne (le rappel : le jour choisi). Même mécanisme que les tâches du permis (126) : destinataire « personne ».
--  Prérequis : script 126 passé (destinataire « personne », alerte_visible_objet et mandat_de du 126).

-- Tags de l'incident dans la liste des tickets (ligne ajoutée au texte en place de pilotage_sinistres)
do $$
declare def text; ancre text := '''statut'', i.data->>''status'',';
begin
  def := pg_get_functiondef('public.pilotage_sinistres()'::regprocedure);
  if position('''tags''' in def) > 0 then return; end if;
  if (length(def) - length(replace(def, ancre, ''))) / length(ancre) <> 1 then raise exception 'pilotage_sinistres : point d''insertion introuvable, rien n''est modifié'; end if;
  execute replace(def, ancre, ancre || ' ''tags'', coalesce(i.data->''tags'', ''[]''::jsonb),');
end $$;

create table if not exists pilotage.tickets_rappels (
  id bigserial primary key,
  ticket_id text not null,                  -- id de l'incident Rivage (inc_…) ou du dossier repris (monday_…)
  ticket_titre text,                        -- titre au moment de la création, pour Ma journée
  nature text not null check (nature in ('rappel', 'notification')),
  destinataire uuid not null,               -- pilotage.membres.user_id
  message text,
  echeance date not null,                   -- notification : le jour même ; rappel : le jour choisi
  auteur uuid,
  cree_le timestamptz not null default now(),
  fait_le timestamptz,
  supprime_le timestamptz
);
create index if not exists tickets_rappels_ticket on pilotage.tickets_rappels (ticket_id) where supprime_le is null;
alter table pilotage.tickets_rappels enable row level security;
revoke all on pilotage.tickets_rappels from public, anon, authenticated;
drop trigger if exists controles_demande on pilotage.tickets_rappels;
create trigger controles_demande after insert or update or delete on pilotage.tickets_rappels
  for each statement execute function pilotage.controles_demander();

create or replace function public.pilotage_ticket_rappels(p_ticket text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return jsonb_build_object('moi', auth.uid(),
    'membres', coalesce((select jsonb_agg(jsonb_build_object('id', user_id, 'prenom', prenom) order by prenom) from pilotage.membres where actif), '[]'::jsonb),
    'rappels', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'nature', r.nature, 'message', r.message, 'echeance', r.echeance, 'cree_le', r.cree_le, 'fait_le', r.fait_le,
        'destinataire', r.destinataire, 'destinataire_prenom', (select m.prenom from pilotage.membres m where m.user_id = r.destinataire),
        'auteur', r.auteur, 'auteur_prenom', (select m.prenom from pilotage.membres m where m.user_id = r.auteur))
        order by (r.fait_le is not null), r.echeance, r.id)
      from pilotage.tickets_rappels r where r.ticket_id = p_ticket and r.supprime_le is null), '[]'::jsonb));
end $$;

-- p_action : creer, fait, rouvrir, supprimer. Un rappel est pour soi ; une notification pour un autre membre.
create or replace function public.pilotage_ticket_rappel(p_action text, p_id bigint, p_ticket text, p_titre text, p_nature text, p_destinataire uuid, p_message text, p_echeance date)
returns bigint language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare r pilotage.tickets_rappels; v bigint;
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  if p_action = 'creer' then
    if nullif(trim(p_ticket), '') is null then raise exception 'Ticket inconnu'; end if;
    if p_nature not in ('rappel', 'notification') then raise exception 'Rappel ou notification ?'; end if;
    if p_nature = 'rappel' then p_destinataire := auth.uid(); end if;
    if not exists (select 1 from pilotage.membres where user_id = p_destinataire and actif) then raise exception 'Choisir la personne à notifier'; end if;
    if p_nature = 'notification' and nullif(trim(p_message), '') is null then raise exception 'Écrire le message de la notification'; end if;
    p_echeance := case when p_nature = 'notification' then current_date else coalesce(p_echeance, current_date + 1) end;
    if p_echeance < current_date then raise exception 'La date du rappel est passée'; end if;
    insert into pilotage.tickets_rappels (ticket_id, ticket_titre, nature, destinataire, message, echeance, auteur)
    values (p_ticket, nullif(trim(p_titre), ''), p_nature, p_destinataire, nullif(trim(p_message), ''), p_echeance, auth.uid()) returning id into v;
    return v;
  end if;
  select * into r from pilotage.tickets_rappels where id = p_id and supprime_le is null;
  if r.id is null then raise exception 'Rappel introuvable'; end if;
  -- le destinataire, l'auteur ou la direction
  if not (auth.uid() in (r.destinataire, r.auteur) or pilotage.mon_role() in ('direction', 'superviseur')) then raise exception 'Réservé au destinataire ou à l''auteur'; end if;
  if p_action = 'fait' then update pilotage.tickets_rappels set fait_le = now() where id = r.id;
  elsif p_action = 'rouvrir' then update pilotage.tickets_rappels set fait_le = null where id = r.id;
  elsif p_action = 'supprimer' then update pilotage.tickets_rappels set supprime_le = now() where id = r.id;
  else raise exception 'Action inconnue'; end if;
  return r.id;
end $$;

do $$
declare f text;
begin
  foreach f in array array['pilotage_ticket_rappels(text)', 'pilotage_ticket_rappel(text, bigint, text, text, text, uuid, text, date)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- Ma journée : règle « ticket_rappel », alerte le jour de l'échéance, pour le destinataire seulement
insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire)
values ('ticket_rappel', 'Ticket : rappel ou notification', 'Entretien et contrats', 'haute', 'tache', true,
  'Rappel qu''un membre s''est mis sur un ticket (incident Rivage ou dossier repris), ou notification envoyée par un collègue : arrive dans Ma journée de la personne le jour prévu ; disparaît quand elle est marquée faite (ici ou dans la fiche du ticket).',
  '[]'::jsonb, 'personne')
on conflict (cle) do nothing;

create or replace function pilotage.tickets_rappels_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select 'ticket_rappel', 'TicketRappel', r.id::text,
    case r.nature when 'notification' then 'Notification de ' || coalesce((select m.prenom from pilotage.membres m where m.user_id = r.auteur), '?') else 'Rappel' end
      || ' · ' || coalesce(case when i.id is not null then 'incident n°' || (i.data->>'number') || ' ' || (i.data->>'title') end, r.ticket_titre, 'ticket'),
    concat_ws(' · ', r.message, case when r.nature = 'rappel' then 'prévu le ' || to_char(r.echeance, 'DD/MM/YYYY') end,
      'créé le ' || to_char(r.cree_le at time zone 'Europe/Paris', 'DD/MM/YYYY')),
    case when i.id is not null then 'https://rivage.immo/incidents/' || i.id else null end
  from pilotage.tickets_rappels r left join pilotage.objets i on i.type = 'Incident' and i.id = r.ticket_id
  where r.supprime_le is null and r.fait_le is null and r.echeance <= current_date
$$;
revoke all on function pilotage.tickets_rappels_detections() from public, anon, authenticated;

do $$
declare def text; ancre text := 'from pilotage.permis_taches_detections() k;';
begin
  def := pg_get_functiondef('pilotage.executer_controles()'::regprocedure);
  if position('tickets_rappels_detections' in def) > 0 then return; end if;
  if (length(def) - length(replace(def, ancre, ''))) / length(ancre) <> 1 then raise exception 'executer_controles : point d''insertion introuvable (script 126 passé ?), rien n''est modifié'; end if;
  execute replace(def, ancre, 'from pilotage.permis_taches_detections() k' || E'\n  union all\n  select t.regle, t.objet_type, t.objet_id, t.titre, t.detail, t.lien from pilotage.tickets_rappels_detections() t;');
end $$;

-- Visibilité : tâche du permis (126) et rappel de ticket vont à leur personne ; le reste inchangé
create or replace function pilotage.alerte_visible_objet(p_regle text, p_mandat text, p_user uuid, p_type text, p_objet text)
returns boolean language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare c uuid;
begin
  if p_type = 'PermisTache' then
    return exists (select 1 from pilotage.permis_taches t where t.id::text = p_objet and t.assigne = p_user);
  end if;
  if p_type = 'TicketRappel' then
    return exists (select 1 from pilotage.tickets_rappels r where r.id::text = p_objet and r.destinataire = p_user);
  end if;
  if coalesce((select r.destinataire from pilotage.regles r where r.cle = p_regle), 'gestion') <> 'commercial' then
    return pilotage.alerte_visible(p_regle, p_mandat, p_user);
  end if;
  c := case p_type when 'LeasingContract' then pilotage.commercial_dossier('bail', p_objet)
                   when 'ManagementContract' then pilotage.commercial_dossier('mandat', p_objet) end;
  if c is not null then return c = p_user; end if;
  return exists (select 1 from pilotage.membres m where m.user_id = p_user and m.actif and m.role = 'negociateur');
end $$;

create or replace function pilotage.mandat_de(p_type text, p_id text)
returns text language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select case p_type
    when 'ManagementContract' then p_id
    when 'Asset' then (select data->>'management_contract_id' from pilotage.objets where type = 'Asset' and id = p_id)
    when 'LeasingContract' then (select a.data->>'management_contract_id' from pilotage.objets b join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id' where b.type = 'LeasingContract' and b.id = p_id)
    when 'Upload' then (select a.data->>'management_contract_id' from pilotage.objets u join pilotage.objets a on a.type = 'Asset' and a.id = u.data->'resourceables'->0->>'id' where u.type = 'Upload' and u.id = p_id)
    when 'PermisTache' then (select a.data->>'management_contract_id' from pilotage.permis_taches t join pilotage.objets a on a.type = 'Asset' and a.id = t.asset_id where t.id::text = p_id)
    when 'TicketRappel' then (select a.data->>'management_contract_id' from pilotage.tickets_rappels r join pilotage.objets i on i.type = 'Incident' and i.id = r.ticket_id
                              join pilotage.objets a on a.type = 'Asset' and a.id = i.data->>'asset_id' where r.id::text = p_id)
  end
$$;

-- Ma journée : en-tête lisible pour ces deux objets (le lot de la tâche du permis, le ticket du rappel)
do $$
declare def text; ancre text := 'else jsonb_build_object(''type'', lower(a.objet_type)';
begin
  def := pg_get_functiondef('public.pilotage_journee(uuid)'::regprocedure);
  if position('TicketRappel' in def) > 0 then return; end if;
  if (length(def) - length(replace(def, ancre, ''))) / length(ancre) <> 1 then raise exception 'pilotage_journee : point d''insertion introuvable, rien n''est modifié'; end if;
  execute replace(def, ancre,
    'when ''PermisTache'' then (select jsonb_build_object(''type'',''lot'',''ref'', l.reference, ''adresse'', l.adresse, ''lien'', ''https://rivage.immo/asset_list'') from pilotage.permis_taches t join pilotage.v_lots l on l.id = t.asset_id where t.id::text = a.objet_id)' || E'\n        ' ||
    'when ''TicketRappel'' then (select jsonb_build_object(''type'',''ticket'',''ref'', coalesce(i.data->>''number'', r.ticket_id), ''titre'', coalesce(i.data->>''title'', r.ticket_titre), ''ticket_id'', r.ticket_id, ''lien'', a.lien_rivage) from pilotage.tickets_rappels r left join pilotage.objets i on i.type = ''Incident'' and i.id = r.ticket_id where r.id::text = a.objet_id)' || E'\n        ' || ancre);
end $$;

-- 127 : Tickets (ex-Sinistres) : tags Rivage des incidents, rappels et notifications vers Ma journée (bloc 2 sur 2)
select position('''tags''' in pg_get_functiondef('public.pilotage_sinistres()'::regprocedure)) > 0 as tags_dans_la_liste,
  to_regclass('pilotage.tickets_rappels') is not null as table_rappels,
  (select destinataire from pilotage.regles where cle = 'ticket_rappel') as regle,
  position('tickets_rappels_detections' in pg_get_functiondef('pilotage.executer_controles()'::regprocedure)) > 0 as controle_branche,
  position('TicketRappel' in pg_get_functiondef('public.pilotage_journee(uuid)'::regprocedure)) > 0 as journee;
