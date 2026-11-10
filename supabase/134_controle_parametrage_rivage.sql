-- 134 : contrôle d'entrée, paramétrage saisi dans Rivage (bail, lot, mandat, propriétaire) et PNO datée (bloc 1 sur 3)
--  Demandes de Nicolas du 10/11/2026, faites sur les écrans Rivage du bail 531 (lot 429, 3 rue de Milly, Mennecy, LEDEZ / LEBOUVIER),
--  du mandat 414 (ANDRIEU Christine), du lot 429 et de la fiche du propriétaire : vérifier que chaque champ saisi par le commercial
--  est rempli et cohérent, et alerter s'il manque ou s'il y a une incohérence.
--  Champs relevés dans l'API Rivage le 10/11 (fiche du bail, edit_attributes, lignes de facturation, mandat, lot, profil) :
--  tous ceux de ces écrans arrivent, sauf les compteurs du lot (PDL, PCE, eau, emplacement), l'accès (n° de porte, codes),
--  les « contrats souscrits » du mandat (PNO) et la naissance / l'adresse du propriétaire (lues par l'API mais non gardées par la
--  synchronisation, choix de 2026 sur les données personnelles). Ceux-là ne peuvent pas être contrôlés : demande faite à Rivage.
--
--  Nouveaux points du contrôle d'entrée (bloc « Rivage », à la charge du commercial ; un écart se justifie comme les autres) :
--   Bail (habitation et commercial)
--    - Échéance et appel : jour d'échéance (le 1er, règle de Nicolas du 10/11, exigée pour les dossiers nouveaux ; le stock est affiché
--      sans anomalie : 173 baux au 5 et 1 au 2 le 10/11, décision à prendre), appel à échoir ou à terme échu, fréquence,
--      GLI et seuil d'impayé (seuil obligatoire quand une GLI est choisie).
--    - Mode de paiement de chaque locataire (prélèvement avec son jour et un compte bancaire rattaché, ou virement) : vide = anomalie.
--      Les garants ne sont pas concernés.
--    - Répartition du loyer entre locataires : total des parts = loyer + charges + complément.
--    - Honoraires d'entrée (location et état des lieux, locataire et bailleur), lus dans le bail (edit_attributes) et les lignes de
--      facturation du bailleur : honoraires d'EDL du locataire sans ceux du bailleur, part du locataire supérieure à celle du bailleur
--      (habitation), montant du locataire au-delà du tarif au m² du mandat × surface du lot, libellé de ligne abîmé (« &#39; »),
--      aucun honoraire hors reprise de gestion.
--    - Identité des locataires : nom et prénom de Rivage comparés à l'identité lue dans le bail (110, 112) ; nom et prénom inversés
--      (bail 531 : prénom « Ledez », nom « Julien ») ou locataire absent du bail = anomalie.
--    - Habitation, dossier nouveau : logement loué dans les 18 mois avant le début du bail et dernier loyer du précédent locataire
--      vide = anomalie (mention obligatoire en zone tendue ; « sans objet » à justifier hors zone tendue).
--   Mandat
--    - Fiche de chaque lot : surface, pièces, étage, identifiant fiscal, n° de lot de copropriété quand un syndic est renseigné,
--      année de construction cohérente avec la période ; numéros de lot cités dans le nom du mandat comparés aux n° de lot Rivage
--      (mandat 414 « (Lot 15 et 18) », lot 429 « 15, 28 »).
--    - Propriétaires : compte bancaire rattaché au mandat, date d'entrée pas après le début du mandat (mandat 414 : entrée le 06/11,
--      début le 22/09), e-mail et téléphone renseignés, téléphone avec indicatif (« 33620894583 » au lieu de « +33… »).
--    - Syndic : un lot rattaché dans Rivage à un groupe « immeuble » n'est plus dispensé d'office (lot 428 : groupe d'un seul lot créé
--      le 31/10). Un syndic vide est une anomalie, sauf monopropriété justifiée. RETOUR SUR UNE EXCEPTION du 024 (accord de Nicolas le 10/11).
--    - PNO (règle de Nicolas du 10/11) : l'attestation est déposée dans la GED de Rivage avec « PNO » dans le nom ; sa date de fin est
--      saisie dans le pilotage (Rivage n'a ni nature de pièce ni date d'expiration pour la PNO), rappelée à la gestion 30 jours avant.
--  Alertes nouvelles : pno_a_renouveler (gestion), identite_locataire (gestion, tous les baux en cours, stock compris : Rivage envoie
--  ses quittances et ses mails avec ces noms).
--  Mesure à blanc du 10/11 sur la production : 1 bail sans mode de paiement (531), 2 baux sans honoraires d'EDL du bailleur,
--  3 noms inversés et 15 locataires introuvables sur les 140 baux dont l'identité est lue, 1 propriétaire entré après le début
--  de son mandat, 1 sans compte rattaché, 225 propriétaires au téléphone sans indicatif, 12 lots sans syndic qui étaient dispensés.
--  Rien n'est écrit dans Rivage. Les fonctions controle_bail, controle_mandat et executer_controles sont modifiées par remplacement
--  de texte (fins de ligne normalisées, leçon du 109) : chaque bloc s'arrête net si son ancre n'est pas trouvée.

