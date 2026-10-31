-- 107 — Pack de gestion lu dans Rivage et contrôlé contre le barème (Nicolas, 31/10/2026).
-- Constat sur le mandat n° 378 (MARIN Laurent, lot 428, 25 rue Notre-Dame-des-Champs, Corbeil), arrivé le 31/10 à 11 h 30 :
-- Rivage envoie l'offre de gestion choisie (management_offer_id) mais pas son nom ; le pilotage demandait donc le pack au commercial.
-- Offres de gestion de Rivage, relevées dans Paramètres > Offres le 31/10 (identifiants publics) :
--   Pack Essentiel 5,5 % ; Pack Essentiel + extranet 5,5 % + 3 € ; Pack Confort 7,5 % ; Pack Confort + extranet 7,5 % + 3 € ; Pack Pro 7 %.
-- Mandat 378 : offre « Pack Pro » mais taux de gestion à 2,5 % TTC dans Rivage. Barème du pilotage (045, précision du 18/10) :
-- Pack Pro 7 % moins 2 % par lot au-delà du 2e, plancher 6 % ; le mandant a 16 lots dans des mandats actifs, 6 % attendus. L'écart s'affichera dans
-- le contrôle d'entrée et demandera une justification (ou une correction dans Rivage).
-- Ajouts : table des offres Rivage ; la question « Pack de gestion » est réglée par Rivage quand l'offre est connue ;
-- le contrôle du taux utilise le pack de Rivage, à défaut celui répondu ; frais fixes de l'option extranet (3 €) contrôlés.
-- Aussi : lots_mandant comptait seulement les mandats « active » ; Rivage envoie « created » pour un mandat actif (corrigé).
-- Fonctions modifiées : lots_mandant, pack_mandat, ecart_bareme (remplacées), controle_mandat (remplacement ciblé, contrôlé). Un seul bloc.

begin;

create table if not exists pilotage.offres_gestion_rivage (
  rivage_id text primary key,
  nom text not null,
  pack text not null check (pack in ('essentiel', 'confort', 'pro')),
  taux_ttc numeric not null,
  forfait_ttc numeric not null default 0
);
alter table pilotage.offres_gestion_rivage enable row level security;
revoke all on pilotage.offres_gestion_rivage from public, anon, authenticated;

insert into pilotage.offres_gestion_rivage (rivage_id, nom, pack, taux_ttc, forfait_ttc) values
 ('o_ab6753513d403171f2122ef7', 'Pack Essentiel', 'essentiel', 5.5, 0),
 ('o_1ae5b8ffec98f7176554a3b2', 'Pack Essentiel + extranet', 'essentiel', 5.5, 3),
 ('o_1f6ba1bdcae48689459b4be8', 'Pack Confort', 'confort', 7.5, 0),
 ('o_6ab011df795afeefaa707103', 'Pack Confort + extranet', 'confort', 7.5, 3),
 ('o_22d8bd92722a3d075e05b205', 'Pack Pro', 'pro', 7, 0)
on conflict (rivage_id) do update set nom = excluded.nom, pack = excluded.pack, taux_ttc = excluded.taux_ttc, forfait_ttc = excluded.forfait_ttc;

-- Offre de gestion du mandat dans Rivage (null si aucune ou inconnue)
create or replace function pilotage.offre_mandat(p_mandat text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('rivage_id', o.data->>'management_offer_id', 'nom', g.nom, 'pack', g.pack, 'forfait_ttc', g.forfait_ttc)
    from pilotage.objets o left join pilotage.offres_gestion_rivage g on g.rivage_id = o.data->>'management_offer_id'
   where o.type = 'ManagementContract' and o.id = p_mandat and nullif(o.data->>'management_offer_id', '') is not null
$$;

-- Lots confiés par le(s) mandant(s) : tous les mandats en cours. Rivage envoie « created » pour un mandat actif (328 mandats, affichés
-- « Actif » dans Rivage) et « lost » pour un mandat perdu ; l'ancienne version ne comptait que « active » (2 mandats), d'où un
-- nombre de lots trop faible dans le barème du pack Pro (mandat 378 : 1 lot compté au lieu de 16).
create or replace function pilotage.lots_mandant(p_mandat text) returns integer
language sql stable security definer set search_path = pilotage, public as $$
  select count(distinct a.id)::integer from pilotage.objets a
  where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' in (
    select m2.id from pilotage.objets m2, jsonb_array_elements(coalesce(m2.data->'profile_contracts_attributes', '[]'::jsonb)) p2
    where m2.type = 'ManagementContract' and m2.supprime_le is null and coalesce(m2.data->>'status', 'created') <> 'lost'
      and p2->>'profile_id' in (select p->>'profile_id' from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
                                where m.type = 'ManagementContract' and m.id = p_mandat))
