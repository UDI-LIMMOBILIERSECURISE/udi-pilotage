-- Validation des mandats et des baux, pipeline des mandats et commissions des négociateurs.
-- Règles de rémunération (barème validé par Nicolas, sept. 2026) :
--   rentrée de mandat = 8 mois d'honoraires de gestion HT (6 mois si le mandat est apporté par la direction : base abattue de 25 %) ;
--   honoraires de gestion mensuels HT = loyer CC × taux TTC / 100 / 1,2 ;
--   versements (décision Nicolas du 15/10/2026) : 50 % à la signature du mandat (sur le loyer prévisionnel), 25 % au dossier complet validé (GO),
--   25 % + ajustement à la mise en location : solde recalculé sur le loyer réel du bail signé (peut être négatif : reprise sur commissions à venir) ;
--   mise en location par un commercial : 40 % des honoraires de location HT (honoraires bailleur + locataire du bail).
-- Seuls les mandats dont la date de début est à partir du 01/01/2026 sont suivis.

-- Appliqué : migrations pilotage_mandats_commissions et pilotage_mandats_loyer_reel (15/10/2026) ; GO et « loué sans GO » exigés seulement pour les mandats depuis 2026.
create table if not exists pilotage.mandats_suivi (
  mandat_id text primary key,
  negociateur uuid references auth.users(id),
  apport_direction boolean not null default false,
  go_le date, go_par uuid,
  retire_le date,
  note text,
  loyer_prevu numeric(12,2),
  maj_par uuid, maj_le timestamptz not null default now()
);
create table if not exists pilotage.baux_suivi (
  bail_id text primary key,
  loue_par uuid references auth.users(id),
  valide_le date, valide_par uuid,
  maj_par uuid, maj_le timestamptz not null default now()
);
-- Versement facturé par le négociateur (n° de facture), clé = mandat + versement (v1, v2, v3, loc)
create table if not exists pilotage.commissions_factures (
  mandat_id text not null,
  versement text not null check (versement in ('v1', 'v2', 'v3', 'loc')),
  facture text not null,
  montant numeric(12,2),
  le date not null default current_date,
  par uuid,
  primary key (mandat_id, versement)
);
revoke all on pilotage.mandats_suivi, pilotage.baux_suivi, pilotage.commissions_factures from public, anon, authenticated;

-- Reprise des saisies faites dans l'ancienne version de l'onglet (négociateur en texte, GO)
insert into pilotage.mandats_suivi(mandat_id, negociateur, go_le)
select m.id,
  (select mb.user_id from pilotage.membres mb where lower(mb.prenom) = lower(trim((select s.valeur->>'v' from pilotage.saisies s where s.objet_type = 'ManagementContract' and s.objet_id = m.id and s.cle = 'negociateur' order by s.saisi_le desc limit 1)))),
  (select (s.valeur->>'le')::date from pilotage.saisies s where s.objet_type = 'ManagementContract' and s.objet_id = m.id and s.cle = 'go' order by s.saisi_le desc limit 1)
from pilotage.v_mandats m
on conflict (mandat_id) do nothing;

