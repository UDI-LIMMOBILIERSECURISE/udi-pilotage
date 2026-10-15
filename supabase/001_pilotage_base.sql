-- Back-office de pilotage UDI Gestion : schéma isolé, aucune table existante modifiée
-- (seul ajout hors schéma : un trigger AFTER INSERT sur public.rivage_webhook_events, qui ne bloque jamais l'insertion)

create schema if not exists pilotage;
revoke all on schema pilotage from public, anon, authenticated;

-- 1. Reflet des objets Rivage (un enregistrement par objet, état le plus récent)
create table pilotage.objets (
  type        text not null,             -- modèle Rivage : Asset, LeasingContract, ManagementContract, Profile, AssetGroup, Upload, Incident, Message, SepaMandate...
  id          text not null,             -- identifiant public Rivage (a_..., lc_..., mc_...)
  data        jsonb not null default '{}',
  source      text not null check (source in ('webhook','api')),
  maj_le      timestamptz not null,
  supprime_le timestamptz,
  primary key (type, id)
);
create index on pilotage.objets (type) where supprime_le is null;

-- 2. Informations absentes de Rivage, saisies dans le back-office (équipements, réponses aux questions)
create table pilotage.saisies (
  id          bigserial primary key,
  objet_type  text not null,
  objet_id    text not null,
  cle         text not null,              -- ex. equipements, activite, negociateur
  valeur      jsonb not null,
  saisi_par   text not null,
  saisi_le    timestamptz not null default now()
);
create index on pilotage.saisies (objet_type, objet_id, cle, saisi_le desc);

-- 3. Règles de contrôle
create table pilotage.regles (
  cle         text primary key,
  libelle     text not null,
  domaine     text not null,
  gravite     text not null check (gravite in ('critique','haute','normale')),
  categorie   text not null check (categorie in ('oblig','tache','controle','courrier')),
  actif       boolean not null default true,
  explication text not null
);

-- 4. Alertes produites par les règles
create table pilotage.alertes (
  id                 bigserial primary key,
  regle              text not null references pilotage.regles(cle),
  objet_type         text not null,
  objet_id           text not null,
  gravite            text not null,
  titre              text not null,
  detail             text,
  lien_rivage        text,
  statut             text not null default 'ouverte' check (statut in ('ouverte','traitee','resolue')),
  premiere_detection timestamptz not null default now(),
  derniere_detection timestamptz not null default now(),
  resolue_le         timestamptz,
  traitee_par        text,
  traitee_le         timestamptz,
  unique (regle, objet_type, objet_id)
);

-- 5. Journal des erreurs d'application des webhooks (le webhook n'est jamais bloqué)
create table pilotage.erreurs (
  id       bigserial primary key,
  survenue timestamptz not null default now(),
  source   text,
  message  text,
  contexte jsonb
);


-- 5 bis. Correspondances entre un objet Rivage et son équivalent dans UDIGESTION ou WeRoof (lecture seule de leurs tables)
create table pilotage.correspondances (
  rivage_type  text not null,
  rivage_id    text not null,
  cible_table  text not null,            -- ex. public.biens, public.bailleurs, public.mandats_vente
  cible_id     text not null,
  methode      text not null,            -- adresse, reference, identite, manuel
  confiance    numeric not null check (confiance between 0 and 1),
  valide_par   text,
  valide_le    timestamptz,
  cree_le      timestamptz not null default now(),
  primary key (rivage_type, rivage_id, cible_table)
);

alter table pilotage.objets   enable row level security;
alter table pilotage.correspondances enable row level security;
alter table pilotage.saisies  enable row level security;
alter table pilotage.regles   enable row level security;
alter table pilotage.alertes  enable row level security;
alter table pilotage.erreurs  enable row level security;
revoke all on all tables in schema pilotage from public, anon, authenticated;

