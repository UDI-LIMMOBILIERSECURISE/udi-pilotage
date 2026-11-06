-- 125 : tableau des clés, rattaché aux lots Rivage, repris de WeRoof (bloc 1 sur 3)
--  Demande de Nicolas du 06/11/2026 : reprendre le tableau des clés de WeRoof (public.biens.numero_trousseau, agence_depositaire_id,
--  public.cles_mouvements, vue v_biens_cles_etat) et rattacher les clés au bien, c'est-à-dire au lot Rivage.
--  Même principe que WeRoof : n° de trousseau et agence dépositaire par lot, journal des prises et retours (qui, motif, date, commentaire),
--  état courant calculé sur le dernier mouvement (jamais stocké, donc jamais désynchronisé).
--  Écart assumé avec WeRoof : un lot peut avoir plusieurs trousseaux (un par agence, par exemple). Dans WeRoof, trois biens portent deux
--  trousseaux dans le même champ texte (« 84 (et 69 ballancourt) », « 20 corbeil et ballancourt »), et deux fiches ne notent que le contenu
--  (« 4 clés remises », « IL y a 10 clés et un BIP ») : d'où le champ composition.
--  Rien n'est écrit dans WeRoof ni dans Rivage. Les tables WeRoof restent intactes.
--  Bloc 1 : tables. Bloc 2 : fonctions. Bloc 3 : reprise des biens WeRoof rapprochés (rapprochement validé du 092-093, un seul lot).

create table if not exists pilotage.cles_agences (
  code text primary key,
  nom text not null,
  ordre integer not null default 0,
  actif boolean not null default true
);
insert into pilotage.cles_agences (code, nom, ordre) values ('udi_gestion', 'UDI Gestion', 1), ('ballancourt', 'Ballancourt', 2)
on conflict (code) do nothing;

create table if not exists pilotage.cles_trousseaux (
  id bigserial primary key,
  asset_id text not null,                                   -- lot Rivage
  numero text,                                              -- étiquette physique du trousseau
  agence text references pilotage.cles_agences (code),      -- agence où il est rangé
  composition text,                                         -- ex. « 3 clés, 1 bip, 1 badge »
  note text,
  a_verifier text,                                          -- reprise WeRoof non standard, effacé dès qu'une personne modifie le trousseau
  weroof_bien_id uuid,
  par uuid,
  le timestamptz not null default now(),
  supprime_le timestamptz,
  check (numero is not null or composition is not null or agence is not null)
);
create index if not exists cles_trousseaux_lot on pilotage.cles_trousseaux (asset_id) where supprime_le is null;

create table if not exists pilotage.cles_mouvements (
  id bigserial primary key,
  asset_id text not null,
  trousseau_id bigint references pilotage.cles_trousseaux (id),
  type_mouvement text not null check (type_mouvement in ('prise', 'retour')),
  date_mouvement timestamptz not null default now(),
  qui text not null check (qui in ('membre', 'prestataire', 'locataire', 'proprietaire', 'autre')),
  membre_id uuid,                                           -- pilotage.membres.user_id quand qui = membre
  nom text,                                                 -- nom libre dans les autres cas
  motif text check (motif in ('edl_entree', 'edl_sortie', 'visite', 'diagnostic', 'travaux', 'remise_locataire', 'restitution_locataire', 'autre')),
  commentaire text,
  source text not null default 'pilotage' check (source in ('pilotage', 'weroof')),
  weroof_id uuid unique,
  par uuid,
  le timestamptz not null default now(),
  supprime_le timestamptz,
  supprime_par uuid,
  check ((qui = 'membre' and membre_id is not null) or (qui <> 'membre' and nullif(trim(nom), '') is not null))
);
create index if not exists cles_mouvements_lot on pilotage.cles_mouvements (asset_id, date_mouvement desc) where supprime_le is null;

