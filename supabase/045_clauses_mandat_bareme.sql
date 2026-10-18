-- 045 : clauses du mandat simplifiées (décision de Nicolas du 18/10, barème UDI Gestion du 01/09/2026)
-- Retirées du contrôle du mandat (ni question au commercial, ni point bloquant) :
--   - Travaux sans accord préalable : aucun plafond, tout travaux doit être validé par le bailleur (règle fixe du cabinet).
--   - Reddition des comptes et reversement : géré automatiquement par Rivage, aucun contrôle à faire.
--   - Résiliation du mandat : géré automatiquement par Rivage, aucun contrôle à faire.
--   - Anomalies de rédaction : relevées par la lecture IA du mandat signé (côté gestion), plus de question au commercial.
-- La garantie des loyers impayés devient une option du barème (2,8 % des sommes quittancées) : souscrite ou non, en un clic.
-- Pack de gestion du mandat (Essentiel, Confort, Pro) : nouvelle question en un clic ; le taux de gestion saisi dans Rivage
-- est contrôlé contre le barème du pack (Essentiel 5,5 % TTC, Confort 7,5 % TTC, Pro 7 % TTC à partir de 2 lots du même mandant,
-- puis remise de 2 % sur ce taux par lot supplémentaire, minimum 6 % TTC).
-- Corrige aussi permis_lot (038), qui faisait échouer le contrôle de certains mandats (voir ci-dessous).
-- Les questions retirées sont gardées avec la portée « retire » (réponses déjà saisies conservées, retour en arrière possible).

-- ========== Correctif du 038 : permis_lot ==========
-- Erreur constatée au premier passage du 045 (18/10) : « column reference "voie" is ambiguous » dans permis_lot. La variable
-- « voie » portait le même nom que la colonne permis_rues.voie : tout lot d'habitation situé dans une commune à périmètre
-- (Corbeil-Essonnes) faisait échouer le contrôle du mandat. Variable renommée, rien d'autre ne change.
create or replace function pilotage.permis_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare a jsonb; c pilotage.permis_communes; num integer; v_voie text; rue record; dans boolean; regime text; detail text;
begin
  select data into a from pilotage.objets where type = 'Asset' and id = p_asset;
  if a is null then return null; end if;
  if coalesce(a->>'nature', '') not in ('flat', 'room', 'house') then
    return jsonb_build_object('regime', 'non_concerne', 'commune', a->'address'->>'city', 'detail', 'Pas un logement : permis de louer non applicable.');
  end if;
  select * into c from pilotage.permis_communes where commune = pilotage.norm_commune(a->'address'->>'city');
  if c.commune is null then
    return jsonb_build_object('regime', 'inconnu', 'commune', a->'address'->>'city', 'detail', 'Commune jamais vérifiée : recherche à faire.');
  end if;
  if c.perimetre = 'commune' then
    regime := c.regime; detail := 'Toute la commune.';
  else
    v_voie := pilotage.norm_voie(a->'address'->>'street');
    num := nullif(substring(coalesce(a->'address'->>'number', '') from '^\s*(\d+)'), '')::integer;
    dans := false;
    for rue in select * from pilotage.permis_rues r where r.commune = c.commune and r.voie = v_voie loop
      if rue.num_min is null then dans := true; detail := 'Voie du périmètre : ' || rue.libelle; exit; end if;
      if num is null then dans := null; detail := 'Voie partiellement dans le périmètre (' || rue.condition || ') : numéro absent dans Rivage, à vérifier.'; continue; end if;
      if num between rue.num_min and rue.num_max and (rue.parite is null or (rue.parite = 'pair') = (num % 2 = 0)) then
        dans := true; detail := 'Dans le périmètre : ' || rue.libelle || ' (' || rue.condition || ')'; exit;
      end if;
    end loop;
    if dans is null then regime := 'a_verifier';
    elsif dans then regime := c.regime;
    else regime := coalesce(c.regime_hors_perimetre, 'aucun');
      detail := 'Hors du périmètre (adresse : ' || coalesce(a->'address'->>'number', '') || ' ' || coalesce(a->'address'->>'street', '') || ').';
    end if;
  end if;
  return jsonb_build_object('regime', regime, 'commune', c.libelle, 'a_confirmer', c.statut = 'a_confirmer', 'detail', detail,
    'email_depot', c.email_depot, 'adresse_depot', c.adresse_depot, 'source', c.source, 'verifie_le', c.verifie_le);
end $$;

alter table pilotage.controle_questions drop constraint if exists controle_questions_portee_check;
alter table pilotage.controle_questions add constraint controle_questions_portee_check
  check (portee = any (array['commercial', 'habitation', 'mandat', 'retire']));

update pilotage.controle_questions set portee = 'retire',
  aide = case cle
    when 'm_cl_travaux' then 'Retiré le 18/10/2026 : aucun plafond, tout travaux est validé par le bailleur.'
    when 'm_cl_reddition' then 'Retiré le 18/10/2026 : géré automatiquement par Rivage.'
    when 'm_cl_resiliation' then 'Retiré le 18/10/2026 : géré automatiquement par Rivage.'
    when 'm_cl_anomalies' then 'Retiré le 18/10/2026 : anomalies relevées par la lecture IA du mandat signé.' end
where cle in ('m_cl_travaux', 'm_cl_reddition', 'm_cl_resiliation', 'm_cl_anomalies');

