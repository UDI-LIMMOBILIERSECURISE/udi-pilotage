-- 122 : paiements lus dans la comptabilité Rivage
--  1. Factures : l'alerte « Facture à traiter » affiche en première ligne l'état du paiement trouvé en comptabilité
--     (virement au fournisseur passé, ordre de virement SEPA et son statut, fournisseur crédité sans ordre).
--     L'alerte ne se ferme toujours qu'au statut « Payée » de Rivage : un ordre de virement ne porte ni la facture
--     ni le fournisseur, le rapprochement par montant ne suffit pas à clore.
--  2. Dépôt de garantie détenu par le bailleur : un encaissement au compte du bailleur (411) du montant exact du dépôt,
--     ou une « provision conservée » du même montant, depuis la demande (sinon 90 jours avant le départ), est noté
--     automatiquement comme dépôt reçu (dg_suivi.recu_le, recu_compta = 'auto'). Plusieurs encaissements du même montant :
--     rien n'est noté, l'alerte de reversement signale « reçu probable, à confirmer ». Une date effacée à la main après
--     un relevé automatique n'est plus jamais remplie automatiquement (recu_compta = 'refuse').
--  Exemples du 03/11 : facture BRUREAU 202623 (1 040 €) créditée le 29/10, ordre SEPA « fichier généré », aucun virement
--  passé ; DG NEFYP IMMO bail 356 (4 280 €) encaissé le 30/10 (remise de chèques), provision conservée le 03/11.

alter table pilotage.dg_suivi add column if not exists recu_compta text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'dg_suivi_recu_compta_check') then
    alter table pilotage.dg_suivi add constraint dg_suivi_recu_compta_check check (recu_compta in ('auto', 'refuse'));
  end if;
end $$;

-- Encaissement du dépôt au compte du bailleur du bail
create or replace function pilotage.dg_recu_compta(p_bail text, p_depot numeric, p_depuis date)
returns table(le date, nature text, libelle text, nb_encaissements integer)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with cpt as (
    select distinct e.data->>'accounting_account_id' id
      from pilotage.objets e
      join pilotage.objets a on a.type = 'AccountingAccount' and a.id = e.data->>'accounting_account_id'
     where e.type = 'AccountingEntry' and e.supprime_le is null and e.data->>'leasing_contract_id' = p_bail
       and a.data->>'holder_type' = 'landlord' and a.data->>'general_number' = '411'),
  c as (
    select coalesce(nullif(e.data->>'accounting_transaction_operation_date', '')::date,
                    nullif(e.data->>'accounting_transaction_effective_date', '')::date) le,
           e.data->>'accounting_transaction_nature' nature, e.data->>'accounting_transaction_description' libelle
      from pilotage.objets e
     where e.type = 'AccountingEntry' and e.supprime_le is null
       and e.data->>'accounting_account_id' in (select id from cpt)
       and ((e.data->>'accounting_transaction_nature' = 'agency_pending_payin' and (e.data->>'credit_in_cents')::numeric = round(p_depot * 100))
         or (e.data->>'accounting_transaction_nature' = 'landlord_provision' and (e.data->>'debit_in_cents')::numeric = round(p_depot * 100))))
  select c.le, c.nature, c.libelle, (select count(*)::int from c where c.nature = 'agency_pending_payin' and c.le >= p_depuis)
    from c
   where coalesce(p_depot, 0) > 0 and c.le >= p_depuis
   order by (c.nature = 'agency_pending_payin') desc, c.le
   limit 1
$$;

-- Note pour l'alerte de reversement quand le rapprochement est ambigu
create or replace function pilotage.dg_recu_doute(p_bail text, p_depot numeric, p_depuis date)
returns text language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select ' Comptabilité Rivage : ' || r.nb_encaissements || ' encaissements de ' || pilotage.euros(p_depot)
         || ' au compte du bailleur depuis le ' || to_char(p_depuis, 'DD/MM/YYYY')
         || ' : reçu probable, à confirmer dans Sorties et DG.'
    from pilotage.dg_recu_compta(p_bail, p_depot, p_depuis) r
   where r.nb_encaissements > 1
