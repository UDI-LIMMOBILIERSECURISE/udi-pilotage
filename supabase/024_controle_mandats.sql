-- 024 : contrôle d'entrée des mandats de gestion (décision de Nicolas, 16/10/2026), sur le modèle des baux.
--   Mandats concernés : début à partir du 01/01/2026 (les plus anciens arrivent directement en synthèse).
--   Un seul GO : le GO « dossier complet validé » des commissions (25 %), refusé tant que le contrôle n'est pas bouclé.
--   Pièces toutes déposées dans Rivage (sur le mandat, un de ses lots ou un mandant), reconnues par catégorie ou par nom.
--   Croisement avec Rivage : champs vides signalés, différences avec la lecture du mandat par l'IA signalées.
--   Équipements du bien (contrats d'entretien, compteurs divisionnaires) saisis par lot : repris ensuite dans le suivi des baux.
-- Réponses et lectures IA rangées dans baux_reponses et baux_lectures, avec l'identifiant du mandat (mc_…).

alter table pilotage.controle_questions drop constraint if exists controle_questions_portee_check;
alter table pilotage.controle_questions add constraint controle_questions_portee_check check (portee in ('commercial', 'habitation', 'mandat'));

insert into pilotage.controle_questions (cle, portee, bloc, ordre, libelle, aide, mode, ref, genere, mots) values
('m_doc_mandat','mandat','pieces',10,'Mandat de gestion signé et ses annexes','Lu par l''IA et croisé avec Rivage.','document',null,null,array['mandat de gestion','mandat gestion','mandat signe']),
('m_doc_identite','mandat','pieces',20,'Pièce d''identité de chaque mandant (Kbis et statuts pour une société)','Vigilance LCB-FT.','document',null,null,array['piece d identite','carte d identite','cni','passeport','kbis','extrait k','statuts']),
('m_doc_propriete','mandat','pieces',30,'Titre de propriété ou taxe foncière','Preuve que le mandant est propriétaire.','document',null,null,array['titre de propriete','acte de propriete','attestation de propriete','attestation notariee','acte de vente','taxe fonciere','avis de taxe']),
('m_doc_rib','mandat','pieces',40,'RIB du mandant','Pour le reversement des fonds.','document',null,null,array['rib','releve d identite bancaire','iban']),
('m_doc_pno','mandat','pieces',50,'Attestation d''assurance propriétaire non occupant (PNO)','','document',null,null,array['pno','proprietaire non occupant','assurance proprietaire']),
('m_doc_dpe','mandat','pieces',60,'DPE de chaque lot d''habitation','','document','energy_performance_diagnosis',null,array['dpe','performance energetique']),
('m_doc_erp','mandat','pieces',70,'État des risques (ERP)','Moins de 6 mois à la signature de chaque bail.','document',null,null,array['erp','etat des risques','risques et pollutions','ernmt','ernt','esris']),
('m_doc_amiante','mandat','pieces',80,'Diagnostic amiante (DTA ou parties privatives)','Immeubles dont le permis de construire est antérieur au 1er juillet 1997.','document','asbestos_diagnosis_private_parts',null,array['amiante','dta']),
('m_doc_plomb','mandat','pieces',90,'Constat de risque d''exposition au plomb (CREP)','Logements construits avant 1949.','document',null,null,array['plomb','crep']),
('m_doc_copro','mandat','pieces',100,'Règlement de copropriété et état descriptif de division','Sans objet hors copropriété.','document',null,null,array['reglement de copropriete','etat descriptif de division','edd','copropriete']),
('m_rv_mandants','mandat','rivage',10,'Mandants et quotes-parts','','rivage','mandants',null,null),
('m_rv_dates','mandat','rivage',20,'Date de signature, début et fin du mandat','','rivage','dates',null,null),
('m_rv_reconduction','mandat','rivage',30,'Reconduction (tacite ou expresse) et durée','','rivage','reconduction',null,null),
('m_rv_registre','mandat','rivage',40,'Numéro d''inscription au registre des mandats','Loi Hoguet : le numéro du registre figure sur le mandat.','rivage','registre',null,null),
('m_rv_gestion','mandat','rivage',50,'Honoraires de gestion : taux, base, minimum et frais fixes','','rivage','hono_gestion',null,null),
('m_rv_location','mandat','rivage',60,'Honoraires de location et d''état des lieux','','rivage','hono_location',null,null),
('m_rv_lots','mandat','rivage',70,'Lots rattachés au mandat','','rivage','lots',null,null),
('m_cl_equipements','mandat','clauses',10,'Équipements du bien et contrats d''entretien','Saisis par lot : repris dans le suivi des baux (entretien à la charge du locataire).','question','equipements',null,null),
('m_cl_compteurs','mandat','clauses',20,'Compteurs divisionnaires','Saisis par lot : relevés et refacturation repris dans le suivi des baux.','question','compteurs',null,null),
('m_cl_travaux','mandat','clauses',30,'Travaux engagés sans accord préalable du mandant : montant maximal','','question',null,null,null),
('m_cl_gli','mandat','clauses',40,'Garantie des loyers impayés : souscrite et à quelles conditions','','question',null,null,null),
('m_cl_reddition','mandat','clauses',50,'Reddition des comptes et reversement des fonds : périodicité','','question',null,null,null),
('m_cl_resiliation','mandat','clauses',60,'Résiliation du mandat : préavis et forme','','question',null,null,null),
('m_cl_anomalies','mandat','clauses',70,'Anomalies de rédaction à signaler','Par exemple un taux ou une date laissés en blanc.','question',null,null,null)
on conflict (cle) do update set portee = excluded.portee, bloc = excluded.bloc, ordre = excluded.ordre, libelle = excluded.libelle, aide = excluded.aide,
  mode = excluded.mode, ref = excluded.ref, genere = excluded.genere, mots = excluded.mots;

-- Équipements et compteurs par lot (saisis au mandat ou depuis un bail)
create table if not exists pilotage.lots_equipements (
  id bigserial primary key, asset_id text not null,
  nature text not null check (nature in ('equipement', 'compteur')),
  libelle text not null,
  contrat_entretien boolean, prestataire text, dernier_entretien date, commentaire text,
  par uuid, le timestamptz not null default now()
);
create index if not exists lots_equipements_asset on pilotage.lots_equipements (asset_id);
alter table pilotage.lots_equipements enable row level security;
revoke all on pilotage.lots_equipements from public, anon, authenticated;
revoke all on sequence pilotage.lots_equipements_id_seq from public, anon, authenticated;

-- Documents Rivage d'un mandat : rattachés au mandat, à un de ses lots ou à un de ses mandants
create or replace function pilotage.uploads_mandat(p_mandat text) returns setof pilotage.objets
language sql stable security definer set search_path = pilotage, public as $$
  select u.* from pilotage.objets u
  where u.type = 'Upload' and u.supprime_le is null
    and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr
                where rr->>'id' = p_mandat
                   or rr->>'id' in (select a.id from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat)
                   or rr->>'id' in (select p->>'profile_id' from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
                                    where m.type = 'ManagementContract' and m.id = p_mandat))
