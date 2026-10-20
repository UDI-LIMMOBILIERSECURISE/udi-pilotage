-- 054 : restitution du dépôt de garantie et révision de loyer (retours de Nicolas, 20/10/2026). À exécuter après 053, à la main.
--
--   1. Dépôt de garantie : Rivage n'indique pas qui détient le dépôt (bailleur ou agence) ni le reversement du bailleur.
--      La gestion le saisit dans l'onglet des sorties (« Détenu par », demande et réception du reversement). Ma journée signale :
--        - qui détient le dépôt, à préciser pour un locataire parti ;
--        - le reversement à demander au bailleur, puis à relancer tous les 7 jours ;
--        - le reversement reçu : restituer le dépôt (l'alerte demandée par Nicolas) ;
--        - la restitution à 10 jours du délai d'un mois, puis hors délai (pénalité de 10 % du loyer HC par mois commencé, art. 22).
--   2. Révision de loyer : Rivage ne donne pas le futur loyer révisé. On garde l'historique du loyer de chaque bail (déclencheur
--      sur les données reçues de Rivage) ; quand le loyer change, Ma journée propose le mail « ancien loyer → nouveau loyer » au bailleur.
-- Rien n'est écrit dans Rivage. Les textes des mails sont dans src/mails.js.

-- ========== 1. Dépôt de garantie ==========
create table if not exists pilotage.dg_suivi (
  bail_id text primary key,
  detenu_par text check (detenu_par in ('bailleur', 'agence')),
  demande_le date,                 -- demande de reversement adressée au bailleur
  relance_le date,                 -- dernière relance
  recu_le date,                    -- reversement du bailleur reçu sur le compte de l'agence
  restitution_mail_le date,        -- mail de restitution adressé au locataire
  par uuid, maj_le timestamptz not null default now()
);
alter table pilotage.dg_suivi enable row level security;
revoke all on pilotage.dg_suivi from public, anon, authenticated;

create or replace function public.pilotage_dg_maj(p_bail text, p_champ text, p_valeur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.objets where type = 'LeasingContract' and id = p_bail) then raise exception 'Bail inconnu'; end if;
  if p_champ not in ('detenu_par', 'demande_le', 'relance_le', 'recu_le', 'restitution_mail_le') then raise exception 'Champ inconnu'; end if;
  if p_champ = 'detenu_par' and nullif(p_valeur, '') is not null and p_valeur not in ('bailleur', 'agence') then raise exception 'Valeur inconnue'; end if;
  insert into pilotage.dg_suivi (bail_id, par) values (p_bail, auth.uid()) on conflict (bail_id) do nothing;
  execute format('update pilotage.dg_suivi set %I = %s, par = $1, maj_le = now() where bail_id = $2', p_champ,
                 case when p_champ = 'detenu_par' then 'nullif($3, '''')' else 'nullif($3, '''')::date' end)
    using auth.uid(), p_bail, p_valeur;
end $$;
revoke all on function public.pilotage_dg_maj(text, text, text) from public, anon;
grant execute on function public.pilotage_dg_maj(text, text, text) to authenticated;

