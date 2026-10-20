-- 055 : détenteur du dépôt de garantie lu dans Rivage (remarque de Nicolas, 20/10/2026). À exécuter après 054, à la main.
-- Le MCP Rivage renvoie depuis le 20/10 le champ deposit_retained_by du bail (attributs de la fiche bail, « landlord » vu sur
-- les trois baux relus le 20/10). Ce champ n'est pas dans les webhooks. Le pilotage le prend désormais par défaut ;
-- la saisie de la gestion (onglet des sorties) reste possible et l'emporte, pour corriger un cas particulier.
-- Les baux relus avant le 20/10 n'ont pas encore ce champ : il arrivera à leur prochaine relecture.

create or replace function pilotage.dg_detenteur_rivage(p_bail text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select case s.data->'lease'->'data'->'attributes'->>'deposit_retained_by'
           when 'landlord' then 'bailleur'
           when 'agency' then 'agence' when 'agent' then 'agence' when 'manager' then 'agence' when 'property_manager' then 'agence'
         end
  from pilotage.baux_situation s where s.bail_id = p_bail
$$;

-- Dossiers de sortie : détenteur = saisie de la gestion, sinon Rivage
create or replace function pilotage.dg_dossiers() returns table (bail_id text, reference text, locataires text, depot numeric, loyer_hc numeric,
  limite date, remboursee boolean, detenu_par text, demande_le date, relance_le date, recu_le date)
language sql stable security definer set search_path = pilotage, public as $$
  select b.id, b.reference, b.locataires, b.depot_garantie, b.loyer_hc,
         (coalesce(pilotage.date_sortie_reelle(b.id), b.fin) + interval '1 month')::date,
         coalesce((g.data->>'deposit_refunded')::boolean, false),
         coalesce(s.detenu_par, pilotage.dg_detenteur_rivage(b.id)), s.demande_le, s.relance_le, s.recu_le
  from pilotage.v_baux b
  left join lateral (select o.data from pilotage.objets o where o.type = 'AccountingEventGroup' and o.supprime_le is null
                       and o.data->>'nature' = 'refund_deposit' and o.data->>'leasing_contract_id' = b.id
                     order by o.data->>'billing_period_start_date' desc limit 1) g on true
  left join pilotage.dg_suivi s on s.bail_id = b.id
  where b.fin is not null and b.fin <= current_date and b.fin > current_date - 365 and coalesce(b.depot_garantie, 0) > 0
$$;
revoke all on function pilotage.dg_detenteur_rivage(text), pilotage.dg_dossiers() from public, anon, authenticated;

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

-- Contrôle : détenteur par bail sorti
select bail_id, locataires, detenu_par, remboursee from pilotage.dg_dossiers();