-- Bail de mise en location d'un mandat : premier bail signé sur un de ses lots à partir du début du mandat
create or replace function pilotage.bail_location(p_mandat text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select b.id from pilotage.v_baux b join pilotage.v_lots l on l.id = b.lot_id join pilotage.v_mandats m on m.id = l.mandat_id
  where m.id = p_mandat and coalesce(b.signe_le, b.debut) >= m.debut
  order by coalesce(b.signe_le, b.debut) limit 1
$$;

create or replace function pilotage.dossier_mandat(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  m record; s pilotage.mandats_suivi; bs pilotage.baux_suivi; b record; bo jsonb;
  loyer_prev numeric; loyer_reel numeric; mois numeric; total_prev numeric; total_reel numeric;
  v1 numeric; v2 numeric; v3 numeric; hono_loc_ttc numeric; loc numeric; statut text; manques jsonb := '[]'::jsonb;
  lots int;
begin
  select * into m from pilotage.v_mandats where id = p_mandat;
  if m.id is null then return null; end if;
  select * into s from pilotage.mandats_suivi where mandat_id = p_mandat;
  select count(*) into lots from pilotage.v_lots where mandat_id = p_mandat;
  select x.* into b from pilotage.v_baux x where x.id = pilotage.bail_location(p_mandat);
  if b.id is not null then
    select * into bs from pilotage.baux_suivi where bail_id = b.id;
    select data into bo from pilotage.objets where type = 'LeasingContract' and id = b.id;
  end if;
  mois := case when coalesce(s.apport_direction, false) then 6 else 8 end;
  -- Loyer prévu : saisi au mandat, sinon loyers des baux en cours ; loyer réel : premier bail de chaque lot signé depuis le début du mandat
  loyer_prev := coalesce(s.loyer_prevu, (select sum(x.loyer_hc + x.charges) from pilotage.v_baux x join pilotage.v_lots l on l.id = x.lot_id
                 where l.mandat_id = p_mandat and x.statut in ('created', 'move_in', 'in_progress')));
  select sum(p.loyer), sum(p.hono) into loyer_reel, hono_loc_ttc from (
    select distinct on (x.lot_id) x.loyer_hc + x.charges loyer,
           round((coalesce((o.data->>'tenant_fees_in_cents')::numeric, 0) + coalesce((o.data->>'landlord_rental_fees_in_cents')::numeric, 0)) / 100, 2) hono
    from pilotage.v_baux x join pilotage.v_lots l on l.id = x.lot_id join pilotage.objets o on o.type = 'LeasingContract' and o.id = x.id
    where l.mandat_id = p_mandat and coalesce(x.signe_le, x.debut) >= m.debut
    order by x.lot_id, coalesce(x.signe_le, x.debut)) p;
  total_prev := round(coalesce(loyer_prev, loyer_reel) * m.taux_gestion_ttc / 100 / 1.2 * mois, 2);
  total_reel := case when loyer_reel is not null then round(loyer_reel * m.taux_gestion_ttc / 100 / 1.2 * mois, 2) end;
  v1 := round(total_prev * 0.50, 2);
  v2 := round(total_prev * 0.25, 2);
  v3 := case when total_reel is not null then total_reel - coalesce(v1, 0) - coalesce(v2, 0) end;
  loc := case when hono_loc_ttc is not null and bs.loue_par is not null then round(hono_loc_ttc / 1.2 * 0.40, 2) end;
  statut := case when s.retire_le is not null and b.id is null then 'Retiré sans location'
                 when b.id is not null then 'Loué'
                 when s.go_le is not null then 'Dossier complet validé'
                 else 'En cours' end;
  -- Ce qui manque
  if s.negociateur is null then manques := manques || '"Négociateur du mandat non attribué"'::jsonb; end if;
  if m.signe_le is null then manques := manques || '"Date de signature du mandat absente dans Rivage"'::jsonb; end if;
  if m.taux_gestion_ttc is null or m.taux_gestion_ttc = 0 then manques := manques || '"Taux de gestion absent ou à 0 % dans Rivage"'::jsonb; end if;
  if lots = 0 then manques := manques || '"Aucun lot rattaché au mandat dans Rivage"'::jsonb; end if;
  if loyer_prev is null and loyer_reel is null then manques := manques || '"Loyer prévu à saisir : commission non calculable"'::jsonb; end if;
  if s.go_le is null and statut <> 'Retiré sans location' and m.debut >= date '2026-01-01' then manques := manques || '"GO (dossier complet) non donné"'::jsonb; end if;
  if b.id is not null and s.go_le is null and m.debut >= date '2026-01-01' then manques := manques || '"Anomalie : bien loué sans GO"'::jsonb; end if;
  if b.id is not null and bs.valide_le is null then manques := manques || '"Bail de mise en location non validé"'::jsonb; end if;
  if b.id is not null and bs.loue_par is null then manques := manques || '"« Loué par » non renseigné sur le bail"'::jsonb; end if;
  return jsonb_build_object(
    'id', m.id, 'reference', m.reference, 'nom', m.nom, 'statut_rivage', m.statut, 'statut', statut,
    'debut', m.debut, 'fin', m.fin, 'signe_le', m.signe_le, 'taux_ttc', m.taux_gestion_ttc, 'lots', lots,
    'bailleur', pilotage.bailleurs_mandat(m.id),
    'suivi_commission', m.debut >= date '2026-01-01',
    'negociateur', s.negociateur, 'negociateur_prenom', (select prenom from pilotage.membres where user_id = s.negociateur),
    'apport_direction', coalesce(s.apport_direction, false), 'go_le', s.go_le, 'go_par', (select prenom from pilotage.membres where user_id = s.go_par),
    'retire_le', s.retire_le, 'note', s.note,
    'loyer_prev', loyer_prev, 'loyer_prevu_saisi', s.loyer_prevu, 'loyer_reel', loyer_reel, 'mois', mois,
    'honoraires_mois_ht', round(coalesce(loyer_reel, loyer_prev) * m.taux_gestion_ttc / 100 / 1.2, 2),
    'total_prev', total_prev, 'total_reel', total_reel,
    'bail', case when b.id is not null then jsonb_build_object('id', b.id, 'reference', b.reference, 'locataires', b.locataires, 'debut', b.debut,
              'signe_le', b.signe_le, 'loyer_cc', loyer_reel, 'honoraires_location_ttc', hono_loc_ttc,
              'loue_par', bs.loue_par, 'loue_par_prenom', (select prenom from pilotage.membres where user_id = bs.loue_par),
              'valide_le', bs.valide_le, 'valide_par', (select prenom from pilotage.membres where user_id = bs.valide_par),
              'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id) end,
    'versements', jsonb_build_array(
      jsonb_build_object('cle', 'v1', 'libelle', '1er versement mandat (50 %)', 'montant', v1, 'condition', 'À la signature du mandat' || coalesce(' le ' || to_char(m.signe_le, 'DD/MM/YYYY'), ''), 'du', m.signe_le is not null and s.negociateur is not null),
      jsonb_build_object('cle', 'v2', 'libelle', '2e versement mandat (25 %)', 'montant', v2, 'condition', case when s.go_le is not null then 'GO donné le ' || to_char(s.go_le, 'DD/MM/YYYY') else 'Au GO (dossier complet validé)' end, 'du', s.go_le is not null and s.negociateur is not null),
      jsonb_build_object('cle', 'v3', 'libelle', '3e versement mandat (25 % + ajustement au loyer réel)', 'montant', v3, 'condition', case when b.id is not null then 'Bail du ' || to_char(coalesce(b.signe_le, b.debut), 'DD/MM/YYYY') || ' · ' || coalesce(loyer_reel::text, '?') || ' € CC' else 'À la mise en location' end, 'du', b.id is not null and bs.valide_le is not null and s.negociateur is not null),
      jsonb_build_object('cle', 'loc', 'libelle', 'Mise en location (40 % des honoraires HT)', 'montant', loc, 'condition', case when b.id is null then 'À la première mise en location' when bs.loue_par is null then 'Renseigner qui a loué' else 'Honoraires de location ' || hono_loc_ttc || ' € TTC · loué par ' || coalesce((select prenom from pilotage.membres where user_id = bs.loue_par), '?') end, 'du', b.id is not null and bs.valide_le is not null and bs.loue_par is not null, 'beneficiaire', bs.loue_par)
    ),
    'factures', (select coalesce(jsonb_object_agg(f.versement, jsonb_build_object('facture', f.facture, 'le', f.le, 'montant', f.montant)), '{}'::jsonb) from pilotage.commissions_factures f where f.mandat_id = m.id),
    'manques', manques,
    'lien', 'https://rivage.immo/landlords/profiles/' || split_part(coalesce(m.proprietaires, ''), ', ', 1)
  );
end $$;

create or replace function public.pilotage_mandats() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'mandats', coalesce((select jsonb_agg(pilotage.dossier_mandat(m.id) order by m.debut desc nulls last) from pilotage.v_mandats m), '[]'::jsonb),
    'negociateurs', (select coalesce(jsonb_agg(jsonb_build_object('user_id', mb.user_id, 'prenom', mb.prenom, 'role', mb.role) order by mb.role <> 'negociateur', mb.prenom), '[]'::jsonb)
                     from pilotage.membres mb where mb.actif),
    'mon_role', pilotage.mon_role()
  );
end $$;

-- Saisie sur un mandat. Romain (superviseur) ne peut donner le GO que sur un dossier sans manque (règle fixée par Nicolas).
create or replace function public.pilotage_mandat_maj(p_mandat text, p_champ text, p_valeur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); d jsonb;
begin
  if r not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.v_mandats where id = p_mandat) then raise exception 'Mandat inconnu'; end if;
  insert into pilotage.mandats_suivi(mandat_id) values (p_mandat) on conflict do nothing;
  if p_champ = 'go' then
    if nullif(p_valeur, '') is not null and r = 'superviseur' then
      d := pilotage.dossier_mandat(p_mandat);
      if exists (select 1 from jsonb_array_elements_text(d->'manques') x where x not like 'GO%') then
        raise exception 'Dossier incomplet : seul Nicolas peut donner ce GO';
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

create or replace function public.pilotage_bail_maj(p_bail text, p_champ text, p_valeur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.objets where type = 'LeasingContract' and id = p_bail) then raise exception 'Bail inconnu'; end if;
  insert into pilotage.baux_suivi(bail_id) values (p_bail) on conflict do nothing;
  if p_champ = 'loue_par' then
    update pilotage.baux_suivi set loue_par = nullif(p_valeur, '')::uuid, maj_par = auth.uid(), maj_le = now() where bail_id = p_bail;
  elsif p_champ = 'valide' then
    update pilotage.baux_suivi set valide_le = nullif(p_valeur, '')::date, valide_par = case when nullif(p_valeur, '') is null then null else auth.uid() end,
      maj_par = auth.uid(), maj_le = now() where bail_id = p_bail;
  else raise exception 'Champ non modifiable'; end if;
end $$;

-- Facturation d'un versement par le négociateur (n° de sa facture)
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

-- Baux récents à valider (signés depuis le 01/01/2026), avec le mandat et le négociateur du mandat
create or replace function public.pilotage_baux_a_valider() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', b.id, 'reference', b.reference, 'statut', b.statut, 'locataires', b.locataires, 'debut', b.debut, 'signe_le', b.signe_le,
      'loyer_cc', b.loyer_hc + b.charges, 'adresse', l.adresse,
      'honoraires_location_ttc', round((coalesce((o.data->>'tenant_fees_in_cents')::numeric, 0) + coalesce((o.data->>'landlord_rental_fees_in_cents')::numeric, 0)) / 100, 2),
      'mandat_id', l.mandat_id, 'mandat', (select coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
      'bailleur', pilotage.bailleurs_mandat(l.mandat_id),
      'mise_en_location_du_mandat', pilotage.bail_location(l.mandat_id) = b.id,
      'loue_par', bs.loue_par, 'loue_par_prenom', (select prenom from pilotage.membres where user_id = bs.loue_par),
      'valide_le', bs.valide_le, 'valide_par', (select prenom from pilotage.membres where user_id = bs.valide_par),
      'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
    ) order by coalesce(b.signe_le, b.debut) desc)
    from pilotage.v_baux b join pilotage.objets o on o.type = 'LeasingContract' and o.id = b.id
    left join pilotage.v_lots l on l.id = b.lot_id left join pilotage.baux_suivi bs on bs.bail_id = b.id
    where coalesce(b.signe_le, b.debut) >= date '2026-01-01'), '[]'::jsonb);
end $$;

revoke all on function pilotage.bail_location(text), pilotage.dossier_mandat(text) from public, anon, authenticated;
revoke all on function public.pilotage_mandat_maj(text, text, text), public.pilotage_bail_maj(text, text, text),
  public.pilotage_commission_facturer(text, text, text, numeric), public.pilotage_baux_a_valider() from public, anon;
grant execute on function public.pilotage_mandat_maj(text, text, text), public.pilotage_bail_maj(text, text, text),
  public.pilotage_commission_facturer(text, text, text, numeric), public.pilotage_baux_a_valider() to authenticated;
