-- 030 : règles de rémunération des commerciaux paramétrables (décision de Nicolas, 16/10/2026).
--   Une règle = une phase (apport du mandat, mandat signé, dossier complet, bail signé, EDL fait), un bénéficiaire
--   (apporteur, négociateur du mandat, commercial qui a loué, auteur de l'EDL), un pourcentage et une base de calcul :
--     gestion       : N mois d'honoraires de gestion HT (N paramétrable ; apport direction : nombre de mois réduit)
--     loc_total     : honoraires de location HT du bail (locataire + bailleur, EDL locataire compris)
--     loc_bailleur  : honoraires de location HT facturés au bailleur
--     loc_locataire : honoraires de location HT facturés au locataire (hors EDL quand Rivage donne le détail)
--     edl           : honoraires d'état des lieux HT (part locataire : la part bailleur n'est pas transmise par Rivage)
--     forfait       : montant fixe HT
--   Les règles par défaut reprennent le barème en vigueur (rentrée 8 mois, 50 % signature / 25 % GO / 25 % + ajustement au bail ;
--   mise en location 40 % des honoraires de location) : les montants actuels ne changent pas.
--   Rentrée (base gestion) : calculée sur le loyer prévu, puis recalculée sur le loyer réel au bail signé (ajustement sur la règle
--   « bail signé »). Bases location et EDL : une ligne par bail signé depuis la date de départ (mise en location et relocations).

create table if not exists pilotage.remuneration_parametres (cle text primary key, valeur numeric not null, libelle text);
insert into pilotage.remuneration_parametres (cle, valeur, libelle) values
  ('mois_gestion', 8, 'Mois d''honoraires de gestion HT pour la rentrée d''un mandat'),
  ('mois_gestion_direction', 6, 'Mois d''honoraires de gestion HT quand le mandat est apporté par la direction'),
  ('ajustement_loyer_reel', 1, 'Recalcul de la rentrée sur le loyer réel au bail signé (1 = oui, 0 = non)')
on conflict (cle) do nothing;

create table if not exists pilotage.remuneration_regles (
  id serial primary key, code text unique,
  phase text not null check (phase in ('apport', 'mandat_signe', 'dossier_complet', 'bail_signe', 'edl_fait')),
  beneficiaire text not null check (beneficiaire in ('apporteur', 'negociateur', 'loueur', 'edl')),
  pourcentage numeric(6,2), base text not null check (base in ('gestion', 'loc_total', 'loc_bailleur', 'loc_locataire', 'edl', 'forfait')),
  forfait numeric(12,2), actif boolean not null default true, ordre integer not null default 0,
  maj_par uuid, maj_le timestamptz not null default now()
);
insert into pilotage.remuneration_regles (code, phase, beneficiaire, pourcentage, base, ordre) values
  ('v1', 'mandat_signe', 'negociateur', 50, 'gestion', 20),
  ('v2', 'dossier_complet', 'negociateur', 25, 'gestion', 30),
  ('v3', 'bail_signe', 'negociateur', 25, 'gestion', 40),
  ('loc', 'bail_signe', 'loueur', 40, 'loc_total', 45)
on conflict (code) do nothing;

alter table pilotage.mandats_suivi add column if not exists apporteur uuid;
alter table pilotage.baux_suivi add column if not exists edl_par uuid;
-- Factures : clé libre (code de règle) ; la commission de location est désormais rattachée au bail (relocations comprises)
alter table pilotage.commissions_factures drop constraint if exists commissions_factures_versement_check;
update pilotage.commissions_factures f set mandat_id = pilotage.bail_location(f.mandat_id)
 where f.versement = 'loc' and f.mandat_id like 'mc\_%' and pilotage.bail_location(f.mandat_id) is not null;

alter table pilotage.remuneration_parametres enable row level security;
alter table pilotage.remuneration_regles enable row level security;
revoke all on pilotage.remuneration_parametres, pilotage.remuneration_regles from public, anon, authenticated;

create or replace function pilotage.param_remu(p text) returns numeric language sql stable security definer set search_path = pilotage, public as $$
  select valeur from pilotage.remuneration_parametres where cle = p $$;

