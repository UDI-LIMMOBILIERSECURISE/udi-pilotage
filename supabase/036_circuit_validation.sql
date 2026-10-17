-- 036 : circuit de validation des mandats et des baux, fil de discussion par dossier, données sensibles (décisions de Nicolas, 17/10/2026).
--   Remplace le « 036 » proposé le matin même (jamais passé), écrit sans avoir vu le code : il recréait des tables qui existent déjà.
--
--   1. Données sensibles reçues de Rivage : les identifiants d'extranet des fournisseurs (mot de passe compris), les dates et lieux de
--      naissance, les notes internes et les liens d'accès ne sont plus stockés. Exception : la date de naissance des locataires,
--      nécessaire au contrôle des plus de 65 ans avant un congé. Nettoyage à l'arrivée du webhook et purge de l'existant.
--   2. Circuit (mandats et baux soumis au contrôle d'entrée) :
--        À finaliser            : le commercial répond aux questions, dépose les pièces, fait corriger Rivage ;
--        En attente de validation : automatique dès que tout est complet (plus de bouton « prévalider ») ;
--        Validé                 : la gestion valide ; le dossier sort des deux listes.
--      Un champ Rivage vide bloque, même si une réponse a été saisie : il se corrige dans Rivage. Seuls Nicolas (direction) et
--      Romain (superviseur) peuvent forcer ce blocage, avec une justification écrite ; le forçage est tracé et le champ reste signalé.
--      Bail : la validation est le GO du contrôle d'entrée (Marion, Romain ou Nicolas, règle inchangée).
--      Mandat : nouvelle validation par la gestion ; le GO « dossier complet » qui déclenche la commission reste à Nicolas
--      (Romain seulement si le dossier est validé par la gestion et non forcé, ce qui correspond au « tout vert »).
--      Le commercial est le négociateur du mandat, ou le « loué par » du bail : il a accès à ses dossiers et peut y répondre.
--   3. Fil de discussion par dossier : un message peut viser une question précise ; une demande de correction reste affichée
--      comme action à faire tant qu'elle n'est pas traitée ; elle ne change pas l'état du dossier.
--   4. Lecture IA des mandats lancée automatiquement (chaque heure) pour les mandats soumis qui n'ont pas encore été lus.

-- ========== 1. Données sensibles ==========

create or replace function pilotage.nettoyer_personne(p jsonb, p_garder_naissance boolean default false) returns jsonb
language sql immutable as $$
  select case when p is null or jsonb_typeof(p) <> 'object' then p else
    ((case when p_garder_naissance then p else p - 'birth_date' end)
       - 'birth_city' - 'birth_country' - 'internal_note' - 'crypted_path' - 'supplier_detail')
    || case when jsonb_typeof(p->'supplier_detail') = 'object'
            then jsonb_build_object('supplier_detail', (p->'supplier_detail') - 'extranet_login' - 'extranet_password')
            else '{}'::jsonb end
  end
$$;

create or replace function pilotage.nettoyer_donnees(p_model text, p_data jsonb) returns jsonb
language plpgsql immutable as $$
declare d jsonb := p_data;
begin
  if d is null or jsonb_typeof(d) <> 'object' then return d; end if;
  if p_model = 'Profile' then return pilotage.nettoyer_personne(d); end if;
  if p_model = 'LeasingContract' then
    if jsonb_typeof(d->'tenants') = 'array' then
      d := jsonb_set(d, '{tenants}', coalesce((select jsonb_agg(pilotage.nettoyer_personne(t.v, true) order by t.n)
                                               from jsonb_array_elements(d->'tenants') with ordinality t(v, n)), '[]'::jsonb));
    end if;
    if jsonb_typeof(d->'guarantors') = 'array' then
      d := jsonb_set(d, '{guarantors}', coalesce((select jsonb_agg(pilotage.nettoyer_personne(g.v) order by g.n)
                                                  from jsonb_array_elements(d->'guarantors') with ordinality g(v, n)), '[]'::jsonb));
    end if;
  end if;
  return d;
end $$;

-- Le reflet ne garde que les données nettoyées (webhooks et synchronisation de rattrapage passent tous deux par ici)
create or replace function pilotage.appliquer(p_model text, p_id text, p_event text, p_data jsonb, p_ts timestamptz, p_source text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if p_model is null or p_id is null then return; end if;
  if p_event = 'deleted' then
    insert into pilotage.objets(type, id, data, source, maj_le, supprime_le)
    values (p_model, p_id, '{}'::jsonb, p_source, p_ts, p_ts)
    on conflict (type, id) do update set supprime_le = excluded.supprime_le, maj_le = greatest(pilotage.objets.maj_le, excluded.maj_le);
  else
    insert into pilotage.objets(type, id, data, source, maj_le, supprime_le)
    values (p_model, p_id, coalesce(pilotage.nettoyer_donnees(p_model, p_data), '{}'::jsonb), p_source, p_ts, null)
    on conflict (type, id) do update
      set data = excluded.data, source = excluded.source, maj_le = excluded.maj_le, supprime_le = null
      where pilotage.objets.maj_le <= excluded.maj_le;
  end if;
end $$;

-- Le journal brut des webhooks (purgé à 90 jours) est nettoyé avant même d'être écrit
create or replace function pilotage.trg_webhook_nettoyer() returns trigger
language plpgsql security definer set search_path = pilotage, public as $$
begin
  begin
    if jsonb_typeof(new.payload->'payload') = 'object' then
      new.payload := jsonb_set(new.payload, '{payload}', pilotage.nettoyer_donnees(new.model_name, new.payload->'payload'));
    end if;
  exception when others then null; -- ne jamais bloquer la réception d'un webhook
  end;
  return new;
end $$;
drop trigger if exists pilotage_nettoyer on public.rivage_webhook_events;
create trigger pilotage_nettoyer before insert on public.rivage_webhook_events
for each row execute function pilotage.trg_webhook_nettoyer();

-- Purge de l'existant
update pilotage.objets set data = pilotage.nettoyer_donnees(type, data)
 where type in ('Profile', 'LeasingContract') and data is distinct from pilotage.nettoyer_donnees(type, data);
update public.rivage_webhook_events set payload = jsonb_set(payload, '{payload}', pilotage.nettoyer_donnees(model_name, payload->'payload'))
 where model_name in ('Profile', 'LeasingContract') and jsonb_typeof(payload->'payload') = 'object'
   and payload->'payload' is distinct from pilotage.nettoyer_donnees(model_name, payload->'payload');

-- ========== 2. Circuit de validation ==========

alter table pilotage.mandats_suivi add column if not exists valide_le timestamptz;
alter table pilotage.mandats_suivi add column if not exists valide_par uuid;

create table if not exists pilotage.dossiers_forcages (
  id bigserial primary key,
  objet text not null check (objet in ('mandat', 'bail')),
  objet_id text not null,
  justification text not null check (length(trim(justification)) >= 10),
  points jsonb not null default '[]'::jsonb,       -- points en suspens au moment du forçage
  par uuid not null, le timestamptz not null default now(),
  leve_le timestamptz, leve_par uuid
);
create index if not exists dossiers_forcages_actifs on pilotage.dossiers_forcages (objet, objet_id) where leve_le is null;

create table if not exists pilotage.dossiers_messages (
  id bigserial primary key,
  objet text not null check (objet in ('mandat', 'bail')),
  objet_id text not null,
  cle text,                                         -- question visée (facultatif)
  auteur uuid not null,
  texte text not null check (length(trim(texte)) > 0),
  demande boolean not null default false,          -- demande de correction : reste à faire tant qu'elle n'est pas traitée
  le timestamptz not null default now(),
  traite_le timestamptz, traite_par uuid
);
create index if not exists dossiers_messages_dossier on pilotage.dossiers_messages (objet, objet_id, le);

create table if not exists pilotage.dossiers_vus (
  user_id uuid not null, objet text not null, objet_id text not null, vu_le timestamptz not null default now(),
  primary key (user_id, objet, objet_id)
);

alter table pilotage.dossiers_forcages enable row level security;
alter table pilotage.dossiers_messages enable row level security;
alter table pilotage.dossiers_vus enable row level security;
revoke all on pilotage.dossiers_forcages, pilotage.dossiers_messages, pilotage.dossiers_vus from public, anon, authenticated;
revoke all on sequence pilotage.dossiers_forcages_id_seq, pilotage.dossiers_messages_id_seq from public, anon, authenticated;

-- Commercial d'un dossier : négociateur du mandat, « loué par » du bail
create or replace function pilotage.commercial_dossier(p_objet text, p_id text) returns uuid
language sql stable security definer set search_path = pilotage, public as $$
  select case p_objet when 'mandat' then (select negociateur from pilotage.mandats_suivi where mandat_id = p_id)
                      when 'bail' then (select loue_par from pilotage.baux_suivi where bail_id = p_id) end
$$;

create or replace function pilotage.peut_traiter_dossier(p_objet text, p_id text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select pilotage.peut_suivre_baux()
      or (pilotage.mon_role() = 'negociateur' and pilotage.commercial_dossier(p_objet, p_id) = auth.uid())
$$;

-- Un lot : la gestion, ou le commercial d'un mandat ou d'un bail de ce lot
create or replace function pilotage.peut_traiter_lot(p_asset text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select pilotage.peut_suivre_baux()
      or (pilotage.mon_role() = 'negociateur' and (
            exists (select 1 from pilotage.objets a join pilotage.mandats_suivi s on s.mandat_id = a.data->>'management_contract_id'
                    where a.type = 'Asset' and a.id = p_asset and s.negociateur = auth.uid())
         or exists (select 1 from pilotage.objets b join pilotage.baux_suivi s on s.bail_id = b.id
                    where b.type = 'LeasingContract' and b.data->>'asset_id' = p_asset and s.loue_par = auth.uid())))
$$;

create or replace function pilotage.peut_forcer() returns boolean
language sql stable security definer set search_path = pilotage, public as $$ select pilotage.mon_role() in ('direction', 'superviseur') $$;

create or replace function pilotage.forcage_actif(p_objet text, p_id text) returns pilotage.dossiers_forcages
language sql stable security definer set search_path = pilotage, public as $$
  select * from pilotage.dossiers_forcages where objet = p_objet and objet_id = p_id and leve_le is null order by le desc limit 1
$$;

-- Bail soumis au contrôle d'entrée : commercial, dérogatoire, professionnel, ou bail commençant à partir du 16/10/2026 (règle de l'écran)
create or replace function pilotage.bail_soumis(p_bail text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(coalesce((select c.ligne->'echeance'->>'type' from pilotage.baux_cache c where c.bail_id = b.id),
                           pilotage.echeance_bail(b.id)->>'type') in ('commercial', 'derogatoire', 'professionnel'), false)
      or coalesce(b.debut >= date '2026-10-16', false)
  from pilotage.v_baux b where b.id = p_bail
$$;

-- Champs Rivage vides d'un contrôle : ils bloquent jusqu'à leur correction dans Rivage (ou un forçage)
create or replace function pilotage.champs_vides(p_controle jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(i->>'libelle' order by i->>'libelle'), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_controle->'items', '[]'::jsonb)) i
  where i->>'detail' like '% : non renseigné dans Rivage%'
$$;

create or replace function pilotage.etat_calcule(p_soumis boolean, p_valide boolean, p_restant integer, p_vides integer, p_force boolean) returns text
language sql immutable as $$
  select case when not coalesce(p_soumis, false) then 'non_soumis'
              when p_valide then 'valide'
              when p_force or (coalesce(p_restant, 0) = 0 and coalesce(p_vides, 0) = 0) then 'en_attente'
              else 'a_finaliser' end
$$;

-- État d'un dossier (calcul complet)
create or replace function pilotage.etat_dossier(p_objet text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare c jsonb; soumis boolean; valide timestamptz; valide_par uuid; vides jsonb; f pilotage.dossiers_forcages; com uuid;
begin
  if p_objet = 'mandat' then
    c := pilotage.controle_mandat(p_id);
    if c is null then return null; end if;
    soumis := coalesce((c->>'soumis')::boolean, false);
    select s.valide_le, s.valide_par into valide, valide_par from pilotage.mandats_suivi s where s.mandat_id = p_id;
  elsif p_objet = 'bail' then
    c := pilotage.controle_bail(p_id);
    if c is null then return null; end if;
    soumis := coalesce(pilotage.bail_soumis(p_id), false);
    select f2.go_le, f2.go_par into valide, valide_par from pilotage.baux_fiche f2 where f2.bail_id = p_id;
  else raise exception 'Objet inconnu'; end if;
  vides := pilotage.champs_vides(c);
  f := pilotage.forcage_actif(p_objet, p_id);
  com := pilotage.commercial_dossier(p_objet, p_id);
  return jsonb_build_object(
    'objet', p_objet, 'id', p_id,
    'etat', pilotage.etat_calcule(soumis, valide is not null, (c->>'restant')::integer, jsonb_array_length(vides), f.id is not null),
    'soumis', soumis, 'restant', (c->>'restant')::integer, 'anomalies', (c->>'anomalies')::integer, 'vides', vides,
    'valide_le', valide, 'valide_par', pilotage.prenom_membre(valide_par),
    'forcage', case when f.id is not null then jsonb_build_object('le', f.le, 'par', pilotage.prenom_membre(f.par), 'justification', f.justification, 'points', f.points) end,
    'commercial', com, 'commercial_prenom', pilotage.prenom_membre(com),
    'peut_traiter', pilotage.peut_traiter_dossier(p_objet, p_id),
    'peut_valider', pilotage.peut_suivre_baux(),
    'peut_forcer', pilotage.peut_forcer(),
    'questions', coalesce((select jsonb_agg(jsonb_build_object('cle', i->>'cle', 'libelle', i->>'libelle')) from jsonb_array_elements(coalesce(c->'items', '[]'::jsonb)) i), '[]'::jsonb));
end $$;

create or replace function public.pilotage_dossier_etat(p_objet text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  if not (pilotage.peut_suivre_baux() or pilotage.peut_traiter_dossier(p_objet, p_id) or pilotage.peut_forcer()) then raise exception 'Accès refusé'; end if;
  return pilotage.etat_dossier(p_objet, p_id);
end $$;

-- Forçage du blocage (direction et superviseur) et levée
create or replace function public.pilotage_dossier_forcer(p_objet text, p_id text, p_justification text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare e jsonb;
begin
  if not pilotage.peut_forcer() then raise exception 'Seuls Nicolas et Romain peuvent forcer un dossier'; end if;
  if length(trim(coalesce(p_justification, ''))) < 10 then raise exception 'Justification obligatoire (10 caractères au moins)'; end if;
  e := pilotage.etat_dossier(p_objet, p_id);
  if e is null then raise exception 'Dossier inconnu'; end if;
  if e->>'etat' <> 'a_finaliser' then raise exception 'Ce dossier n''est pas bloqué'; end if;
  insert into pilotage.dossiers_forcages (objet, objet_id, justification, points, par)
  values (p_objet, p_id, trim(p_justification),
          jsonb_build_object('champs_vides', e->'vides', 'points_restants', e->'restant'), auth.uid());
  insert into pilotage.dossiers_messages (objet, objet_id, auteur, texte)
  values (p_objet, p_id, auth.uid(), 'Dossier forcé : ' || trim(p_justification));
  if p_objet = 'bail' then perform public.pilotage_bail_rafraichir(p_id); end if;
end $$;

create or replace function public.pilotage_dossier_lever_forcage(p_objet text, p_id text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_forcer() then raise exception 'Accès refusé'; end if;
  update pilotage.dossiers_forcages set leve_le = now(), leve_par = auth.uid() where objet = p_objet and objet_id = p_id and leve_le is null;
  if p_objet = 'bail' then perform public.pilotage_bail_rafraichir(p_id); end if;
end $$;

-- GO du contrôle d'entrée d'un bail = validation par la gestion. Refusé tant que le dossier n'est pas complet
-- (points à traiter ou champs Rivage vides), sauf dossier forcé par Nicolas ou Romain.
create or replace function public.pilotage_bail_go(p_bail text, p_oui boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare c jsonb; vides jsonb; force boolean;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_oui then
    force := (pilotage.forcage_actif('bail', p_bail)).id is not null;
    c := pilotage.controle_bail(p_bail);
    if not force then
      if (c->>'restant')::int > 0 then raise exception 'Il reste % point(s) à traiter avant le GO', c->>'restant'; end if;
      vides := pilotage.champs_vides(c);
      if coalesce(pilotage.bail_soumis(p_bail), false) and jsonb_array_length(vides) > 0 then
        raise exception 'Champ(s) non rempli(s) dans Rivage : % (à corriger dans Rivage, ou dossier à faire forcer par Nicolas ou Romain)',
          (select string_agg(x, ', ') from jsonb_array_elements_text(vides) x);
      end if;
    end if;
    if not exists (select 1 from pilotage.baux_fiche where bail_id = p_bail and type_bail is not null) then raise exception 'Confirmez d''abord le type de bail'; end if;
  end if;
  insert into pilotage.baux_fiche (bail_id) values (p_bail) on conflict do nothing;
  update pilotage.baux_fiche set go_le = case when p_oui then now() end, go_par = case when p_oui then auth.uid() end where bail_id = p_bail;
end $$;

-- Validation par la gestion (mandat : nouvelle étape ; bail : GO du contrôle d'entrée)
create or replace function public.pilotage_dossier_valider(p_objet text, p_id text, p_oui boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare e jsonb;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Validation réservée à la gestion'; end if;
  if p_objet = 'bail' then
    perform public.pilotage_bail_go(p_id, p_oui);
    perform public.pilotage_bail_rafraichir(p_id);
    return;
  end if;
  if p_objet <> 'mandat' then raise exception 'Objet inconnu'; end if;
  if p_oui then
    e := pilotage.etat_dossier('mandat', p_id);
    if e is null then raise exception 'Mandat inconnu'; end if;
    if e->>'etat' = 'a_finaliser' then
      raise exception 'Dossier incomplet : % point(s) à traiter%', e->>'restant',
        case when jsonb_array_length(e->'vides') > 0 then ', champ(s) non rempli(s) dans Rivage : ' || (select string_agg(x, ', ') from jsonb_array_elements_text(e->'vides') x) else '' end;
    end if;
  end if;
  insert into pilotage.mandats_suivi (mandat_id) values (p_id) on conflict do nothing;
  update pilotage.mandats_suivi set valide_le = case when p_oui then now() end, valide_par = case when p_oui then auth.uid() end,
    maj_par = auth.uid(), maj_le = now() where mandat_id = p_id;
end $$;

-- GO « dossier complet » d'un mandat (commission) : un dossier forcé ne peut recevoir son GO que de Nicolas ;
-- Romain ne le donne que sur un dossier validé par la gestion et non forcé.
create or replace function public.pilotage_mandat_maj(p_mandat text, p_champ text, p_valeur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); d jsonb; c jsonb; s pilotage.mandats_suivi; force boolean;
begin
  if r not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.v_mandats where id = p_mandat) then raise exception 'Mandat inconnu'; end if;
  insert into pilotage.mandats_suivi(mandat_id) values (p_mandat) on conflict do nothing;
  if p_champ = 'go' then
    if nullif(p_valeur, '') is not null then
      c := pilotage.controle_mandat(p_mandat);
      force := (pilotage.forcage_actif('mandat', p_mandat)).id is not null;
      if (c->>'soumis')::boolean and (c->>'restant')::integer > 0 and not (force and r = 'direction') then
        raise exception 'Contrôle d''entrée du mandat non bouclé : % point(s) à traiter', c->>'restant';
      end if;
      if r = 'superviseur' then
        d := pilotage.dossier_mandat(p_mandat);
        if exists (select 1 from jsonb_array_elements_text(d->'manques') x where x not like 'GO%') then
          raise exception 'Dossier incomplet : seul Nicolas peut donner ce GO';
        end if;
        select * into s from pilotage.mandats_suivi where mandat_id = p_mandat;
        if (c->>'soumis')::boolean and (s.valide_le is null or force) then
          raise exception 'Dossier non validé par la gestion ou forcé : seul Nicolas peut donner ce GO';
        end if;
      end if;
    end if;
    update pilotage.mandats_suivi set go_le = nullif(p_valeur, '')::date, go_par = case when nullif(p_valeur, '') is null then null else auth.uid() end,
      maj_par = auth.uid(), maj_le = now() where mandat_id = p_mandat;
  elsif p_champ = 'negociateur' then
    update pilotage.mandats_suivi set negociateur = nullif(p_valeur, '')::uuid, maj_par = auth.uid(), maj_le = now() where mandat_id = p_mandat;
  elsif p_champ = 'apport_direction' then
    update pilotage.mandats_suivi set apport_direction = coalesce(nullif(p_valeur, '')::boolean, false), maj_par = auth.uid(), maj_le = now() where mandat_id = p_mandat;
  elsif p_champ = 'retire' then
    update pilotage.mandats_suivi set retire_le = nullif(p_valeur, '')::date, maj_par = auth.uid(), maj_le = now() where mandat_id = p_mandat;
  elsif p_champ = 'loyer_prevu' then
    update pilotage.mandats_suivi set loyer_prevu = nullif(replace(replace(p_valeur, ' ', ''), ',', '.'), '')::numeric, maj_par = auth.uid(), maj_le = now() where mandat_id = p_mandat;
  elsif p_champ = 'note' then
    update pilotage.mandats_suivi set note = nullif(p_valeur, ''), maj_par = auth.uid(), maj_le = now() where mandat_id = p_mandat;
  else raise exception 'Champ non modifiable'; end if;
end $$;

-- Le commercial accède à ses dossiers : mêmes fonctions, droit étendu au négociateur du mandat ou au « loué par » du bail
do $do$
declare f record; n text; cible text;
begin
  for f in select p.oid, p.oid::regprocedure::text sig, pg_get_functiondef(p.oid) def from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.proname in ('pilotage_mandat_repondre', 'pilotage_mandat_dossier', 'pilotage_bail_repondre', 'pilotage_fiche_bail_maj', 'pilotage_lot_equipement') loop
    cible := case when f.sig like 'pilotage_mandat_%' then 'pilotage.peut_traiter_dossier(''mandat'', p_mandat)'
                  when f.sig like 'pilotage_lot_%' then 'pilotage.peut_traiter_lot(p_asset)'
                  else 'pilotage.peut_traiter_dossier(''bail'', p_bail)' end;
    n := replace(f.def, 'if not pilotage.peut_suivre_baux() then', 'if not ' || cible || ' then');
    if n = f.def then raise notice 'Droit non modifié dans % (contrôle introuvable)', f.sig; else execute n; end if;
  end loop;
end $do$;

-- La liste des baux garde ses champs vides et l'état du circuit dans le cache (liste rapide, sans recalcul)
create or replace function pilotage.ligne_bail(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object(
    'bail_id', b.id, 'reference', b.reference, 'statut', b.statut, 'locataires', b.locataires, 'debut', b.debut, 'loyer_hc', b.loyer_hc,
    'lot', l.reference, 'adresse', l.adresse, 'nature_lot', l.nature, 'mandat_id', l.mandat_id,
    'mandat', (select coalesce(nullif(m.nom,''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
    'bailleur', pilotage.bailleurs_mandat(l.mandat_id),
    'echeance', e.ech,
    'controle', (select jsonb_build_object('restant', (c->>'restant')::int, 'anomalies', (c->>'anomalies')::int, 'go_le', c->'go_le', 'go_par', c->'go_par', 'portee', c->'portee',
                   'vides', pilotage.champs_vides(c),
                   'soumis', coalesce((e.ech->>'type') in ('commercial', 'derogatoire', 'professionnel'), false) or coalesce(b.debut >= date '2026-10-16', false),
                   'force', (pilotage.forcage_actif('bail', b.id)).id is not null)
                 from pilotage.controle_bail(b.id) c),
    'commercial', (select loue_par from pilotage.baux_suivi where bail_id = b.id),
    'obligations', coalesce((select jsonb_agg(pilotage.obligation_etat(o.id) order by o.prochaine) from pilotage.baux_obligations o where o.bail_id = b.id and o.actif), '[]'::jsonb),
    'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id)
  from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id
  cross join lateral (select pilotage.echeance_bail(b.id) ech) e
  where b.id = p_bail
$$;

-- Mes dossiers : le commercial voit ses dossiers non validés ; la gestion, tous les dossiers non validés.
create or replace function public.pilotage_mes_dossiers() returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); gestion boolean; moi uuid := auth.uid(); res jsonb := '[]'::jsonb; x record; e jsonb;
begin
  if r is null then raise exception 'Accès refusé'; end if;
  gestion := r in ('direction', 'superviseur', 'gestionnaire');
  if not gestion and r <> 'negociateur' then return jsonb_build_object('role', r, 'dossiers', '[]'::jsonb); end if;

  -- Mandats soumis (début à partir du 01/01/2026), non retirés, non validés
  for x in select m.id, coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) titre, pilotage.bailleurs_mandat(m.id) bailleur, m.debut
             from pilotage.v_mandats m left join pilotage.mandats_suivi s on s.mandat_id = m.id
            where m.debut >= date '2026-01-01' and s.retire_le is null and s.valide_le is null
              and (gestion or s.negociateur = moi) loop
    e := pilotage.etat_dossier('mandat', x.id);
    if e->>'etat' in ('a_finaliser', 'en_attente') then
      res := res || jsonb_build_object('objet', 'mandat', 'id', x.id, 'titre', x.titre, 'sous_titre', x.bailleur, 'date', x.debut,
        'etat', e->>'etat', 'restant', e->'restant', 'vides', e->'vides', 'force', e->'forcage' is not null and e->'forcage' <> 'null'::jsonb,
        'commercial', e->>'commercial_prenom');
    end if;
  end loop;

  -- Baux soumis, non validés (depuis le cache de la liste des baux)
  perform pilotage.rafraichir_baux('30 minutes');
  for x in select c.ligne l from pilotage.baux_cache c
            where (c.ligne->'controle'->>'soumis')::boolean and c.ligne->'controle'->>'go_le' is null
              and (gestion or (c.ligne->>'commercial')::uuid = moi) loop
    res := res || jsonb_build_object('objet', 'bail', 'id', x.l->>'bail_id',
      'titre', 'Bail ' || coalesce(x.l->>'reference', '') || ' · ' || coalesce(x.l->>'locataires', ''), 'sous_titre', x.l->>'adresse', 'date', x.l->'debut',
      'etat', pilotage.etat_calcule(true, false, (x.l->'controle'->>'restant')::int, jsonb_array_length(coalesce(x.l->'controle'->'vides', '[]'::jsonb)),
                                    coalesce((x.l->'controle'->>'force')::boolean, false)),
      'restant', x.l->'controle'->'restant', 'vides', coalesce(x.l->'controle'->'vides', '[]'::jsonb), 'force', coalesce((x.l->'controle'->>'force')::boolean, false),
      'commercial', pilotage.prenom_membre((x.l->>'commercial')::uuid), 'ligne', x.l);
  end loop;

  -- Messages non lus et demandes de correction ouvertes
  select coalesce(jsonb_agg(d || jsonb_build_object(
           'non_lus', (select count(*) from pilotage.dossiers_messages mm
                        where mm.objet = d->>'objet' and mm.objet_id = d->>'id' and mm.auteur <> moi
                          and mm.le > coalesce((select v.vu_le from pilotage.dossiers_vus v where v.user_id = moi and v.objet = mm.objet and v.objet_id = mm.objet_id), '-infinity')),
           'demandes', (select count(*) from pilotage.dossiers_messages mm where mm.objet = d->>'objet' and mm.objet_id = d->>'id' and mm.demande and mm.traite_le is null))
         order by (d->>'etat') = 'en_attente', d->>'date'), '[]'::jsonb)
    into res from jsonb_array_elements(res) d;
  return jsonb_build_object('role', r, 'gestion', gestion, 'dossiers', res);
end $$;

-- ========== 3. Fil de discussion ==========

create or replace function pilotage.peut_lire_fil(p_objet text, p_id text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select pilotage.peut_suivre_baux() or pilotage.peut_traiter_dossier(p_objet, p_id)
$$;

create or replace function public.pilotage_dossier_fil(p_objet text, p_id text) returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_lire_fil(p_objet, p_id) then raise exception 'Accès refusé'; end if;
  insert into pilotage.dossiers_vus (user_id, objet, objet_id, vu_le) values (auth.uid(), p_objet, p_id, now())
  on conflict (user_id, objet, objet_id) do update set vu_le = now();
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'cle', m.cle,
      'question', (select q.libelle from pilotage.controle_questions q where q.cle = m.cle),
      'auteur', pilotage.prenom_membre(m.auteur), 'moi', m.auteur = auth.uid(), 'texte', m.texte, 'demande', m.demande, 'le', m.le,
      'traite_le', m.traite_le, 'traite_par', pilotage.prenom_membre(m.traite_par)) order by m.le)
    from pilotage.dossiers_messages m where m.objet = p_objet and m.objet_id = p_id), '[]'::jsonb);
end $$;

create or replace function public.pilotage_dossier_ecrire(p_objet text, p_id text, p_cle text, p_texte text, p_demande boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_lire_fil(p_objet, p_id) then raise exception 'Accès refusé'; end if;
  if nullif(trim(coalesce(p_texte, '')), '') is null then raise exception 'Message vide'; end if;
  if p_cle is not null and not exists (select 1 from pilotage.controle_questions where cle = p_cle) then raise exception 'Question inconnue'; end if;
  insert into pilotage.dossiers_messages (objet, objet_id, cle, auteur, texte, demande)
  values (p_objet, p_id, nullif(p_cle, ''), auth.uid(), trim(p_texte), coalesce(p_demande, false));
  insert into pilotage.dossiers_vus (user_id, objet, objet_id, vu_le) values (auth.uid(), p_objet, p_id, now())
  on conflict (user_id, objet, objet_id) do update set vu_le = now();
end $$;

create or replace function public.pilotage_dossier_message_traiter(p_message bigint, p_oui boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare m pilotage.dossiers_messages;
begin
  select * into m from pilotage.dossiers_messages where id = p_message;
  if m.id is null or not pilotage.peut_lire_fil(m.objet, m.objet_id) then raise exception 'Accès refusé'; end if;
  update pilotage.dossiers_messages set traite_le = case when p_oui then now() end, traite_par = case when p_oui then auth.uid() end where id = p_message;
end $$;

-- ========== 4. Lecture IA automatique des mandats ==========

create or replace function public.pilotage_mandats_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (
    select m.id from pilotage.v_mandats m left join pilotage.mandats_suivi s on s.mandat_id = m.id
    where m.debut >= date '2026-01-01' and s.retire_le is null
      and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = m.id)
      and public.pilotage_mandat_source(m.id) is not null
    order by m.debut desc limit p_max) t
$$;

-- Droit du commercial pour lancer la lecture IA de son mandat ou de son bail (vérifié par la fonction serveur)
create or replace function public.pilotage_peut_lire(p_objet text, p_id text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$ select pilotage.peut_traiter_dossier(p_objet, p_id) $$;

select cron.unschedule('pilotage-lecture-mandats') where exists (select 1 from cron.job where jobname = 'pilotage-lecture-mandats');
select cron.schedule('pilotage-lecture-mandats', '20 * * * *', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-lecture-bail',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{"mandats": true}'::jsonb, timeout_milliseconds := 300000) $$);

-- ========== Droits ==========
revoke all on all functions in schema pilotage from public, anon, authenticated;
revoke all on function public.pilotage_mandats_a_lire(integer) from public, anon, authenticated;
revoke all on function public.pilotage_dossier_etat(text, text), public.pilotage_dossier_forcer(text, text, text), public.pilotage_dossier_lever_forcage(text, text),
  public.pilotage_dossier_valider(text, text, boolean), public.pilotage_mes_dossiers(), public.pilotage_dossier_fil(text, text),
  public.pilotage_dossier_ecrire(text, text, text, text, boolean), public.pilotage_dossier_message_traiter(bigint, boolean),
  public.pilotage_peut_lire(text, text), public.pilotage_bail_go(text, boolean), public.pilotage_mandat_maj(text, text, text) from public, anon;
grant execute on function public.pilotage_dossier_etat(text, text), public.pilotage_dossier_forcer(text, text, text), public.pilotage_dossier_lever_forcage(text, text),
  public.pilotage_dossier_valider(text, text, boolean), public.pilotage_mes_dossiers(), public.pilotage_dossier_fil(text, text),
  public.pilotage_dossier_ecrire(text, text, text, text, boolean), public.pilotage_dossier_message_traiter(bigint, boolean),
  public.pilotage_peut_lire(text, text), public.pilotage_bail_go(text, boolean), public.pilotage_mandat_maj(text, text, text) to authenticated;

-- Le cache des baux est recalculé avec les nouveaux champs
select pilotage.rafraichir_baux();
