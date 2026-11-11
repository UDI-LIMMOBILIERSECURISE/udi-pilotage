-- 139 : tickets Rivage suivis par le pilotage, clés après un départ, données à corriger (bloc unique)
--  Décisions de Nicolas du 11/11/2026 (refonte « Ma journée » et fiche du bien) :
--   - un sinistre ou des travaux se créent et avancent dans Rivage ; le pilotage lit l'étape, compte le temps passé, relance et garde
--     les notes de l'équipe (084). Étape lue sur l'intervention la plus avancée du ticket : aucune intervention = déclaré, puis devis à
--     demander, devis demandé, artisan sélectionné (= devis accepté par le bailleur, pratique UDI), planifié, en cours (date de début
--     passée), faits, facturé (facture rattachée). Pas de case « accord du bailleur » dans le pilotage ;
--   - les tags du ticket le classent et se combinent : Sinistre, Travaux, PL, DMEL, À facturer, Logement occupé, Logement vide (liste
--     complète). Sinistre et Travaux : relances ci-dessous. PL et DMEL : suivi du permis (132), inchangé. À facturer : Audrey ET la
--     gestionnaire. Logement occupé ou vide : information. Un ticket ouvert sans tag de type (Sinistre, Travaux, PL, DMEL) devient
--     « Ticket à classer » pour la gestion, jusqu'à ce qu'il soit tagué dans Rivage ;
--   - délais de relance (point de départ proposé par Claude, modifiables dans Règles de relance) : aucun artisan 2 jours ouvrés, devis à
--     demander 2 jours ouvrés, devis demandé sans retour 7 jours, devis accepté non planifié 5 jours, fin prévue dépassée 1 jour,
--     travaux faits sans facture 15 jours, ticket facturé non clos 15 jours ;
--   - les clés ne bloquent pas la frise : rappel à la gestion 2 jours après le départ du locataire si aucun trousseau du lot n'est
--     enregistré à l'agence (page Clés) ;
--   - les données Rivage douteuses vont à Nicolas (direction), pas à Romain : « Données à corriger », signalées depuis la fiche du bien.
--     Premier cas : lot 441 (mandat 417), loué selon l'agence, sans bail dans Rivage.
--  Chaque changement d'étape d'un ticket crée une nouvelle relance (une relance traitée ne masque pas la suivante).
--  Rien n'est écrit dans Rivage.

-- 1. Outils
create or replace function pilotage.jours_ouvres(d1 date, d2 date) returns integer
language sql immutable as $$
  select count(*)::int from generate_series(d1 + 1, d2, interval '1 day') g where extract(isodow from g) < 6
$$;

