-- Droits du back-office : membres, attribution des mandats, fonctions d'accès filtrées par rôle.
-- Toutes les lectures passent par des fonctions qui vérifient le rôle de l'utilisateur connecté (auth.uid()).

create table pilotage.membres (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  prenom    text not null,
  role      text not null check (role in ('direction','superviseur','gestionnaire','comptable','negociateur')),
  actif     boolean not null default true,
  cree_le   timestamptz not null default now()
);

create table pilotage.attributions (
  mandat_id text not null,
  user_id   uuid not null references pilotage.membres(user_id) on delete cascade,
  cree_le   timestamptz not null default now(),
  primary key (mandat_id, user_id)
);

create table pilotage.obligations (
  id       serial primary key,
  domaine  text, moment text, types text, obligation text, texte text, declencheur text,
  donnee   text, alerte text, statut text, manque text
);

alter table pilotage.membres enable row level security;
alter table pilotage.attributions enable row level security;
alter table pilotage.obligations enable row level security;
revoke all on pilotage.membres, pilotage.attributions, pilotage.obligations from public, anon, authenticated;

alter table pilotage.alertes add column if not exists mandat_id text;

-- Mandat de rattachement d'un objet Rivage
create or replace function pilotage.mandat_de(p_type text, p_id text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select case p_type
    when 'ManagementContract' then p_id
    when 'Asset' then (select data->>'management_contract_id' from pilotage.objets where type = 'Asset' and id = p_id)
    when 'LeasingContract' then (select a.data->>'management_contract_id' from pilotage.objets b join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id' where b.type = 'LeasingContract' and b.id = p_id)
    when 'Upload' then (select a.data->>'management_contract_id' from pilotage.objets u join pilotage.objets a on a.type = 'Asset' and a.id = u.data->'resourceables'->0->>'id' where u.type = 'Upload' and u.id = p_id)
  end
$$;

-- Les contrôles renseignent désormais le mandat de chaque alerte
create or replace function pilotage.rattacher_alertes() returns void
language sql security definer set search_path = pilotage, public as $$
  update pilotage.alertes set mandat_id = pilotage.mandat_de(objet_type, objet_id) where mandat_id is null and statut <> 'resolue';
$$;
select pilotage.rattacher_alertes();
select cron.unschedule('pilotage-controles');
select cron.schedule('pilotage-controles', '*/30 * * * *', $$select pilotage.executer_controles(); select pilotage.rattacher_alertes();$$);

-- Rôle de l'utilisateur connecté
create or replace function pilotage.mon_role() returns text
language sql stable security definer set search_path = pilotage, public as $$
  select role from pilotage.membres where user_id = auth.uid() and actif
$$;

-- Un membre voit une alerte si son mandat lui est attribué ; la direction reçoit en plus les alertes sans attribution.
create or replace function pilotage.alerte_visible_par(p_mandat text, p_user uuid) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select exists (select 1 from pilotage.attributions t where t.mandat_id = p_mandat and t.user_id = p_user)
      or (exists (select 1 from pilotage.membres m where m.user_id = p_user and m.role = 'direction')
          and not exists (select 1 from pilotage.attributions t where t.mandat_id = p_mandat))
$$;

-- ===== Fonctions exposées à l'appli (schéma public, préfixe pilotage_) =====

create or replace function public.pilotage_moi() returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('user_id', m.user_id, 'prenom', m.prenom, 'role', m.role,
    'voit_equipe', m.role in ('direction','superviseur'),
    'voit_commissions', m.role in ('direction','superviseur'),
    'voit_reglages', m.role = 'direction')
  from pilotage.membres m where m.user_id = auth.uid() and m.actif
$$;

create or replace function public.pilotage_membres() returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'prenom', m.prenom, 'role', m.role) order by m.prenom), '[]'::jsonb)
  from pilotage.membres m
  where m.actif and (pilotage.mon_role() in ('direction','superviseur') or m.user_id = auth.uid())
$$;

