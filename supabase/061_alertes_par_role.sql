-- 061 : les alertes vont à la personne qui les traite, la direction supervise (Nicolas, 20/10/2026)
--   Avant : une alerte allait à la personne attribuée au mandat, sinon à la direction. Aucun mandat n'étant attribué,
--   tout arrivait chez Nicolas. Désormais chaque règle a un destinataire (gestion, comptabilité ou direction),
--   modifiable dans « Règles de relance » :
--     - gestion : la gestionnaire (ou, si le mandat est attribué à quelqu'un dans « Équipe », cette personne) ;
--     - comptabilité : la comptable (impayés, reversement et restitution des dépôts de garantie) ;
--     - direction : la direction et le superviseur.
--   La direction et le superviseur gardent une vue de supervision : nombre d'alertes de chacun, et accès à sa journée.

alter table pilotage.regles add column if not exists destinataire text not null default 'gestion';
alter table pilotage.regles drop constraint if exists regles_destinataire_check;
alter table pilotage.regles add constraint regles_destinataire_check check (destinataire in ('gestion', 'compta', 'direction'));
update pilotage.regles set destinataire = 'compta'
 where cle in ('impaye_actualisation', 'impaye_reglement', 'impaye_zelok_declarer', 'impaye_zelok_urgent',
               'dg_reversement', 'dg_reverse', 'dg_delai', 'dg_hors_delai');

-- Qui voit une alerte dans sa journée
create or replace function pilotage.alerte_visible(p_regle text, p_mandat text, p_user uuid) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  with u as (select m.role from pilotage.membres m where m.user_id = p_user and m.actif),
       d as (select coalesce((select r.destinataire from pilotage.regles r where r.cle = p_regle), 'gestion') dest),
       att as (select exists (select 1 from pilotage.attributions t where t.mandat_id = p_mandat) attribue,
                      exists (select 1 from pilotage.attributions t where t.mandat_id = p_mandat and t.user_id = p_user) a_moi)
  select coalesce((
    select case
      -- Alerte de gestion d'un mandat attribué : seulement à la personne attribuée
      when d.dest = 'gestion' and att.attribue then att.a_moi
      when d.dest = 'gestion' then u.role = 'gestionnaire'
      when d.dest = 'compta' then u.role = 'comptable'
      when d.dest = 'direction' then u.role in ('direction', 'superviseur')
      else false end
    from u, d, att), false)
$$;

do $$
declare def text;
begin
  def := pg_get_functiondef('public.pilotage_journee(uuid)'::regprocedure);
  if position('where pilotage.alerte_visible_par(a.mandat_id, cible)' in def) = 0 then raise exception 'Code inattendu dans pilotage_journee'; end if;
  execute replace(def, 'where pilotage.alerte_visible_par(a.mandat_id, cible)', 'where pilotage.alerte_visible(a.regle, a.mandat_id, cible)');
  def := pg_get_functiondef('public.pilotage_traiter(bigint, boolean)'::regprocedure);
  if position('not pilotage.alerte_visible_par(a.mandat_id, auth.uid())' in def) = 0 then raise exception 'Code inattendu dans pilotage_traiter'; end if;
  execute replace(def, 'not pilotage.alerte_visible_par(a.mandat_id, auth.uid())', 'not pilotage.alerte_visible(a.regle, a.mandat_id, auth.uid())');
  -- Le destinataire figure dans les réglages des règles
  def := pg_get_functiondef('public.pilotage_reglages()'::regprocedure);
  if position('''parametres'', parametres,' in def) = 0 then raise exception 'Code inattendu dans pilotage_reglages (script 057 passé ?)'; end if;
  execute replace(def, '''parametres'', parametres,', '''parametres'', parametres, ''destinataire'', destinataire,');
end $$;

-- Changer le destinataire d'une règle
create or replace function public.pilotage_regle_destinataire(p_cle text, p_destinataire text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  update pilotage.regles set destinataire = p_destinataire where cle = p_cle;
  if not found then raise exception 'Règle inconnue'; end if;
end $$;

-- Supervision : charge de chaque membre (alertes ouvertes, critiques, plus ancienne)
create or replace function public.pilotage_supervision() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'prenom', m.prenom, 'role', m.role,
      'ouvertes', (select count(*) from pilotage.alertes a where a.statut = 'ouverte' and pilotage.alerte_visible(a.regle, a.mandat_id, m.user_id)),
      'critiques', (select count(*) from pilotage.alertes a where a.statut = 'ouverte' and a.gravite = 'critique' and pilotage.alerte_visible(a.regle, a.mandat_id, m.user_id)),
      'plus_ancienne', (select min(a.premiere_detection) from pilotage.alertes a where a.statut = 'ouverte' and pilotage.alerte_visible(a.regle, a.mandat_id, m.user_id)))
    order by case m.role when 'gestionnaire' then 1 when 'comptable' then 2 when 'negociateur' then 3 else 4 end, m.prenom)
    from pilotage.membres m where m.actif and m.role in ('gestionnaire', 'comptable', 'negociateur')), '[]'::jsonb);
end $$;

revoke all on function public.pilotage_regle_destinataire(text, text), public.pilotage_supervision() from public, anon;
grant execute on function public.pilotage_regle_destinataire(text, text), public.pilotage_supervision() to authenticated;

-- Contrôle : alertes ouvertes par personne
select m.prenom, m.role, (select count(*) from pilotage.alertes a where a.statut = 'ouverte' and pilotage.alerte_visible(a.regle, a.mandat_id, m.user_id)) alertes
from pilotage.membres m where m.actif order by 3 desc;
