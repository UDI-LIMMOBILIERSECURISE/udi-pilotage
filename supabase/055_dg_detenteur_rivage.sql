-- 055 : détenteur du dépôt de garantie lu dans Rivage (remarque de Nicolas, 20/10/2026). À exécuter après 054, à la main.
-- Le MCP Rivage renvoie depuis le 20/10 le champ deposit_retained_by du bail (attributs de la fiche bail, « landlord » vu sur
-- les trois baux relus le 20/10). Ce champ n'est pas dans les webhooks. Le pilotage le prend désormais par défaut ;
-- la saisie de la gestion (onglet des sorties) reste possible et l'emporte, pour corriger un cas particulier.
-- Les baux relus avant le 20/10 n'ont pas encore ce champ : il arrivera à leur prochaine relecture.
-- Mails selon le détenteur : la demande de reversement ne concerne que le dépôt détenu par le bailleur. Elle est proposée dès
-- la réception du congé (bail passé en « Sortie locataire » dans Rivage, ou date de sortie saisie pour tous les locataires),
-- puis relancée à partir de 15 jours avant le départ si rien n'est reçu, et ensuite tous les 7 jours (décision de Nicolas, 20/10).
-- Le mail Rivage de fin de bail au propriétaire ne parle plus du reversement (il ne peut pas distinguer les deux cas).