-- Toutes les lignes de commission (mandats et baux depuis le 01/01/2026)
create or replace function pilotage.lignes_commissions() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  m record; s pilotage.mandats_suivi; b record; bs pilotage.baux_suivi; r record; o jsonb;
  lignes jsonb := '[]'::jsonb; mois numeric; loyer_prev numeric; loyer_reel numeric; base_prev numeric; base_reel numeric;
  bail_ml text; bs_ml pilotage.baux_suivi; pct_avant numeric; montant numeric; benef uuid; du boolean; cond text; base_lib text; base_val numeric;
  tf numeric; tf_loc numeric; tf_edl numeric; lf numeric; edl_le date; cle_obj text; phase_lib jsonb := '{"apport":"Apport du mandat","mandat_signe":"Mandat signé","dossier_complet":"Dossier complet (GO)","bail_signe":"Bail signé","edl_fait":"État des lieux d''entrée fait"}';
begin
  -- 1) Rentrée et étapes du mandat (bases gestion et forfait sur les phases du mandat)
  for m in select * from pilotage.v_mandats where debut >= date '2026-01-01' order by debut loop
    select * into s from pilotage.mandats_suivi where mandat_id = m.id;
    mois := case when coalesce(s.apport_direction, false) then pilotage.param_remu('mois_gestion_direction') else pilotage.param_remu('mois_gestion') end;
    loyer_prev := coalesce(s.loyer_prevu, (select sum(x.loyer_hc + x.charges) from pilotage.v_baux x join pilotage.v_lots l on l.id = x.lot_id
                   where l.mandat_id = m.id and x.statut in ('created', 'move_in', 'in_progress')));
    select sum(p.loyer) into loyer_reel from (
      select distinct on (x.lot_id) x.loyer_hc + x.charges loyer from pilotage.v_baux x join pilotage.v_lots l on l.id = x.lot_id
      where l.mandat_id = m.id and coalesce(x.signe_le, x.debut) >= m.debut order by x.lot_id, coalesce(x.signe_le, x.debut)) p;
    base_prev := round(coalesce(loyer_prev, loyer_reel) * m.taux_gestion_ttc / 100 / 1.2 * mois, 2);
    base_reel := case when loyer_reel is not null then round(loyer_reel * m.taux_gestion_ttc / 100 / 1.2 * mois, 2) end;
    bail_ml := pilotage.bail_location(m.id);
    bs_ml := null; select * into bs_ml from pilotage.baux_suivi where bail_id = bail_ml;
    pct_avant := 0;
    for r in select * from pilotage.remuneration_regles where actif and (base = 'gestion' or (base = 'forfait' and phase in ('apport', 'mandat_signe', 'dossier_complet')))
             order by case phase when 'apport' then 1 when 'mandat_signe' then 2 when 'dossier_complet' then 3 when 'bail_signe' then 4 else 5 end, ordre, id loop
      benef := case r.beneficiaire when 'apporteur' then s.apporteur when 'negociateur' then s.negociateur when 'loueur' then bs_ml.loue_par when 'edl' then bs_ml.edl_par end;
      if r.base = 'forfait' then montant := r.forfait; base_lib := 'Forfait'; base_val := r.forfait;
      elsif r.phase = 'bail_signe' and base_reel is not null then
        montant := round(r.pourcentage / 100 * base_reel + case when pilotage.param_remu('ajustement_loyer_reel') = 1 then pct_avant / 100 * (base_reel - coalesce(base_prev, base_reel)) else 0 end, 2);
        base_lib := mois || ' mois d''honoraires de gestion HT sur le loyer réel' || case when pilotage.param_remu('ajustement_loyer_reel') = 1 and pct_avant > 0 then ' + ajustement des versements précédents' else '' end;
        base_val := base_reel;
      else
        montant := round(r.pourcentage / 100 * base_prev, 2); base_val := base_prev;
        base_lib := mois || ' mois d''honoraires de gestion HT sur le loyer prévu';
        if r.base = 'gestion' then pct_avant := pct_avant + r.pourcentage; end if;
      end if;
      du := benef is not null and case r.phase
        when 'apport' then m.signe_le is not null
        when 'mandat_signe' then m.signe_le is not null
        when 'dossier_complet' then s.go_le is not null
        when 'bail_signe' then bail_ml is not null and bs_ml.valide_le is not null else false end;
      cond := case r.phase
        when 'apport' then 'À la signature du mandat' || coalesce(' le ' || to_char(m.signe_le, 'DD/MM/YYYY'), '')
        when 'mandat_signe' then 'À la signature du mandat' || coalesce(' le ' || to_char(m.signe_le, 'DD/MM/YYYY'), ' (date absente dans Rivage)')
        when 'dossier_complet' then coalesce('GO donné le ' || to_char(s.go_le, 'DD/MM/YYYY'), 'Au GO (dossier complet validé)')
        when 'bail_signe' then case when bail_ml is null then 'À la mise en location' when bs_ml.valide_le is null then 'Bail signé, à valider' else 'Bail validé le ' || to_char(bs_ml.valide_le, 'DD/MM/YYYY') end end
        || case when benef is null then ' · ' || case r.beneficiaire when 'apporteur' then 'apporteur' when 'negociateur' then 'négociateur' when 'loueur' then '« loué par »' else 'auteur de l''EDL' end || ' à renseigner' else '' end;
      lignes := lignes || jsonb_build_object('objet', m.id, 'type', 'mandat', 'mandat_id', m.id, 'mandat_ref', m.reference, 'bailleur', pilotage.bailleurs_mandat(m.id),
        'regle', coalesce(r.code, 'r' || r.id), 'phase', r.phase, 'phase_libelle', phase_lib->>r.phase, 'beneficiaire_role', r.beneficiaire, 'beneficiaire', benef,
        'prenom', (select prenom from pilotage.membres where user_id = benef), 'pourcentage', r.pourcentage, 'base', r.base, 'base_libelle', base_lib, 'base_montant', base_val,
        'montant', montant, 'condition', cond, 'du', du,
        'facture', (select jsonb_build_object('facture', f.facture, 'le', f.le, 'montant', f.montant) from pilotage.commissions_factures f where f.mandat_id = m.id and f.versement = coalesce(r.code, 'r' || r.id)));
    end loop;
  end loop;

  -- 2) Baux signés depuis le 01/01/2026 (mise en location et relocations) : bases location, EDL et forfait des phases bail et EDL
  for b in select x.*, l.mandat_id from pilotage.v_baux x left join pilotage.v_lots l on l.id = x.lot_id where coalesce(x.signe_le, x.debut) >= date '2026-01-01' loop
    select data into o from pilotage.objets where type = 'LeasingContract' and id = b.id;
    bs := null; select * into bs from pilotage.baux_suivi where bail_id = b.id;
    tf := coalesce((o->>'tenant_fees_in_cents')::numeric, 0) / 100;
    tf_edl := coalesce((o->'tenant_fees_breakdown'->>'inventory_fees_in_cents')::numeric, 0) / 100;
    tf_loc := case when o->'tenant_fees_breakdown'->>'rental_fees_in_cents' is not null then (o->'tenant_fees_breakdown'->>'rental_fees_in_cents')::numeric / 100 else tf end;
    lf := coalesce((o->>'landlord_rental_fees_in_cents')::numeric, 0) / 100;
    select min(u.maj_le::date) into edl_le from pilotage.objets u
     where u.type = 'Upload' and u.supprime_le is null and u.data->>'nature' = 'move_in_inventory'
       and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr where rr->>'id' = b.id);
    for r in select * from pilotage.remuneration_regles where actif and base <> 'gestion' and not (base = 'forfait' and phase in ('apport', 'mandat_signe', 'dossier_complet'))
             order by ordre, id loop
      benef := case r.beneficiaire when 'loueur' then bs.loue_par when 'edl' then bs.edl_par
                 when 'negociateur' then (select negociateur from pilotage.mandats_suivi where mandat_id = b.mandat_id)
                 when 'apporteur' then (select apporteur from pilotage.mandats_suivi where mandat_id = b.mandat_id) end;
      base_val := round(case r.base when 'loc_total' then (tf + lf) / 1.2 when 'loc_bailleur' then lf / 1.2 when 'loc_locataire' then tf_loc / 1.2
                                    when 'edl' then tf_edl / 1.2 when 'forfait' then r.forfait end, 2);
      base_lib := case r.base when 'loc_total' then 'Honoraires de location HT (locataire + bailleur)' when 'loc_bailleur' then 'Honoraires de location HT facturés au bailleur'
                    when 'loc_locataire' then 'Honoraires de location HT facturés au locataire' when 'edl' then 'Honoraires d''état des lieux HT (part locataire)' else 'Forfait' end;
      montant := case when r.base = 'forfait' then r.forfait else round(r.pourcentage / 100 * base_val, 2) end;
      continue when coalesce(montant, 0) = 0 and r.base <> 'forfait';
      du := benef is not null and bs.valide_le is not null and (r.phase <> 'edl_fait' or edl_le is not null);
      cond := case when bs.valide_le is null then 'Bail signé le ' || to_char(coalesce(b.signe_le, b.debut), 'DD/MM/YYYY') || ', à valider'
                   when r.phase = 'edl_fait' and edl_le is null then 'État des lieux d''entrée pas encore déposé dans Rivage'
                   when r.phase = 'edl_fait' then 'EDL déposé dans Rivage le ' || to_char(edl_le, 'DD/MM/YYYY')
                   else 'Bail validé le ' || to_char(bs.valide_le, 'DD/MM/YYYY') end
        || case when benef is null then ' · ' || case r.beneficiaire when 'loueur' then '« loué par »' when 'edl' then '« EDL fait par »' when 'negociateur' then 'négociateur du mandat' else 'apporteur' end || ' à renseigner' else '' end;
      lignes := lignes || jsonb_build_object('objet', b.id, 'type', 'bail', 'bail_id', b.id, 'bail_ref', b.reference, 'locataires', b.locataires,
        'mandat_id', b.mandat_id, 'mandat_ref', (select reference from pilotage.v_mandats where id = b.mandat_id), 'bailleur', pilotage.bailleurs_mandat(b.mandat_id),
        'mise_en_location', pilotage.bail_location(b.mandat_id) = b.id,
        'regle', coalesce(r.code, 'r' || r.id), 'phase', r.phase, 'phase_libelle', phase_lib->>r.phase, 'beneficiaire_role', r.beneficiaire, 'beneficiaire', benef,
        'prenom', (select prenom from pilotage.membres where user_id = benef), 'pourcentage', r.pourcentage, 'base', r.base, 'base_libelle', base_lib, 'base_montant', base_val,
        'montant', montant, 'condition', cond, 'du', du,
        'facture', (select jsonb_build_object('facture', f.facture, 'le', f.le, 'montant', f.montant) from pilotage.commissions_factures f where f.mandat_id = b.id and f.versement = coalesce(r.code, 'r' || r.id)));
    end loop;
  end loop;
  return lignes;
