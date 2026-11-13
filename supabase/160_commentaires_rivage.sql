-- 160 : commentaires Rivage affichés dans le pilotage (demande de Nicolas du 13/11, dossier Kharroubi)
--  Les messages Rivage (objets « Message » reçus par webhook et synchronisation) n'étaient lus nulle part dans le pilotage.
--  Rivage les rattache à un lot (Asset), un ticket (Incident), un bail, un mandat ou une fiche personne (Profile).
--  - pilotage.rivage_auteurs : correspondance identifiant d'utilisateur Rivage → prénom. Rivage ne donne que l'identifiant ;
--    la table se remplit à la main, une fois l'auteur confirmé (au 13/11, un seul auteur de commentaires dans tout Rivage).
--  - public.pilotage_rivage_commentaires(p_asset) : commentaires de l'équipe et journal automatique (mails envoyés par Rivage)
--    du lot, de ses baux, de ses mandats et de ses tickets, du plus récent au plus ancien. Même droit d'accès que les mails du lot.
--  Lecture seule : rien n'est écrit dans Rivage. Bloc unique.

begin;

create table if not exists pilotage.rivage_auteurs (
  user_id text primary key,
  prenom text not null,
  maj_le timestamptz not null default now()
);
alter table pilotage.rivage_auteurs enable row level security;
revoke all on pilotage.rivage_auteurs from anon, authenticated;

create or replace function public.pilotage_rivage_commentaires(p_asset text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null or not pilotage.voit_tableau('sinistres', (select mandat_id from pilotage.v_lots where id = p_asset)) then
    raise exception 'Accès refusé';
  end if;
  return coalesce((
    with cibles as (
      select p_asset id, 'Lot' sur, null::text ref
      union select b.id, 'Bail', b.reference from pilotage.v_baux b where b.lot_id = p_asset
      union select i.id, 'Ticket', i.data->>'number' from pilotage.objets i where i.type = 'Incident' and i.data->>'asset_id' = p_asset
      union select (select mandat_id from pilotage.v_lots where id = p_asset), 'Mandat', null)
    select jsonb_agg(jsonb_build_object(
             'id', m.id, 'le', m.data->>'sent_at', 'texte', m.data->>'content',
             'auto', coalesce(m.data->>'nature', '') = 'log' or m.data->>'user_id' is null,
             'auteur', coalesce(a.prenom, case when m.data->>'user_id' is not null then 'Équipe (Rivage)' end),
             'sur', c.sur, 'ref', c.ref,
             'titre_ticket', case when c.sur = 'Ticket' then (select i.data->>'title' from pilotage.objets i where i.id = c.id and i.type = 'Incident') end)
           order by m.data->>'sent_at' desc)
      from pilotage.objets m
      join cibles c on c.id = m.data->>'messageable_id'
      left join pilotage.rivage_auteurs a on a.user_id = m.data->>'user_id'
     where m.type = 'Message'), '[]'::jsonb);
end $$;
revoke all on function public.pilotage_rivage_commentaires(text) from public, anon;
grant execute on function public.pilotage_rivage_commentaires(text) to authenticated;

commit;