create or replace function public.pilotage_journee(p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare cible uuid := coalesce(p_user, auth.uid()); r text := pilotage.mon_role();
begin
  if r is null then raise exception 'Accès refusé'; end if;
  if cible <> auth.uid() and r not in ('direction','superviseur') then raise exception 'Accès refusé'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'regle', a.regle, 'libelle', g.libelle, 'categorie', g.categorie, 'domaine', g.domaine,
      'gravite', a.gravite, 'titre', a.titre, 'detail', a.detail, 'explication', g.explication,
      'lien', a.lien_rivage, 'statut', a.statut, 'depuis', a.premiere_detection,
      'traitee_par', a.traitee_par, 'traitee_le', a.traitee_le,
      'mandat_id', a.mandat_id,
      'mandat', (select coalesce(nullif(mc.data->>'name',''), 'Mandat n°' || (mc.data->>'reference')) from pilotage.objets mc where mc.type = 'ManagementContract' and mc.id = a.mandat_id),
      'dossier', case a.objet_type
        when 'LeasingContract' then (select jsonb_build_object('type','bail','ref', b.reference, 'locataires', b.locataires, 'adresse', l.adresse, 'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id)
                                     from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id where b.id = a.objet_id)
        when 'Asset' then (select jsonb_build_object('type','lot','ref', l.reference, 'adresse', l.adresse, 'lien', 'https://rivage.immo/asset_list') from pilotage.v_lots l where l.id = a.objet_id)
        else jsonb_build_object('type', lower(a.objet_type), 'ref', a.objet_id, 'lien', a.lien_rivage) end
    ) order by case a.gravite when 'critique' then 0 when 'haute' then 1 else 2 end, a.premiere_detection)
    from pilotage.alertes a join pilotage.regles g on g.cle = a.regle
    where pilotage.alerte_visible_par(a.mandat_id, cible)
      and (a.statut = 'ouverte' or (a.statut = 'traitee' and a.traitee_le > now() - interval '7 days'))
  ), '[]'::jsonb);
end $$;

create or replace function public.pilotage_traiter(p_alerte bigint, p_traitee boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare a record; r text := pilotage.mon_role(); moi text;
begin
  if r is null then raise exception 'Accès refusé'; end if;
  select * into a from pilotage.alertes where id = p_alerte;
  if not found then raise exception 'Alerte introuvable'; end if;
  if r not in ('direction','superviseur') and not pilotage.alerte_visible_par(a.mandat_id, auth.uid()) then raise exception 'Accès refusé'; end if;
  select prenom into moi from pilotage.membres where user_id = auth.uid();
  update pilotage.alertes set statut = case when p_traitee then 'traitee' else 'ouverte' end,
    traitee_par = case when p_traitee then moi end, traitee_le = case when p_traitee then now() end
  where id = p_alerte and statut <> 'resolue';
end $$;

-- Mandats et commissions : direction et superviseur
create or replace function public.pilotage_mandats() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction','superviseur') then raise exception 'Accès refusé'; end if;
  return coalesce((
    select jsonb_agg(x order by (x->>'debut') desc nulls last) from (
      select jsonb_build_object(
        'id', m.id, 'reference', m.reference, 'nom', m.nom, 'statut', m.statut, 'debut', m.debut, 'signe_le', m.signe_le,
        'taux_ttc', m.taux_gestion_ttc,
        'lots', (select count(*) from pilotage.v_lots l where l.mandat_id = m.id),
        'loyer_cc', (select sum(b.loyer_hc + b.charges) from pilotage.v_baux b join pilotage.v_lots l on l.id = b.lot_id where l.mandat_id = m.id and b.statut in ('created','move_in','in_progress')),
        'negociateur', (select s.valeur->>'v' from pilotage.saisies s where s.objet_type = 'ManagementContract' and s.objet_id = m.id and s.cle = 'negociateur' order by s.saisi_le desc limit 1),
        'go', (select s.valeur from pilotage.saisies s where s.objet_type = 'ManagementContract' and s.objet_id = m.id and s.cle = 'go' order by s.saisi_le desc limit 1),
        'lien', 'https://rivage.immo/landlords/profiles/' || split_part(coalesce(m.proprietaires,''), ', ', 1)
      ) x from pilotage.v_mandats m) t
  ), '[]'::jsonb);
end $$;

create or replace function public.pilotage_saisir_mandat(p_mandat text, p_cle text, p_valeur jsonb) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare moi text;
begin
  if pilotage.mon_role() not in ('direction','superviseur') then raise exception 'Accès refusé'; end if;
  if p_cle not in ('negociateur','go') then raise exception 'Information non prévue'; end if;
  select prenom into moi from pilotage.membres where user_id = auth.uid();
  insert into pilotage.saisies(objet_type, objet_id, cle, valeur, saisi_par) values ('ManagementContract', p_mandat, p_cle, p_valeur, moi);
end $$;

-- Réglages : direction seulement
create or replace function public.pilotage_reglages() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'regles', (select jsonb_agg(jsonb_build_object('cle', cle, 'libelle', libelle, 'domaine', domaine, 'gravite', gravite, 'actif', actif, 'explication', explication,
                 'ouvertes', (select count(*) from pilotage.alertes a where a.regle = r.cle and a.statut = 'ouverte')) order by domaine, libelle) from pilotage.regles r),
    'obligations', (select jsonb_agg(to_jsonb(o) order by o.id) from pilotage.obligations o),
    'membres', (select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'prenom', m.prenom, 'role', m.role, 'actif', m.actif,
                 'email', (select email from auth.users u where u.id = m.user_id),
                 'mandats', (select coalesce(jsonb_agg(t.mandat_id), '[]'::jsonb) from pilotage.attributions t where t.user_id = m.user_id)) order by m.prenom) from pilotage.membres m),
    'mandats', (select jsonb_agg(jsonb_build_object('id', id, 'reference', reference, 'nom', nom, 'statut', statut) order by lpad(reference, 6, '0')) from pilotage.v_mandats)
  );
