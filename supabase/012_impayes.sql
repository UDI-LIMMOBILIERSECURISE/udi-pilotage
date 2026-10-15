-- Suivi des impayés, sur le modèle du tableau Monday « UDI Gestion - Suivi IMPAYES ».
-- Les informations venant de Rivage (bail, locataire, bailleur, lot, montant impayé, assureur GLI) sont lues dans le reflet ;
-- le suivi propre à l'agence (déclaration, prise en charge, procédure, indemnisation, remboursements...) est saisi ici.

create table if not exists pilotage.impayes (
  id bigserial primary key,
  bail_id text not null,
  groupe text not null default 'GLI',            -- section du tableau (GLI, Transfert assureur, Caution, Avocat, Liquidation, Clôturé)
  cause text,                                    -- Impayé loyer, Loyer non réglé, Rejet prélèvement, TEOM non réglée, Dégradations, Préavis en cours…
  responsable uuid references auth.users(id),
  notif_bailleur text,                           -- Infos impayé / Prise en charge
  declaration_le date,
  garantie text,                                 -- GLI Zelok, Mila, Garantme, SmartGarant (caution), Aucune
  procedure text,                                -- Assignation avocat par l'assureur, Commandement de payer, …
  audience_le date,
  maj_assureur_le date,                          -- dernière mise à jour du dossier chez l'assureur
  prise_en_charge text,                          -- Oui / En cours / Compte mis à jour / Refusée / Dossier clos
  montant_impaye numeric(12,2),                  -- montant déclaré à l'assureur
  indemnisation_recue text,                      -- OK reçue / En cours / Quittance subrogative / Non
  indemnisation_montant numeric(12,2),
  indemnite_versee_bailleur text,                -- Oui / Oui avec le décompte / Non
  dette_remb_loc numeric(12,2),
  solde_a_rembourser_assureur numeric(12,2),
  indemnisation_a_rembourser numeric(12,2),
  observations text,
  commandement_le date,
  cree_par uuid, cree_le timestamptz not null default now(),
  maj_par uuid, maj_le timestamptz not null default now()
);
create index if not exists impayes_bail on pilotage.impayes(bail_id);

create table if not exists pilotage.impayes_actions (
  id bigserial primary key,
  impaye_id bigint not null references pilotage.impayes(id) on delete cascade,
  libelle text not null,
  statut text not null default 'À faire',       -- À faire / En cours / Fait
  le date,
  par uuid,
  cree_le timestamptz not null default now()
);
revoke all on pilotage.impayes, pilotage.impayes_actions from public, anon, authenticated;

create or replace function pilotage.peut_saisir_impayes() returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select pilotage.mon_role() in ('direction', 'superviseur', 'gestionnaire', 'comptable')
$$;

-- Coordonnées utiles : nom, civilité, e-mail, téléphone (rien d'autre)
create or replace function pilotage.contacts_profils(p_ids text[]) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('nom', pilotage.nom_profil(o.id),
           'civilite', o.data->>'civility', 'email', o.data->>'email', 'tel', o.data->>'phone_number', 'nature', o.data->>'nature')), '[]'::jsonb)
  from unnest(p_ids) i join pilotage.objets o on o.type = 'Profile' and o.id = i
$$;

create or replace function public.pilotage_impayes() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'peut_saisir', pilotage.peut_saisir_impayes(),
    'membres', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'prenom', m.prenom) order by m.prenom), '[]'::jsonb) from pilotage.membres m where m.actif),
    'dossiers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'bail_id', d.bail_id, 'groupe', d.groupe, 'cause', d.cause, 'responsable', d.responsable,
        'responsable_prenom', (select prenom from pilotage.membres where user_id = d.responsable),
        'notif_bailleur', d.notif_bailleur, 'declaration_le', d.declaration_le, 'garantie', d.garantie, 'procedure', d.procedure,
        'audience_le', d.audience_le, 'maj_assureur_le', d.maj_assureur_le, 'prise_en_charge', d.prise_en_charge,
        'montant_impaye', d.montant_impaye, 'indemnisation_recue', d.indemnisation_recue, 'indemnisation_montant', d.indemnisation_montant,
        'indemnite_versee_bailleur', d.indemnite_versee_bailleur, 'dette_remb_loc', d.dette_remb_loc,
        'solde_a_rembourser_assureur', d.solde_a_rembourser_assureur, 'indemnisation_a_rembourser', d.indemnisation_a_rembourser,
        'observations', d.observations, 'commandement_le', d.commandement_le, 'cree_le', d.cree_le, 'maj_le', d.maj_le,
        'maj_par', (select prenom from pilotage.membres where user_id = d.maj_par),
        'rivage', pilotage.impaye_rivage(d.bail_id),
        'actions', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'libelle', a.libelle, 'statut', a.statut, 'le', a.le,
                       'par', (select prenom from pilotage.membres where user_id = a.par)) order by a.le nulls last, a.id), '[]'::jsonb)
                    from pilotage.impayes_actions a where a.impaye_id = d.id)
      ) order by d.maj_le desc) from pilotage.impayes d), '[]'::jsonb),
    -- Baux en impayé dans Rivage sans dossier ouvert
    'candidats', coalesce((
      select jsonb_agg(pilotage.impaye_rivage(b.id) order by b.impaye desc)
      from pilotage.v_baux b
      where b.impaye > 0 and not exists (select 1 from pilotage.impayes d where d.bail_id = b.id and d.groupe <> 'Clôturé')), '[]'::jsonb)
  );
end $$;