$$;

-- Report automatique de la date de réception (appelé à chaque contrôle)
create or replace function pilotage.dg_recus_compta_maj()
returns integer language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare n integer := 0; d record; r record;
begin
  for d in select x.* from pilotage.dg_dossiers() x
            where x.detenu_par = 'bailleur' and x.recu_le is null and not x.remboursee
              and not exists (select 1 from pilotage.dg_suivi s where s.bail_id = x.bail_id and s.recu_compta = 'refuse') loop
    select * into r from pilotage.dg_recu_compta(d.bail_id, d.depot, coalesce(d.demande_le, d.depart - 90));
    if r.le is not null and r.nb_encaissements <= 1 then
      insert into pilotage.dg_suivi (bail_id, recu_le, recu_compta, maj_le) values (d.bail_id, r.le, 'auto', now())
      on conflict (bail_id) do update set recu_le = excluded.recu_le, recu_compta = 'auto', maj_le = now()
        where pilotage.dg_suivi.recu_le is null and pilotage.dg_suivi.recu_compta is distinct from 'refuse';
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- État du paiement d'une facture fournisseur dans la comptabilité Rivage
create or replace function pilotage.facture_paiement_texte(p_facture text)
returns text language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with f as (
    select o.data d, (o.data->>'amount_in_cents')::numeric cts, (o.data->>'created_at')::timestamptz::date cree,
           o.data->>'status' statut, pilotage.nom_profil(o.data->>'supplier_id') fournisseur
      from pilotage.objets o where o.type = 'Invoice' and o.id = p_facture),
  -- fournisseur crédité (écritures « Facture - réf - fournisseur - ligne »)
  cr as (
    select sum((select sum((e->>'debit_in_cents')::numeric) from jsonb_array_elements(x.data->'accounting_entries') e)) cts,
           min(nullif(x.data->>'effective_date', '')::date) le
      from f, pilotage.objets x
     where x.type = 'AccountingTransaction' and x.supprime_le is null and x.data->>'nature' = 'invoice_supplier_credited'
       and x.data->>'description' like 'Facture - ' || (f.d->>'reference') || ' - ' || f.fournisseur || ' - %'),
  -- virement passé au débit du compte fournisseur (401) pour le montant de la facture
  cpt as (
    select a.id from f, pilotage.objets a
     where a.type = 'AccountingAccount' and a.data->>'general_number' = '401' and a.data->>'description' = 'Fournisseurs - ' || f.fournisseur),
  pay as (
    select max(nullif(e.data->>'accounting_transaction_effective_date', '')::date) le, count(*) nb
      from f, pilotage.objets e
     where e.type = 'AccountingEntry' and e.supprime_le is null and e.data->>'accounting_account_id' in (select id from cpt)
       and e.data->>'accounting_transaction_nature' = 'agency_pending_payout'
       and (e.data->>'debit_in_cents')::numeric = f.cts
       and nullif(e.data->>'accounting_transaction_effective_date', '')::date >= f.cree),
  -- ordre de virement SEPA à un fournisseur du même montant, depuis la création de la facture
  po as (
    select p.data->>'status' st, nullif(p.data->>'due_date', '')::date le, count(*) over () nb
      from f, pilotage.objets p
     where p.type = 'PaymentOrder' and p.supprime_le is null and p.data->>'order_type' = 'sepa_credit'
       and p.data->>'counterparty_type' = 'supplier' and coalesce(p.data->>'status', '') <> 'archived'
       and (p.data->>'amount_in_cents')::numeric = f.cts
       and coalesce(nullif(p.data->>'due_date', '')::date, f.cree) >= f.cree - 1
     order by p.data->>'due_date' desc limit 1)
  select case
    when pay.nb > 0 then 'Paiement : virement de ' || pilotage.euros(f.cts / 100) || ' au fournisseur passé en comptabilité le ' || to_char(pay.le, 'DD/MM/YYYY')
                         || ', en attente du statut « Payée » dans Rivage'
    when po.st is not null then 'Paiement : ordre de virement SEPA de ' || pilotage.euros(f.cts / 100) || coalesce(' du ' || to_char(po.le, 'DD/MM/YYYY'), '') || ', '
                         || case po.st when 'pending' then 'à valider' when 'approved' then 'validé, fichier SEPA à générer'
                                       when 'sepa_file_created' then 'fichier SEPA généré : vérifier son dépôt à la banque' else po.st end
                         || case when po.nb > 1 then ' (' || po.nb || ' ordres du même montant, rapprochement à confirmer)' else '' end
    when cr.cts >= f.cts then 'Paiement : fournisseur crédité le ' || to_char(cr.le, 'DD/MM/YYYY') || ', aucun ordre de virement trouvé'
    when f.statut = 'to_pay' then 'Paiement : rien en comptabilité Rivage'
  end
  from f left join cr on true left join pay on true left join po on true