-- Application d'un événement Rivage au reflet
create or replace function pilotage.appliquer(p_model text, p_id text, p_event text, p_data jsonb, p_ts timestamptz, p_source text)
returns void language plpgsql security definer set search_path = pilotage, public as $$
begin
  if p_model is null or p_id is null then return; end if;
  if p_event = 'deleted' then
    insert into pilotage.objets(type, id, data, source, maj_le, supprime_le)
    values (p_model, p_id, '{}'::jsonb, p_source, p_ts, p_ts)
    on conflict (type, id) do update set supprime_le = excluded.supprime_le, maj_le = greatest(pilotage.objets.maj_le, excluded.maj_le);
  else
    insert into pilotage.objets(type, id, data, source, maj_le, supprime_le)
    values (p_model, p_id, coalesce(p_data, '{}'::jsonb), p_source, p_ts, null)
    on conflict (type, id) do update
      set data = excluded.data, source = excluded.source, maj_le = excluded.maj_le, supprime_le = null
      where pilotage.objets.maj_le <= excluded.maj_le;
  end if;
end $$;

create or replace function pilotage.trg_webhook() returns trigger
language plpgsql security definer set search_path = pilotage, public as $$
begin
  begin
    if new.event_name is null and jsonb_typeof(new.payload->'payload') = 'object' then
      perform pilotage.appliquer(new.model_name, new.object_id, new.event_type, new.payload->'payload',
        coalesce((new.payload->>'created_at')::timestamptz, new.received_at), 'webhook');
    end if;
  exception when others then
    insert into pilotage.erreurs(source, message, contexte)
    values ('webhook', sqlerrm, jsonb_build_object('event_id', new.id, 'model', new.model_name, 'object_id', new.object_id));
  end;
  return new;
end $$;

create trigger pilotage_reflet after insert on public.rivage_webhook_events
for each row execute function pilotage.trg_webhook();

-- Rejeu de l'historique déjà reçu, dans l'ordre d'arrivée
do $$
declare r record;
begin
  for r in select * from public.rivage_webhook_events
           where event_name is null and jsonb_typeof(payload->'payload') = 'object' order by id loop
    begin
      perform pilotage.appliquer(r.model_name, r.object_id, r.event_type, r.payload->'payload',
        coalesce((r.payload->>'created_at')::timestamptz, r.received_at), 'webhook');
    exception when others then
      insert into pilotage.erreurs(source, message, contexte)
      values ('rejeu', sqlerrm, jsonb_build_object('event_id', r.id, 'model', r.model_name, 'object_id', r.object_id));
    end;
  end loop;
end $$;

-- Vues de lecture
create or replace view pilotage.v_lots as
select o.id, o.data->>'reference' reference, o.data->>'nature' nature, o.data->>'management_contract_id' mandat_id,
  concat_ws(' ', o.data->'address'->>'number', o.data->'address'->>'street', o.data->'address'->>'zip_code', o.data->'address'->>'city') adresse,
  o.data->'address'->>'zip_code' code_postal,
  (o.data->>'area')::numeric surface, (o.data->>'boutin_area')::numeric surface_boutin,
  (o.data->>'construction_year')::int annee_construction,
  o.data->'equipment'->>'heating_method' chauffage, o.data->'equipment'->>'heating_type' type_chauffage,
  o.data->>'syndic_id' syndic_id, o.maj_le
from pilotage.objets o where o.type = 'Asset' and o.supprime_le is null;

create or replace view pilotage.v_baux as
select o.id, o.data->>'reference' reference, o.data->>'status' statut, o.data->>'asset_id' lot_id,
  (o.data->>'start_date')::date debut, (o.data->>'end_date')::date fin, (o.data->>'signed_at')::date signe_le,
  round((o.data->>'rent_in_cents')::numeric / 100, 2) loyer_hc, round((o.data->>'charges_in_cents')::numeric / 100, 2) charges,
  round((o.data->>'deposit_in_cents')::numeric / 100, 2) depot_garantie, (o.data->>'rent_due_day')::int jour_echeance,
  o.data->'quarter_revision_index'->>'nature' indice, (o.data->>'last_boiler_maintenance_date')::date entretien_chaudiere,
  round((o.data->>'unpaid_amount')::numeric / 100, 2) impaye,
  (select string_agg(coalesce(nullif(t->>'company_name',''), concat_ws(' ', t->>'last_name', t->>'first_name')), ', ') from jsonb_array_elements(o.data->'tenants') t) locataires,
  o.maj_le