end $$;

create or replace function public.pilotage_regle_activer(p_cle text, p_actif boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  update pilotage.regles set actif = p_actif where cle = p_cle;
end $$;

-- Ajout d'un membre : uniquement un compte existant (même connexion qu'UDIGESTION)
create or replace function public.pilotage_membre_enregistrer(p_email text, p_prenom text, p_role text, p_actif boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare uid uuid;
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'Aucun compte avec cet e-mail'; end if;
  if uid = auth.uid() and (p_role <> 'direction' or not p_actif) then raise exception 'Vous ne pouvez pas retirer votre propre accès'; end if;
  insert into pilotage.membres(user_id, prenom, role, actif) values (uid, p_prenom, p_role, p_actif)
  on conflict (user_id) do update set prenom = excluded.prenom, role = excluded.role, actif = excluded.actif;
end $$;

create or replace function public.pilotage_attribuer(p_mandat text, p_user uuid, p_oui boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  if p_oui then insert into pilotage.attributions(mandat_id, user_id) values (p_mandat, p_user) on conflict do nothing;
  else delete from pilotage.attributions where mandat_id = p_mandat and user_id = p_user; end if;
end $$;

revoke all on function public.pilotage_moi(), public.pilotage_membres(), public.pilotage_journee(uuid), public.pilotage_traiter(bigint, boolean),
  public.pilotage_mandats(), public.pilotage_saisir_mandat(text, text, jsonb), public.pilotage_reglages(), public.pilotage_regle_activer(text, boolean),
  public.pilotage_membre_enregistrer(text, text, text, boolean), public.pilotage_attribuer(text, uuid, boolean) from public, anon;
grant execute on function public.pilotage_moi(), public.pilotage_membres(), public.pilotage_journee(uuid), public.pilotage_traiter(bigint, boolean),
  public.pilotage_mandats(), public.pilotage_saisir_mandat(text, text, jsonb), public.pilotage_reglages(), public.pilotage_regle_activer(text, boolean),
  public.pilotage_membre_enregistrer(text, text, text, boolean), public.pilotage_attribuer(text, uuid, boolean) to authenticated;
revoke all on all functions in schema pilotage from public, anon, authenticated;

-- Premier membre : Nicolas, direction
insert into pilotage.membres(user_id, prenom, role) values ('d60281d0-51fd-45f5-831a-aaa2a1de01a7', 'Nicolas', 'direction') on conflict do nothing;