-- Biens WeRoof déjà traités : repris sur un lot, ou écartés par la gestion
create table if not exists pilotage.cles_weroof_traites (
  bien_id uuid primary key,
  asset_id text,
  decision text not null check (decision in ('repris', 'ecarte')),
  par uuid,
  le timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['cles_agences', 'cles_trousseaux', 'cles_mouvements', 'cles_weroof_traites'] loop
    execute format('alter table pilotage.%I enable row level security', t);
    execute format('revoke all on pilotage.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- 125 : tableau des clés, rattaché aux lots Rivage, repris de WeRoof (bloc 2 sur 3)

-- Un lot : trousseaux avec leur état, état des clés sans trousseau, dernier mouvement, historique si demandé
create or replace function pilotage.cles_lot_json(p_asset text, p_histo boolean) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with mv as (
    select m.*, case m.qui when 'membre' then coalesce((select mb.prenom from pilotage.membres mb where mb.user_id = m.membre_id), 'Membre') else m.nom end as detenteur,
      (select mb.prenom from pilotage.membres mb where mb.user_id = m.par) as saisi_par
    from pilotage.cles_mouvements m where m.asset_id = p_asset and m.supprime_le is null),
  tr as (select t.* from pilotage.cles_trousseaux t where t.asset_id = p_asset and t.supprime_le is null),
  etats as (  -- dernier mouvement par trousseau ; clé 0 = mouvements notés sans trousseau
    select distinct on (coalesce(trousseau_id, 0)) coalesce(trousseau_id, 0) as k, type_mouvement as type, date_mouvement as date, qui, detenteur, motif
    from mv order by coalesce(trousseau_id, 0), date_mouvement desc, id desc)
  select jsonb_build_object(
    'asset_id', l.id, 'lot', coalesce(nullif(l.reference, ''), l.id), 'nature', l.nature, 'adresse', l.adresse,
    'mandat', (select o.data->>'reference' from pilotage.objets o where o.type = 'ManagementContract' and o.id = l.mandat_id),
    'trousseaux', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'numero', t.numero, 'agence', t.agence, 'agence_nom', a.nom,
         'composition', t.composition, 'note', t.note, 'a_verifier', t.a_verifier,
         'etat', (select to_jsonb(e) - 'k' from etats e where e.k = t.id),
         -- même numéro dans la même agence sur un autre lot : trousseau commun à l'immeuble, ou erreur à corriger
         'aussi_sur', (select jsonb_agg(distinct coalesce(nullif(l2.reference, ''), l2.id)) from pilotage.cles_trousseaux t2 join pilotage.v_lots l2 on l2.id = t2.asset_id
                       where t2.supprime_le is null and t2.asset_id <> t.asset_id and t2.numero = t.numero and t2.agence is not distinct from t.agence))
       order by t.id) from tr t left join pilotage.cles_agences a on a.code = t.agence), '[]'::jsonb),
    'etat_lot', (select to_jsonb(e) - 'k' from etats e where e.k = 0),
    'sorties', (select count(*) from etats e where e.type = 'prise' and (e.k = 0 or e.k in (select id from tr))),
    'dernier', (select jsonb_build_object('type', m.type_mouvement, 'date', m.date_mouvement, 'detenteur', m.detenteur, 'motif', m.motif) from mv m order by m.date_mouvement desc, m.id desc limit 1),
    'mouvements', case when p_histo then coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'type', m.type_mouvement, 'date', m.date_mouvement, 'qui', m.qui,
         'detenteur', m.detenteur, 'motif', m.motif, 'commentaire', m.commentaire, 'trousseau', (select t.numero from pilotage.cles_trousseaux t where t.id = m.trousseau_id),
         'source', m.source, 'saisi_par', m.saisi_par, 'saisi_le', m.le, 'par_id', m.par) order by m.date_mouvement desc, m.id desc) from mv m), '[]'::jsonb) end)
  from pilotage.v_lots l where l.id = p_asset
$$;