create or replace function pilotage.dg_detenteur_rivage(p_bail text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select case s.data->'lease'->'data'->'attributes'->>'deposit_retained_by'
           when 'landlord' then 'bailleur'
           when 'agency' then 'agence' when 'agent' then 'agence' when 'manager' then 'agence' when 'property_manager' then 'agence'
         end
  from pilotage.baux_situation s where s.bail_id = p_bail
$$;

-- Dossiers de sortie : congé reçu ou bail terminé. Départ = sortie réelle, sinon dernière sortie annoncée, sinon fin du bail.
-- Détenteur = saisie de la gestion, sinon Rivage.
drop function if exists pilotage.dg_dossiers();
create or replace function pilotage.dg_dossiers() returns table (bail_id text, reference text, locataires text, depot numeric, loyer_hc numeric,
  limite date, remboursee boolean, detenu_par text, demande_le date, relance_le date, recu_le date, depart date, parti boolean)
language sql stable security definer set search_path = pilotage, public as $$
  select b.id, b.reference, b.locataires, b.depot_garantie, b.loyer_hc,
         (x.depart + interval '1 month')::date,
         coalesce((g.data->>'deposit_refunded')::boolean, false),
         coalesce(s.detenu_par, pilotage.dg_detenteur_rivage(b.id)), s.demande_le, s.relance_le, s.recu_le,
         x.depart, x.depart <= current_date
  from pilotage.v_baux b
  cross join lateral (select pilotage.sortie_locataires(b.id) sl) y
  cross join lateral (select coalesce(pilotage.date_sortie_reelle(b.id), case when (y.sl->>'tous_sortis')::boolean then (y.sl->>'derniere_sortie')::date end, b.fin) depart,
                             b.statut = 'move_out' or coalesce((y.sl->>'tous_sortis')::boolean, false) conge) x
  left join lateral (select o.data from pilotage.objets o where o.type = 'AccountingEventGroup' and o.supprime_le is null
                       and o.data->>'nature' = 'refund_deposit' and o.data->>'leasing_contract_id' = b.id
                     order by o.data->>'billing_period_start_date' desc limit 1) g on true
  left join pilotage.dg_suivi s on s.bail_id = b.id
  where x.depart is not null and (x.conge or x.depart <= current_date) and x.depart > current_date - 365 and coalesce(b.depot_garantie, 0) > 0
$$;

-- Détections : reversement à demander dès le congé (dépôt chez le bailleur), relance à partir de J-15 avant le départ puis tous les 7 jours ;
-- les alertes de délai après le départ
create or replace function pilotage.suivi_detections_dg() returns table (regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  with d as (select * from pilotage.dg_dossiers() where not remboursee), l as (select 'https://rivage.immo/leasing_contracts?leasing_contract_id=' u)
  select 'dg_detention', 'LeasingContract', d.bail_id, 'Dépôt de garantie : préciser qui le détient (' || coalesce(d.locataires, '') || ')',
         'Bailleur ou agence : Rivage ne l''indique pas encore pour ce bail. À préciser dans l''onglet des sorties, pour savoir s''il faut demander le reversement au bailleur.',
         (select u from l) || d.bail_id
  from d where d.detenu_par is null
  union all
  select 'dg_reversement', 'LeasingContract', d.bail_id,
         case when d.demande_le is null then 'Demander au bailleur le reversement du dépôt de garantie' else 'Relancer le bailleur : reversement du dépôt de garantie' end
           || ' (' || coalesce(d.locataires, '') || ')',
         'Dépôt de ' || coalesce(d.depot::text, '?') || ' € détenu par le bailleur, départ du locataire le ' || to_char(d.depart, 'DD/MM/YYYY')
           || coalesce(', demandé le ' || to_char(d.demande_le, 'DD/MM/YYYY'), '') || coalesce(', relancé le ' || to_char(d.relance_le, 'DD/MM/YYYY'), '')
           || '. Restitution au locataire au plus tard le ' || to_char(d.limite, 'DD/MM/YYYY') || ' si l''état des lieux de sortie est conforme.', (select u from l) || d.bail_id
  from d where d.detenu_par = 'bailleur' and d.recu_le is null
    and (d.demande_le is null
         or (current_date >= d.depart - 15 and greatest(d.demande_le, coalesce(d.relance_le, d.demande_le)) <= current_date - 7))
  union all
  select 'dg_reverse', 'LeasingContract', d.bail_id, 'Reversement du dépôt reçu le ' || to_char(d.recu_le, 'DD/MM/YYYY') || ' : restituer au locataire (' || coalesce(d.locataires, '') || ')',
         'Préparer la restitution dans Rivage et le mail au locataire. Délai : ' || to_char(d.limite, 'DD/MM/YYYY') || ' si l''état des lieux de sortie est conforme.', (select u from l) || d.bail_id
  from d where d.recu_le is not null and d.parti
  union all
  select case when current_date > d.limite then 'dg_hors_delai' else 'dg_delai' end, 'LeasingContract', d.bail_id,
         case when current_date > d.limite then 'Dépôt de garantie non restitué après le délai d''un mois' else 'Dépôt de garantie à restituer avant le ' || to_char(d.limite, 'DD/MM/YYYY') end
           || ' (' || coalesce(d.locataires, '') || ')',
         'Au-delà du délai (1 mois si l''état des lieux de sortie est conforme, 2 mois sinon), le dépôt restant dû est majoré de 10 % du loyer HC ('
           || coalesce(round(d.loyer_hc * 0.10, 2)::text, '?') || ' €) par mois de retard commencé (art. 22 de la loi du 6 juillet 1989).'
           || case when d.detenu_par = 'bailleur' and d.recu_le is null then ' Le bailleur n''a toujours pas reversé le dépôt.' else '' end, (select u from l) || d.bail_id
  from d where d.parti and current_date >= d.limite - 10
$$;
revoke all on function pilotage.dg_detenteur_rivage(text), pilotage.dg_dossiers(), pilotage.suivi_detections_dg() from public, anon, authenticated;

-- Onglet des sorties : détenteur indiqué par Rivage, à côté de la saisie
do $$
declare def text; n text;
begin
  def := pg_get_functiondef('public.pilotage_dg()'::regprocedure);
  if position('detenu_rivage' in def) > 0 then raise notice 'pilotage_dg : déjà fait'; return; end if;
  n := replace(def, '''suivi'', (select to_jsonb(s) - ''par'' from pilotage.dg_suivi s where s.bail_id = b.id),',
    '''suivi'', (select to_jsonb(s) - ''par'' from pilotage.dg_suivi s where s.bail_id = b.id),
        ''detenu_rivage'', pilotage.dg_detenteur_rivage(b.id),');
  if n = def then raise exception '055 : point d''injection introuvable dans pilotage_dg (le 054 est-il passé ?)'; end if;
  execute n;
end $$;

update pilotage.regles set explication = 'Rivage n''a pas encore indiqué si le dépôt est chez le bailleur ou sur le compte de l''agence (champ lu à la relecture du bail) : la gestion le précise dans l''onglet des sorties.'
 where cle = 'dg_detention';
update pilotage.regles set explication = 'Dépôt détenu par le bailleur : lui demander de le reverser dès la réception du congé ; sans reversement, relancer à partir de 15 jours avant le départ, puis tous les 7 jours.'
 where cle = 'dg_reversement';

-- Contrôle : détenteur par bail sorti
select bail_id, locataires, depart, detenu_par, remboursee from pilotage.dg_dossiers();