$$;

create or replace function pilotage.controle_mandat(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  o jsonb; s pilotage.mandats_suivi; items jsonb := '[]'::jsonb; q record; rep pilotage.baux_reponses; up record; piece jsonb;
  auto text; detail text; valeur_ia jsonb; lecture jsonb; restant integer := 0; anomalies integer := 0; ia_diff text; vide boolean; ia_ok boolean;
  nb_lots integer; annees integer[]; avant1949 boolean; inconnu boolean; mois integer; equip integer; compt integer;
begin
  select data into o from pilotage.objets where type = 'ManagementContract' and id = p_mandat and supprime_le is null;
  if o is null then return null; end if;
  select * into s from pilotage.mandats_suivi where mandat_id = p_mandat;
  select resultat into lecture from pilotage.baux_lectures where bail_id = p_mandat order by le desc limit 1;
  select count(*), array_agg(nullif(a.data->>'construction_year', '')::integer) into nb_lots, annees
    from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat;
  select count(*) filter (where e.nature = 'equipement'), count(*) filter (where e.nature = 'compteur') into equip, compt
    from pilotage.lots_equipements e where e.asset_id in (select a.id from pilotage.objets a where a.type = 'Asset' and a.data->>'management_contract_id' = p_mandat);

  for q in select * from pilotage.controle_questions where portee = 'mandat' order by case bloc when 'pieces' then 1 when 'rivage' then 2 else 3 end, ordre loop
    select * into rep from pilotage.baux_reponses where bail_id = p_mandat and cle = q.cle;
    auto := null; detail := null; valeur_ia := lecture->q.cle; piece := null; up := null; ia_diff := null; vide := false; ia_ok := false;

    if q.mode = 'document' then
      select u.id, u.data->>'label' as label, coalesce(u.data->>'nature' = q.ref, false) as par_nature into up
        from pilotage.uploads_mandat(p_mandat) u
       where (q.ref is not null and u.data->>'nature' = q.ref)
          or (q.mots is not null and pilotage.sans_accents(u.data->>'label') ~ ('\m(' || array_to_string(q.mots, '|') || ')'))
       order by coalesce(u.data->>'nature' = q.ref, false) desc, u.maj_le desc limit 1;
      if up.id is not null then
        auto := 'ok';
        detail := 'Déposé dans Rivage : « ' || coalesce(up.label, 'sans nom') || ' »' || case when up.par_nature then '' else ' (reconnu par son nom)' end;
        piece := jsonb_build_object('id', up.id, 'libelle', up.label, 'par_nom', not up.par_nature);
      else
        detail := 'Absent dans Rivage.';
        -- Diagnostics non exigés d'après l'année de construction des lots (quand Rivage la donne pour tous les lots)
        inconnu := annees is null or array_position(annees, null) is not null or nb_lots = 0;
        if q.cle = 'm_doc_amiante' and not inconnu and (select min(x) from unnest(annees) x) >= 1998 then
          auto := 'sans_objet'; detail := 'Non exigé : lots construits en 1998 ou après d''après Rivage (permis postérieur au 01/07/1997 à confirmer).';
        elsif q.cle = 'm_doc_plomb' and not inconnu and (select min(x) from unnest(annees) x) >= 1949 then
          auto := 'sans_objet'; detail := 'Non exigé : lots construits en 1949 ou après d''après Rivage.';
        end if;
      end if;

    elsif q.mode = 'rivage' then
      case q.ref
        when 'mandants' then
          detail := 'Mandants : ' || coalesce((select string_agg(coalesce(pilotage.nom_profil(p->>'profile_id'), 'propriétaire non transmis') || ' (' || coalesce(p->>'share', '?') || ' %)', ', ')
                                               from jsonb_array_elements(coalesce(o->'profile_contracts_attributes', '[]'::jsonb)) p), '—');
          vide := jsonb_array_length(coalesce(o->'profile_contracts_attributes', '[]'::jsonb)) = 0
               or coalesce((select sum((p->>'share')::numeric) from jsonb_array_elements(o->'profile_contracts_attributes') p), 0) <> 100;
          if vide and jsonb_array_length(coalesce(o->'profile_contracts_attributes', '[]'::jsonb)) > 0 then detail := detail || ' : total des quotes-parts différent de 100 %'; vide := false; auto := 'anomalie'; end if;
        when 'dates' then
          detail := 'Signé le ' || coalesce(to_char((o->>'signed_at')::date, 'DD/MM/YYYY'), '—') || ', début ' || coalesce(to_char((o->>'start_date')::date, 'DD/MM/YYYY'), '—')
                 || ', fin ' || coalesce(to_char((o->>'end_date')::date, 'DD/MM/YYYY'), '—');
          vide := o->>'signed_at' is null or o->>'start_date' is null;
          mois := case when o->>'end_date' is not null and o->>'start_date' is not null
                       then ((extract(year from age(((o->>'end_date')::date + 1), (o->>'start_date')::date)) * 12) + extract(month from age(((o->>'end_date')::date + 1), (o->>'start_date')::date)))::integer end;
          if valeur_ia is not null and nullif(valeur_ia->>'signature', '') is not null and valeur_ia->>'signature' <> coalesce(o->>'signed_at', '') then
            ia_diff := 'signé le ' || to_char((valeur_ia->>'signature')::date, 'DD/MM/YYYY'); end if;
          if valeur_ia is not null and nullif(valeur_ia->>'debut', '') is not null and valeur_ia->>'debut' <> coalesce(o->>'start_date', '') then
            ia_diff := concat_ws(', ', ia_diff, 'début le ' || to_char((valeur_ia->>'debut')::date, 'DD/MM/YYYY')); end if;
          if valeur_ia is not null and nullif(valeur_ia->>'duree_mois', '') is not null and mois is not null and (valeur_ia->>'duree_mois')::integer <> mois then
            ia_diff := concat_ws(', ', ia_diff, 'durée initiale de ' || (valeur_ia->>'duree_mois') || ' mois'); end if;
          ia_ok := ia_diff is null and nullif(valeur_ia->>'debut', '') is not null;
        when 'reconduction' then
          detail := case o->>'renewal_type' when 'tacit' then 'Tacite' when 'express' then 'Expresse' else coalesce(o->>'renewal_type', '—') end
                 || coalesce(', par périodes de ' || (o->>'renewal_duration_years') || ' an(s)', '');
          vide := o->>'renewal_type' is null;
          if valeur_ia is not null and nullif(valeur_ia->>'code', '') is not null
             and (case valeur_ia->>'code' when 'tacite' then 'tacit' when 'expresse' then 'express' else valeur_ia->>'code' end) <> coalesce(o->>'renewal_type', '') then
            ia_diff := 'reconduction ' || (valeur_ia->>'code'); end if;
          if valeur_ia is not null and nullif(valeur_ia->>'annees', '') is not null and valeur_ia->>'annees' <> coalesce(o->>'renewal_duration_years', '') then
            ia_diff := concat_ws(', ', ia_diff, 'par périodes de ' || (valeur_ia->>'annees') || ' an(s)'); end if;
          ia_ok := ia_diff is null and nullif(valeur_ia->>'code', '') is not null;
        when 'registre' then
          detail := 'N° ' || coalesce(o->>'register_number', '—');
          vide := o->>'register_number' is null;
          if valeur_ia is not null and nullif(valeur_ia->>'numero', '') is not null and valeur_ia->>'numero' <> coalesce(o->>'register_number', '') then
            ia_diff := 'n° ' || (valeur_ia->>'numero'); end if;
          ia_ok := ia_diff is null and nullif(valeur_ia->>'numero', '') is not null;
        when 'hono_gestion' then
          detail := coalesce(o->>'management_fees_rate', '—') || ' % TTC'
                 || case o->>'management_fees_base' when 'all_collections_except_deposit' then ' des encaissements hors dépôt de garantie' else coalesce(' (base : ' || (o->>'management_fees_base') || ')', '') end
                 || case when coalesce((o->>'minimal_management_fees_in_cents')::numeric, 0) > 0 then ', minimum ' || round((o->>'minimal_management_fees_in_cents')::numeric / 100, 2) || ' €' else '' end
                 || case when coalesce((o->>'fixed_management_fees_in_cents')::numeric, 0) > 0 then ', frais fixes ' || round((o->>'fixed_management_fees_in_cents')::numeric / 100, 2) || ' €' else '' end;
          vide := coalesce(nullif(o->>'management_fees_rate', '')::numeric, 0) = 0;
          if valeur_ia is not null and nullif(valeur_ia->>'taux', '') is not null
             and abs((valeur_ia->>'taux')::numeric - coalesce(nullif(o->>'management_fees_rate', '')::numeric, 0)) >= 0.01 then
            ia_diff := 'taux de ' || (valeur_ia->>'taux') || ' % TTC'; end if;
          ia_ok := ia_diff is null and nullif(valeur_ia->>'taux', '') is not null;
        when 'hono_location' then
          detail := 'Location : ' || coalesce(o->>'rental_fees_rate', '—') || ' %'
                 || case when coalesce((o->>'rental_fees_per_sqm_in_cents')::numeric, 0) > 0 then ', ' || round((o->>'rental_fees_per_sqm_in_cents')::numeric / 100, 2) || ' €/m²' else '' end
                 || case when coalesce((o->>'fixed_rental_fees_in_cents')::numeric, 0) > 0 then ', fixe ' || round((o->>'fixed_rental_fees_in_cents')::numeric / 100, 2) || ' €' else '' end
                 || case when coalesce((o->>'minimal_rental_fees_in_cents')::numeric, 0) > 0 then ', minimum ' || round((o->>'minimal_rental_fees_in_cents')::numeric / 100, 2) || ' €' else '' end
                 || ' · état des lieux : ' || coalesce(round((o->>'inventory_fees_per_sqm_in_cents')::numeric / 100, 2)::text, '—') || ' €/m²';
          vide := coalesce(nullif(o->>'rental_fees_rate', '')::numeric, 0) = 0 and coalesce((o->>'rental_fees_per_sqm_in_cents')::numeric, 0) = 0
              and coalesce((o->>'fixed_rental_fees_in_cents')::numeric, 0) = 0;
        when 'lots' then
          detail := nb_lots || ' lot(s)' || coalesce(' : ' || (select string_agg(coalesce(a.data->>'reference', a.data->>'name', a.id), ', ') from pilotage.objets a
                    where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat), '');
          vide := nb_lots = 0;
        else null;
      end case;
      if vide then auto := 'anomalie'; detail := detail || ' : non renseigné dans Rivage';
      elsif ia_diff is not null then auto := 'anomalie'; detail := detail || ' · le mandat indique : ' || ia_diff;
      elsif auto is null and ia_ok then auto := 'ok';
      elsif auto is null then detail := detail || ' · à confirmer : non vérifié dans le mandat'; end if;

    elsif q.ref = 'equipements' then
      detail := case when equip > 0 then equip || ' équipement(s) saisi(s)' end;
    elsif q.ref = 'compteurs' then
      detail := case when compt > 0 then compt || ' compteur(s) divisionnaire(s) saisi(s)' end;
    end if;

    -- Une réponse sur un champ Rivage ou une pièce vaut pour l'état constaté : si Rivage ou le document change, elle tombe.
    if q.bloc in ('rivage', 'pieces') and rep.statut is not null and (
         (auto = 'anomalie' and rep.valeur is distinct from detail)
      or (coalesce(auto, '') <> 'anomalie' and rep.valeur is not null and rep.valeur is distinct from detail)) then
      rep := null;
    end if;
    if rep.statut is null and coalesce(auto, '') not in ('ok', 'sans_objet') then restant := restant + 1; end if;
    if coalesce(rep.statut, auto) = 'anomalie' then anomalies := anomalies + 1; end if;
    items := items || jsonb_build_object('cle', q.cle, 'bloc', q.bloc, 'libelle', q.libelle, 'aide', q.aide, 'mode', q.mode, 'ref', q.ref, 'genere', q.genere,
      'auto', auto, 'detail', detail, 'ia', valeur_ia, 'piece', piece,
      'statut', coalesce(rep.statut, case when auto in ('ok', 'sans_objet') then auto end), 'repondu', rep.statut is not null,
      'suivi', rep.suivi, 'valeur', rep.valeur, 'commentaire', rep.commentaire, 'par', pilotage.prenom_membre(rep.par), 'le', rep.le,
      'a_traiter', rep.statut is null and coalesce(auto, '') not in ('ok', 'sans_objet'));
  end loop;
  return jsonb_build_object('portee', 'mandat', 'items', items, 'restant', restant, 'anomalies', anomalies,
    'soumis', (o->>'start_date')::date >= date '2026-01-01',
    'go_le', s.go_le, 'go_par', pilotage.prenom_membre(s.go_par), 'lecture_le', (select max(le) from pilotage.baux_lectures where bail_id = p_mandat));
end $$;

-- Dossier du mandat pour l'écran : contrôle, lots et équipements, lecture IA
create or replace function public.pilotage_mandat_dossier(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'controle', pilotage.controle_mandat(p_mandat),
    'lots', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'reference', coalesce(a.data->>'reference', a.data->>'name'), 'nature', a.data->>'nature',
              'adresse', concat_ws(' ', a.data->'address'->>'number', a.data->'address'->>'street', a.data->'address'->>'zip_code', a.data->'address'->>'city'),
              'construction', a.data->>'construction_year', 'chauffage', a.data->'equipment'->>'heating_method', 'chauffage_type', a.data->'equipment'->>'heating_type',
              'eau_chaude', a.data->'equipment'->>'hot_water_method', 'syndic', a.data->>'syndic_id' is not null,
              'equipements', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nature', e.nature, 'libelle', e.libelle, 'contrat_entretien', e.contrat_entretien,
                             'prestataire', e.prestataire, 'dernier_entretien', e.dernier_entretien, 'commentaire', e.commentaire) order by e.nature, e.libelle)
                             from pilotage.lots_equipements e where e.asset_id = a.id), '[]'::jsonb)) order by a.data->>'reference')
             from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat), '[]'::jsonb),
    'lecture', (select jsonb_build_object('le', l.le, 'source', l.source, 'modele', l.modele, 'resultat', l.resultat) from pilotage.baux_lectures l where l.bail_id = p_mandat order by l.le desc limit 1),
    'lien', 'https://rivage.immo/landlords/profiles/' || coalesce((select p->>'profile_id' from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
                                                                 where m.type = 'ManagementContract' and m.id = p_mandat limit 1), '')
  );
