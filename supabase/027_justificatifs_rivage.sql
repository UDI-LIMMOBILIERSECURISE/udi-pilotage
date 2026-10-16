-- 027 : justificatifs des suivis récurrents reconnus quand ils sont déposés dans Rivage (décision de Nicolas, 16/10/2026).
--   Un document déposé sur le bail ou son lot, dans la catégorie Rivage correspondant au suivi, vaut justificatif :
--   le suivi passe à l'échéance suivante, l'étape est inscrite au journal, les relances s'arrêtent.
--   Catégories relevées dans Rivage (écran « Ajouter un document ») le 16/10/2026.
--   Passage toutes les 30 minutes (tâche planifiée pilotage-justificatifs).

create table if not exists pilotage.obligations_categories (
  nature text not null, categorie text not null, filtre text,   -- filtre : expression régulière sur le libellé du suivi (sinon tous)
  primary key (nature, categorie)
);
insert into pilotage.obligations_categories (nature, categorie, filtre) values
  ('assurance', 'home_insurance_certificate', null),
  ('entretien', 'boiler_maintenance_certificate', 'chaudi|chauff|gaz|fioul|pompe|ballon'),
  ('entretien', 'maintenance_contracts', null),
  ('dpe', 'energy_performance_diagnosis', null),
  ('garantie', 'guarantee_act', null), ('garantie', 'guarantor_documents', null),
  ('caution', 'guarantee_act', null), ('caution', 'guarantor_documents', null),
  ('charges_regul', 'charges_regularisations', null)
on conflict (nature, categorie) do update set filtre = excluded.filtre;

-- Documents déjà utilisés comme justificatif (un document ne sert qu'une fois par suivi)
create table if not exists pilotage.obligations_justificatifs (
  upload_id text not null, obligation_id bigint not null, applique_le timestamptz not null default now(),
  primary key (upload_id, obligation_id)
);
alter table pilotage.obligations_categories enable row level security;
alter table pilotage.obligations_justificatifs enable row level security;
revoke all on pilotage.obligations_categories, pilotage.obligations_justificatifs from public, anon, authenticated;

create or replace function pilotage.appliquer_justificatifs() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare ob record; up record; n integer := 0; suivante date; d date;
begin
  for ob in
    select o.*, b.data->>'asset_id' as lot from pilotage.baux_obligations o
    join pilotage.objets b on b.type = 'LeasingContract' and b.id = o.bail_id
    where o.actif and exists (select 1 from pilotage.obligations_categories c where c.nature = o.nature)
  loop
    -- Document le plus ancien déposé depuis 4 mois avant l'échéance, pas encore utilisé pour ce suivi
    select u.id, u.data->>'nature' as categorie, u.maj_le::date as le into up
      from pilotage.objets u join pilotage.obligations_categories c on c.nature = ob.nature and c.categorie = u.data->>'nature'
     where u.type = 'Upload' and u.supprime_le is null
       and (c.filtre is null or pilotage.sans_accents(ob.libelle) ~ c.filtre)
       and u.maj_le::date >= ob.prochaine - 120
       and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr where rr->>'id' in (ob.bail_id, ob.lot))
       and not exists (select 1 from pilotage.obligations_justificatifs j where j.upload_id = u.id and j.obligation_id = ob.id)
     order by u.maj_le limit 1;
    continue when up.id is null;
    d := up.le;
    -- Échéance suivante : attestation, garantie, caution => échéance + périodicité ; entretien, régularisation => date du justificatif + périodicité ;
    -- DPE sans périodicité => 10 ans après le dépôt ; sans périodicité sinon => suivi clos.
    suivante := case
      when ob.nature in ('assurance', 'garantie', 'caution') and ob.periodicite_mois is not null then pilotage.ajouter_mois(ob.prochaine, ob.periodicite_mois)
      when ob.periodicite_mois is not null then pilotage.ajouter_mois(d, ob.periodicite_mois)
      when ob.nature = 'dpe' then pilotage.ajouter_mois(d, 120) end;
    insert into pilotage.obligations_justificatifs (upload_id, obligation_id) values (up.id, ob.id) on conflict do nothing;
    insert into pilotage.suivis_etapes (cle, etape, par, detail)
    values ('o:' || ob.id || ':' || ob.prochaine, 'realise', null,
            'Justificatif déposé dans Rivage le ' || to_char(d, 'DD/MM/YYYY') || ' (catégorie « ' || pilotage.categorie_rivage(up.categorie) || ' »)')
    on conflict (cle, etape) do nothing;
    update pilotage.baux_obligations set derniere_le = d, prochaine = coalesce(suivante, prochaine), actif = suivante is not null where id = ob.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Libellés des catégories utilisées par les suivis (complète 026)
create or replace function pilotage.categorie_rivage(t text) returns text language sql immutable as $$
  select coalesce((select l from (values ('lease_contract','Contrat de bail'),('amendment','Avenant'),('lease_renewal','Renouvellement de bail'),
    ('move_in_inventory','État des lieux d''entrée'),('energy_performance_diagnosis','DPE'),('natural_risks_and_pollution_state','État des risques et pollutions'),
    ('asbestos_diagnosis_private_parts','Diagnostic amiante'),('lead_exposure_risk_assessment','Constat plomb'),('internal_electricity_installations_state','État de l''installation électrique'),
    ('internal_gas_installations_state','État de l''installation gaz'),('habitable_surface_attestation','Attestation de surface habitable'),
    ('home_insurance_certificate','Attestation d''assurance habitation'),('guarantee_act','Acte de caution'),('guarantor_documents','Documents de caution'),
    ('management_mandate','Mandat de gestion'),('identity_document','Document d''identité'),('landlord_identity_and_residence_proof','Justificatif d''identité et de domicile'),
    ('property_title','Titre de propriété'),('property_ownership_certificate','Attestation de propriété foncière'),('property_tax','Taxe foncière'),
    ('landlord_bank_details','RIB du bailleur'),('property_insurance_contracts','Contrat d''assurance du bien'),
    ('boiler_maintenance_certificate','Attestation d''entretien de chaudière'),('maintenance_contracts','Contrats d''entretien'),
    ('charges_regularisations','Avis de régularisation de charges')) v(c, l) where c = t), t)
$$;

revoke all on all functions in schema pilotage from public, anon, authenticated;

-- Premier passage immédiat, puis toutes les 30 minutes
select pilotage.appliquer_justificatifs();
select cron.unschedule('pilotage-justificatifs') where exists (select 1 from cron.job where jobname = 'pilotage-justificatifs');
select cron.schedule('pilotage-justificatifs', '*/30 * * * *', $$ select pilotage.appliquer_justificatifs() $$);