-- Listes communes aux écrans : droits, agences, membres, noms déjà saisis (proposés à la saisie)
create or replace function pilotage.cles_contexte() returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object(
    'peut', pilotage.peut_suivre_baux(),
    'role', pilotage.mon_role(),
    'moi', auth.uid(),
    'agences', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'nom', nom) order by ordre) from pilotage.cles_agences where actif), '[]'::jsonb),
    'membres', coalesce((select jsonb_agg(jsonb_build_object('id', user_id, 'prenom', prenom) order by prenom) from pilotage.membres where actif), '[]'::jsonb),
    'noms', coalesce((select jsonb_agg(distinct jsonb_build_object('qui', qui, 'nom', nom)) from pilotage.cles_mouvements where qui <> 'membre' and supprime_le is null), '[]'::jsonb))
$$;

-- Biens WeRoof qui ont des clés (trousseau, n° ou mouvements) et ne sont encore ni repris ni écartés, avec leurs lots candidats
create or replace function pilotage.cles_weroof_restants() returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with s as (
    select b.id, concat_ws(' ', b.adresse, b.code_postal, b.ville) as adresse, nullif(trim(b.numero_trousseau), '') as tr, nullif(trim(b.cles_numero), '') as cn, a.nom as agence,
      (select count(*) from public.cles_mouvements m where m.bien_id = b.id) as nb
    from public.biens b left join public.agences a on a.id = b.agence_depositaire_id
    where (nullif(trim(b.numero_trousseau), '') is not null or nullif(trim(b.cles_numero), '') is not null
           or exists (select 1 from public.cles_mouvements m where m.bien_id = b.id))
      and not exists (select 1 from pilotage.cles_weroof_traites w where w.bien_id = b.id))
  select coalesce(jsonb_agg(jsonb_build_object('bien_id', s.id, 'adresse', s.adresse, 'trousseau', s.tr, 'cles_numero', s.cn, 'agence', s.agence, 'mouvements', s.nb,
    'candidats', (select jsonb_agg(jsonb_build_object('asset_id', r.asset_id, 'lot', coalesce(nullif(l.reference, ''), l.id), 'adresse', l.adresse, 'statut', r.statut)
                  order by r.statut desc, r.score desc) from pilotage.weroof_rapprochements r join pilotage.v_lots l on l.id = r.asset_id where r.bien_id = s.id))
    order by s.adresse), '[]'::jsonb) from s
$$;