update pilotage.controle_questions
set libelle = 'Garantie des loyers impayés (option du barème : 2,8 % des sommes quittancées)',
    aide = 'Souscrite ou non par le mandant.'
where cle = 'm_cl_gli';

-- ========== Pack de gestion ==========
insert into pilotage.controle_questions (cle, portee, bloc, ordre, libelle, aide, mode)
values ('m_cl_pack', 'mandat', 'clauses', 5, 'Pack de gestion souscrit (barème du 01/09/2026)',
        'Essentiel 5,5 % TTC · Confort 7,5 % TTC · Pro 7 % TTC à partir de 2 lots, remise de 2 % par lot supplémentaire, minimum 6 %.', 'question')
on conflict (cle) do update set portee = excluded.portee, bloc = excluded.bloc, ordre = excluded.ordre, libelle = excluded.libelle, aide = excluded.aide, mode = excluded.mode;

create or replace function pilotage.pack_mandat(p_mandat text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select lower(commentaire) from pilotage.baux_reponses where bail_id = p_mandat and cle = 'm_cl_pack' and statut = 'ok'
$$;

-- Nombre de lots confiés par les mandants de ce mandat (tous mandats actifs confondus), pour le taux dégressif du pack Pro
create or replace function pilotage.lots_mandant(p_mandat text) returns integer
language sql stable security definer set search_path = pilotage, public as $$
  select count(distinct a.id)::integer from pilotage.objets a
  where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' in (
    select m2.id from pilotage.objets m2, jsonb_array_elements(coalesce(m2.data->'profile_contracts_attributes', '[]'::jsonb)) p2
    where m2.type = 'ManagementContract' and m2.supprime_le is null and coalesce(m2.data->>'status', 'active') = 'active'
      and p2->>'profile_id' in (select p->>'profile_id' from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
                                where m.type = 'ManagementContract' and m.id = p_mandat))
$$;

-- Écart entre le taux de gestion Rivage et le barème du pack (null si conforme ou pack non renseigné)
create or replace function pilotage.ecart_bareme(p_mandat text, p_taux numeric) returns text
language plpgsql stable security definer set search_path = pilotage, public as $$
declare pk text := pilotage.pack_mandat(p_mandat); n integer; attendu numeric;
begin
  if pk is null or p_taux is null or p_taux = 0 then return null; end if;
  if pk = 'essentiel' and abs(p_taux - 5.5) > 0.01 then return 'barème pack Essentiel : 5,5 % TTC attendu'; end if;
  if pk = 'confort' and abs(p_taux - 7.5) > 0.01 then return 'barème pack Confort : 7,5 % TTC attendu'; end if;
  if pk = 'pro' then
    n := pilotage.lots_mandant(p_mandat);
    if n < 2 then return 'pack Pro réservé aux mandants d''au moins 2 lots (' || n || ' lot confié)'; end if;
    -- Remise de 2 % sur le taux de 7 % par lot au-delà du 2e (précision de Nicolas du 18/10), plancher 6 % :
    -- 2 lots 7 %, 3 lots 6,86 %, 4 lots 6,72 %… ; tolérance de 0,05 point pour un taux arrondi à une décimale dans Rivage.
    attendu := greatest(6, round(7 * (1 - 0.02 * (n - 2)), 2));
    if abs(p_taux - attendu) > 0.05 then
      return 'barème pack Pro, ' || n || ' lots : ' || replace(to_char(attendu, 'FM990.00'), '.', ',') || ' % TTC attendu'; end if;
  end if;
  return null;
end $$;

revoke all on function pilotage.pack_mandat(text), pilotage.lots_mandant(text), pilotage.ecart_bareme(text, numeric) from public, anon, authenticated;

-- Contrôle du taux de gestion contre le barème, dans le point « Honoraires de gestion » (ajout dans la fonction en place)
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('pilotage.controle_mandat(text)'::regprocedure);
  if position('ecart_bareme' in d) = 0 then
    n := replace(d, 'vide := coalesce(nullif(o->>''management_fees_rate'', '''')::numeric, 0) = 0;',
      'vide := coalesce(nullif(o->>''management_fees_rate'', '''')::numeric, 0) = 0;
          if not vide and pilotage.ecart_bareme(p_mandat, nullif(o->>''management_fees_rate'', '''')::numeric) is not null then
            auto := ''anomalie''; detail := detail || '' · '' || pilotage.ecart_bareme(p_mandat, nullif(o->>''management_fees_rate'', '''')::numeric); end if;');
    if n = d then raise exception '045 : emplacement des honoraires de gestion introuvable dans controle_mandat'; end if;
    execute n;
  end if;
end $$;

-- Le cache des mandats est recalculé avec le nouveau questionnaire
select pilotage.rafraichir_audit();

-- Contrôle du mandat DREZET (pack non encore renseigné : pas d'écart calculé)
select pilotage.ecart_bareme('mc_940f0f67b439e70f734a6be8', 6) as ecart_si_pack_vide, pilotage.lots_mandant('mc_940f0f67b439e70f734a6be8') as lots_du_mandant;

-- Contrôle : questions de clauses encore posées pour un mandat (doit renvoyer pack, équipements, compteurs, garantie des loyers impayés)
select cle, libelle from pilotage.controle_questions where portee = 'mandat' and bloc = 'clauses' order by ordre;
