-- 103 — Factures à traiter : à qui la facture incombe et les notes Rivage qui en parlent, en tête de l'alerte (Nicolas, 30/10/2026).
-- Première ligne du détail (affichée sans ouvrir l'alerte dans Ma journée) : « À la charge du locataire / du bailleur » d'après
-- l'incident rapproché, puis les deux dernières notes Rivage sur l'incident, le lot ou le bail depuis la veille de la facture,
-- adressées à la comptable (@prénom) ou parlant de facture, refacturation, charge, imputation, retenue. Le reste du détail suit.
-- Ligne de facture sans libellé : « ligne sans libellé » (facture 1561). La règle n'est plus affichée sur ces alertes (appli).
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
           -- Notes Rivage sur l'incident, le lot ou le bail depuis la veille de la facture : adressées à la comptable,
           -- ou qui parlent de facture, de refacturation ou de charge (à qui facturer)
           (select string_agg('Note Rivage du ' || to_char(z.le at time zone 'Europe/Paris', 'DD/MM à HH24:MI') || ' : « ' || left(z.contenu, 300) || ' »', ' · ' order by z.le desc)
              from (select nullif(m.data->>'sent_at', '')::timestamptz le, m.data->>'content' contenu
                      from pilotage.objets m
                     where m.type = 'Message' and m.supprime_le is null and m.data->>'user_id' is not null
                       and m.data->>'messageable_id' in (x.incident_id, x.d->>'asset_id', x.d->>'leasing_contract_id')
                       and nullif(m.data->>'sent_at', '')::timestamptz >= x.cree - interval '1 day'
                       and (exists (select 1 from pilotage.membres c where c.actif and c.role = 'comptable' and m.data->>'content' ilike '%@' || c.prenom || '%')
                            or pilotage.sans_accents(lower(m.data->>'content')) ~ '(factur|a la charge|imput|retenir|deduire)')
                     order by 1 desc limit 2) z) notes
      from x left join pilotage.objets i on i.type = 'Incident' and i.id = x.incident_id)
  select 'facture_a_traiter'::text, 'Invoice'::text, y.id,
         'Facture à traiter : ' || coalesce(y.d->>'reference', 'sans référence') || ' · ' || coalesce(y.fournisseur, 'fournisseur ?') || ' · ' || coalesce(pilotage.euros(y.montant), '?')
           || case when y.echeance < current_date then ' · échéance dépassée' else '' end,
         -- Première ligne, toujours affichée dans Ma journée : à qui la facture incombe et les notes Rivage qui en parlent
         coalesce(nullif(concat_ws(' · ',
           case when y.inc is not null then
             case y.inc->>'charged_to' when 'tenant' then 'À la charge du locataire' when 'landlord' then 'À la charge du bailleur'
                  else 'Charge non indiquée' end
             || ' (incident n°' || coalesce(y.inc->>'number', '?') || ' « ' || coalesce(y.inc->>'title', '') || ' »)' end,
           y.notes), '') || E'\n', '')
         || concat_ws(' · ',
           'Référence ' || coalesce(y.d->>'reference', '—') || ' (à rechercher dans Rivage > Factures)',
           'émise le ' || to_char(y.emise, 'DD/MM/YYYY'),
           'échéance le ' || to_char(y.echeance, 'DD/MM/YYYY'),
           'statut Rivage : ' || case y.statut when 'pending' then 'à traiter' when 'validated' then 'validée' when 'to_pay' then 'à décaisser' else y.statut end,
           case y.d->>'payment_method' when 'landlord_withholding_payment' then 'paiement sur les fonds du bailleur' else 'paiement : ' || (y.d->>'payment_method') end,
           (select string_agg(coalesce(nullif(trim(v.l->>'label'), ''), 'ligne sans libellé') || ' ' || pilotage.euros((v.l->>'amount_in_cents')::numeric / 100)
                              || coalesce(' (TVA ' || trim_scale(nullif(v.l->>'vat_rate', '')::numeric)::text || ' %)', ''), ', ' order by v.n)
                    || case when jsonb_array_length(coalesce(y.d->'invoice_ventilation_lines', '[]'::jsonb)) > 3
                            then ' et ' || (jsonb_array_length(y.d->'invoice_ventilation_lines') - 3) || ' autre(s) ligne(s)' else '' end
              from jsonb_array_elements(coalesce(y.d->'invoice_ventilation_lines', '[]'::jsonb)) with ordinality v(l, n) where v.n <= 3),
           'lot ' || y.lot_ref || coalesce(', ' || y.adresse, ''),
           'bail ' || y.bail_ref || coalesce(' (' || y.locataires || ')', ''),
           case when y.lot_ref is null and y.bail_ref is null then 'facture sans lot ni bail dans Rivage' end,
           null),
         -- Rivage n'a pas d'adresse propre à une facture (elle s'ouvre en panneau sur la liste) : lien vers la liste des factures
         'https://rivage.immo/invoices'
    from y
$$;
revoke all on function pilotage.factures_detections() from public, anon, authenticated;

select pilotage.executer_controles();

commit;