-- Tout ce que Rivage sait du bail, pour l'en-tête du dossier
create or replace function pilotage.impaye_rivage(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object(
    'bail_id', b.id, 'reference', b.reference, 'statut', b.statut, 'debut', b.debut, 'fin', b.fin,
    'loyer_hc', b.loyer_hc, 'charges', b.charges, 'depot', b.depot_garantie, 'impaye', b.impaye,
    'solde_locataire', round((o.data->>'tenant_balance_in_cents')::numeric / 100, 2),
    'dernier_appel', o.data->>'last_rent_call_date', 'dernier_appel_montant', round((o.data->>'last_rent_call_amount')::numeric / 100, 2),
    'dernier_encaissement', o.data->>'received_rent_date', 'dernier_encaissement_montant', round((o.data->>'received_rent_amount')::numeric / 100, 2),
    'assureur_gli', (select g.data->>'name' from pilotage.objets g where g.type = 'GliProvider' and g.id = o.data->>'gli_provider_id'),
    'locataires', (select coalesce(jsonb_agg(jsonb_build_object(
                     'nom', coalesce(nullif(t->>'company_name', ''), concat_ws(' ', upper(t->>'last_name'), t->>'first_name')),
                     'civilite', t->>'civility', 'email', t->>'email', 'tel', t->>'phone_number')), '[]'::jsonb)
                   from jsonb_array_elements(coalesce(o.data->'tenants', '[]'::jsonb)) t),
    'lot', l.reference, 'adresse', l.adresse, 'nature_lot', l.nature,
    'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
    'bailleurs', (select pilotage.contacts_profils(array_agg(p->>'profile_id'))
                  from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
                  where m.type = 'ManagementContract' and m.id = l.mandat_id),
    'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
  )
  from pilotage.v_baux b
  join pilotage.objets o on o.type = 'LeasingContract' and o.id = b.id
  left join pilotage.v_lots l on l.id = b.lot_id
  where b.id = p_bail
$$;

create or replace function public.pilotage_impaye_ouvrir(p_bail text, p_groupe text default 'GLI') returns bigint
language plpgsql security definer set search_path = pilotage, public as $$
declare n bigint;
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.objets where type = 'LeasingContract' and id = p_bail) then raise exception 'Bail inconnu'; end if;
  insert into pilotage.impayes(bail_id, groupe, cree_par, maj_par, responsable, montant_impaye, cause)
  select p_bail, coalesce(p_groupe, 'GLI'), auth.uid(), auth.uid(), auth.uid(), nullif(b.impaye, 0), 'Impayé loyer'
  from pilotage.v_baux b where b.id = p_bail
  returning id into n;
  return n;
end $$;

-- Mise à jour d'un champ, avec liste blanche
create or replace function public.pilotage_impaye_maj(p_id bigint, p_champ text, p_valeur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare typ text;
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  typ := case
    when p_champ in ('groupe','cause','notif_bailleur','garantie','procedure','prise_en_charge','indemnisation_recue','indemnite_versee_bailleur','observations') then 'text'
    when p_champ in ('declaration_le','audience_le','maj_assureur_le','commandement_le') then 'date'
    when p_champ in ('montant_impaye','indemnisation_montant','dette_remb_loc','solde_a_rembourser_assureur','indemnisation_a_rembourser') then 'numeric'
    when p_champ = 'responsable' then 'uuid'
    else null end;
  if typ is null then raise exception 'Champ non modifiable'; end if;
  if p_champ = 'groupe' and nullif(p_valeur, '') is null then raise exception 'Section obligatoire'; end if;
  execute format('update pilotage.impayes set %I = nullif($1, '''')::%s, maj_par = auth.uid(), maj_le = now() where id = $2', p_champ, typ)
    using case when typ = 'numeric' then replace(replace(coalesce(p_valeur, ''), ' ', ''), ',', '.') else coalesce(p_valeur, '') end, p_id;
end $$;

create or replace function public.pilotage_impaye_action(p_impaye bigint, p_libelle text, p_le date default null) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  if nullif(trim(p_libelle), '') is null then raise exception 'Libellé vide'; end if;
  insert into pilotage.impayes_actions(impaye_id, libelle, le, par) values (p_impaye, trim(p_libelle), p_le, auth.uid());
  update pilotage.impayes set maj_par = auth.uid(), maj_le = now() where id = p_impaye;
end $$;

create or replace function public.pilotage_impaye_action_statut(p_action bigint, p_statut text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  if p_statut not in ('À faire', 'En cours', 'Fait') then raise exception 'Statut inconnu'; end if;
  update pilotage.impayes_actions set statut = p_statut, par = auth.uid() where id = p_action;
end $$;

revoke all on function pilotage.peut_saisir_impayes(), pilotage.contacts_profils(text[]), pilotage.impaye_rivage(text) from public, anon, authenticated;
revoke all on function public.pilotage_impayes(), public.pilotage_impaye_ouvrir(text, text), public.pilotage_impaye_maj(bigint, text, text),
  public.pilotage_impaye_action(bigint, text, date), public.pilotage_impaye_action_statut(bigint, text) from public, anon;
grant execute on function public.pilotage_impayes(), public.pilotage_impaye_ouvrir(text, text), public.pilotage_impaye_maj(bigint, text, text),
  public.pilotage_impaye_action(bigint, text, date), public.pilotage_impaye_action_statut(bigint, text) to authenticated;

-- Le tableau Impayés rejoint les tableaux de suivi visibles par tous
create or replace function public.pilotage_tableaux_visibles() returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when pilotage.mon_role() is not null then '["agence","sinistres","dg","compta","impayes"]'::jsonb else '[]'::jsonb end
$$;