end $$;

-- Page Commissions : lignes, règles, paramètres, membres
create or replace function public.pilotage_commissions() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'lignes', pilotage.lignes_commissions(),
    'regles', (select coalesce(jsonb_agg(to_jsonb(r) order by case r.phase when 'apport' then 1 when 'mandat_signe' then 2 when 'dossier_complet' then 3 when 'bail_signe' then 4 else 5 end, r.ordre, r.id), '[]'::jsonb) from pilotage.remuneration_regles r),
    'parametres', (select coalesce(jsonb_agg(to_jsonb(p) order by p.cle), '[]'::jsonb) from pilotage.remuneration_parametres p),
    'membres', (select coalesce(jsonb_agg(jsonb_build_object('user_id', mb.user_id, 'prenom', mb.prenom, 'role', mb.role) order by mb.prenom), '[]'::jsonb) from pilotage.membres mb where mb.actif),
    'mon_role', pilotage.mon_role());
end $$;

-- Modification des règles et paramètres : direction seulement
create or replace function public.pilotage_regle_remu(p_id integer, p_phase text, p_beneficiaire text, p_pourcentage numeric, p_base text, p_forfait numeric, p_actif boolean, p_supprimer boolean)
returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Réservé à la direction'; end if;
  if p_supprimer then
    if exists (select 1 from pilotage.commissions_factures f join pilotage.remuneration_regles r on f.versement = coalesce(r.code, 'r' || r.id) where r.id = p_id) then
      raise exception 'Des versements de cette règle ont déjà été facturés : la désactiver plutôt que la supprimer';
    end if;
    delete from pilotage.remuneration_regles where id = p_id; return;
  end if;
  if p_base = 'gestion' and p_phase = 'edl_fait' then raise exception 'La base « honoraires de gestion » s''applique aux phases du mandat et au bail signé'; end if;
  if p_base in ('loc_total', 'loc_bailleur', 'loc_locataire', 'edl') and p_phase not in ('bail_signe', 'edl_fait') then
    raise exception 'Les honoraires de location et d''EDL ne sont connus qu''au bail signé : choisir la phase « Bail signé » ou « EDL fait »';
  end if;
  if p_base = 'forfait' and coalesce(p_forfait, 0) <= 0 then raise exception 'Montant du forfait obligatoire'; end if;
  if p_base <> 'forfait' and (p_pourcentage is null or p_pourcentage < 0 or p_pourcentage > 100) then raise exception 'Pourcentage entre 0 et 100'; end if;
  if p_id is null then
    insert into pilotage.remuneration_regles (phase, beneficiaire, pourcentage, base, forfait, actif, ordre, maj_par)
    values (p_phase, p_beneficiaire, case when p_base = 'forfait' then null else p_pourcentage end, p_base, case when p_base = 'forfait' then p_forfait end, coalesce(p_actif, true), 50, auth.uid());
  else
    update pilotage.remuneration_regles set phase = p_phase, beneficiaire = p_beneficiaire, pourcentage = case when p_base = 'forfait' then null else p_pourcentage end,
      base = p_base, forfait = case when p_base = 'forfait' then p_forfait end, actif = coalesce(p_actif, actif), maj_par = auth.uid(), maj_le = now() where id = p_id;
  end if;
