-- 042 : journal des écritures faites dans Rivage depuis le pilotage (test du 17/10 : dépôt de pièces dans un mandat)
-- Toute écriture passe par la fonction serveur pilotage-ecriture-rivage, réservée à la direction pour l'instant,
-- et laisse une ligne ici : qui, quand, quoi, et la réponse de Rivage. Rien n'est écrit dans Rivage par ce script.
-- À passer après le 041 (indépendant de lui).

create table if not exists pilotage.rivage_ecritures (
  id bigserial primary key,
  le timestamptz not null default now(),
  par uuid,
  action text not null,                -- 'upload' pour l'instant
  cible_type text, cible_id text,      -- ManagementContract / LeasingContract et son identifiant Rivage
  nature text, libelle text,           -- nature Rivage du document et nom du fichier
  statut_http integer, ok boolean not null default false,
  rivage_id text,                      -- identifiant de l'objet créé dans Rivage
  reponse jsonb                        -- réponse de Rivage (tronquée)
);
create index if not exists rivage_ecritures_cible on pilotage.rivage_ecritures (cible_id);
alter table pilotage.rivage_ecritures enable row level security;
revoke all on pilotage.rivage_ecritures from public, anon, authenticated;
revoke all on sequence pilotage.rivage_ecritures_id_seq from public, anon, authenticated;

-- Droit d'écrire dans Rivage depuis le pilotage : direction seulement (à élargir plus tard, par exemple au commercial sur ses dossiers)
create or replace function public.pilotage_peut_ecrire_rivage() returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(pilotage.mon_role() = 'direction', false)
$$;

-- Journal (appelé par la fonction serveur)
create or replace function public.pilotage_ecriture_rivage_noter(p_par uuid, p_action text, p_cible_type text, p_cible_id text, p_nature text,
  p_libelle text, p_statut integer, p_ok boolean, p_rivage_id text, p_reponse jsonb) returns bigint
language sql security definer set search_path = pilotage, public as $$
  insert into pilotage.rivage_ecritures (par, action, cible_type, cible_id, nature, libelle, statut_http, ok, rivage_id, reponse)
  values (p_par, p_action, p_cible_type, p_cible_id, p_nature, left(p_libelle, 200), p_statut, p_ok, p_rivage_id, p_reponse)
  returning id
$$;

-- Écritures d'un dossier, pour l'écran
create or replace function public.pilotage_ecritures_rivage(p_cible text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('le', e.le, 'par', pilotage.prenom_membre(e.par), 'nature', e.nature, 'libelle', e.libelle,
            'ok', e.ok, 'statut', e.statut_http, 'message', e.reponse->>'message') order by e.le desc)
    from pilotage.rivage_ecritures e where e.cible_id = p_cible), '[]'::jsonb);
end $$;

revoke all on function public.pilotage_ecriture_rivage_noter(uuid, text, text, text, text, text, integer, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.pilotage_ecriture_rivage_noter(uuid, text, text, text, text, text, integer, boolean, text, jsonb) to service_role;
revoke all on function public.pilotage_peut_ecrire_rivage(), public.pilotage_ecritures_rivage(text) from public, anon;
grant execute on function public.pilotage_peut_ecrire_rivage(), public.pilotage_ecritures_rivage(text) to authenticated;

-- Contrôle : doit renvoyer true
select to_regclass('pilotage.rivage_ecritures') is not null as ok;