-- Reprise d'un bien WeRoof sur un lot Rivage : trousseau (n°, agence) puis tous ses mouvements. Relançable sans doublon.
create or replace function pilotage.cles_reprendre_weroof(p_bien uuid, p_asset text, p_par uuid) returns integer
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare b record; txt text; autre text; num text; verif text; compo text; ag text; t_id bigint; n integer;
begin
  if exists (select 1 from pilotage.cles_weroof_traites where bien_id = p_bien) then return 0; end if;
  select bb.numero_trousseau, bb.cles_numero, a.nom as agence_nom into b
  from public.biens bb left join public.agences a on a.id = bb.agence_depositaire_id where bb.id = p_bien;
  if not found then raise exception 'Bien WeRoof introuvable'; end if;
  if not exists (select 1 from pilotage.v_lots where id = p_asset) then raise exception 'Lot inconnu dans Rivage'; end if;
  txt := coalesce(nullif(trim(b.numero_trousseau), ''), nullif(trim(b.cles_numero), ''));
  autre := case when nullif(trim(b.numero_trousseau), '') is not null and nullif(trim(b.cles_numero), '') is not null
                 and trim(b.numero_trousseau) <> trim(b.cles_numero) then trim(b.cles_numero) end;
  ag := case lower(trim(b.agence_nom)) when 'udi gestion' then 'udi_gestion' when 'ballancourt' then 'ballancourt' end;
  if txt ~ '^\d+$' then num := txt;
  elsif txt ~ '^\d+' then num := substring(txt from '^\d+');
    verif := 'Repris de WeRoof tel quel : « ' || txt || ' » ; vérifier le numéro et l''agence';
  elsif txt is not null then compo := txt;
    verif := 'Repris de WeRoof : « ' || txt || ' », sans numéro de trousseau';
  end if;
  if b.agence_nom is not null and ag is null then verif := concat_ws(' · ', verif, 'Agence WeRoof « ' || b.agence_nom || ' » absente de la liste'); end if;
  if autre is not null then verif := concat_ws(' · ', verif, 'Autre numéro noté dans WeRoof : « ' || autre || ' »'); end if;
  if num is not null or compo is not null or ag is not null then
    insert into pilotage.cles_trousseaux (asset_id, numero, agence, composition, a_verifier, weroof_bien_id, par)
    values (p_asset, num, ag, compo, verif, p_bien, p_par) returning id into t_id;
  end if;
  insert into pilotage.cles_mouvements (asset_id, trousseau_id, type_mouvement, date_mouvement, qui, membre_id, nom, motif, commentaire, source, weroof_id, par, le)
  select p_asset, t_id, m.type_mouvement, m.date_mouvement,
    case when mb.user_id is not null then 'membre'
         when m.user_id is not null then 'autre'
         when m.fournisseur_id is not null then 'prestataire'
         when lower(trim(m.personne_externe_nom)) in ('propriétaire', 'proprietaire', 'bailleur') then 'proprietaire'
         else 'autre' end,
    mb.user_id,
    case when mb.user_id is not null then null
         when m.user_id is not null then coalesce(nullif(trim(concat_ws(' ', p.prenom, p.nom)), ''), 'Collaborateur WeRoof')
         when m.fournisseur_id is not null then coalesce(nullif(trim(f.raison_sociale), ''), 'Prestataire')
         else coalesce(nullif(trim(m.personne_externe_nom), ''), 'Personne externe') end,
    m.motif, m.commentaire, 'weroof', m.id, p_par, coalesce(m.created_at, m.date_mouvement)
  from public.cles_mouvements m
  left join public.profiles p on p.id = m.user_id
  left join public.fournisseurs f on f.id = m.fournisseur_id
  left join lateral (select x.user_id from pilotage.membres x
                     where m.user_id is not null and x.actif and lower(x.prenom) = lower(trim(p.prenom)) limit 1) mb on true
  where m.bien_id = p_bien
  on conflict (weroof_id) do nothing;
  get diagnostics n = row_count;
  insert into pilotage.cles_weroof_traites (bien_id, asset_id, decision, par) values (p_bien, p_asset, 'repris', p_par);
  return n;
end $$;

revoke all on function pilotage.cles_lot_json(text, boolean) from public, anon, authenticated;
revoke all on function pilotage.cles_contexte() from public, anon, authenticated;
revoke all on function pilotage.cles_weroof_restants() from public, anon, authenticated;
revoke all on function pilotage.cles_reprendre_weroof(uuid, text, uuid) from public, anon, authenticated;

-- Écran « Clés » : tous les lots qui ont un trousseau ou un mouvement, liste des lots pour en ajouter, reste WeRoof à rattacher (gestion)
create or replace function public.pilotage_cles_liste() returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return pilotage.cles_contexte() || jsonb_build_object(
    'lots', coalesce((select jsonb_agg(pilotage.cles_lot_json(x.a, false)) from (
        select asset_id as a from pilotage.cles_trousseaux where supprime_le is null
        union select asset_id from pilotage.cles_mouvements where supprime_le is null) x
      where exists (select 1 from pilotage.v_lots l where l.id = x.a)), '[]'::jsonb),
    'tous_lots', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'lot', coalesce(nullif(reference, ''), id), 'adresse', adresse)) from pilotage.v_lots), '[]'::jsonb),
    'weroof', case when pilotage.peut_suivre_baux() then pilotage.cles_weroof_restants() else '[]'::jsonb end);
end $$;