end $$;

create or replace function public.pilotage_param_remu(p_cle text, p_valeur numeric) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Réservé à la direction'; end if;
  if p_valeur is null or p_valeur < 0 then raise exception 'Valeur invalide'; end if;
  update pilotage.remuneration_parametres set valeur = p_valeur where cle = p_cle;
  if not found then raise exception 'Paramètre inconnu'; end if;
end $$;

-- Saisies : apporteur du mandat, auteur de l'EDL du bail (en plus des champs existants)
create or replace function public.pilotage_remu_affecter(p_type text, p_id text, p_champ text, p_valeur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  if p_type = 'mandat' and p_champ = 'apporteur' then
    insert into pilotage.mandats_suivi(mandat_id) values (p_id) on conflict do nothing;
    update pilotage.mandats_suivi set apporteur = nullif(p_valeur, '')::uuid, maj_par = auth.uid(), maj_le = now() where mandat_id = p_id;
  elsif p_type = 'bail' and p_champ = 'edl_par' then
    insert into pilotage.baux_suivi(bail_id) values (p_id) on conflict do nothing;
    update pilotage.baux_suivi set edl_par = nullif(p_valeur, '')::uuid, maj_par = auth.uid(), maj_le = now() where bail_id = p_id;
  else raise exception 'Champ non modifiable'; end if;
end $$;

-- Facturation : clé libre (code de la règle), objet = mandat ou bail
create or replace function public.pilotage_commission_facturer(p_mandat text, p_versement text, p_facture text, p_montant numeric) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  if nullif(trim(p_facture), '') is null then
    delete from pilotage.commissions_factures where mandat_id = p_mandat and versement = p_versement;
  else
    insert into pilotage.commissions_factures(mandat_id, versement, facture, montant, par) values (p_mandat, p_versement, trim(p_facture), p_montant, auth.uid())
    on conflict (mandat_id, versement) do update set facture = excluded.facture, montant = excluded.montant, le = current_date, par = auth.uid();
  end if;
end $$;

revoke all on all functions in schema pilotage from public, anon, authenticated;
revoke all on function public.pilotage_commissions(), public.pilotage_regle_remu(integer, text, text, numeric, text, numeric, boolean, boolean),
  public.pilotage_param_remu(text, numeric), public.pilotage_remu_affecter(text, text, text, text) from public, anon;
grant execute on function public.pilotage_commissions(), public.pilotage_regle_remu(integer, text, text, numeric, text, numeric, boolean, boolean),
  public.pilotage_param_remu(text, numeric), public.pilotage_remu_affecter(text, text, text, text) to authenticated;