from pilotage.objets o where o.type = 'LeasingContract' and o.supprime_le is null;

create or replace view pilotage.v_mandats as
select o.id, o.data->>'reference' reference, o.data->>'name' nom, o.data->>'status' statut,
  (o.data->>'start_date')::date debut, (o.data->>'end_date')::date fin, (o.data->>'signed_at')::date signe_le,
  (o.data->>'management_fees_rate')::numeric taux_gestion_ttc, (o.data->>'register_number')::int numero_registre,
  (select string_agg(p->>'profile_id', ', ') from jsonb_array_elements(o.data->'profile_contracts_attributes') p) proprietaires,
  o.maj_le
from pilotage.objets o where o.type = 'ManagementContract' and o.supprime_le is null;

revoke all on all tables in schema pilotage from public, anon, authenticated;

-- Règles de la première vague : uniquement des données réellement exposées par Rivage
insert into pilotage.regles(cle, libelle, domaine, gravite, categorie, explication) values
('surface_boutin', 'Surface loi Boutin supérieure à la surface du lot', 'Lots', 'normale', 'controle', 'La surface Boutin ne peut pas dépasser la surface totale : erreur de saisie probable, qui fausse l''encadrement et la décence.'),
('irl_outremer_metropole', 'Indice IRL outre-mer sur un lot en métropole', 'Baux habitation', 'normale', 'controle', 'L''IRL outre-mer ne s''applique qu''aux départements d''outre-mer. Mauvais indice = révision erronée.'),
('irl_local_professionnel', 'Indice IRL sur un local commercial ou de bureaux', 'Baux commerciaux', 'haute', 'controle', 'Un local commercial ou de bureaux est indexé sur l''ILC ou l''ILAT, pas sur l''IRL.'),
('mandat_sans_signature', 'Mandat actif sans date de signature', 'Mandat, compta, agence', 'haute', 'controle', 'Le mandat écrit et signé est obligatoire (loi Hoguet) et sa date alimente le registre des mandats.'),
('dg_plafond', 'Dépôt de garantie au-dessus du plafond légal', 'Baux habitation', 'haute', 'controle', 'Habitation : 1 mois de loyer HC en location vide, 2 mois en meublé (loi du 6 juillet 1989, art. 22 et 25-6). La nature du bail n''étant pas exposée par l''API, la règle s''appuie sur la nature du lot.'),
('chaudiere_gaz_entretien', 'Chauffage au gaz sans entretien de chaudière à jour', 'Entretien et contrats', 'normale', 'oblig', 'Entretien annuel obligatoire de la chaudière : attestation à réclamer au locataire.'),
('bail_non_entre', 'Bail commencé mais toujours au statut « Créé »', 'Baux habitation', 'haute', 'oblig', 'La date de début est passée depuis plus de 5 jours et le bail n''est pas passé en entrée : date d''entrée et EDL d''entrée à vérifier.'),
('document_supprime', 'Document supprimé dans Rivage', 'Documents', 'normale', 'controle', 'Un document de suivi (bail, EDL, diagnostic, assurance, mandat) a été supprimé : vérifier qu''il a été remplacé.');