$$;

-- Alerte facture : état du paiement en tête de la première ligne
do $$
declare def text := pg_get_functiondef('pilotage.factures_detections'::regproc);
begin
  if position('facture_paiement_texte' in def) = 0 then
    if position($a$y.notes), ''$a$ in def) = 0 then raise exception '122 : ancre introuvable dans factures_detections'; end if;
    execute replace(def, $a$y.notes), ''$a$, $b$pilotage.facture_paiement_texte(y.id),
           y.notes), ''$b$);
  end if;
end $$;

-- Dépôt : relevé en comptabilité, note de doute, source affichée
do $$
declare def text := pg_get_functiondef('pilotage.suivi_detections_dg'::regproc);
        a1 text := $a$|| '. Restitution au locataire au plus tard le ' || to_char(d.limite, 'DD/MM/YYYY') || ' si l''état des lieux de sortie est conforme.'$a$;
        a2 text := $a$Délai : ' || to_char(d.limite, 'DD/MM/YYYY') || ' si l''état des lieux de sortie est conforme.'$a$;
begin
  if position('dg_recu_doute' in def) = 0 then
    if position(a1 in def) = 0 or position(a2 in def) = 0 then raise exception '122 : ancre introuvable dans suivi_detections_dg'; end if;
    def := replace(def, a1, a1 || $b$
           || coalesce(pilotage.dg_recu_doute(d.bail_id, d.depot, coalesce(d.demande_le, d.depart - 90)), '')$b$);
    def := replace(def, a2, a2 || $b$
           || case when (select s.recu_compta from pilotage.dg_suivi s where s.bail_id = d.bail_id) = 'auto'
                   then ' Réception relevée automatiquement dans la comptabilité Rivage (encaissement ou provision du montant du dépôt au compte du bailleur) : effacer la date dans Sorties et DG si ce n''est pas le dépôt.' else '' end$b$);
    execute def;
  end if;
end $$;

-- Effacer à la main une date relevée automatiquement : plus de relevé automatique pour ce bail
do $$
declare def text := pg_get_functiondef('public.pilotage_dg_maj'::regproc);
        a text := $a$    using auth.uid(), p_bail, p_valeur;$a$;
begin
  if position('recu_compta' in def) = 0 then
    if position(a in def) = 0 then raise exception '122 : ancre introuvable dans pilotage_dg_maj'; end if;
    execute replace(def, a, a || $b$
  if p_champ = 'recu_le' and nullif(p_valeur, '') is null then
    update pilotage.dg_suivi set recu_compta = 'refuse' where bail_id = p_bail and recu_compta = 'auto';
  end if;$b$);
  end if;
end $$;

-- Relevé à chaque contrôle, avant les détections
do $$
declare def text := pg_get_functiondef('pilotage.executer_controles'::regproc);
        a text := 'create temp table _det on commit drop as';
begin
  if position('dg_recus_compta_maj' in def) = 0 then
    if position(a in def) = 0 then raise exception '122 : ancre introuvable dans executer_controles'; end if;
    execute replace(def, a, 'perform pilotage.dg_recus_compta_maj();
  ' || a);
  end if;
end $$;

-- Contrôle immédiat
select pilotage.executer_controles();
select b.reference, s.recu_le, s.recu_compta from pilotage.dg_suivi s join pilotage.v_baux b on b.id = s.bail_id where s.recu_compta is not null;