end $$;

create or replace function public.pilotage_mandat_repondre(p_mandat text, p_cle text, p_statut text, p_commentaire text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare it jsonb; v_valeur text;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_cle not like 'm\_%' then raise exception 'Question inconnue'; end if;
  if p_statut is null then delete from pilotage.baux_reponses where bail_id = p_mandat and cle = p_cle; return; end if;
  if p_statut = 'anomalie' and nullif(trim(coalesce(p_commentaire, '')), '') is null then raise exception 'Décrivez l''anomalie en commentaire'; end if;
  select x into it from jsonb_array_elements(pilotage.controle_mandat(p_mandat)->'items') x where x->>'cle' = p_cle;
  if it is null then raise exception 'Mandat ou question inconnus'; end if;
  if it->>'bloc' in ('rivage', 'pieces') then
    v_valeur := it->>'detail';
    if it->>'bloc' = 'rivage' and it->>'auto' = 'anomalie' and p_statut <> 'sans_objet' and nullif(trim(coalesce(p_commentaire, '')), '') is null then
      raise exception 'Écart détecté : justifiez la réponse en commentaire ou corrigez Rivage';
    end if;
  end if;
  insert into pilotage.baux_reponses (bail_id, cle, statut, suivi, valeur, commentaire, par)
  values (p_mandat, p_cle, p_statut, case when it->>'bloc' in ('rivage', 'pieces') then 'rivage' else 'backoffice' end, v_valeur, p_commentaire, auth.uid())
  on conflict (bail_id, cle) do update set statut = excluded.statut, suivi = excluded.suivi, valeur = excluded.valeur, commentaire = excluded.commentaire, par = auth.uid(), le = now();
end $$;

-- Équipement ou compteur d'un lot
create or replace function public.pilotage_lot_equipement(p_asset text, p_id bigint, p_nature text, p_libelle text, p_contrat boolean, p_prestataire text, p_dernier date, p_commentaire text, p_supprimer boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.objets where type = 'Asset' and id = p_asset) then raise exception 'Lot inconnu'; end if;
  if p_supprimer then delete from pilotage.lots_equipements where id = p_id and asset_id = p_asset; return; end if;
  if nullif(trim(coalesce(p_libelle, '')), '') is null then raise exception 'Nom de l''équipement obligatoire'; end if;
  if p_id is null then
    insert into pilotage.lots_equipements (asset_id, nature, libelle, contrat_entretien, prestataire, dernier_entretien, commentaire, par)
    values (p_asset, p_nature, trim(p_libelle), p_contrat, nullif(p_prestataire, ''), p_dernier, nullif(p_commentaire, ''), auth.uid());
  else
    update pilotage.lots_equipements set libelle = trim(p_libelle), contrat_entretien = p_contrat, prestataire = nullif(p_prestataire, ''),
      dernier_entretien = p_dernier, commentaire = nullif(p_commentaire, ''), par = auth.uid(), le = now() where id = p_id and asset_id = p_asset;
  end if;
end $$;

-- Équipements du lot d'un bail : pour pré-remplir les suivis d'entretien et de compteurs du bail
create or replace function public.pilotage_bail_equipements(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nature', e.nature, 'libelle', e.libelle, 'contrat_entretien', e.contrat_entretien,
                     'prestataire', e.prestataire, 'dernier_entretien', e.dernier_entretien) order by e.nature, e.libelle)
                   from pilotage.lots_equipements e
                   where e.asset_id = (select data->>'asset_id' from pilotage.objets where type = 'LeasingContract' and id = p_bail)), '[]'::jsonb);