-- Fiches mandat et bail : clés des lots du dossier (lot du bail retrouvé dans Rivage), avec l'historique
create or replace function public.pilotage_cles_lots(p_assets text[], p_bail text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare a text[] := coalesce(p_assets, '{}');
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  if p_bail is not null then
    a := a || array(select data->>'asset_id' from pilotage.objets where type = 'LeasingContract' and id = p_bail and data->>'asset_id' is not null);
  end if;
  return pilotage.cles_contexte() || jsonb_build_object(
    'lots', coalesce((select jsonb_agg(pilotage.cles_lot_json(y.x, true) order by y.x) from (select distinct unnest(a) as x) y
                      where exists (select 1 from pilotage.v_lots l where l.id = y.x)), '[]'::jsonb));
end $$;

-- Trousseau : création, modification, suppression (gestion et direction)
create or replace function public.pilotage_cles_trousseau(p_id bigint, p_asset text, p_numero text, p_agence text, p_composition text, p_note text, p_supprimer boolean)
returns bigint language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v bigint;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Réservé à la gestion et à la direction'; end if;
  if coalesce(p_supprimer, false) then
    update pilotage.cles_trousseaux set supprime_le = now(), par = auth.uid() where id = p_id and supprime_le is null returning id into v;
    if v is null then raise exception 'Trousseau introuvable'; end if;
    return v;
  end if;
  p_numero := nullif(trim(p_numero), ''); p_agence := nullif(trim(p_agence), ''); p_composition := nullif(trim(p_composition), ''); p_note := nullif(trim(p_note), '');
  if p_numero is null and p_composition is null then raise exception 'Indiquer le numéro du trousseau, ou à défaut ce qu''il contient'; end if;
  if p_agence is not null and not exists (select 1 from pilotage.cles_agences where code = p_agence) then raise exception 'Agence inconnue'; end if;
  if p_id is null then
    if not exists (select 1 from pilotage.v_lots where id = p_asset) then raise exception 'Lot inconnu dans Rivage'; end if;
    insert into pilotage.cles_trousseaux (asset_id, numero, agence, composition, note, par)
    values (p_asset, p_numero, p_agence, p_composition, p_note, auth.uid()) returning id into v;
  else
    update pilotage.cles_trousseaux set numero = p_numero, agence = p_agence, composition = p_composition, note = p_note,
      a_verifier = null, par = auth.uid(), le = now()
    where id = p_id and supprime_le is null returning id into v;
    if v is null then raise exception 'Trousseau introuvable'; end if;
  end if;
  return v;
end $$;

-- Prise ou retour de clés : toute l'équipe (un négociateur prend les clés pour une visite)
create or replace function public.pilotage_cles_mouvement(p_asset text, p_trousseau bigint, p_type text, p_date timestamptz, p_qui text, p_membre uuid,
  p_nom text, p_motif text, p_commentaire text) returns bigint
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v bigint; nb integer;
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.v_lots where id = p_asset) then raise exception 'Lot inconnu dans Rivage'; end if;
  if p_type not in ('prise', 'retour') then raise exception 'Indiquer prise ou retour'; end if;
  if p_date > now() + interval '5 minutes' then raise exception 'La date ne peut pas être dans le futur'; end if;
  if p_trousseau is not null then
    if not exists (select 1 from pilotage.cles_trousseaux where id = p_trousseau and asset_id = p_asset and supprime_le is null) then
      raise exception 'Ce trousseau n''est pas rattaché à ce lot'; end if;
  else
    select count(*), min(id) into nb, v from pilotage.cles_trousseaux where asset_id = p_asset and supprime_le is null;
    if nb > 1 then raise exception 'Le lot a plusieurs trousseaux : choisir lequel'; end if;
    p_trousseau := v; v := null;
  end if;
  p_qui := coalesce(nullif(p_qui, ''), 'membre');
  if p_qui = 'membre' then
    p_membre := coalesce(p_membre, auth.uid()); p_nom := null;
    if not exists (select 1 from pilotage.membres where user_id = p_membre and actif) then raise exception 'Membre inconnu'; end if;
  else
    p_membre := null; p_nom := nullif(trim(p_nom), '');
    if p_nom is null then raise exception 'Indiquer le nom de la personne ou de l''entreprise'; end if;
  end if;
  insert into pilotage.cles_mouvements (asset_id, trousseau_id, type_mouvement, date_mouvement, qui, membre_id, nom, motif, commentaire, par)
  values (p_asset, p_trousseau, p_type, coalesce(p_date, now()), p_qui, p_membre, p_nom, nullif(p_motif, ''), nullif(trim(p_commentaire), ''), auth.uid())
  returning id into v;
  return v;
