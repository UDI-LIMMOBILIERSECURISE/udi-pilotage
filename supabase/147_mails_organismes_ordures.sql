-- 147 : les mails des organismes d'ordures ménagères rattachés aux lots (précision de Nicolas du 12/11/2026)
--  Règle confirmée : un correspondant n'est reconnu que s'il est lié à un lot ou à un bail (locataire, garant, bailleur, prestataire d'un
--  ticket, syndic du lot — dans Rivage, le « fournisseur » d'un lot est son syndic). Une adresse seulement présente dans Rivage ne suffit pas.
--  Ajout : l'organisme de collecte des ordures ménagères (table organismes_ordures, lots via lots_ordures). Un organisme couvre
--  souvent plusieurs lots : l'IA choisit d'après l'adresse ou le nom cités dans le mail, sinon le mail va dans « Mails à vérifier ».

create or replace function pilotage.mails_annuaire(p_emails text[])
returns table(email text, role text, nom text, bail_id text, lot_id text, mandat_id text, ticket_id text, debut date, fin date)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with e as (select lower(trim(x)) x from unnest(p_emails) x)
  select lower(trim(t->>'email')), 'locataire', coalesce(nullif(t->>'company_name', ''), concat_ws(' ', t->>'first_name', t->>'last_name')),
         b.id, b.data->>'asset_id', a.data->>'management_contract_id', null,
         coalesce((t->>'entry_date')::date, (b.data->>'start_date')::date), coalesce((t->>'exit_date')::date, (b.data->>'end_date')::date)
    from pilotage.objets b cross join jsonb_array_elements(coalesce(b.data->'tenants', '[]'::jsonb)) t
    left join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id'
   where b.type = 'LeasingContract' and b.supprime_le is null and lower(trim(t->>'email')) in (select x from e)
  union all
  select lower(trim(pr.data->>'email')), 'garant', pilotage.nom_profil(pr.id), b.id, b.data->>'asset_id', a.data->>'management_contract_id', null,
         coalesce((g->>'entry_date')::date, (b.data->>'start_date')::date), coalesce((g->>'exit_date')::date, (b.data->>'end_date')::date)
    from pilotage.objets b cross join jsonb_array_elements(coalesce(b.data->'guarantors', '[]'::jsonb)) g
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = g->>'id'
    left join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id'
   where b.type = 'LeasingContract' and b.supprime_le is null and lower(trim(pr.data->>'email')) in (select x from e)
  union all
  select lower(trim(pr.data->>'email')), 'bailleur', pilotage.nom_profil(pr.id), null, a.id, m.id, null, vm.debut, vm.fin
    from pilotage.objets m cross join jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = p->>'profile_id'
    join pilotage.objets a on a.type = 'Asset' and a.data->>'management_contract_id' = m.id and a.supprime_le is null
    left join pilotage.v_mandats vm on vm.id = m.id
   where m.type = 'ManagementContract' and m.supprime_le is null and lower(trim(pr.data->>'email')) in (select x from e)
  union all
  select lower(trim(pr.data->>'email')), 'prestataire', pilotage.nom_profil(pr.id), i.data->>'leasing_contract_id', i.data->>'asset_id', null, i.id,
         (i.data->>'declared_at')::date - 15, coalesce((i.data->>'resolved_at')::date + 90, null)
    from pilotage.objets i cross join jsonb_array_elements_text(coalesce(i.data->'contractor_ids', '[]'::jsonb)) c
    join pilotage.objets pr on pr.type = 'Profile' and pr.id = c
   where i.type = 'Incident' and i.supprime_le is null and lower(trim(pr.data->>'email')) in (select x from e)
  union all
  select lower(trim(pr.data->>'email')), 'syndic', pilotage.nom_profil(pr.id), null, a.id, a.data->>'management_contract_id', null, null, null
    from pilotage.objets a join pilotage.objets pr on pr.type = 'Profile' and pr.id = a.data->>'syndic_id'
   where a.type = 'Asset' and a.supprime_le is null and lower(trim(pr.data->>'email')) in (select x from e)
  union all
  -- 147 : organisme de collecte des ordures ménagères (TEOM / REOM) : lots qui lui sont rattachés dans le pilotage (lots_ordures)
  select lower(trim(o.email)), 'organisme', o.nom, null, lo.asset_id, a.data->>'management_contract_id', null, null, null
    from pilotage.organismes_ordures o
    join pilotage.lots_ordures lo on lo.organisme_id = o.id
    left join pilotage.objets a on a.type = 'Asset' and a.id = lo.asset_id
   where o.actif and lower(trim(o.email)) in (select x from e)
$$;
revoke all on function pilotage.mails_annuaire(text[]) from public, anon, authenticated;