end $$;

-- Lecture IA du mandat (fonction pilotage-lecture-bail, rôle service) : questions et document source
create or replace function public.pilotage_questions_mandat(p_mandat text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('cle', cle, 'libelle', libelle, 'aide', aide) order by bloc, ordre), '[]'::jsonb)
  from pilotage.controle_questions where portee = 'mandat' and mode <> 'document'
    and exists (select 1 from pilotage.objets where type = 'ManagementContract' and id = p_mandat)
$$;
create or replace function public.pilotage_mandat_source(p_mandat text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('upload_id', u.id, 'libelle', u.data->>'label', 'url', u.data->>'file_url')
  from pilotage.uploads_mandat(p_mandat) u
  where pilotage.sans_accents(u.data->>'label') ~ '\m(mandat de gestion|mandat gestion|mandat signe)'
  order by u.maj_le desc limit 1
$$;
create or replace function public.pilotage_piece_mandat_source(p_mandat text, p_upload text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('upload_id', u.id, 'libelle', u.data->>'label', 'url', u.data->>'file_url')
  from pilotage.uploads_mandat(p_mandat) u where u.id = p_upload
$$;
revoke all on function public.pilotage_questions_mandat(text), public.pilotage_mandat_source(text), public.pilotage_piece_mandat_source(text, text) from public, anon, authenticated;
grant execute on function public.pilotage_questions_mandat(text), public.pilotage_mandat_source(text), public.pilotage_piece_mandat_source(text, text) to service_role;
revoke all on function public.pilotage_mandat_dossier(text), public.pilotage_mandat_repondre(text, text, text, text),
  public.pilotage_lot_equipement(text, bigint, text, text, boolean, text, date, text, boolean), public.pilotage_bail_equipements(text) from public, anon;
grant execute on function public.pilotage_mandat_dossier(text), public.pilotage_mandat_repondre(text, text, text, text),
  public.pilotage_lot_equipement(text, bigint, text, text, boolean, text, date, text, boolean), public.pilotage_bail_equipements(text) to authenticated;

-- GO du mandat : refusé (pour tous) tant que le contrôle d'entrée d'un mandat 2026 n'est pas bouclé.
-- Le reste de la règle existante est inchangé (le superviseur ne donne le GO que sur un dossier sans manque).
create or replace function public.pilotage_mandat_maj(p_mandat text, p_champ text, p_valeur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); d jsonb; c jsonb;
begin
  if r not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.v_mandats where id = p_mandat) then raise exception 'Mandat inconnu'; end if;
  insert into pilotage.mandats_suivi(mandat_id) values (p_mandat) on conflict do nothing;
  if p_champ = 'go' then
    if nullif(p_valeur, '') is not null then
      c := pilotage.controle_mandat(p_mandat);
      if (c->>'soumis')::boolean and (c->>'restant')::integer > 0 then
        raise exception 'Contrôle d''entrée du mandat non bouclé : % point(s) à traiter', c->>'restant';
      end if;
      if r = 'superviseur' then
        d := pilotage.dossier_mandat(p_mandat);
        if exists (select 1 from jsonb_array_elements_text(d->'manques') x where x not like 'GO%') then
          raise exception 'Dossier incomplet : seul Nicolas peut donner ce GO';
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

revoke all on all functions in schema pilotage from public, anon, authenticated;