-- PNO : date de fin saisie dans le pilotage
create table if not exists pilotage.mandats_pno (
  mandat_id text primary key,
  fin date not null,
  assureur text,
  numero text,
  par uuid,
  le timestamptz not null default now()
);
alter table pilotage.mandats_pno enable row level security;
revoke all on pilotage.mandats_pno from public, anon, authenticated;
drop trigger if exists controles_demande on pilotage.mandats_pno;
create trigger controles_demande after insert or update or delete on pilotage.mandats_pno
  for each statement execute function pilotage.controles_demander();

create or replace function public.pilotage_pno_enregistrer(p_mandat text, p_fin date, p_assureur text, p_numero text) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if not pilotage.peut_traiter_dossier('ManagementContract', p_mandat) then raise exception 'Réservé à la gestion, à la direction et au commercial du mandat'; end if;
  if not exists (select 1 from pilotage.objets where type = 'ManagementContract' and id = p_mandat and supprime_le is null) then raise exception 'Mandat inconnu dans Rivage'; end if;
  if p_fin is null then
    delete from pilotage.mandats_pno where mandat_id = p_mandat;
  else
    insert into pilotage.mandats_pno (mandat_id, fin, assureur, numero, par)
    values (p_mandat, p_fin, nullif(trim(p_assureur), ''), nullif(trim(p_numero), ''), auth.uid())
    on conflict (mandat_id) do update set fin = excluded.fin, assureur = excluded.assureur, numero = excluded.numero, par = excluded.par, le = now();
  end if;
end $$;
revoke all on function public.pilotage_pno_enregistrer(text, date, text, text) from public, anon;
grant execute on function public.pilotage_pno_enregistrer(text, date, text, text) to authenticated;

create or replace function public.pilotage_pno_lire(p_mandat text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select case when pilotage.peut_traiter_dossier('ManagementContract', p_mandat) or pilotage.mon_role() in ('comptable') then
    (select jsonb_build_object('fin', x.fin, 'assureur', x.assureur, 'numero', x.numero, 'par', pilotage.prenom_membre(x.par), 'le', x.le)
       from pilotage.mandats_pno x where x.mandat_id = p_mandat) end
$$;
revoke all on function public.pilotage_pno_lire(text) from public, anon;
grant execute on function public.pilotage_pno_lire(text) to authenticated;

-- Nouveaux points du contrôle d'entrée
insert into pilotage.controle_questions (cle, portee, bloc, ordre, libelle, aide, mode, ref, qui) values
  ('h_rv_appel', 'habitation', 'rivage', 61, 'Échéance, appel du loyer et GLI', 'Échéance le 1er du mois ; seuil d''impayé obligatoire si une GLI est choisie.', 'rivage', 'appel', 'commercial'),
  ('h_rv_paiement', 'habitation', 'rivage', 62, 'Mode de paiement de chaque locataire', 'Prélèvement (jour et compte bancaire) ou virement, locataire par locataire.', 'rivage', 'paiement', 'commercial'),
  ('h_rv_parts', 'habitation', 'rivage', 63, 'Répartition du loyer entre les locataires', 'Le total des parts doit égaler loyer + charges.', 'rivage', 'parts', 'commercial'),
  ('h_rv_honoraires', 'habitation', 'rivage', 64, 'Honoraires d''entrée (location et état des lieux, locataire et bailleur)', 'Comparés au tarif au m² du mandat et à la surface du lot ; la part du locataire ne dépasse pas celle du bailleur.', 'rivage', 'hono_entree', 'commercial'),
  ('h_rv_identite', 'habitation', 'rivage', 65, 'Nom et prénom des locataires conformes au bail', 'Comparés à l''identité lue dans le bail signé.', 'rivage', 'identite', 'commercial'),
  ('h_rv_precedent', 'habitation', 'rivage', 66, 'Dernier loyer du précédent locataire', 'Mention obligatoire au bail en zone tendue si le logement a été loué dans les 18 mois.', 'rivage', 'precedent', 'commercial'),
  ('c_rv_appel', 'commercial', 'rivage', 101, 'Échéance, appel du loyer et GLI', 'Échéance le 1er du mois ; seuil d''impayé obligatoire si une GLI est choisie.', 'rivage', 'appel', 'commercial'),
  ('c_rv_paiement', 'commercial', 'rivage', 102, 'Mode de paiement de chaque preneur', 'Prélèvement (jour et compte bancaire) ou virement.', 'rivage', 'paiement', 'commercial'),
  ('c_rv_parts', 'commercial', 'rivage', 103, 'Répartition du loyer entre les preneurs', 'Le total des parts doit égaler loyer + charges.', 'rivage', 'parts', 'commercial'),
  ('c_rv_honoraires', 'commercial', 'rivage', 104, 'Honoraires d''entrée (preneur et bailleur)', null, 'rivage', 'hono_entree', 'commercial'),
  ('c_rv_identite', 'commercial', 'rivage', 105, 'Identité des preneurs conforme au bail', 'Personnes physiques comparées à l''identité lue dans le bail signé.', 'rivage', 'identite', 'commercial'),
  ('m_rv_lots_fiche', 'mandat', 'rivage', 111, 'Fiche de chaque lot : surface, pièces, étage, identifiant fiscal, n° de lot', 'Et cohérence de l''année de construction et des n° de lot cités dans le nom du mandat.', 'rivage', 'lots_fiche', 'commercial'),
  ('m_rv_proprietaires', 'mandat', 'rivage', 112, 'Propriétaires : compte bancaire, date d''entrée, e-mail et téléphone', null, 'rivage', 'proprietaires', 'commercial'),
  ('m_cl_pno', 'mandat', 'clauses', 46, 'Assurance propriétaire non occupant (PNO) : date de fin', 'Attestation déposée dans la GED de Rivage avec « PNO » dans le nom ; date de fin saisie ici, rappelée 30 jours avant.', 'question', 'pno', 'commercial')
on conflict (cle) do update set portee = excluded.portee, bloc = excluded.bloc, ordre = excluded.ordre, libelle = excluded.libelle,
  aide = excluded.aide, mode = excluded.mode, ref = excluded.ref, qui = excluded.qui;

-- Alertes
insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire) values
  ('pno_a_renouveler', 'PNO du mandat expirée ou à renouveler', 'Mandat', 'normale', 'oblig', true,
   'Date de fin de l''assurance propriétaire non occupant saisie dans le pilotage : demander la nouvelle attestation au bailleur, la déposer dans Rivage avec « PNO » dans le nom et mettre la date à jour.',
   '[{"nom": "jours_avant", "unite": "jours", "valeur": 30, "libelle": "Alerte à partir de"}]'::jsonb, 'gestion'),
  ('identite_locataire', 'Nom et prénom du locataire inversés dans Rivage', 'Baux habitation', 'haute', 'controle', true,
   'Le nom et le prénom saisis dans Rivage sont inversés par rapport au bail signé : Rivage envoie ses quittances et ses mails avec ces noms. Corriger la fiche du locataire dans Rivage.',
   '[]'::jsonb, 'gestion')
