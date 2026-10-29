-- 092 — Ordures ménagères par lot et rapprochement WeRoof ↔ Rivage (Nicolas, 29/10/2026). À passer après 091.
--   1. Organismes d'ordures ménagères (redevance REOM) : liste reprise de WeRoof (public.organismes_teom), extensible dans le pilotage.
--   2. Mode par lot : « taxe incluse dans la taxe foncière » ou « organisme externe » (avec l'organisme). Nouvelle question du contrôle
--      d'entrée du mandat (m_cl_ordures), validée quand chaque lot a sa réponse, comme les équipements (062).
--   3. Rapprochement WeRoof ↔ Rivage : pour chaque lot Rivage, le bien WeRoof le plus probable (même code postal ; adresse ;
--      nom du bailleur ; nom du locataire ; n° de lot). Le pilotage PROPOSE, la gestion valide ou rejette (règle « l'IA propose,
--      l'humain confirme »). Rien n'est écrit dans Rivage ni dans WeRoof.
--   4. Une fois un lot rapproché, ce que WeRoof sait des ordures ménagères est proposé sur le lot, à confirmer.
-- Données : quatre tables nouvelles, une question ajoutée au contrôle d'entrée ; rien d'existant n'est modifié ni supprimé.
-- Au 29/10 : aucun mandat dans le circuit, la nouvelle question ne bloque donc aucun dossier en cours.
-- Retour arrière : delete from pilotage.controle_questions where cle = 'm_cl_ordures' ; drop des fonctions de ce script ;
--   drop table pilotage.weroof_rapprochements, pilotage.lots_ordures, pilotage.organismes_ordures.
-- À passer en trois blocs, dans l'ordre.


-- ============================================================================================================================
-- BLOC 1 / 3 : tables, reprise de la liste WeRoof, question du contrôle d'entrée
-- ============================================================================================================================
begin;

create table if not exists pilotage.organismes_ordures (
  id bigserial primary key,
  nom text not null,
  email text, telephone text, adresse text, code_postal text, ville text, site_web text, notes text,
  weroof_id uuid unique,
  actif boolean not null default true,
  cree_par uuid, cree_le timestamptz not null default now(), modifie_le timestamptz);

create table if not exists pilotage.lots_ordures (
  asset_id text primary key,
  mode text not null check (mode in ('taxe_fonciere', 'organisme_externe')),
  organisme_id bigint references pilotage.organismes_ordures(id),
  source text not null default 'saisie' check (source in ('saisie', 'weroof')),
  par uuid, le timestamptz not null default now(),
  check (mode = 'taxe_fonciere' or organisme_id is not null));

create table if not exists pilotage.weroof_rapprochements (
  asset_id text not null,
  bien_id uuid not null,
  score integer not null,
  criteres jsonb not null default '{}'::jsonb,
  ambigu boolean not null default false,
  statut text not null default 'propose' check (statut in ('propose', 'valide', 'rejete')),
  par uuid, le timestamptz not null default now(),
  primary key (asset_id, bien_id));
create unique index if not exists weroof_rapprochements_un_valide on pilotage.weroof_rapprochements (asset_id) where statut = 'valide';

alter table pilotage.organismes_ordures enable row level security;
alter table pilotage.lots_ordures enable row level security;
alter table pilotage.weroof_rapprochements enable row level security;
revoke all on pilotage.organismes_ordures, pilotage.lots_ordures, pilotage.weroof_rapprochements from anon, authenticated;

insert into pilotage.organismes_ordures (nom, email, telephone, adresse, code_postal, ville, site_web, notes, weroof_id)
select trim(o.nom), nullif(trim(o.email), ''), nullif(trim(o.telephone), ''), nullif(trim(o.adresse), ''), nullif(trim(o.code_postal), ''),
       nullif(trim(o.ville), ''), nullif(trim(o.site_web), ''), nullif(trim(o.notes), ''), o.id
  from public.organismes_teom o
 where nullif(trim(o.nom), '') is not null
on conflict (weroof_id) do nothing;

insert into pilotage.controle_questions (cle, portee, bloc, ordre, libelle, aide, mode, ref)
values ('m_cl_ordures', 'mandat', 'clauses', 45, 'Ordures ménagères de chaque lot',
        'Taxe incluse dans la taxe foncière, ou organisme externe (redevance) : dans ce cas, le nouveau locataire et son départ lui sont déclarés.',
        'question', 'ordures')
on conflict (cle) do nothing;

commit;


-- ============================================================================================================================
-- BLOC 2 / 3 : rapprochement WeRoof ↔ Rivage
-- ============================================================================================================================
begin;

-- Mots de 4 lettres et plus, sans accents ni ponctuation (noms de bailleurs et de locataires)
create or replace function pilotage.mots_noms(p text) returns text[]
language sql stable as $$
  select coalesce(array(select distinct m from regexp_split_to_table(lower(pilotage.sans_accents(coalesce(p, ''))), '[^a-z0-9]+') m
                         where length(m) >= 4 and m not in ('mme', 'madame', 'monsieur', 'societe', 'civile', 'immobiliere')), '{}')
$$;

-- Adresse sans code postal ni ville, sans accents ni ponctuation
create or replace function pilotage.rue_normalisee(p text) returns text
language sql stable as $$
  select trim(regexp_replace(lower(pilotage.sans_accents(regexp_replace(coalesce(p, ''), '\s*\d{5}\s.*$', ''))), '[^a-z0-9]+', ' ', 'g'))
$$;

-- Calcule les propositions (lots sans rapprochement validé) : meilleurs candidats seulement, score sur 115
--   adresse : 50 si même numéro et rue très proche, 25 si rue proche ; bailleur : 30 ; locataire : 25 ; n° de lot : 10.
create or replace function pilotage.weroof_rapprocher() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer;
begin
  delete from pilotage.weroof_rapprochements p where p.statut = 'propose';
  with r as materialized (
    select l.id asset_id, l.code_postal cp, a.data->>'lot_number' lotnum, pilotage.rue_normalisee(l.adresse) rue,
           (regexp_match(l.adresse, '^\s*(\d+)'))[1] num,
           pilotage.mots_noms(pilotage.bailleurs_mandat(l.mandat_id)) bai,
           pilotage.mots_noms((select string_agg(coalesce(nullif(t->>'company_name', ''), concat_ws(' ', t->>'first_name', t->>'last_name')), ' ')
                                 from pilotage.objets b, jsonb_array_elements(coalesce(b.data->'tenants', '[]'::jsonb)) t
                                where b.type = 'LeasingContract' and b.data->>'asset_id' = l.id)) loc
      from pilotage.v_lots l join pilotage.objets a on a.type = 'Asset' and a.id = l.id and a.supprime_le is null
     where not exists (select 1 from pilotage.weroof_rapprochements v where v.asset_id = l.id and v.statut = 'valide')),
  w as materialized (
    select b.id bien_id, b.code_postal cp, coalesce(nullif(b.numero_lot, ''), nullif(b.lot_numero, '')) lotnum,
           pilotage.rue_normalisee(b.adresse) rue, (regexp_match(b.adresse, '^\s*(\d+)'))[1] num,
           pilotage.mots_noms(coalesce(bl.nom_societe, '') || ' ' || coalesce(bl.nom, '')) bai,
           pilotage.mots_noms((select string_agg(coalesce(lo.nom, '') || ' ' || coalesce(lo.nom_societe, ''), ' ')
                                 from public.baux bx join public.locataires lo on lo.id = bx.locataire_id where bx.bien_id = b.id)) loc
      from public.biens b left join public.bailleurs bl on bl.id = b.bailleur_id
     where coalesce(b.archived, false) = false
       and not exists (select 1 from pilotage.weroof_rapprochements v where v.bien_id = b.id and v.statut = 'valide')),
  c as (
    select r.asset_id, w.bien_id,
           r.num = w.num and similarity(r.rue, w.rue) >= 0.6 adr_fort, similarity(r.rue, w.rue) >= 0.45 adr_proche,
           r.bai && w.bai bai_ok, r.loc && w.loc loc_ok, r.lotnum is not null and r.lotnum = w.lotnum lot_ok
      from r join w on w.cp = r.cp
     where not exists (select 1 from pilotage.weroof_rapprochements x where x.asset_id = r.asset_id and x.bien_id = w.bien_id and x.statut = 'rejete')),
  s as (
    select c.*, (case when adr_fort then 50 when adr_proche then 25 else 0 end) + (case when bai_ok then 30 else 0 end)
              + (case when loc_ok then 25 else 0 end) + (case when lot_ok then 10 else 0 end) score
      from c),
  k as (select s.*, rank() over (partition by asset_id order by score desc) rg, count(*) over (partition by asset_id, score) ex_aequo,
               count(*) over (partition by bien_id, score) meme_bien from s where score >= 50)
  insert into pilotage.weroof_rapprochements (asset_id, bien_id, score, criteres, ambigu)
  select k.asset_id, k.bien_id, k.score,
         jsonb_build_object('adresse', case when adr_fort then 'identique' when adr_proche then 'proche' else 'différente' end,
                            'bailleur', bai_ok, 'locataire', loc_ok, 'lot', lot_ok),
         k.ex_aequo > 1 or k.meme_bien > 1
    from k where k.rg = 1
      and not exists (select 1 from pilotage.weroof_rapprochements x where x.asset_id = k.asset_id and x.bien_id = k.bien_id);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.pilotage_rapprochements_weroof() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'lots', (select count(*) from pilotage.v_lots),
    'valides', (select count(*) from pilotage.weroof_rapprochements where statut = 'valide'),
    'surs', (select count(distinct asset_id) from pilotage.weroof_rapprochements p where statut = 'propose' and score >= 75 and not ambigu),
    'lignes', coalesce((select jsonb_agg(jsonb_build_object(
        'asset_id', p.asset_id, 'bien_id', p.bien_id, 'score', p.score, 'criteres', p.criteres, 'ambigu', p.ambigu, 'statut', p.statut,
        'par', pilotage.prenom_membre(p.par), 'le', p.le,
        'lot', jsonb_build_object('reference', l.reference, 'adresse', l.adresse, 'bailleur', pilotage.bailleurs_mandat(l.mandat_id)),
        'bien', jsonb_build_object('reference', b.reference, 'adresse', concat_ws(' ', b.adresse, b.code_postal, b.ville), 'lot', coalesce(b.numero_lot, b.lot_numero),
                                   'bailleur', nullif(trim(coalesce(bl.nom_societe, '') || ' ' || coalesce(bl.nom, '') || ' ' || coalesce(bl.prenom, '')), ''),
                                   'ordures', b.teom_mode, 'organisme', coalesce(ot.nom, b.teom_organisme_nom), 'syndic', b.nom_syndic))
        order by p.statut <> 'propose', p.ambigu, p.score desc, l.adresse)
      from pilotage.weroof_rapprochements p
      join pilotage.v_lots l on l.id = p.asset_id
      join public.biens b on b.id = p.bien_id
      left join public.bailleurs bl on bl.id = b.bailleur_id
      left join public.organismes_teom ot on ot.id = b.organisme_teom_id
     where p.statut <> 'rejete'), '[]'::jsonb));
end $$;

create or replace function public.pilotage_rapprochement_weroof_decider(p_asset text, p_bien uuid, p_accepter boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_accepter then
    if exists (select 1 from pilotage.weroof_rapprochements where asset_id = p_asset and statut = 'valide' and bien_id <> p_bien) then
      raise exception 'Ce lot est déjà rapproché d''un autre bien WeRoof : annulez d''abord ce rapprochement'; end if;
    insert into pilotage.weroof_rapprochements (asset_id, bien_id, score, statut, par, le) values (p_asset, p_bien, 0, 'valide', auth.uid(), now())
    on conflict (asset_id, bien_id) do update set statut = 'valide', par = auth.uid(), le = now();
    delete from pilotage.weroof_rapprochements where asset_id = p_asset and statut = 'propose';
  else
    update pilotage.weroof_rapprochements set statut = 'rejete', par = auth.uid(), le = now() where asset_id = p_asset and bien_id = p_bien;
  end if;
end $$;

-- Validation groupée des propositions sûres (score ≥ 75, un seul candidat, bien non revendiqué par un autre lot)
create or replace function public.pilotage_rapprochements_weroof_valider_surs() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  update pilotage.weroof_rapprochements p set statut = 'valide', par = auth.uid(), le = now()
   where p.statut = 'propose' and p.score >= 75 and not p.ambigu
     and (select count(*) from pilotage.weroof_rapprochements q where q.asset_id = p.asset_id and q.statut = 'propose') = 1
     and not exists (select 1 from pilotage.weroof_rapprochements v where v.asset_id = p.asset_id and v.statut = 'valide');
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.pilotage_rapprochements_weroof_recalculer() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  return pilotage.weroof_rapprocher();
end $$;

-- Annuler un rapprochement validé (erreur) : le lot repasse en proposition au prochain calcul
create or replace function public.pilotage_rapprochement_weroof_annuler(p_asset text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  delete from pilotage.weroof_rapprochements where asset_id = p_asset and statut = 'valide';
end $$;

select pilotage.weroof_rapprocher();

commit;


-- ============================================================================================================================
-- BLOC 3 / 3 : organismes, réponse par lot, droits
-- ============================================================================================================================
begin;

-- Ce que l'on sait des ordures ménagères d'un lot : réponse du pilotage, sinon proposition WeRoof (lot rapproché et validé)
create or replace function pilotage.ordures_lot(p_asset text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object(
    'reponse', (select jsonb_build_object('mode', lo.mode, 'organisme_id', lo.organisme_id, 'organisme', to_jsonb(o) - 'weroof_id' - 'cree_par',
                                          'source', lo.source, 'par', pilotage.prenom_membre(lo.par), 'le', lo.le)
                  from pilotage.lots_ordures lo left join pilotage.organismes_ordures o on o.id = lo.organisme_id where lo.asset_id = p_asset),
    'weroof', (select jsonb_build_object('mode', b.teom_mode,
                                         'organisme_id', (select o.id from pilotage.organismes_ordures o where o.weroof_id = b.organisme_teom_id),
                                         'organisme_nom', coalesce((select o.nom from pilotage.organismes_ordures o where o.weroof_id = b.organisme_teom_id), b.teom_organisme_nom))
                 from pilotage.weroof_rapprochements v join public.biens b on b.id = v.bien_id
                where v.asset_id = p_asset and v.statut = 'valide' and b.teom_mode in ('taxe_fonciere', 'organisme_externe')))
$$;

create or replace function public.pilotage_lots_ordures(p_assets text[]) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'lots', coalesce((select jsonb_object_agg(a, pilotage.ordures_lot(a)) from unnest(p_assets) a), '{}'::jsonb),
    'organismes', coalesce((select jsonb_agg(to_jsonb(o) - 'weroof_id' - 'cree_par' order by o.nom) from pilotage.organismes_ordures o where o.actif), '[]'::jsonb));
end $$;

create or replace function public.pilotage_lot_ordures(p_asset text, p_mode text, p_organisme bigint, p_source text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role();
begin
  if r is null or r = 'comptable' then raise exception 'Accès refusé'; end if;
  if r = 'negociateur' and coalesce(pilotage.commercial_dossier('mandat', (select data->>'management_contract_id' from pilotage.objets where type = 'Asset' and id = p_asset)), auth.uid()) <> auth.uid() then
    raise exception 'Accès refusé'; end if;
  if p_mode is null then delete from pilotage.lots_ordures where asset_id = p_asset; return; end if;
  if p_mode = 'organisme_externe' and p_organisme is null then raise exception 'Choisissez l''organisme'; end if;
  insert into pilotage.lots_ordures (asset_id, mode, organisme_id, source, par, le)
  values (p_asset, p_mode, case when p_mode = 'organisme_externe' then p_organisme end, coalesce(p_source, 'saisie'), auth.uid(), now())
  on conflict (asset_id) do update set mode = excluded.mode, organisme_id = excluded.organisme_id, source = excluded.source, par = excluded.par, le = excluded.le;
end $$;

-- Ajouter ou corriger un organisme (tout le monde sauf la comptabilité, qui n'en saisit pas)
create or replace function public.pilotage_organisme_ordures_maj(p_id bigint, p_nom text, p_email text, p_telephone text, p_adresse text,
  p_code_postal text, p_ville text, p_site_web text, p_notes text) returns bigint
language plpgsql security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); nid bigint;
begin
  if r is null or r = 'comptable' then raise exception 'Accès refusé'; end if;
  if coalesce(trim(p_nom), '') = '' then raise exception 'Le nom de l''organisme est obligatoire'; end if;
  if p_id is null then
    insert into pilotage.organismes_ordures (nom, email, telephone, adresse, code_postal, ville, site_web, notes, cree_par)
    values (trim(p_nom), nullif(trim(p_email), ''), nullif(trim(p_telephone), ''), nullif(trim(p_adresse), ''), nullif(trim(p_code_postal), ''),
            nullif(trim(p_ville), ''), nullif(trim(p_site_web), ''), nullif(trim(p_notes), ''), auth.uid()) returning id into nid;
  else
    update pilotage.organismes_ordures set nom = trim(p_nom), email = nullif(trim(p_email), ''), telephone = nullif(trim(p_telephone), ''),
           adresse = nullif(trim(p_adresse), ''), code_postal = nullif(trim(p_code_postal), ''), ville = nullif(trim(p_ville), ''),
           site_web = nullif(trim(p_site_web), ''), notes = nullif(trim(p_notes), ''), modifie_le = now()
     where id = p_id returning id into nid;
  end if;
  return nid;
end $$;

-- Reprise groupée : pour les lots rapprochés sans réponse, la réponse WeRoof devient la réponse du lot (source « weroof »)
create or replace function public.pilotage_lots_ordures_reprendre_weroof() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  insert into pilotage.lots_ordures (asset_id, mode, organisme_id, source, par, le)
  select v.asset_id, b.teom_mode, (select o.id from pilotage.organismes_ordures o where o.weroof_id = b.organisme_teom_id), 'weroof', auth.uid(), now()
    from pilotage.weroof_rapprochements v join public.biens b on b.id = v.bien_id
   where v.statut = 'valide' and b.teom_mode in ('taxe_fonciere', 'organisme_externe')
     and (b.teom_mode = 'taxe_fonciere' or exists (select 1 from pilotage.organismes_ordures o where o.weroof_id = b.organisme_teom_id))
     and not exists (select 1 from pilotage.lots_ordures lo where lo.asset_id = v.asset_id);
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.pilotage_rapprochements_weroof(), public.pilotage_rapprochement_weroof_decider(text, uuid, boolean),
  public.pilotage_rapprochements_weroof_valider_surs(), public.pilotage_rapprochements_weroof_recalculer(),
  public.pilotage_rapprochement_weroof_annuler(text), public.pilotage_lots_ordures(text[]), public.pilotage_lot_ordures(text, text, bigint, text),
  public.pilotage_organisme_ordures_maj(bigint, text, text, text, text, text, text, text, text), public.pilotage_lots_ordures_reprendre_weroof() from public, anon;
grant execute on function public.pilotage_rapprochements_weroof(), public.pilotage_rapprochement_weroof_decider(text, uuid, boolean),
  public.pilotage_rapprochements_weroof_valider_surs(), public.pilotage_rapprochements_weroof_recalculer(),
  public.pilotage_rapprochement_weroof_annuler(text), public.pilotage_lots_ordures(text[]), public.pilotage_lot_ordures(text, text, bigint, text),
  public.pilotage_organisme_ordures_maj(bigint, text, text, text, text, text, text, text, text), public.pilotage_lots_ordures_reprendre_weroof() to authenticated;
revoke all on function pilotage.weroof_rapprocher(), pilotage.ordures_lot(text) from public, anon, authenticated;

commit;

-- Vérification après passage :
-- select (select count(*) from pilotage.organismes_ordures) organismes, (select count(*) from pilotage.weroof_rapprochements) propositions,
--        (select count(*) from pilotage.controle_questions where cle = 'm_cl_ordures') question;