-- Contacts d'un bail (053) : ouverts aussi au comptable, qui prépare les restitutions et les mails d'impayés
create or replace function public.pilotage_contacts_bail(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not (pilotage.peut_traiter_dossier('bail', p_bail) or pilotage.mon_role() = 'comptable') then raise exception 'Accès refusé'; end if;
  return pilotage.contacts_bail(p_bail) || jsonb_build_object('adresse', (select l.adresse from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id where b.id = p_bail));
end $$;

-- Onglet des sorties : ajoute le suivi saisi (remplacement ciblé dans la fonction en place)
do $$
declare def text; n text;
begin
  def := pg_get_functiondef('public.pilotage_dg()'::regprocedure);
  if position('dg_suivi' in def) > 0 then raise notice 'pilotage_dg : déjà fait'; return; end if;
  n := replace(def, '''historique'', pilotage.historique(b.id),',
    '''historique'', pilotage.historique(b.id),
        ''suivi'', (select to_jsonb(s) - ''par'' from pilotage.dg_suivi s where s.bail_id = b.id),');
  if n = def then raise exception '054 : point d''injection introuvable dans pilotage_dg'; end if;
  execute n;
end $$;

-- Dossiers de sortie : délai d'un mois à partir de la sortie réelle (ou de la fin du bail), restitution faite ou non dans Rivage
create or replace function pilotage.dg_dossiers() returns table (bail_id text, reference text, locataires text, depot numeric, loyer_hc numeric,
  limite date, remboursee boolean, detenu_par text, demande_le date, relance_le date, recu_le date)
language sql stable security definer set search_path = pilotage, public as $$
  select b.id, b.reference, b.locataires, b.depot_garantie, b.loyer_hc,
         (coalesce(pilotage.date_sortie_reelle(b.id), b.fin) + interval '1 month')::date,
         coalesce((g.data->>'deposit_refunded')::boolean, false),
         s.detenu_par, s.demande_le, s.relance_le, s.recu_le
  from pilotage.v_baux b
  left join lateral (select o.data from pilotage.objets o where o.type = 'AccountingEventGroup' and o.supprime_le is null
                       and o.data->>'nature' = 'refund_deposit' and o.data->>'leasing_contract_id' = b.id
                     order by o.data->>'billing_period_start_date' desc limit 1) g on true
  left join pilotage.dg_suivi s on s.bail_id = b.id
  where b.fin is not null and b.fin <= current_date and b.fin > current_date - 365 and coalesce(b.depot_garantie, 0) > 0
$$;

create or replace function pilotage.suivi_detections_dg() returns table (regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  with d as (select * from pilotage.dg_dossiers() where not remboursee), l as (select 'https://rivage.immo/leasing_contracts?leasing_contract_id=' u)
  select 'dg_detention', 'LeasingContract', d.bail_id, 'Dépôt de garantie : préciser qui le détient (' || coalesce(d.locataires, '') || ')',
         'Bailleur ou agence : à indiquer dans l''onglet des sorties, pour savoir s''il faut demander le reversement au bailleur. Restitution au plus tard le '
           || to_char(d.limite, 'DD/MM/YYYY') || ' si l''état des lieux de sortie est conforme.', (select u from l) || d.bail_id
  from d where d.detenu_par is null
  union all
  select 'dg_reversement', 'LeasingContract', d.bail_id,
         case when d.demande_le is null then 'Demander au bailleur le reversement du dépôt de garantie' else 'Relancer le bailleur : reversement du dépôt de garantie' end
           || ' (' || coalesce(d.locataires, '') || ')',
         'Dépôt de ' || coalesce(d.depot::text, '?') || ' € détenu par le bailleur'
           || coalesce(', demandé le ' || to_char(d.demande_le, 'DD/MM/YYYY'), '') || coalesce(', relancé le ' || to_char(d.relance_le, 'DD/MM/YYYY'), '')
           || '. Restitution au locataire au plus tard le ' || to_char(d.limite, 'DD/MM/YYYY') || '.', (select u from l) || d.bail_id
  from d where d.detenu_par = 'bailleur' and d.recu_le is null
    and (d.demande_le is null or greatest(d.demande_le, coalesce(d.relance_le, d.demande_le)) <= current_date - 7)
  union all
  select 'dg_reverse', 'LeasingContract', d.bail_id, 'Reversement du dépôt reçu le ' || to_char(d.recu_le, 'DD/MM/YYYY') || ' : restituer au locataire (' || coalesce(d.locataires, '') || ')',
         'Préparer la restitution dans Rivage et le mail au locataire. Délai : ' || to_char(d.limite, 'DD/MM/YYYY') || ' si l''état des lieux de sortie est conforme.', (select u from l) || d.bail_id
  from d where d.recu_le is not null
  union all
  select case when current_date > d.limite then 'dg_hors_delai' else 'dg_delai' end, 'LeasingContract', d.bail_id,
         case when current_date > d.limite then 'Dépôt de garantie non restitué après le délai d''un mois' else 'Dépôt de garantie à restituer avant le ' || to_char(d.limite, 'DD/MM/YYYY') end
           || ' (' || coalesce(d.locataires, '') || ')',
         'Au-delà du délai (1 mois si l''état des lieux de sortie est conforme, 2 mois sinon), le dépôt restant dû est majoré de 10 % du loyer HC ('
           || coalesce(round(d.loyer_hc * 0.10, 2)::text, '?') || ' €) par mois de retard commencé (art. 22 de la loi du 6 juillet 1989).', (select u from l) || d.bail_id
  from d where current_date >= d.limite - 10
$$;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication) values
 ('dg_detention', 'Dépôt de garantie : détenteur à préciser', 'baux', 'haute', 'tache', true,
  'Rivage n''indique pas si le dépôt est chez le bailleur ou sur le compte de l''agence : la gestion le précise à la sortie du locataire.'),
 ('dg_reversement', 'Reversement du dépôt à demander au bailleur', 'baux', 'haute', 'tache', true,
  'Dépôt détenu par le bailleur : lui demander de le reverser dès la sortie, puis relancer tous les 7 jours jusqu''à réception.'),
 ('dg_reverse', 'Reversement du dépôt reçu : à restituer', 'baux', 'haute', 'tache', true,
  'Le bailleur a reversé le dépôt : préparer la restitution au locataire dans le délai légal.'),
 ('dg_delai', 'Dépôt de garantie : délai de restitution proche', 'baux', 'haute', 'oblig', true,
  'Restitution sous 1 mois après la remise des clés si l''état des lieux de sortie est conforme, 2 mois sinon (art. 22). Alerte 10 jours avant le délai d''un mois.'),
 ('dg_hors_delai', 'Dépôt de garantie : délai d''un mois dépassé', 'baux', 'critique', 'oblig', true,
  'Délai d''un mois dépassé : sauf état des lieux non conforme (délai de 2 mois), le dépôt restant dû est majoré de 10 % du loyer HC par mois commencé.')
on conflict (cle) do update set libelle = excluded.libelle, domaine = excluded.domaine, gravite = excluded.gravite, categorie = excluded.categorie, explication = excluded.explication;

-- ========== 2. Révision de loyer : historique du loyer ==========
create table if not exists pilotage.baux_loyers_historique (
  id bigserial primary key, bail_id text not null,
  ancien_cents bigint, nouveau_cents bigint, indice jsonb, le timestamptz not null default now()
);
create index if not exists baux_loyers_historique_bail on pilotage.baux_loyers_historique (bail_id, le desc);
alter table pilotage.baux_loyers_historique enable row level security;
revoke all on pilotage.baux_loyers_historique from public, anon, authenticated;
revoke all on sequence pilotage.baux_loyers_historique_id_seq from public, anon, authenticated;

create or replace function pilotage.trg_loyer_change() returns trigger
language plpgsql security definer set search_path = pilotage, public as $$
begin
  -- Suppression (data vidée) ou loyer absent : pas un changement de loyer
  if new.type = 'LeasingContract' and (old.data->>'rent_in_cents') is not null and (new.data->>'rent_in_cents') is not null
     and (new.data->>'rent_in_cents') <> (old.data->>'rent_in_cents') then
    insert into pilotage.baux_loyers_historique (bail_id, ancien_cents, nouveau_cents, indice)
    values (new.id, (old.data->>'rent_in_cents')::bigint, (new.data->>'rent_in_cents')::bigint, new.data->'quarter_revision_index');
  end if;
  return new;
end $$;
drop trigger if exists objets_loyer_change on pilotage.objets;
create trigger objets_loyer_change after update on pilotage.objets
  for each row when (new.type = 'LeasingContract') execute function pilotage.trg_loyer_change();

-- Dernier changement de loyer d'un bail (pour le mail au bailleur)
create or replace function public.pilotage_loyer_changement(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_traiter_dossier('bail', p_bail) then raise exception 'Accès refusé'; end if;
  return (select jsonb_build_object('ancien', round(h.ancien_cents / 100.0, 2), 'nouveau', round(h.nouveau_cents / 100.0, 2), 'le', h.le, 'indice', h.indice,
                   'commercial', (select (b.data->>'vat_applicable')::boolean from pilotage.objets b where b.type = 'LeasingContract' and b.id = p_bail))
          from pilotage.baux_loyers_historique h where h.bail_id = p_bail order by h.le desc limit 1);
end $$;
revoke all on function public.pilotage_loyer_changement(text) from public, anon;
grant execute on function public.pilotage_loyer_changement(text) to authenticated;

create or replace function pilotage.suivi_detections_loyers() returns table (regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  select distinct on (h.bail_id) 'loyer_modifie', 'LeasingContract', h.bail_id,
         'Loyer modifié dans Rivage : ' || to_char(h.ancien_cents / 100.0, 'FM999G990D00') || ' € → ' || to_char(h.nouveau_cents / 100.0, 'FM999G990D00') || ' € HC (' || coalesce(b.locataires, '') || ')',
         'Changement enregistré le ' || to_char(h.le at time zone 'Europe/Paris', 'DD/MM/YYYY') || coalesce(' ; indice ' || upper(h.indice->>'nature') || ' ' || (h.indice->>'year') || ' T' || (h.indice->>'quarter') || ' : ' || (h.indice->>'value'), '')
           || '. Informer le bailleur (mail proposé), et vérifier le calcul si c''est une révision.',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || h.bail_id
  from pilotage.baux_loyers_historique h join pilotage.v_baux b on b.id = h.bail_id
  where h.le > now() - interval '45 days' and b.statut in ('move_in', 'in_progress')
  order by h.bail_id, h.le desc
$$;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication) values
 ('loyer_modifie', 'Loyer modifié dans Rivage (révision ou palier)', 'baux', 'normale', 'courrier', true,
  'Le loyer d''un bail a changé dans Rivage : informer le bailleur de l''ancien et du nouveau loyer. L''alerte disparaît 45 jours après le changement.')
on conflict (cle) do update set libelle = excluded.libelle, domaine = excluded.domaine, gravite = excluded.gravite, categorie = excluded.categorie, explication = excluded.explication;

-- ========== Branchement des détections dans Ma journée ==========
do $$
declare def text;
begin
  def := pg_get_functiondef('pilotage.suivi_detections()'::regprocedure);
  if position('suivi_detections_dg' in def) = 0 then
    def := regexp_replace(def, '\s*\$function\$\s*$', E'\n  union all\n  select * from pilotage.suivi_detections_dg()\n  union all\n  select * from pilotage.suivi_detections_loyers()\n$function$\n');
    if position('suivi_detections_dg' in def) = 0 then raise exception '054 : branchement des détections impossible'; end if;
    execute def;
  end if;
end $$;

revoke all on function pilotage.dg_dossiers(), pilotage.suivi_detections_dg(), pilotage.suivi_detections_loyers(), pilotage.trg_loyer_change()
  from public, anon, authenticated;

-- ========== Contrôle ==========
select regle, titre from pilotage.suivi_detections_dg()
union all select regle, titre from pilotage.suivi_detections_loyers();
