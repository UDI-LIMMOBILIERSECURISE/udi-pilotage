-- 102 — Factures à traiter : lien vers la liste des factures de Rivage, statuts au vocabulaire de Rivage (Nicolas, 30/10/2026).
-- Vérifié dans Rivage le 30/10 (Chrome) : une facture s'ouvre en panneau latéral sur https://rivage.immo/invoices, sans adresse
-- propre (ni /invoices/<id>, ni ?invoice_id=). Le lien de l'alerte ouvre donc la liste des factures ; la référence est rappelée
-- dans le détail pour la retrouver. Statuts affichés par Rivage : À traiter (pending), Validée (validated), À décaisser (to_pay),
-- Payée (paid). Le paramètre rivage_url_facture du 101 est supprimé.
-- Ma journée (appli) : filtre par type d'alerte sous les catégories (ex. « Facture fournisseur à traiter »).
-- Un seul bloc.

begin;

create or replace function pilotage.factures_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  with f as (
    select o.id, o.data d, (o.data->>'created_at')::timestamptz cree,
           nullif(o.data->>'due_date', '')::date echeance, nullif(o.data->>'emission_date', '')::date emise,
           (o.data->>'amount_in_cents')::numeric / 100 montant, o.data->>'status' statut
      from pilotage.objets o
     where o.type = 'Invoice' and o.supprime_le is null and o.data->>'status' in ('pending', 'validated', 'to_pay')),
  x as (
    select f.*, pilotage.nom_profil(f.d->>'supplier_id') fournisseur, l.reference lot_ref, l.adresse,
           b.reference bail_ref, b.locataires,
           -- Incident du même lot : d'abord celui où le fournisseur intervient, sinon le plus récent encore ouvert
           (select i.id from pilotage.objets i
             where i.type = 'Incident' and i.supprime_le is null and i.data->>'asset_id' = f.d->>'asset_id'
             order by (i.data->'contractor_ids' ? (f.d->>'supplier_id')
                       or exists (select 1 from jsonb_array_elements(coalesce(i.data->'interventions', '[]'::jsonb)) iv where iv->>'contractor_id' = f.d->>'supplier_id')) desc,
                      (i.data->>'archived_at') is null and coalesce(i.data->>'status', '') not in ('resolved', 'closed', 'cancelled') desc,
                      i.maj_le desc limit 1) incident_id
      from f
      left join pilotage.v_lots l on l.id = f.d->>'asset_id'
      left join pilotage.v_baux b on b.id = f.d->>'leasing_contract_id'),
  y as (
    select x.*, i.data inc,
           (select m.data from pilotage.objets m
             where m.type = 'Message' and m.supprime_le is null
               and m.data->>'messageable_id' in (x.incident_id, x.d->>'asset_id', x.d->>'leasing_contract_id')
               and nullif(m.data->>'sent_at', '')::timestamptz >= x.cree - interval '1 day'
               and exists (select 1 from pilotage.membres c where c.actif and c.role = 'comptable'
                            and m.data->>'content' ilike '%@' || c.prenom || '%')
             order by nullif(m.data->>'sent_at', '')::timestamptz desc limit 1) note
      from x left join pilotage.objets i on i.type = 'Incident' and i.id = x.incident_id)
  select 'facture_a_traiter'::text, 'Invoice'::text, y.id,
         'Facture à traiter : ' || coalesce(y.d->>'reference', 'sans référence') || ' · ' || coalesce(y.fournisseur, 'fournisseur ?') || ' · ' || coalesce(pilotage.euros(y.montant), '?')
           || case when y.echeance < current_date then ' · échéance dépassée' else '' end,
         concat_ws(' · ',
           'Référence ' || coalesce(y.d->>'reference', '—') || ' (à rechercher dans Rivage > Factures)',
           'émise le ' || to_char(y.emise, 'DD/MM/YYYY'),
           'échéance le ' || to_char(y.echeance, 'DD/MM/YYYY'),
           'statut Rivage : ' || case y.statut when 'pending' then 'à traiter' when 'validated' then 'validée' when 'to_pay' then 'à décaisser' else y.statut end,
           case y.d->>'payment_method' when 'landlord_withholding_payment' then 'paiement sur les fonds du bailleur' else 'paiement : ' || (y.d->>'payment_method') end,
           (select string_agg(coalesce(v.l->>'label', 'ligne') || ' ' || pilotage.euros((v.l->>'amount_in_cents')::numeric / 100)
                              || coalesce(' (TVA ' || trim_scale(nullif(v.l->>'vat_rate', '')::numeric)::text || ' %)', ''), ', ' order by v.n)
                    || case when jsonb_array_length(coalesce(y.d->'invoice_ventilation_lines', '[]'::jsonb)) > 3
                            then ' et ' || (jsonb_array_length(y.d->'invoice_ventilation_lines') - 3) || ' autre(s) ligne(s)' else '' end
              from jsonb_array_elements(coalesce(y.d->'invoice_ventilation_lines', '[]'::jsonb)) with ordinality v(l, n) where v.n <= 3),
           'lot ' || y.lot_ref || coalesce(', ' || y.adresse, ''),
           'bail ' || y.bail_ref || coalesce(' (' || y.locataires || ')', ''),
           case when y.lot_ref is null and y.bail_ref is null then 'facture sans lot ni bail dans Rivage' end,
           case when y.inc is not null then 'incident n°' || coalesce(y.inc->>'number', '?') || ' « ' || coalesce(y.inc->>'title', '') || ' »'
             || case y.inc->>'charged_to' when 'tenant' then ', à la charge du locataire' when 'landlord' then ', à la charge du bailleur' else '' end end,
           case when y.note is not null then 'note Rivage du ' || to_char(nullif(y.note->>'sent_at', '')::timestamptz at time zone 'Europe/Paris', 'DD/MM à HH24:MI') || ' : « ' || left(y.note->>'content', 300) || ' »' end),
         -- Rivage n'a pas d'adresse propre à une facture (elle s'ouvre en panneau sur la liste) : lien vers la liste des factures
         'https://rivage.immo/invoices'
    from y
$$;
revoke all on function pilotage.factures_detections() from public, anon, authenticated;

delete from pilotage.parametres where cle = 'rivage_url_facture';

select pilotage.executer_controles();

commit;
