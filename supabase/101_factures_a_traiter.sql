-- 101 — Alerte « Facture à traiter » à la comptable dès qu'une facture fournisseur arrive de Rivage (Nicolas, 30/10/2026).
-- Ce que Rivage envoie, vérifié en base le 30/10 : chaque facture (Invoice) arrive par les notifications automatiques, avec
-- référence, fournisseur, montant, dates d'émission et d'échéance, lignes de ventilation, mode de paiement, lot et bail ;
-- statuts vus : pending (à valider), validated, to_pay. 5 factures au 30/10, toutes de la semaine. Aucune référence à l'incident :
-- l'incident est retrouvé par le lot et le fournisseur (intervenant de l'incident). Les notes Rivage (Message) sont reçues aussi :
-- sur l'incident n°33, « @Audrey GUILLON facture test à payer » (30/10, 10 h 51).
-- Règle : une facture au statut pending, validated ou to_pay ouvre l'alerte ; elle se ferme quand Rivage la passe à un autre statut
-- (payée, annulée...). Le détail reprend toute la facture, l'incident rapproché et la dernière note Rivage qui mentionne la comptable
-- (sur l'incident, le lot ou le bail, depuis la veille de la facture).
-- Lien : la page de l'incident rapproché, sinon celle du bail. L'adresse d'une facture dans Rivage n'est pas connue : dès qu'on
-- l'a, la renseigner dans le paramètre rivage_url_facture (ex. https://rivage.immo/invoices/) et le lien pointera sur la facture.
-- Retour arrière : update pilotage.regles set actif = false where cle = 'facture_a_traiter'.
-- Un seul bloc.

begin;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire)
values ('facture_a_traiter', 'Facture fournisseur à traiter', 'Mandat, compta, agence', 'haute', 'tache', true,
        'Nouvelle facture fournisseur reçue de Rivage (à valider ou à payer) : la traiter dans Rivage. Le détail reprend la facture, l''incident rapproché (même lot, même intervenant) et la dernière note Rivage adressée à la comptable. L''alerte se ferme quand Rivage passe la facture à un autre statut (payée, annulée).',
        '[]'::jsonb, 'compta')
on conflict (cle) do nothing;

insert into pilotage.parametres (cle, valeur) values ('rivage_url_facture', '') on conflict (cle) do nothing;

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
           'Émise le ' || to_char(y.emise, 'DD/MM/YYYY'),
           'échéance le ' || to_char(y.echeance, 'DD/MM/YYYY'),
           case y.statut when 'pending' then 'à valider dans Rivage' when 'validated' then 'validée, à mettre en paiement' when 'to_pay' then 'à payer' else y.statut end,
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
         coalesce(nullif((select valeur from pilotage.parametres where cle = 'rivage_url_facture'), '') || y.id,
                  'https://rivage.immo/incidents/' || y.incident_id,
                  'https://rivage.immo/leasing_contracts?leasing_contract_id=' || (y.d->>'leasing_contract_id'))
    from y
$$;
revoke all on function pilotage.factures_detections() from public, anon, authenticated;

do $do$
declare d text;
begin
  d := pg_get_functiondef('pilotage.executer_controles()'::regprocedure);
  if position('factures_detections' in d) = 0 then
    if position($r$select e.regle, e.objet_type, e.objet_id, e.titre, e.detail, e.lien from pilotage.etapes_detections() e;$r$ in d) = 0 then
      raise exception 'executer_controles : point d''insertion introuvable'; end if;
    d := replace(d, $r$select e.regle, e.objet_type, e.objet_id, e.titre, e.detail, e.lien from pilotage.etapes_detections() e;$r$,
      $r$select e.regle, e.objet_type, e.objet_id, e.titre, e.detail, e.lien from pilotage.etapes_detections() e
  union all
  select x.regle, x.objet_type, x.objet_id, x.titre, x.detail, x.lien from pilotage.factures_detections() x;$r$);
    execute d;
  end if;
end $do$;

select pilotage.executer_controles();

commit;

-- Vérification : alertes « Facture à traiter »
-- select statut, titre, detail, lien_rivage from pilotage.alertes where regle = 'facture_a_traiter' order by premiere_detection desc;