$$;

-- Pack du mandat : celui de Rivage d'abord, sinon celui répondu par le commercial (045)
create or replace function pilotage.pack_mandat(p_mandat text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(pilotage.offre_mandat(p_mandat)->>'pack',
                  (select lower(commentaire) from pilotage.baux_reponses where bail_id = p_mandat and cle = 'm_cl_pack' and statut = 'ok'))
$$;

-- Barème (045) inchangé ; 107 : frais fixes de l'option extranet contrôlés
create or replace function pilotage.ecart_bareme(p_mandat text, p_taux numeric) returns text
language plpgsql stable security definer set search_path = pilotage, public as $$
declare pk text := pilotage.pack_mandat(p_mandat); n integer; attendu numeric; off jsonb := pilotage.offre_mandat(p_mandat); fixe numeric;
begin
  if pk is null or p_taux is null or p_taux = 0 then return null; end if;
  if pk = 'essentiel' and abs(p_taux - 5.5) > 0.01 then return 'barème pack Essentiel : 5,5 % TTC attendu'; end if;
  if pk = 'confort' and abs(p_taux - 7.5) > 0.01 then return 'barème pack Confort : 7,5 % TTC attendu'; end if;
  if pk = 'pro' then
    n := pilotage.lots_mandant(p_mandat);
    if n < 2 then return 'pack Pro réservé aux mandants d''au moins 2 lots (' || n || ' lot confié)'; end if;
    -- Remise de 2 % sur le taux de 7 % par lot au-delà du 2e (précision de Nicolas du 18/10), plancher 6 % ;
    -- tolérance de 0,05 point pour un taux arrondi à une décimale dans Rivage.
    attendu := greatest(6, round(7 * (1 - 0.02 * (n - 2)), 2));
    if abs(p_taux - attendu) > 0.05 then
      return 'barème pack Pro, ' || n || ' lots : ' || replace(to_char(attendu, 'FM990.00'), '.', ',') || ' % TTC attendu'; end if;
  end if;
  if off->>'nom' is not null then
    fixe := coalesce((select (o.data->>'fixed_management_fees_in_cents')::numeric / 100 from pilotage.objets o where o.type = 'ManagementContract' and o.id = p_mandat), 0);
    if abs(fixe - (off->>'forfait_ttc')::numeric) > 0.01 then
      return off->>'nom' || ' : frais fixes de ' || replace(to_char((off->>'forfait_ttc')::numeric, 'FM990.00'), '.', ',') || ' € TTC attendus (Rivage : '
             || replace(to_char(fixe, 'FM990.00'), '.', ',') || ' €)'; end if;
  end if;
  return null;
end $$;
revoke all on function pilotage.offre_mandat(text) from public, anon, authenticated;

-- controle_mandat : question « Pack de gestion » réglée par Rivage quand l'offre est connue
do $do$
declare d text;
  avant constant text := $r$auto := null; detail := null; valeur_ia := lecture->q.cle; piece := null; up := null; ia_diff := null; vide := false; ia_ok := false;$r$;
begin
  d := pg_get_functiondef('pilotage.controle_mandat(text)'::regprocedure);
  if position('offre_mandat' in d) = 0 then
    if position(avant in d) = 0 then raise exception 'controle_mandat : point d''insertion introuvable'; end if;
    d := replace(d, avant, avant || $r$
    if q.cle = 'm_cl_pack' and pilotage.offre_mandat(p_mandat)->>'nom' is not null then
      auto := 'ok'; detail := 'Rivage : ' || (pilotage.offre_mandat(p_mandat)->>'nom');
    elsif q.cle = 'm_cl_pack' and pilotage.offre_mandat(p_mandat) is not null then
      detail := 'Offre de gestion Rivage inconnue du pilotage (' || (pilotage.offre_mandat(p_mandat)->>'rivage_id') || ') : choisir le pack ci-dessous';
    end if;$r$);
    execute d;
  end if;
end $do$;

-- Le cache des mandats se recalcule seul toutes les heures (pilotage-cache-mandats).

commit;

-- Vérification : mandat 378, pack lu dans Rivage et écart de taux
-- select pilotage.pack_mandat('mc_b86a143e924cad5677bbc811'), pilotage.ecart_bareme('mc_b86a143e924cad5677bbc811', 2.5);
