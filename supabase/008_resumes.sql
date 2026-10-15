-- Résumés IA des cartes : cache, pour ne régénérer que si les données du dossier ont changé.
create table if not exists pilotage.resumes (
  cle text primary key,            -- ex. 'sinistre:inc_xxx'
  empreinte text not null,         -- hash des données envoyées à l'IA
  texte text not null,
  modele text,
  genere_le timestamptz not null default now(),
  demande_par uuid
);
revoke all on pilotage.resumes from public, anon, authenticated;

-- Lecture et écriture réservées à la fonction serveur (rôle service_role)
create or replace function public.pilotage_resume_lire(p_cle text, p_empreinte text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('texte', texte, 'modele', modele, 'genere_le', genere_le)
  from pilotage.resumes where cle = p_cle and empreinte = p_empreinte
$$;

create or replace function public.pilotage_resume_ecrire(p_cle text, p_empreinte text, p_texte text, p_modele text, p_user uuid) returns void
language sql security definer set search_path = pilotage, public as $$
  insert into pilotage.resumes(cle, empreinte, texte, modele, demande_par) values (p_cle, p_empreinte, p_texte, p_modele, p_user)
  on conflict (cle) do update set empreinte = excluded.empreinte, texte = excluded.texte, modele = excluded.modele, genere_le = now(), demande_par = excluded.demande_par
$$;

revoke all on function public.pilotage_resume_lire(text, text), public.pilotage_resume_ecrire(text, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.pilotage_resume_lire(text, text), public.pilotage_resume_ecrire(text, text, text, text, uuid) to service_role;
