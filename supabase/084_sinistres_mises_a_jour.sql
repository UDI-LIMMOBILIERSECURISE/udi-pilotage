-- 084 — Mises à jour (commentaires de l'équipe) sur les incidents Rivage, comme sur les dossiers repris de Monday (demande de Nicolas du 26/10).
-- Les commentaires vivent dans le pilotage : rien n'est écrit dans Rivage, qui reste la source de vérité de l'incident (statut, prestataires).
-- Le résumé IA d'un incident tient compte de ces commentaires (fonction pilotage-resume v18).

begin;

create table if not exists pilotage.sinistres_notes (
  id bigint generated always as identity primary key,
  incident_id text not null,
  auteur text,
  auteur_id uuid,
  le timestamptz not null default now(),
  contenu text not null
);
create index if not exists sinistres_notes_incident on pilotage.sinistres_notes (incident_id, le desc);
alter table pilotage.sinistres_notes enable row level security;
revoke all on pilotage.sinistres_notes from public, anon, authenticated;

create or replace function public.pilotage_sinistre_notes(p_incident text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $function$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'parent_id', null, 'auteur', n.auteur, 'le', n.le,
            'contenu', n.contenu, 'tronque', false, 'monday', false) order by n.le desc)
          from pilotage.sinistres_notes n where n.incident_id = p_incident), '[]'::jsonb);
end $function$;

create or replace function public.pilotage_sinistre_note(p_incident text, p_contenu text) returns void
language plpgsql security definer set search_path = pilotage, public as $function$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  if nullif(trim(p_contenu), '') is null then raise exception 'Mise à jour vide'; end if;
  if not exists (select 1 from pilotage.objets where type = 'Incident' and id = p_incident and supprime_le is null) then
    raise exception 'Incident introuvable';
  end if;
  insert into pilotage.sinistres_notes (incident_id, auteur, auteur_id, contenu)
  select p_incident, m.prenom, auth.uid(), trim(p_contenu) from pilotage.membres m where m.user_id = auth.uid();
end $function$;

revoke all on function public.pilotage_sinistre_notes(text), public.pilotage_sinistre_note(text, text) from public, anon;
grant execute on function public.pilotage_sinistre_notes(text), public.pilotage_sinistre_note(text, text) to authenticated;

-- Nombre de commentaires et date du dernier sur les cartes des incidents Rivage
do $$
declare
  def text; n int;
  ancien text := $a$'lien', 'https://rivage.immo/incidents/' || i.id$a$;
  nouveau text := $a$'nb_notes', (select count(*) from pilotage.sinistres_notes sn where sn.incident_id = i.id),
        'derniere_note', (select max(sn.le) from pilotage.sinistres_notes sn where sn.incident_id = i.id),
        'lien', 'https://rivage.immo/incidents/' || i.id$a$;
begin
  select pg_get_functiondef('public.pilotage_sinistres'::regproc) into def;
  n := (length(def) - length(replace(def, ancien, ''))) / length(ancien);
  if n <> 1 then raise exception 'Critère attendu trouvé % fois dans pilotage_sinistres (1 attendu) : rien n''est modifié', n; end if;
  execute replace(def, ancien, nouveau);
end $$;

commit;

select (select count(*) from pg_proc where proname in ('pilotage_sinistre_notes', 'pilotage_sinistre_note')) fonctions,
       (select prosrc like '%sinistres_notes%' from pg_proc where proname = 'pilotage_sinistres') cartes_a_jour;