end $$;

-- Mouvement saisi par erreur : retiré par son auteur dans les 24 h, ou par la direction et le superviseur. Ligne conservée (supprime_le).
create or replace function public.pilotage_cles_mouvement_supprimer(p_id bigint) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  update pilotage.cles_mouvements set supprime_le = now(), supprime_par = auth.uid()
  where id = p_id and supprime_le is null
    and (pilotage.mon_role() in ('direction', 'superviseur') or (par = auth.uid() and le > now() - interval '24 hours'));
  if not found then raise exception 'Suppression impossible : réservée à l''auteur dans les 24 h, ou à la direction'; end if;
end $$;

-- Reste WeRoof : rattacher un bien à un lot (reprise de son trousseau et de ses mouvements) ou l'écarter
create or replace function public.pilotage_cles_weroof(p_bien uuid, p_asset text, p_ecarter boolean) returns integer
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Réservé à la gestion et à la direction'; end if;
  if coalesce(p_ecarter, false) then
    insert into pilotage.cles_weroof_traites (bien_id, decision, par) values (p_bien, 'ecarte', auth.uid()) on conflict (bien_id) do nothing;
    return 0;
  end if;
  if exists (select 1 from pilotage.cles_weroof_traites where bien_id = p_bien) then raise exception 'Bien WeRoof déjà traité'; end if;
  return pilotage.cles_reprendre_weroof(p_bien, p_asset, auth.uid());
end $$;

do $$
declare f text;
begin
  foreach f in array array['pilotage_cles_liste()', 'pilotage_cles_lots(text[], text)',
    'pilotage_cles_trousseau(bigint, text, text, text, text, text, boolean)',
    'pilotage_cles_mouvement(text, bigint, text, timestamptz, text, uuid, text, text, text)',
    'pilotage_cles_mouvement_supprimer(bigint)', 'pilotage_cles_weroof(uuid, text, boolean)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- 125 : tableau des clés, rattaché aux lots Rivage, repris de WeRoof (bloc 3 sur 3)
--  Reprise des biens WeRoof qui ont des clés et un seul lot Rivage validé au rapprochement (092-093).
--  Les autres (rapprochement seulement proposé, ou aucun lot) restent dans l'écran Clés, rubrique « Clés WeRoof à rattacher ».
--  Relançable : un bien déjà repris n'est pas repris deux fois.
do $$
declare r record; n integer; nb_biens integer := 0; nb_mvt integer := 0;
begin
  for r in
    select b.id, min(w.asset_id) as asset_id
    from public.biens b join pilotage.weroof_rapprochements w on w.bien_id = b.id and w.statut = 'valide'
    where (nullif(trim(b.numero_trousseau), '') is not null or nullif(trim(b.cles_numero), '') is not null
           or exists (select 1 from public.cles_mouvements m where m.bien_id = b.id))
      and not exists (select 1 from pilotage.cles_weroof_traites t where t.bien_id = b.id)
      and exists (select 1 from pilotage.v_lots l where l.id = w.asset_id)
    group by b.id having count(*) = 1
  loop
    n := pilotage.cles_reprendre_weroof(r.id, r.asset_id, null);
    nb_biens := nb_biens + 1; nb_mvt := nb_mvt + n;
  end loop;
  raise notice 'Clés WeRoof reprises : % biens, % mouvements', nb_biens, nb_mvt;
end $$;

select (select count(*) from pilotage.cles_trousseaux where supprime_le is null) as trousseaux,
  (select count(*) from pilotage.cles_trousseaux where supprime_le is null and a_verifier is not null) as trousseaux_a_verifier,
  (select count(*) from pilotage.cles_mouvements where supprime_le is null) as mouvements,
  jsonb_array_length(pilotage.cles_weroof_restants()) as weroof_a_rattacher;
