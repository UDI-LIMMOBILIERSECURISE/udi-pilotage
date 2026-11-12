-- 147 : l'annuaire des mails reconnaît tous les contacts de Rivage (question de Nicolas du 12/11/2026)
--  Jusqu'ici, un prestataire n'était reconnu que s'il était désigné sur un ticket, et un syndic que s'il était rattaché à un lot.
--  Rivage compte 122 prestataires, 63 syndics et 8 autres fournisseurs avec une adresse mail : tous sont maintenant reconnus.
--  Un mail avec un contact connu mais sans lot identifiable n'est plus ignoré : il est gardé et va dans « Mails à vérifier ».
--  (Les organismes GLI de Rivage n'ont pas d'adresse mail : rien à reconnaître pour eux tant qu'elle n'est pas saisie.)

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
  -- 147 : tout profil Rivage qui a cette adresse (prestataire sans ticket, fournisseur, syndic non rattaché à un lot, organisme…) :
  --       le mail est gardé ; sans lot connu, il va dans « Mails à vérifier »
  select lower(trim(pr.data->>'email')),
         case pr.data->>'nature' when 'contractor' then 'prestataire' when 'syndic' then 'syndic'
              when 'other_supplier' then 'fournisseur' when 'service_contract_provider' then 'fournisseur' when 'gli_provider' then 'organisme'
              when 'physical_landlord' then 'bailleur' when 'moral_landlord' then 'bailleur'
              when 'physical_tenant' then 'locataire' when 'moral_tenant' then 'locataire' when 'physical_guarantor' then 'garant'
              else coalesce(pr.data->>'nature', 'contact') end,
         pilotage.nom_profil(pr.id), null, null, null, null, null, null
    from pilotage.objets pr
   where pr.type = 'Profile' and pr.supprime_le is null and lower(trim(pr.data->>'email')) in (select x from e)
$$;
revoke all on function pilotage.mails_annuaire(text[]) from public, anon, authenticated;

-- Contact connu hors période (ancien locataire, ancien bailleur) : les lots de toutes les périodes restent proposés,
-- même si l'annuaire le reconnaît aussi par son seul profil (qui ne donne pas de lot)
do $do$
declare d text; avant text := $a$  if corr = '[]'::jsonb then
    select coalesce(jsonb_agg(distinct jsonb_build_object('email', a.email, 'nom', a.nom, 'role', a.role)), '[]'::jsonb),$a$;
  apres text := $b$  if lots is null then
    select coalesce(jsonb_agg(distinct jsonb_build_object('email', a.email, 'nom', a.nom, 'role', a.role)), '[]'::jsonb),$b$;
begin
  d := pg_get_functiondef('public.pilotage_mails_preparer(text[], timestamptz, text, text)'::regprocedure);
  if position(avant in d) = 0 then raise exception '147 : texte attendu introuvable dans pilotage_mails_preparer'; end if;
  execute replace(d, avant, apres);
end $do$;