create or replace function pilotage.executer_controles() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer;
begin
  create temp table _det on commit drop as
  with lots as (select * from pilotage.v_lots),
       baux as (select b.*, l.nature lot_nature, l.code_postal, l.chauffage from pilotage.v_baux b left join lots l on l.id = b.lot_id)
  select 'surface_boutin'::text regle, 'Asset'::text objet_type, id objet_id,
    'Lot ' || coalesce(reference,'') || ' : surface Boutin ' || surface_boutin || ' m² pour ' || surface || ' m²' titre,
    adresse detail, 'https://rivage.immo/asset_list' lien
  from lots where surface_boutin > surface
  union all
  select 'irl_outremer_metropole', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : IRL outre-mer hors DOM', 'Lot en ' || coalesce(code_postal,'?') || ' — locataires : ' || coalesce(locataires,'?'),
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where indice = 'irl_outre_mer' and coalesce(code_postal,'') not like '97%' and statut <> 'closed'
  union all
  select 'irl_local_professionnel', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : IRL sur un local ' || lot_nature, 'Locataires : ' || coalesce(locataires,'?') || ' — ILC ou ILAT attendu',
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where indice in ('irl','irl_outre_mer') and lot_nature in ('commercial','office') and statut <> 'closed'
  union all
  select 'mandat_sans_signature', 'ManagementContract', id,
    'Mandat n°' || coalesce(reference,'') || ' ' || coalesce(nom,'') || ' : pas de date de signature', 'Début le ' || to_char(debut,'DD/MM/YYYY'),
    'https://rivage.immo/landlords/profiles/' || split_part(coalesce(proprietaires,''), ', ', 1)
  from pilotage.v_mandats where statut = 'active' and signe_le is null
  union all
  select 'dg_plafond', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : DG de ' || round(depot_garantie / nullif(loyer_hc,0), 1) || ' mois de loyer HC',
    'DG ' || depot_garantie || ' € pour un loyer HC de ' || loyer_hc || ' € — ' || coalesce(locataires,'?') ||
      case when depot_garantie > 2 * loyer_hc then ' (au-delà même du plafond meublé)' else ' (au-delà du plafond en location vide, normal seulement en meublé)' end,
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where lot_nature in ('flat','house','room') and statut in ('created','move_in','in_progress') and loyer_hc > 0 and depot_garantie > loyer_hc
  union all
  select 'chaudiere_gaz_entretien', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : chauffage au gaz, entretien de chaudière ' || coalesce('du ' || to_char(entretien_chaudiere,'DD/MM/YYYY'), 'non renseigné'),
    'Locataires : ' || coalesce(locataires,'?'), 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where chauffage = 'gas' and statut in ('move_in','in_progress') and (entretien_chaudiere is null or entretien_chaudiere < current_date - 365)
  union all
  select 'bail_non_entre', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : début le ' || to_char(debut,'DD/MM/YYYY') || ', toujours au statut « Créé »',
    'Locataires : ' || coalesce(locataires,'?') || ' — vérifier la date d''entrée et l''EDL d''entrée',
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where statut = 'created' and debut < current_date - 5
  union all
  select 'document_supprime', 'Upload', o.id,
    'Document supprimé : ' || coalesce(o.data->>'nature','type inconnu'),
    'Supprimé le ' || to_char(o.supprime_le at time zone 'Europe/Paris','DD/MM/YYYY HH24:MI') || coalesce(' — lot ' || (o.data->'resourceables'->0->>'reference'), ''),
    'https://rivage.immo/customer/uploads'
  from pilotage.objets o where o.type = 'Upload' and o.supprime_le > now() - interval '30 days'
    and o.data->>'nature' in ('lease_contract','move_in_inventory','move_out_inventory','home_insurance_certificate','property_insurance_contracts',
         'management_mandate','technical_diagnostic_reports','maintenance_contracts','guarantor_documents','security_deposit_proof',
         'energy_performance_diagnosis','asbestos_diagnosis_private_parts');

  insert into pilotage.alertes(regle, objet_type, objet_id, gravite, titre, detail, lien_rivage)
  select d.regle, d.objet_type, d.objet_id, r.gravite, d.titre, d.detail, d.lien
  from _det d join pilotage.regles r on r.cle = d.regle and r.actif
  on conflict (regle, objet_type, objet_id) do update
    set titre = excluded.titre, detail = excluded.detail, lien_rivage = excluded.lien_rivage, derniere_detection = now(),
        statut = case when pilotage.alertes.statut = 'resolue' then 'ouverte' else pilotage.alertes.statut end,
        resolue_le = case when pilotage.alertes.statut = 'resolue' then null else pilotage.alertes.resolue_le end;

  update pilotage.alertes a set statut = 'resolue', resolue_le = now()
  where a.statut in ('ouverte','traitee')
    and not exists (select 1 from _det d where d.regle = a.regle and d.objet_type = a.objet_type and d.objet_id = a.objet_id);

  select count(*) into n from pilotage.alertes where statut = 'ouverte';
  return n;
end $$;

revoke all on all functions in schema pilotage from public, anon, authenticated;