on conflict (cle) do nothing;

select (select count(*) from pilotage.controle_questions where cle in ('h_rv_appel','h_rv_paiement','h_rv_parts','h_rv_honoraires','h_rv_identite','h_rv_precedent',
          'c_rv_appel','c_rv_paiement','c_rv_parts','c_rv_honoraires','c_rv_identite','m_rv_lots_fiche','m_rv_proprietaires','m_cl_pno')) as questions_14,
       (select count(*) from pilotage.regles where cle in ('pno_a_renouveler', 'identite_locataire')) as regles_2,
       to_regclass('pilotage.mandats_pno') is not null as table_pno;


-- 134 : contrôle d'entrée, paramétrage saisi dans Rivage (bloc 2 sur 3) : fonctions de contrôle
create or replace function pilotage.cle_nom(t text) returns text
language sql immutable as $$ select nullif(regexp_replace(pilotage.sans_accents(trim(coalesce(t, ''))), '\s+', ' ', 'g'), '') $$;

create or replace function pilotage.euros(c numeric) returns text
language sql immutable as $$ select translate(to_char(round(c / 100, 2), 'FM999G999G990D00'), ',.', ' ,') || ' €' $$;

-- Points « Rivage » du bail ajoutés par le 134 : renvoie {detail, vide, anomalie, ok}
create or replace function pilotage.controle_rivage_bail(p_bail text, p_ref text, o jsonb, p_portee text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare
  e jsonb := coalesce(o->'edit_attributes', '{}'::jsonb);
  pcs jsonb; t jsonb; pc jsonb; occ jsonb; x jsonb;
  detail text; vide boolean := false; anomalie boolean := false; ok boolean := false; pb text[] := '{}';
  nouveau boolean := pilotage.dossier_nouveau('LeasingContract', p_bail);
  v_lot record; v_mandat jsonb; surface numeric; tl numeric; ti numeric; bl numeric; bi numeric; total numeric; somme numeric;
  n text; p text; lignes text[] := '{}';
begin
  -- contrats des locataires (les garants ont aussi une ligne : on ne garde que les locataires du bail)
  select coalesce(jsonb_agg(c), '[]'::jsonb) into pcs from jsonb_array_elements(coalesce(e->'profile_contracts_attributes', '[]'::jsonb)) c
   where c->>'profile_id' in (select tt->>'id' from jsonb_array_elements(coalesce(o->'tenants', '[]'::jsonb)) tt)
     and nullif(c->>'exit_date', '') is null;

  case p_ref
  when 'appel' then
    detail := 'Échéance le ' || coalesce(case o->>'rent_due_day' when '1' then '1er' else o->>'rent_due_day' end, '—')
           || case e->>'rent_call_timing' when 'in_advance' then ', à échoir' when 'in_arrears' then ', à terme échu' else ', appel non renseigné' end
           || case coalesce(o->>'frequency_in_months', '1') when '1' then ', mensuel' when '3' then ', trimestriel' else ', tous les ' || (o->>'frequency_in_months') || ' mois' end
           || case when nullif(o->>'gli_provider_id', '') is not null
                   then ' · GLI ' || coalesce((select nullif(g.data->>'name', '') from pilotage.objets g where g.type = 'GliProvider' and g.id = o->>'gli_provider_id'), 'renseignée')
                        || coalesce(', seuil d''impayé ' || pilotage.euros(nullif((o->>'unpaid_threshold_amount_in_cents')::numeric, 0)), ', seuil d''impayé non renseigné')
                   else ' · sans GLI' end;
    vide := nullif(o->>'rent_due_day', '') is null or nullif(e->>'rent_call_timing', '') is null
         or (nullif(o->>'gli_provider_id', '') is not null and coalesce((o->>'unpaid_threshold_amount_in_cents')::numeric, 0) = 0);
    if not vide and o->>'rent_due_day' <> '1' then
      if nouveau then anomalie := true; detail := detail || ' : l''échéance doit être le 1er du mois';
      else detail := detail || ' (stock : échéance autre que le 1er, à décider)'; end if;
    end if;
    ok := not vide and not anomalie;

  when 'paiement' then
    if jsonb_array_length(pcs) = 0 then vide := true; detail := 'Aucun locataire rattaché';
    else
      for pc in select * from jsonb_array_elements(pcs) loop
        n := coalesce(pilotage.nom_profil(pc->>'profile_id'),
                      (select coalesce(nullif(tt->>'company_name', ''), concat_ws(' ', upper(tt->>'last_name'), tt->>'first_name')) from jsonb_array_elements(o->'tenants') tt where tt->>'id' = pc->>'profile_id'), 'locataire');
        lignes := lignes || (n || ' : ' || case pc->>'payment_method'
          when 'sepa_debit' then 'prélèvement le ' || coalesce(pc->>'sepa_debit_day', '?')
               || case when nullif(pc->>'bank_account_id', '') is null then ' (aucun compte bancaire rattaché)' else '' end
          when 'bank_transfer' then 'virement'
          else coalesce(pc->>'payment_method', 'mode de paiement non choisi') end);
        if nullif(pc->>'payment_method', '') is null then anomalie := true; end if;
        if pc->>'payment_method' = 'sepa_debit' and (nullif(pc->>'bank_account_id', '') is null or nullif(pc->>'sepa_debit_day', '') is null) then anomalie := true; end if;
      end loop;
      detail := array_to_string(lignes, ' · ');
      if exists (select 1 from jsonb_array_elements(pcs) c where c->>'payment_method' = 'sepa_debit' and (nullif(c->>'bank_account_id', '') is null or nullif(c->>'sepa_debit_day', '') is null)) then
        detail := detail || ' : prélèvement sans compte bancaire ou sans jour'; end if;
    end if;
    ok := not vide and not anomalie;

  when 'parts' then
    total := coalesce((o->>'rent_in_cents')::numeric, 0) + coalesce((o->>'charges_in_cents')::numeric, 0) + coalesce((o->>'rent_supplement_in_cents')::numeric, 0);
    select sum((c->>'rent_due_in_cents')::numeric) into somme from jsonb_array_elements(pcs) c where nullif(c->>'rent_due_in_cents', '') is not null;
    detail := coalesce((select string_agg(coalesce(pilotage.nom_profil(c->>'profile_id'), 'locataire') || ' ' || coalesce(pilotage.euros(nullif(c->>'rent_due_in_cents', '')::numeric), 'non réparti'), ' · ')
                          from jsonb_array_elements(pcs) c), 'Aucun locataire')
           || ' · loyer + charges ' || pilotage.euros(total);
    if somme is not null and total > 0 and abs(somme - total) >= 1 then
      anomalie := true; detail := detail || ' : total des parts ' || pilotage.euros(somme) || ' au lieu de ' || pilotage.euros(total);
    end if;
    ok := not anomalie;

  when 'hono_entree' then
    select l.* into v_lot from pilotage.objets l where l.type = 'Asset' and l.id = o->>'asset_id';
    select m.data into v_mandat from pilotage.objets m where m.type = 'ManagementContract' and m.id = v_lot.data->>'management_contract_id';
    surface := nullif(v_lot.data->>'area', '')::numeric;
    tl := coalesce((e->>'tenant_rental_fees_in_cents')::numeric, (o->'tenant_fees_breakdown'->>'rental_fees_in_cents')::numeric, 0);
    ti := coalesce((e->>'tenant_inventory_fees_in_cents')::numeric, (o->'tenant_fees_breakdown'->>'inventory_fees_in_cents')::numeric, 0);
    bl := coalesce((e->>'landlord_rental_fees_in_cents')::numeric, (o->>'landlord_rental_fees_in_cents')::numeric, 0);
    -- honoraires d'état des lieux du bailleur : ligne de facturation du bailleur (Rivage n'a pas de champ dédié dans le bail)
    select coalesce(sum((b.data->>'amount_in_cents')::numeric), 0) into bi from pilotage.objets b
     where b.type = 'BillingLine' and b.supprime_le is null and b.data->>'leasing_contract_id' = p_bail and b.data->>'type' = 'landlord'
       and pilotage.sans_accents(b.data->>'name') ~ '(etat des lieux|edl)';
    detail := 'Locataire : location ' || pilotage.euros(tl) || ', état des lieux ' || pilotage.euros(ti)
           || ' · Bailleur : location ' || pilotage.euros(bl) || ', état des lieux ' || pilotage.euros(bi)
           || case when surface > 0 and v_mandat is not null and (coalesce((v_mandat->>'rental_fees_per_sqm_in_cents')::numeric, 0) > 0 or coalesce((v_mandat->>'inventory_fees_per_sqm_in_cents')::numeric, 0) > 0)
                   then ' · mandat ' || replace(round((v_mandat->>'rental_fees_per_sqm_in_cents')::numeric / 100, 2)::text, '.', ',') || ' et '
                        || replace(round((v_mandat->>'inventory_fees_per_sqm_in_cents')::numeric / 100, 2)::text, '.', ',') || ' €/m² × ' || replace(surface::text, '.', ',') || ' m²'
                   else '' end;
    if coalesce((e->>'rental_transfer')::boolean, false) then
      detail := detail || ' (reprise de gestion)';
    elsif tl + ti + bl + bi = 0 then
      pb := pb || 'aucun honoraire d''entrée (à justifier)'::text;
    end if;
    if ti > 0 and bi = 0 then pb := pb || 'honoraires d''état des lieux du bailleur absents'::text; end if;
    if p_portee = 'habitation' then
      if tl > bl then pb := pb || 'part du locataire supérieure à celle du bailleur (location)'::text; end if;
      if bi > 0 and ti > bi then pb := pb || 'part du locataire supérieure à celle du bailleur (état des lieux)'::text; end if;
      if surface > 0 and coalesce((v_mandat->>'rental_fees_per_sqm_in_cents')::numeric, 0) > 0
         and tl > round((v_mandat->>'rental_fees_per_sqm_in_cents')::numeric * surface) + 1 then
        pb := pb || ('location du locataire au-delà de ' || pilotage.euros(round((v_mandat->>'rental_fees_per_sqm_in_cents')::numeric * surface)))::text; end if;
      if surface > 0 and coalesce((v_mandat->>'inventory_fees_per_sqm_in_cents')::numeric, 0) > 0
         and ti > round((v_mandat->>'inventory_fees_per_sqm_in_cents')::numeric * surface) + 1 then
        pb := pb || ('état des lieux du locataire au-delà de ' || pilotage.euros(round((v_mandat->>'inventory_fees_per_sqm_in_cents')::numeric * surface)))::text; end if;
    end if;
    if exists (select 1 from pilotage.objets b where b.type = 'BillingLine' and b.supprime_le is null and b.data->>'leasing_contract_id' = p_bail
                and b.data->>'name' ~ '&(#[0-9]+|amp|quot|apos);') then
      pb := pb || 'libellé de ligne abîmé (« &#39; » ou « &amp; ») à retaper dans Rivage'::text; end if;
    anomalie := cardinality(pb) > 0;
    if anomalie then detail := detail || ' : ' || array_to_string(pb, ', '); end if;
    ok := not anomalie;

  when 'identite' then
    occ := coalesce((select x2.occupants from pilotage.baux_occupants x2 where x2.bail_id = p_bail),
                    (select l.resultat->'occupants' from pilotage.baux_lectures l where l.bail_id = p_bail and l.resultat ? 'occupants' order by l.le desc limit 1));
    if jsonb_array_length(coalesce(o->'tenants', '[]'::jsonb)) = 0 then vide := true; detail := 'Aucun locataire';
    else
      for t in select * from jsonb_array_elements(o->'tenants') loop
        continue when nullif(t->>'company_name', '') is not null;
        n := pilotage.cle_nom(t->>'last_name'); p := pilotage.cle_nom(t->>'first_name');
        if occ is null or jsonb_typeof(occ) <> 'array' then
          lignes := lignes || (concat_ws(' ', upper(t->>'last_name'), t->>'first_name'));
        elsif exists (select 1 from jsonb_array_elements(occ) y where n is not null and (pilotage.cle_nom(y->>'nom') = n
                       or (length(n) >= 3 and position(n in coalesce(pilotage.cle_nom(y->>'nom'), '')) > 0)
                       or (length(coalesce(pilotage.cle_nom(y->>'nom'), '')) >= 3 and position(pilotage.cle_nom(y->>'nom') in n) > 0))) then
          lignes := lignes || (concat_ws(' ', upper(t->>'last_name'), t->>'first_name') || ' ✓');
        elsif exists (select 1 from jsonb_array_elements(occ) y where p is not null and pilotage.cle_nom(y->>'nom') = p) then
          anomalie := true;
          lignes := lignes || ('prénom « ' || coalesce(t->>'first_name', '') || ' », nom « ' || coalesce(t->>'last_name', '') || ' » : nom et prénom inversés');
        else
          anomalie := true;
          lignes := lignes || (concat_ws(' ', upper(t->>'last_name'), t->>'first_name') || ' : absent du bail lu');
        end if;
      end loop;
      detail := coalesce(array_to_string(lignes, ' · '), 'Preneurs personnes morales');
      if occ is null and cardinality(lignes) > 0 then detail := detail || ' · identité pas encore lue dans le bail';
      else ok := not anomalie; end if;
      if occ is not null and anomalie then
        detail := detail || ' · bail : ' || (select string_agg(concat_ws(' ', upper(y->>'nom'), y->>'prenoms'), ', ') from jsonb_array_elements(occ) y);
      end if;
    end if;

  when 'precedent' then
    if nullif(o->>'previous_tenant_last_rent_in_cents', '') is not null then
      detail := 'Dernier loyer du précédent locataire : ' || pilotage.euros((o->>'previous_tenant_last_rent_in_cents')::numeric)
             || coalesce(', payé le ' || to_char((o->>'previous_tenant_last_rent_paid_on')::date, 'DD/MM/YYYY'), '');
      ok := true;
    else
      select 'Logement loué jusqu''au ' || to_char(max(nullif(pv.data->>'end_date', '')::date), 'DD/MM/YYYY') into detail
        from pilotage.objets pv
       where pv.type = 'LeasingContract' and pv.supprime_le is null and pv.id <> p_bail and pv.data->>'asset_id' = o->>'asset_id'
         and nullif(pv.data->>'end_date', '')::date between nullif(o->>'start_date', '')::date - interval '18 months' and nullif(o->>'start_date', '')::date;
      if detail is null then
        detail := 'Pas de bail précédent sur ce lot dans les 18 mois (d''après Rivage)'; ok := true;
      elsif nouveau and p_portee = 'habitation' then
        anomalie := true; detail := detail || ' : dernier loyer du précédent locataire non renseigné (obligatoire en zone tendue ; sinon sans objet, à justifier)';
      else
        detail := detail || ' · dernier loyer du précédent locataire non renseigné'; ok := true;
      end if;
    end if;

  else
    return null;
  end case;
  return jsonb_build_object('detail', detail, 'vide', vide, 'anomalie', anomalie, 'ok', ok);