-- Tags actifs d'un ticket, en minuscules et sans accent (« À facturer » → « a facturer »)
create or replace function pilotage.ticket_tags(p_data jsonb) returns text[]
language sql immutable as $$
  select coalesce(array_agg(distinct lower(translate(trim(coalesce(g->>'name', g #>> '{}')), 'ÀÂÉÈÊàâéèêÔôÎîÛûÙù', 'AAEEEaaeeeOoIiUuUu'))), '{}')
  from jsonb_array_elements(case when jsonb_typeof(p_data->'tags') = 'array' then p_data->'tags' else '[]'::jsonb end) g
  where not coalesce((g->>'archived')::boolean, false)
$$;

-- 2. Données à corriger (direction)
create table if not exists pilotage.donnees_a_corriger (
  id bigint generated always as identity primary key,
  objet_type text not null check (objet_type in ('Asset', 'LeasingContract', 'ManagementContract', 'Incident')),
  objet_id text not null,
  motif text not null,
  signale_par uuid,
  signale_le timestamptz not null default now(),
  corrige_le timestamptz,
  corrige_par uuid,
  reponse text
);
alter table pilotage.donnees_a_corriger enable row level security;
revoke all on pilotage.donnees_a_corriger from public, anon, authenticated;

create or replace function public.pilotage_donnee_signaler(p_objet_type text, p_objet_id text, p_motif text) returns bigint
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare n bigint;
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  if coalesce(trim(p_motif), '') = '' then raise exception 'Dire ce qui semble faux'; end if;
  insert into pilotage.donnees_a_corriger (objet_type, objet_id, motif, signale_par) values (p_objet_type, p_objet_id, trim(p_motif), auth.uid())
  returning id into n;
  return n;
end $$;
revoke all on function public.pilotage_donnee_signaler(text, text, text) from public, anon;
grant execute on function public.pilotage_donnee_signaler(text, text, text) to authenticated;

create or replace function public.pilotage_donnee_corrigee(p_id bigint, p_reponse text) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Réservé à la direction'; end if;
  update pilotage.donnees_a_corriger set corrige_le = now(), corrige_par = auth.uid(), reponse = nullif(trim(p_reponse), '') where id = p_id;
end $$;
revoke all on function public.pilotage_donnee_corrigee(bigint, text) from public, anon;
grant execute on function public.pilotage_donnee_corrigee(bigint, text) to authenticated;

-- Données à corriger d'un lot (fiche du bien) : celles du lot, de ses baux, de son mandat et de ses tickets
create or replace function public.pilotage_donnees_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'motif', d.motif, 'le', d.signale_le, 'par', pilotage.prenom_membre(d.signale_par),
      'corrige_le', d.corrige_le, 'reponse', d.reponse) order by d.corrige_le nulls first, d.signale_le desc)
    from pilotage.donnees_a_corriger d
    where (d.objet_type = 'Asset' and d.objet_id = p_asset)
       or (d.objet_type = 'LeasingContract' and d.objet_id in (select b.id from pilotage.v_baux b where b.lot_id = p_asset))
       or (d.objet_type = 'ManagementContract' and d.objet_id = (select a.data->>'management_contract_id' from pilotage.objets a where a.type = 'Asset' and a.id = p_asset))
       or (d.objet_type = 'Incident' and d.objet_id in (select i.id from pilotage.objets i where i.type = 'Incident' and i.data->>'asset_id' = p_asset))), '[]'::jsonb);
end $$;
revoke all on function public.pilotage_donnees_lot(text) from public, anon;
grant execute on function public.pilotage_donnees_lot(text) to authenticated;

-- 3. Mandat d'un ticket, d'une relance de ticket (« id:étape ») et d'une donnée à corriger
create or replace function pilotage.mandat_de(p_type text, p_id text)
returns text language sql stable security definer set search_path to 'pilotage', 'public' as $function$
  select case p_type
    when 'ManagementContract' then p_id
    when 'Asset' then (select data->>'management_contract_id' from pilotage.objets where type = 'Asset' and id = p_id)
    when 'LeasingContract' then (select a.data->>'management_contract_id' from pilotage.objets b join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id' where b.type = 'LeasingContract' and b.id = p_id)
    when 'Upload' then (select a.data->>'management_contract_id' from pilotage.objets u join pilotage.objets a on a.type = 'Asset' and a.id = u.data->'resourceables'->0->>'id' where u.type = 'Upload' and u.id = p_id)
    when 'PermisTache' then (select a.data->>'management_contract_id' from pilotage.permis_taches t join pilotage.objets a on a.type = 'Asset' and a.id = t.asset_id where t.id::text = p_id)
    when 'TicketRappel' then (select a.data->>'management_contract_id' from pilotage.tickets_rappels r join pilotage.objets i on i.type = 'Incident' and i.id = r.ticket_id
                              join pilotage.objets a on a.type = 'Asset' and a.id = i.data->>'asset_id' where r.id::text = p_id)
    when 'Incident' then (select coalesce(a.data->>'management_contract_id', ab.data->>'management_contract_id')
                            from pilotage.objets i
                            left join pilotage.objets a on a.type = 'Asset' and a.id = i.data->>'asset_id'
                            left join pilotage.objets b on b.type = 'LeasingContract' and b.id = i.data->>'leasing_contract_id'
                            left join pilotage.objets ab on ab.type = 'Asset' and ab.id = b.data->>'asset_id'
                           where i.type = 'Incident' and i.id = split_part(p_id, ':', 1))
    when 'DonneeCorriger' then (select pilotage.mandat_de(d.objet_type, d.objet_id) from pilotage.donnees_a_corriger d where d.id::text = p_id)
  end
$function$;

-- 4. Suivi des tickets ouverts : tags, étape lue dans Rivage, délai de relance
insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, destinataire, explication, parametres) values
 ('ticket_relance', 'Sinistre ou travaux : étape qui n''avance pas', 'Entretien et contrats', 'haute', 'tache', true, 'gestion',
  'Ticket Rivage tagué Sinistre ou Travaux dont l''étape (lue sur l''intervention la plus avancée) n''a pas bougé dans le délai. Faire avancer le ticket dans Rivage : la relance disparaît à la synchronisation suivante. Artisan sélectionné = devis accepté par le bailleur.',
  '[{"nom": "j_declare", "unite": "jours ouvrés", "valeur": 2, "libelle": "Sinistre déclaré sans artisan"},
    {"nom": "j_devis_a_demander", "unite": "jours ouvrés", "valeur": 2, "libelle": "Devis à demander"},
    {"nom": "j_devis_demande", "unite": "jours", "valeur": 7, "libelle": "Devis demandé, pas de retour de l''artisan"},
    {"nom": "j_devis_accepte", "unite": "jours", "valeur": 5, "libelle": "Artisan sélectionné, travaux pas encore planifiés"},
    {"nom": "j_fin_depassee", "unite": "jours", "valeur": 1, "libelle": "Date de fin des travaux dépassée"},
    {"nom": "j_facture", "unite": "jours", "valeur": 15, "libelle": "Travaux faits, pas de facture rattachée"},
    {"nom": "j_cloture", "unite": "jours", "valeur": 15, "libelle": "Facture rattachée, ticket toujours ouvert"}]'::jsonb),
 ('ticket_a_classer', 'Ticket à classer (sans tag)', 'Entretien et contrats', 'normale', 'controle', true, 'gestion',
  'Ticket Rivage ouvert sans tag Sinistre, Travaux, PL ou DMEL : il n''apparaît dans aucun dossier. Poser le tag dans Rivage.', '[]'::jsonb),
 ('ticket_a_facturer', 'Ticket à facturer', 'Mandat, compta, agence', 'normale', 'tache', true, 'compta',
  'Ticket tagué « À facturer » dans Rivage : refacturation à faire. Retirer le tag dans Rivage une fois facturé.', '[]'::jsonb),
 ('ticket_a_facturer_gestion', 'Ticket à facturer (suivi gestion)', 'Entretien et contrats', 'normale', 'tache', true, 'gestion',
  'Ticket tagué « À facturer » dans Rivage : la gestionnaire suit la refacturation avec la comptabilité.', '[]'::jsonb),
 ('cles_lot_sorti', 'Clés non enregistrées après un départ', 'Baux habitation', 'normale', 'tache', true, 'gestion',
  'Le locataire est parti et aucun trousseau du lot n''est enregistré à l''agence (page Clés). Rappel seulement : la frise n''attend pas les clés.',
  '[{"nom": "jours_apres_depart", "unite": "jours", "valeur": 2, "libelle": "Rappel après la date de départ du locataire"}]'::jsonb),
 ('donnee_a_corriger', 'Donnée Rivage à corriger', 'Mandat, compta, agence', 'haute', 'controle', true, 'direction',
  'Donnée de Rivage signalée comme douteuse par l''équipe : à vérifier puis à faire corriger dans Rivage. Réservé à la direction.', '[]'::jsonb)
on conflict (cle) do nothing;

create or replace function pilotage.ticket_suivi()
returns table(ticket_id text, numero text, titre text, asset_id text, mandat_id text, bail_id text, tags text[],
  sinistre boolean, travaux boolean, permis boolean, a_facturer boolean, occupation text,
  etape text, etape_libelle text, action text, depuis date, delai integer, ouvres boolean, retard integer, statut_rivage text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with t as (
    select i.id, i.data, pilotage.ticket_tags(i.data) tg
      from pilotage.objets i
     where i.type = 'Incident' and i.supprime_le is null and i.data->>'status' in ('open', 'in_progress')
  ), e as (
    select t.*, x.v,
      case
        when x.v is null then 'declare'
        when x.v->>'status' = 'estimate_request_pending' then 'devis_a_demander'
        when x.v->>'status' = 'estimate_requested' then 'devis_demande'
        when x.v->>'status' = 'selected' then 'devis_accepte'
        when x.v->>'status' = 'scheduled' and (x.v->>'scheduled_end_at')::date < current_date then 'fin_depassee'
        when x.v->>'status' = 'scheduled' and (x.v->>'scheduled_start_at')::date <= current_date then 'en_cours'
        when x.v->>'status' = 'scheduled' then 'planifie'
        when x.v->>'status' = 'done' and jsonb_array_length(case when jsonb_typeof(x.v->'invoice_ids') = 'array' then x.v->'invoice_ids' else '[]'::jsonb end) = 0 then 'fait'
        when x.v->>'status' = 'done' then 'facture'
        else 'declare' end etape
    from t
    left join lateral (
      select v from jsonb_array_elements(case when jsonb_typeof(t.data->'interventions') = 'array' then t.data->'interventions' else '[]'::jsonb end) v
       where coalesce(v->>'status', '') not in ('cancelled', 'canceled', 'rejected', 'refused')
       order by array_position(array['estimate_request_pending', 'estimate_requested', 'selected', 'scheduled', 'done'], v->>'status') desc nulls last,
                v->>'updated_at' desc nulls last
       limit 1) x on true
  ), d as (
    select e.*,
      case e.etape when 'declare' then 'Déclaré' when 'devis_a_demander' then 'Devis à demander' when 'devis_demande' then 'Devis demandé'
        when 'devis_accepte' then 'Devis accepté' when 'planifie' then 'Travaux planifiés' when 'en_cours' then 'Travaux en cours'
        when 'fin_depassee' then 'Travaux en cours, fin prévue dépassée' when 'fait' then 'Travaux faits' when 'facture' then 'Facturé' end lib,
      case e.etape when 'declare' then 'Missionner un artisan' when 'devis_a_demander' then 'Demander le devis à l''artisan'
        when 'devis_demande' then 'Relancer l''artisan pour le devis' when 'devis_accepte' then 'Planifier les travaux avec l''artisan'
        when 'fin_depassee' then 'Vérifier avec l''artisan que les travaux sont faits' when 'fait' then 'Récupérer la facture de l''artisan'
        when 'facture' then 'Clôturer le ticket dans Rivage' end act,
      case e.etape when 'declare' then coalesce(e.data->>'declared_at', e.data->>'created_at')::date
        when 'fin_depassee' then (e.v->>'scheduled_end_at')::date
        when 'planifie' then null when 'en_cours' then null
        else coalesce(e.v->>'updated_at', e.v->>'created_at', e.data->>'updated_at')::date end dep,
      case e.etape when 'declare' then pilotage.param('ticket_relance', 'j_declare', 2)
        when 'devis_a_demander' then pilotage.param('ticket_relance', 'j_devis_a_demander', 2)
        when 'devis_demande' then pilotage.param('ticket_relance', 'j_devis_demande', 7)
        when 'devis_accepte' then pilotage.param('ticket_relance', 'j_devis_accepte', 5)
        when 'fin_depassee' then pilotage.param('ticket_relance', 'j_fin_depassee', 1)
        when 'fait' then pilotage.param('ticket_relance', 'j_facture', 15)
        when 'facture' then pilotage.param('ticket_relance', 'j_cloture', 15) end::int del,
      e.etape in ('declare', 'devis_a_demander') ouv
    from e
  )
  select d.id, d.data->>'number', d.data->>'title', d.data->>'asset_id', pilotage.mandat_de('Incident', d.id), d.data->>'leasing_contract_id', d.tg,
    'sinistre' = any(d.tg), 'travaux' = any(d.tg), ('pl' = any(d.tg) or 'dmel' = any(d.tg)), 'a facturer' = any(d.tg),
    case when 'logement occupe' = any(d.tg) then 'occupé' when 'logement vide' = any(d.tg) then 'vide' end,
    d.etape, d.lib, d.act, d.dep, d.del, d.ouv,
    case when d.dep is null or d.del is null then null
         when d.ouv then pilotage.jours_ouvres(d.dep, current_date) - d.del
         else (current_date - d.dep) - d.del end,
    d.data->>'status'
  from d
$$;
revoke all on function pilotage.ticket_suivi() from public, anon, authenticated;

create or replace function pilotage.tickets_suivi_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with s as (select * from pilotage.ticket_suivi()),
  lot as (select a.id, a.data->>'reference' ref, concat_ws(' ', a.data->'address'->>'number', a.data->'address'->>'street', a.data->'address'->>'city') adresse
            from pilotage.objets a where a.type = 'Asset')
  select 'ticket_relance', 'Incident', s.ticket_id || ':' || s.etape,
    (case when s.sinistre then 'Sinistre' else 'Travaux' end) || ' n°' || coalesce(s.numero, '?') || ' · ' || s.etape_libelle || ' : ' || s.action,
    concat_ws(' · ', s.titre, case when l.id is not null then 'lot ' || coalesce(l.ref, '?') || ' ' || coalesce(l.adresse, '') end,
      'sans changement depuis le ' || to_char(s.depuis, 'DD/MM/YYYY') || ' (délai ' || s.delai || case when s.ouvres then ' jours ouvrés)' else ' jours)' end,
      case when s.occupation is not null then 'logement ' || s.occupation end),
    'https://rivage.immo/incidents/' || s.ticket_id
  from s left join lot l on l.id = s.asset_id
  where (s.sinistre or s.travaux) and s.retard >= 0
  union all
  select 'ticket_a_classer', 'Incident', s.ticket_id,
    'Ticket n°' || coalesce(s.numero, '?') || ' à classer : poser le tag Sinistre, Travaux, PL ou DMEL dans Rivage',
    concat_ws(' · ', s.titre, case when l.id is not null then 'lot ' || coalesce(l.ref, '?') || ' ' || coalesce(l.adresse, '') end,
      case when cardinality(s.tags) > 0 then 'tags actuels : ' || array_to_string(s.tags, ', ') end),
    'https://rivage.immo/incidents/' || s.ticket_id
  from s left join lot l on l.id = s.asset_id
  where not (s.sinistre or s.travaux or s.permis)
  union all
  select r, 'Incident', s.ticket_id,
    'Ticket n°' || coalesce(s.numero, '?') || ' à facturer · ' || s.etape_libelle,
    concat_ws(' · ', s.titre, case when l.id is not null then 'lot ' || coalesce(l.ref, '?') || ' ' || coalesce(l.adresse, '') end, 'retirer le tag « À facturer » dans Rivage une fois facturé'),
    'https://rivage.immo/incidents/' || s.ticket_id
  from s left join lot l on l.id = s.asset_id cross join unnest(array['ticket_a_facturer', 'ticket_a_facturer_gestion']) r
  where s.a_facturer
$$;
revoke all on function pilotage.tickets_suivi_detections() from public, anon, authenticated;

-- 5. Clés après un départ : rappel si aucun trousseau du lot n'est enregistré à l'agence
create or replace function pilotage.cles_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select distinct on (b.lot_id) 'cles_lot_sorti', 'Asset', b.lot_id,
    'Lot ' || coalesce(l.reference, '?') || ' : locataire parti le ' || to_char(b.fin, 'DD/MM/YYYY') || ', clés non enregistrées à l''agence',
    concat_ws(' · ', l.adresse, 'bail ' || b.reference, b.locataires, 'enregistrer le trousseau rendu dans la page Clés'),
    'https://rivage.immo/asset_list'
  from pilotage.v_baux b join pilotage.v_lots l on l.id = b.lot_id
  join pilotage.v_mandats m on m.id = l.mandat_id and m.statut in ('created', 'active')
  where b.statut in ('move_out', 'closed') and b.fin is not null
    and b.fin <= current_date - pilotage.param('cles_lot_sorti', 'jours_apres_depart', 2)::int and b.fin > current_date - 60
    and not exists (select 1 from pilotage.v_baux x where x.lot_id = b.lot_id and x.statut in ('created', 'move_in', 'in_progress') and x.debut <= current_date)
    and not exists (select 1 from pilotage.cles_trousseaux t where t.asset_id = b.lot_id and t.supprime_le is null)
  order by b.lot_id, b.fin desc
$$;
revoke all on function pilotage.cles_detections() from public, anon, authenticated;

create or replace function pilotage.donnees_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select 'donnee_a_corriger', 'DonneeCorriger', d.id::text,
    case d.objet_type when 'Asset' then 'Lot ' || coalesce(a.data->>'reference', '?') when 'LeasingContract' then 'Bail ' || coalesce(o.data->>'reference', '?')
      when 'ManagementContract' then 'Mandat n°' || coalesce(o.data->>'reference', '?') else 'Ticket n°' || coalesce(o.data->>'number', '?') end || ' : ' || d.motif,
    'Signalé par ' || coalesce(pilotage.prenom_membre(d.signale_par), '?') || ' le ' || to_char(d.signale_le at time zone 'Europe/Paris', 'DD/MM/YYYY'),
    case d.objet_type when 'LeasingContract' then 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || d.objet_id
      when 'Incident' then 'https://rivage.immo/incidents/' || d.objet_id else 'https://rivage.immo/asset_list' end
  from pilotage.donnees_a_corriger d
  left join pilotage.objets a on d.objet_type = 'Asset' and a.type = 'Asset' and a.id = d.objet_id
  left join pilotage.objets o on d.objet_type <> 'Asset' and o.type = d.objet_type and o.id = d.objet_id
  where d.corrige_le is null
$$;
revoke all on function pilotage.donnees_detections() from public, anon, authenticated;

-- 6. Moteur des contrôles : les trois nouvelles sources s'ajoutent (le reste est inchangé)
create or replace function pilotage.executer_controles()
returns integer language plpgsql security definer set search_path to 'pilotage', 'public' as $function$
declare n integer;
begin
  perform pg_advisory_xact_lock(424201);  -- 124 : un seul contrôle à la fois
  perform set_config('pilotage.en_controle', '1', true);  -- 124 : ses propres écritures ne relancent pas de demande
  perform pilotage.dg_recus_compta_maj();
  perform pilotage.assurance_rivage_auto();
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
    'https://rivage.immo/landlords/profiles?profile_id=' || split_part(coalesce(proprietaires,''), ', ', 1)
  from pilotage.v_mandats where statut = 'active' and signe_le is null
  union all
  select 'dg_plafond', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : DG de ' || round(depot_garantie / nullif(loyer_hc,0), 1) || ' mois de loyer HC',
    'DG ' || depot_garantie || ' € pour un loyer HC de ' || loyer_hc || ' € — ' || coalesce(locataires,'?') ||
      case when depot_garantie > 2 * loyer_hc then ' (au-delà même du plafond meublé)' else ' (au-delà du plafond en location vide, normal seulement en meublé)' end,
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where lot_nature in ('flat','house','room') and statut in ('created','move_in','in_progress') and loyer_hc > 0 and pilotage.dossier_nouveau('LeasingContract', id)
    -- 120 : plafond selon le type (fiche, sinon Rivage) ; types sans plafond légal exclus
    and pilotage.plafond_dg_mois(coalesce((select bf.type_bail from pilotage.baux_fiche bf where bf.bail_id = id), pilotage.type_bail_rivage(id))) is not null
    and depot_garantie > loyer_hc * pilotage.plafond_dg_mois(coalesce((select bf.type_bail from pilotage.baux_fiche bf where bf.bail_id = id), pilotage.type_bail_rivage(id)))
  union all
  select 'chaudiere_gaz_entretien', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : chauffage au gaz, entretien de chaudière ' || coalesce('du ' || to_char(entretien_chaudiere,'DD/MM/YYYY'), 'non renseigné'),
    'Locataires : ' || coalesce(locataires,'?'), 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where chauffage = 'gas' and statut in ('move_in','in_progress') and (entretien_chaudiere is null or entretien_chaudiere < current_date - pilotage.param('chaudiere_gaz_entretien','jours_depuis_entretien',365)::int)
  union all
  select 'bail_non_entre', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : début le ' || to_char(debut,'DD/MM/YYYY') || ', toujours au statut « Créé »',
    'Locataires : ' || coalesce(locataires,'?') || ' — vérifier la date d''entrée et l''EDL d''entrée',
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where statut = 'created' and debut < current_date - pilotage.param('bail_non_entre','jours_apres_debut',5)::int
  union all
  select 'document_supprime', 'Upload', o.id,
    'Document supprimé : ' || coalesce(nullif(o.data->>'label',''), o.data->>'nature','type inconnu'),
    'Supprimé le ' || to_char(o.supprime_le at time zone 'Europe/Paris','DD/MM/YYYY HH24:MI') || coalesce(' — ' || case left(o.data->'resourceables'->0->>'id', 3) when 'lc_' then 'bail ' when 'mc_' then 'mandat ' else 'lot ' end || (o.data->'resourceables'->0->>'reference'), '') || coalesce(' (' || (select string_agg(coalesce(t->>'last_name','') || ' ' || coalesce(t->>'first_name',''), ', ') from jsonb_array_elements(o.data->'resourceables'->0->'tenants') t) || ')', ''),
    case when left(o.data->'resourceables'->0->>'id', 3) = 'lc_' then 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || (o.data->'resourceables'->0->>'id') else 'https://rivage.immo/customer/uploads' end
  from pilotage.objets o where o.type = 'Upload' and not exists (select 1 from pilotage.objets r where r.type = 'Upload' and r.supprime_le is null and r.id <> o.id and r.data->>'nature' = o.data->>'nature' and r.data->'resourceables'->0->>'id' = o.data->'resourceables'->0->>'id') and o.supprime_le > now() - make_interval(days => pilotage.param('document_supprime','jours_affichage',30)::int)
    and o.data->>'nature' in ('lease_contract','move_in_inventory','move_out_inventory','home_insurance_certificate','property_insurance_contracts',
         'management_mandate','technical_diagnostic_reports','maintenance_contracts','guarantor_documents','security_deposit_proof',
         'energy_performance_diagnosis','asbestos_diagnosis_private_parts')
  union all
  select d.regle, d.objet_type, d.objet_id, d.titre, d.detail, d.lien from pilotage.suivi_detections() d
  union all
  select e.regle, e.objet_type, e.objet_id, e.titre, e.detail, e.lien from pilotage.etapes_detections() e
  union all
  select x.regle, x.objet_type, x.objet_id, x.titre, x.detail, x.lien from pilotage.factures_detections() x
  union all
  select k.regle, k.objet_type, k.objet_id, k.titre, k.detail, k.lien from pilotage.permis_taches_detections() k
  union all
  select t.regle, t.objet_type, t.objet_id, t.titre, t.detail, t.lien from pilotage.tickets_rappels_detections() t
  union all
  select p.regle, p.objet_type, p.objet_id, p.titre, p.detail, p.lien from pilotage.parametrage_detections() p
  union all  -- 139
  select s.regle, s.objet_type, s.objet_id, s.titre, s.detail, s.lien from pilotage.tickets_suivi_detections() s
  union all
  select c.regle, c.objet_type, c.objet_id, c.titre, c.detail, c.lien from pilotage.cles_detections() c
  union all
  select g.regle, g.objet_type, g.objet_id, g.titre, g.detail, g.lien from pilotage.donnees_detections() g;

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
end $function$;

-- 7. Ma journée : dossier d'un ticket et d'une donnée à corriger ; famille de chaque alerte (filtres de la page)
create or replace function pilotage.famille_alerte(p_regle text, p_type text, p_id text, p_titre text) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select case
    when p_regle = 'ticket_relance' then (select case when 'sinistre' = any(pilotage.ticket_tags(i.data)) then 'sinistres' else 'travaux' end
                                           from pilotage.objets i where i.type = 'Incident' and i.id = split_part(p_id, ':', 1))
    when p_regle in ('ticket_a_classer') then 'a_classer'
    when p_regle in ('ticket_a_facturer', 'ticket_a_facturer_gestion', 'facture_a_traiter') then 'facturation'
    when p_regle = 'ticket_rappel' then 'tickets'
    when p_regle like 'impaye%' then 'impayes'
    when p_regle = 'permis_tache' then 'permis'
    when p_regle in ('bail_suivi', 'bail_suivi_retard') and p_titre ilike '%assurance%' then 'assurance'
    when p_regle in ('bail_suivi', 'bail_suivi_retard', 'chaudiere_gaz_entretien', 'pno_a_renouveler', 'mandat_suivi_retard') then 'suivis'
    when p_regle in ('conge_recu', 'edl_sortie_a_commander', 'edl_sortie_a_confirmer', 'sortie_incoherente', 'colocataire_sorti', 'garant_sorti',
                     'dg_detention', 'dg_reverse', 'dg_hors_delai', 'dg_delai', 'dg_reversement') then 'sorties'
    when p_regle in ('bail_echeance', 'bail_echeance_urgente', 'bail_douze_ans', 'bail_palier', 'bail_acte_delai', 'loyer_modifie', 'bail_derogatoire') then 'echeances'
    when p_regle in ('mandat_controle_entree', 'bail_controle_entree', 'mandat_pieces', 'mandat_pieces_retard', 'bail_dossier_a_completer',
                     'bail_incomplet_entree', 'bail_go_restants_gestion', 'bail_a_signer', 'edl_entree_a_organiser', 'mandat_suivi',
                     'identite_locataire', 'bail_non_entre') then 'entree'
    when p_regle = 'cles_lot_sorti' then 'cles'
    when p_regle = 'donnee_a_corriger' then 'donnees'
    else 'controles' end
$$;

create or replace function public.pilotage_journee(p_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $function$
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
      'objet_type', a.objet_type, 'objet_id', a.objet_id,
      'famille', pilotage.famille_alerte(a.regle, a.objet_type, a.objet_id, a.titre),
      'mandat_id', a.mandat_id, 'bailleur', pilotage.bailleurs_mandat(a.mandat_id),
      'mandat', (select coalesce(nullif(mc.data->>'name',''), 'Mandat n°' || (mc.data->>'reference')) from pilotage.objets mc where mc.type = 'ManagementContract' and mc.id = a.mandat_id),
      'dossier', case a.objet_type
        when 'LeasingContract' then (select jsonb_build_object('type','bail','ref', b.reference, 'locataires', b.locataires, 'adresse', l.adresse, 'asset_id', l.id, 'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id)
                                     from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id where b.id = a.objet_id)
        when 'Asset' then (select jsonb_build_object('type','lot','ref', l.reference, 'adresse', l.adresse, 'asset_id', l.id, 'lien', 'https://rivage.immo/asset_list') from pilotage.v_lots l where l.id = a.objet_id)
        when 'PermisTache' then (select jsonb_build_object('type','lot','ref', l.reference, 'adresse', l.adresse, 'asset_id', l.id, 'lien', 'https://rivage.immo/asset_list') from pilotage.permis_taches t join pilotage.v_lots l on l.id = t.asset_id where t.id::text = a.objet_id)
        when 'TicketRappel' then (select jsonb_build_object('type','ticket','ref', coalesce(i.data->>'number', r.ticket_id), 'titre', coalesce(i.data->>'title', r.ticket_titre), 'ticket_id', r.ticket_id, 'asset_id', i.data->>'asset_id', 'lien', a.lien_rivage) from pilotage.tickets_rappels r left join pilotage.objets i on i.type = 'Incident' and i.id = r.ticket_id where r.id::text = a.objet_id)
        when 'Incident' then (select jsonb_build_object('type','ticket','ref', i.data->>'number', 'titre', i.data->>'title', 'ticket_id', i.id, 'asset_id', i.data->>'asset_id', 'adresse', l.adresse, 'lien', a.lien_rivage)
                                from pilotage.objets i left join pilotage.v_lots l on l.id = i.data->>'asset_id' where i.type = 'Incident' and i.id = split_part(a.objet_id, ':', 1))
        when 'DonneeCorriger' then (select jsonb_build_object('type','donnee','ref', d.id, 'objet_type', d.objet_type, 'objet_id', d.objet_id,
                                       'asset_id', case d.objet_type when 'Asset' then d.objet_id when 'LeasingContract' then (select b.lot_id from pilotage.v_baux b where b.id = d.objet_id)
                                                   when 'Incident' then (select i.data->>'asset_id' from pilotage.objets i where i.type = 'Incident' and i.id = d.objet_id) end,
                                       'lien', a.lien_rivage)
                                    from pilotage.donnees_a_corriger d where d.id::text = a.objet_id)
        else jsonb_build_object('type', lower(a.objet_type), 'ref', a.objet_id, 'lien', a.lien_rivage) end
    ) order by case a.gravite when 'critique' then 0 when 'haute' then 1 else 2 end, a.premiere_detection)
    from pilotage.alertes a join pilotage.regles g on g.cle = a.regle
    where pilotage.alerte_visible_objet(a.regle, a.mandat_id, cible, a.objet_type, a.objet_id)
      and (a.statut = 'ouverte' or (a.statut = 'traitee' and a.traitee_le > now() - interval '7 days'))
  ), '[]'::jsonb);
end $function$;

-- 8. Premier cas de donnée à corriger : lot 441 (mandat 417)
insert into pilotage.donnees_a_corriger (objet_type, objet_id, motif)
select 'Asset', a.id, 'loué selon l''agence, mais aucun bail sur ce lot dans Rivage (mandat 417 « lot 4, 10 et 11 » ; le bail 510 est sur le lot 436)'
from pilotage.objets a where a.type = 'Asset' and a.data->>'reference' = '441'
  and not exists (select 1 from pilotage.donnees_a_corriger d where d.objet_type = 'Asset' and d.objet_id = a.id);

-- Premier passage du contrôle, puis rattachement des nouvelles alertes à leur mandat
select pilotage.executer_controles() as alertes_ouvertes;
select pilotage.rattacher_alertes();
select regle, count(*) as alertes from pilotage.alertes
 where statut = 'ouverte' and regle in ('ticket_relance', 'ticket_a_classer', 'ticket_a_facturer', 'ticket_a_facturer_gestion', 'cles_lot_sorti', 'donnee_a_corriger')
 group by 1 order by 1;