end $$;

-- Points « Rivage » du mandat ajoutés par le 134 : renvoie {detail, vide, anomalie, ok}
create or replace function pilotage.controle_rivage_mandat(p_mandat text, p_ref text, o jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare
  a record; pc jsonb; pr jsonb; manque text[]; lignes text[] := '{}'; pb text[] := '{}';
  detail text; vide boolean := false; anomalie boolean := false; deb integer; fin integer;
  nums_nom text[]; nums_lots text[]; absents text[];
begin
  case p_ref
  when 'lots_fiche' then
    for a in select x.id, x.data from pilotage.objets x where x.type = 'Asset' and x.supprime_le is null and x.data->>'management_contract_id' = p_mandat
             order by x.data->>'reference' loop
      manque := '{}';
      if coalesce(nullif(a.data->>'area', '')::numeric, 0) = 0 then manque := manque || 'surface'::text; end if;
      if a.data->>'nature' in ('flat', 'house', 'room') then
        if nullif(a.data->>'room_count', '') is null then manque := manque || 'nombre de pièces'::text; end if;
        if nullif(a.data->>'fiscal_identifier', '') is null then manque := manque || 'identifiant fiscal'::text; end if;
      end if;
      if a.data->>'nature' = 'flat' and nullif(a.data->>'floor', '') is null then manque := manque || 'étage'::text; end if;
      if nullif(a.data->>'syndic_id', '') is not null and nullif(trim(a.data->>'lot_number'), '') is null then manque := manque || 'n° de lot de copropriété'::text; end if;
      if cardinality(manque) > 0 then
        vide := true; lignes := lignes || ('lot ' || coalesce(nullif(a.data->>'reference', ''), a.id) || ' : ' || array_to_string(manque, ', '));
      end if;
      -- année de construction hors de la période choisie
      if a.data->>'construction_period' ~ '^from_[0-9]{4}_to_[0-9]{4}$' and nullif(a.data->>'construction_year', '') is not null then
        deb := substring(a.data->>'construction_period' from 6 for 4)::integer; fin := substring(a.data->>'construction_period' from 14 for 4)::integer;
        if (a.data->>'construction_year')::integer not between deb and fin then
          pb := pb || ('lot ' || coalesce(nullif(a.data->>'reference', ''), a.id) || ' : année ' || (a.data->>'construction_year') || ' hors de la période ' || deb || '-' || fin);
        end if;
      end if;
    end loop;
    -- n° de lot cités dans le nom du mandat (« (Lot 15 et 18) ») comparés aux n° de lot de copropriété Rivage
    if pilotage.sans_accents(o->>'name') ~ '\mlots?\M' then
      select array_agg(distinct m[1]) into nums_nom
        from regexp_matches(substring(pilotage.sans_accents(o->>'name') from '\mlots?\M(.*)$'), '([0-9]+)', 'g') m;
      select array_agg(distinct m[1]) into nums_lots
        from pilotage.objets x, regexp_matches(coalesce(x.data->>'lot_number', ''), '([0-9]+)', 'g') m
       where x.type = 'Asset' and x.supprime_le is null and x.data->>'management_contract_id' = p_mandat;
      if nums_nom is not null and nums_lots is not null then
        select array_agg(z) into absents from unnest(nums_nom) z where not z = any(nums_lots);
        if absents is not null then
          pb := pb || ('nom du mandat « ' || (o->>'name') || ' » : lot ' || array_to_string(absents, ', ') || ' absent des n° de lot Rivage (' || array_to_string(nums_lots, ', ') || ')');
        end if;
      end if;
    end if;
    anomalie := cardinality(pb) > 0;
    detail := case when cardinality(lignes) > 0 then 'À compléter dans Rivage : ' || array_to_string(lignes, ' · ')
                   else (select count(*) from pilotage.objets x where x.type = 'Asset' and x.supprime_le is null and x.data->>'management_contract_id' = p_mandat) || ' lot(s) renseigné(s)' end
           || case when anomalie then ' · ' || array_to_string(pb, ' · ') else '' end;
    if vide then detail := regexp_replace(detail, '^À compléter dans Rivage : ', ''); end if;

  when 'proprietaires' then
    if jsonb_array_length(coalesce(o->'profile_contracts_attributes', '[]'::jsonb)) = 0 then vide := true; detail := 'Aucun propriétaire';
    else
      for pc in select * from jsonb_array_elements(o->'profile_contracts_attributes') loop
        continue when nullif(pc->>'exit_date', '') is not null;
        select x.data into pr from pilotage.objets x where x.type = 'Profile' and x.id = pc->>'profile_id';
        manque := '{}';
        if nullif(pc->>'bank_account_id', '') is null then manque := manque || 'compte bancaire non rattaché au mandat'::text; end if;
        if nullif(pc->>'entry_date', '') is not null and nullif(o->>'start_date', '') is not null and (pc->>'entry_date')::date > (o->>'start_date')::date then
          manque := manque || ('entré le ' || to_char((pc->>'entry_date')::date, 'DD/MM/YYYY') || ', après le début du mandat (' || to_char((o->>'start_date')::date, 'DD/MM/YYYY') || ')'); end if;
        if pr is not null then
          if nullif(pr->>'email', '') is null then manque := manque || 'e-mail'::text; end if;
          if nullif(pr->>'phone_number', '') is null then manque := manque || 'téléphone'::text;
          elsif pr->>'phone_number' !~ '^(\+|0)' then manque := manque || ('téléphone sans indicatif (« ' || (pr->>'phone_number') || ' » au lieu de « +' || (pr->>'phone_number') || ' »)'); end if;
        end if;
        lignes := lignes || (coalesce(pilotage.nom_profil(pc->>'profile_id'), 'propriétaire') || coalesce(' (' || (pc->>'share') || ' %)', '')
                             || case when cardinality(manque) > 0 then ' : ' || array_to_string(manque, ', ') else ' ✓' end);
        if cardinality(manque) > 0 then anomalie := true; end if;
      end loop;
      detail := array_to_string(lignes, ' · ');
    end if;

  else
    return null;
  end case;
  return jsonb_build_object('detail', detail, 'vide', vide, 'anomalie', anomalie, 'ok', not vide and not anomalie);
end $$;

-- Alertes du 134 : PNO à renouveler, nom et prénom inversés (tous les baux en cours)
create or replace function pilotage.parametrage_detections() returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select 'pno_a_renouveler'::text, 'ManagementContract'::text, m.id,
    'Mandat n° ' || coalesce(m.data->>'reference', '') || ' : PNO ' || case when x.fin < current_date then 'expirée le ' else 'à renouveler avant le ' end || to_char(x.fin, 'DD/MM/YYYY'),
    coalesce(pilotage.bailleurs_mandat(m.id), '') || coalesce(' · ' || x.assureur, '') || coalesce(' n° ' || x.numero, ''),
    'https://rivage.immo/landlords/profiles?profile_id=' || coalesce(m.data->'profile_contracts_attributes'->0->>'profile_id', '')
  from pilotage.mandats_pno x join pilotage.objets m on m.type = 'ManagementContract' and m.id = x.mandat_id and m.supprime_le is null
  where m.data->>'status' not in ('lost', 'terminated', 'closed')
    and x.fin <= current_date + pilotage.param('pno_a_renouveler', 'jours_avant', 30)::int
  union all
  select 'identite_locataire', 'LeasingContract', b.id,
    'Bail ' || coalesce(b.data->>'reference', '') || ' : nom et prénom inversés dans Rivage',
    r->>'detail',
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
  from pilotage.objets b
  cross join lateral (select pilotage.controle_rivage_bail(b.id, 'identite', b.data, 'habitation') r) z
  where b.type = 'LeasingContract' and b.supprime_le is null and b.data->>'status' in ('created', 'in_progress', 'move_out')
    and (exists (select 1 from pilotage.baux_occupants o where o.bail_id = b.id)
         or exists (select 1 from pilotage.baux_lectures l where l.bail_id = b.id and l.resultat ? 'occupants'))
    and r->>'detail' like '%inversés%'
$$;

-- Vérification à blanc (rien n'est écrit) : bail 531, mandat 414
select pilotage.controle_rivage_bail(b.id, 'paiement', b.data, 'habitation')->>'detail' as bail_531_paiement,
       pilotage.controle_rivage_bail(b.id, 'hono_entree', b.data, 'habitation')->>'detail' as bail_531_honoraires,
       pilotage.controle_rivage_bail(b.id, 'identite', b.data, 'habitation')->>'detail' as bail_531_identite,
       pilotage.controle_rivage_mandat(m.id, 'proprietaires', m.data)->>'detail' as mandat_414_proprietaires,
       pilotage.controle_rivage_mandat(m.id, 'lots_fiche', m.data)->>'detail' as mandat_414_lots,
       (select count(*) from pilotage.parametrage_detections()) as alertes_a_ouvrir
from pilotage.objets b
join pilotage.objets m on m.type = 'ManagementContract' and m.id = 'mc_16c0992d53d1a71dcf538eed'
where b.type = 'LeasingContract' and b.id = 'lc_59c91f0ad232ff5b0f58310f';


-- 134 : contrôle d'entrée, paramétrage saisi dans Rivage (bloc 3 sur 3) : branchement dans les contrôles existants
do $$
declare
  d text := replace(pg_get_functiondef('pilotage.controle_bail'::regproc), E'\r\n', E'\n');
  a1 text := E'  o jsonb; lot record;';
  a2 text := E'        else null;\n      end case;';
begin
  if position('controle_rivage_bail' in d) > 0 then raise notice '134 : controle_bail déjà branché'; return; end if;
  if position(a1 in d) = 0 or position(a2 in d) = 0 then raise exception '134 : ancre introuvable dans controle_bail (script 133 passé ?)'; end if;
  d := replace(d, a1, E'  r134 jsonb; o jsonb; lot record;');
  d := replace(d, a2, E'        else\n'
    || E'          -- 134 : paramétrage Rivage (échéance, paiement, parts, honoraires d''entrée, identité, précédent locataire)\n'
    || E'          r134 := pilotage.controle_rivage_bail(p_bail, q.ref, o, v_portee);\n'
    || E'          if r134 is not null then\n'
    || E'            detail := r134->>''detail''; vide := coalesce((r134->>''vide'')::boolean, false); ia_ok := coalesce((r134->>''ok'')::boolean, false);\n'
    || E'            if coalesce((r134->>''anomalie'')::boolean, false) then auto := ''anomalie''; end if;\n'
    || E'          end if;\n'
    || E'      end case;');
  execute d;
end $$;

do $$
declare
  d text := replace(pg_get_functiondef('pilotage.controle_mandat'::regproc), E'\r\n', E'\n');
  a1 text := E'  o jsonb; s pilotage.mandats_suivi;';
  a2 text := E'        else null;\n      end case;';
  a3 text := E'    if q.mode = ''document'' then';
  a4 text := E' and nullif(a.data->>''syndic_id'', '''') is null and not pilotage.lot_dans_immeuble(a.id)';
  a5 text := E'''Pas de copropriété (maison ou immeuble géré en entier)''';
begin
  if position('controle_rivage_mandat' in d) > 0 then raise notice '134 : controle_mandat déjà branché'; return; end if;
  if position(a1 in d) = 0 or position(a2 in d) = 0 or position(a3 in d) = 0 or position(a4 in d) = 0 or position(a5 in d) = 0 then
    raise exception '134 : ancre introuvable dans controle_mandat'; end if;
  d := replace(d, a1, E'  r134 jsonb; o jsonb; s pilotage.mandats_suivi;');
  d := replace(d, a2, E'        else\n'
    || E'          -- 134 : fiche des lots et propriétaires\n'
    || E'          r134 := pilotage.controle_rivage_mandat(p_mandat, q.ref, o);\n'
    || E'          if r134 is not null then\n'
    || E'            detail := r134->>''detail''; vide := coalesce((r134->>''vide'')::boolean, false); ia_ok := coalesce((r134->>''ok'')::boolean, false);\n'
    || E'            if coalesce((r134->>''anomalie'')::boolean, false) then auto := ''anomalie''; end if;\n'
    || E'          end if;\n'
    || E'      end case;');
  d := replace(d, a3, E'    -- 134 : PNO, date de fin saisie dans le pilotage (Rivage n''a ni nature de pièce ni date pour la PNO)\n'
    || E'    if q.ref = ''pno'' then\n'
    || E'      detail := (select case when x.fin < current_date then ''PNO expirée le '' else ''PNO valable jusqu''''au '' end || to_char(x.fin, ''DD/MM/YYYY'')\n'
    || E'                   || coalesce('' · '' || x.assureur, '''') || coalesce('' n° '' || x.numero, '''') from pilotage.mandats_pno x where x.mandat_id = p_mandat);\n'
    || E'      auto := case when detail is null then null when detail like ''PNO expirée%'' then ''anomalie'' else ''ok'' end;\n'
    || E'      if detail is null then detail := ''Date de fin de la PNO à saisir (attestation déposée dans la GED de Rivage avec « PNO » dans le nom)''; end if;\n'
    || E'    end if;\n\n'
    || a3);
  -- 134 : un lot rattaché à un groupe « immeuble » de Rivage n'est plus dispensé de syndic (retour sur l'exception du 024)
  d := replace(d, a4, E' and nullif(a.data->>''syndic_id'', '''') is null');
  d := replace(d, a5, E'''Pas de copropriété (maisons)''');
  execute d;
end $$;

do $$
declare
  d text := replace(pg_get_functiondef('pilotage.executer_controles'::regproc), E'\r\n', E'\n');
  a text := E'from pilotage.tickets_rappels_detections() t;';
begin
  if position('parametrage_detections' in d) > 0 then raise notice '134 : executer_controles déjà branché'; return; end if;
  if position(a in d) = 0 then raise exception '134 : ancre introuvable dans executer_controles (script 127 passé ?)'; end if;
  execute replace(d, a, E'from pilotage.tickets_rappels_detections() t\n  union all\n  select p.regle, p.objet_type, p.objet_id, p.titre, p.detail, p.lien from pilotage.parametrage_detections() p;');
end $$;

-- Vérification : fonctions branchées, bail 531 et mandat 414 recontrôlés (lecture seule)
select position('controle_rivage_bail' in pg_get_functiondef('pilotage.controle_bail'::regproc)) > 0 as controle_bail_branche,
       position('controle_rivage_mandat' in pg_get_functiondef('pilotage.controle_mandat'::regproc)) > 0 as controle_mandat_branche,
       position('parametrage_detections' in pg_get_functiondef('pilotage.executer_controles'::regproc)) > 0 as alertes_branchees,
       (select string_agg(i->>'libelle' || ' : ' || coalesce(i->>'auto', '?'), ' | ') from jsonb_array_elements(pilotage.controle_bail('lc_59c91f0ad232ff5b0f58310f')->'items') i
         where i->>'cle' like 'h_rv_%' and i->>'cle' in ('h_rv_appel','h_rv_paiement','h_rv_parts','h_rv_honoraires','h_rv_identite','h_rv_precedent')) as bail_531,
       (select string_agg(i->>'libelle' || ' : ' || coalesce(i->>'auto', '?'), ' | ') from jsonb_array_elements(pilotage.controle_mandat('mc_16c0992d53d1a71dcf538eed')->'items') i
         where i->>'cle' in ('m_rv_lots_fiche', 'm_rv_proprietaires', 'm_rv_syndic', 'm_cl_pno')) as mandat_414;
