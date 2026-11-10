-- 135 : assurance habitation du stock relancée 20 baux par jour, facturation lue dans Rivage, pagination par curseur (bloc unique)
--  Demandes de Nicolas du 10/11/2026 (« MRH étendue au stock », suite du 134).
--
--  1. Assurance habitation du stock. Jusqu'ici, le suivi « Attestation d'assurance » n'était ouvert que pour les baux nouveaux
--     (123) : 8 suivis sur 301 baux en cours le 10/11. Rivage donne, pour ces 301 baux : 181 attestations valables, 84 expirées,
--     1 sans date de fin, 35 baux sans attestation. Mesure du 10/11 sur les 293 baux du stock sans suivi (mandat actif) : 160 attestations
--     valables plus de 45 jours, 13 finissant d'ici le 19/12, 85 expirées (la plus ancienne au 31/12/2022), 35 absentes. Désormais, pour chaque bail en cours du stock (mandat actif, pas de suivi ouvert) :
--      - attestation valable plus de 45 jours : suivi ouvert d'un coup, échéance = sa date de fin dans Rivage ; aucune relance avant
--        45 jours de l'échéance (calendrier « assurance » des Règles de relance) ;
--      - attestation expirée, sans date, absente ou finissant dans les 45 jours : suivi ouvert 20 baux par jour ouvré (133 baux, soit 7 jours ouvrés) (paramètre
--        « assurance_stock_par_jour » de la règle « Suivi du bail : relance à faire », modifiable sans code), les plus anciennes
--        expirations d'abord ; échéance à J+45 pour que la relance commence le jour même par le 1er mail au locataire
--        (SMS à J+15, 2e mail à J+30, mise en demeure à J+46), ou la date de fin réelle si l'attestation est encore valable.
--     Les attestations déjà déposées dans Rivage sont rattachées au suivi à sa création : seule une attestation déposée ensuite
--     le fait avancer (sinon une attestation expirée, relue par la synchronisation, aurait été prise pour un renouvellement).
--     Passage chaque jour ouvré à 6 h 50 (heure de Paris en hiver).
--  2. Facturation : la synchronisation lit désormais les lignes (BillingLine, 3 167 dans Rivage) et les taux (BillingRate, 782)
--     de tous les baux, chaque semaine ; il n'y en avait que 282 et 34, reçus par webhook. Le contrôle des honoraires du 134 s'en sert.
--     Le mode de paiement de chaque locataire était déjà reçu (301 baux sur 301). Les mandats SEPA ne sont pas exposés par l'API
--     (/api/v1/sepa_mandates : 404).
--  3. Pagination : Rivage refuse la pagination par numéro de page à partir du 20/11/2026 (avertissement « DEPRECATED » dans chaque
--     réponse). La fonction pilotage-sync-rivage suit désormais le curseur (pagination=cursor, cursor=next_cursor) ; la reprise
--     d'une relecture interrompue transmet le curseur. À déployer APRÈS ce script (sinon la reprise perdrait le curseur et
--     relirait une liste depuis le début).
--  Rien n'est écrit dans Rivage.

-- 1. Assurance du stock
create table if not exists pilotage.assurance_stock (
  bail_id text primary key,
  mode text not null check (mode in ('valide', 'relance')),
  obligation_id bigint,
  fin_attestation date,
  cree_le timestamptz not null default now()
);
alter table pilotage.assurance_stock enable row level security;
revoke all on pilotage.assurance_stock from public, anon, authenticated;

update pilotage.regles set parametres = coalesce(parametres, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
    'nom', 'assurance_stock_par_jour', 'unite', 'baux', 'valeur', 20,
    'libelle', 'Assurance des baux du stock : nouveaux suivis mis en relance par jour ouvré'))
 where cle = 'bail_suivi'
   and not exists (select 1 from jsonb_array_elements(coalesce(parametres, '[]'::jsonb)) x where x->>'nom' = 'assurance_stock_par_jour');

create or replace function pilotage.assurance_stock_auto()
returns integer language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare quota integer; n integer := 0; x record; nid bigint;
begin
  -- attestations d'assurance déposées dans Rivage, par bail ou lot auquel elles sont rattachées (lues une fois : 53 000 pièces)
  drop table if exists _att;
  create temp table _att on commit drop as
    select u.id upload_id, rr->>'id' rid, nullif(u.data->>'expiration_date', '')::date fin
      from pilotage.objets u, jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr
     where u.type = 'Upload' and u.supprime_le is null and u.data->>'nature' = 'home_insurance_certificate';
  quota := greatest(0, pilotage.param('bail_suivi', 'assurance_stock_par_jour', 20)::integer
           - (select count(*) from pilotage.assurance_stock s where s.mode = 'relance' and s.cree_le::date = current_date)::integer);
  for x in
    with cand as (
      select b.id bail_id, b.lot_id,
             (select max(a.fin) from _att a where a.rid = b.id or (a.rid = b.lot_id and a.fin > b.debut)) fin
        from pilotage.v_baux b
        join pilotage.v_lots l on l.id = b.lot_id
        join pilotage.v_mandats m on m.id = l.mandat_id and m.statut in ('created', 'active')
       where b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > current_date)
         and not exists (select 1 from pilotage.baux_obligations o where o.bail_id = b.id and o.nature = 'assurance' and o.actif)
         and not exists (select 1 from pilotage.assurance_stock s where s.bail_id = b.id)
         and not pilotage.dossier_nouveau('LeasingContract', b.id)
    )
    select c.*, case when c.fin > current_date + 45 then 'valide' else 'relance' end mode
      from cand c
     order by (c.fin > current_date + 45) is true desc, coalesce(c.fin, date '1900-01-01'), c.bail_id
  loop
    if x.mode = 'relance' then
      exit when quota <= 0;
      quota := quota - 1;
    end if;
    insert into pilotage.baux_obligations (bail_id, nature, libelle, periodicite_mois, prochaine, derniere_le)
    values (x.bail_id, 'assurance', 'Attestation d’assurance', 12,
            case when x.fin > current_date then x.fin else current_date + 45 end, null)
    returning id into nid;
    -- attestations déjà déposées : rattachées, pour que seule une nouvelle attestation fasse avancer le suivi
    insert into pilotage.obligations_justificatifs (upload_id, obligation_id)
    select distinct a.upload_id, nid from _att a where a.rid in (x.bail_id, x.lot_id)
    on conflict do nothing;
    insert into pilotage.assurance_stock (bail_id, mode, obligation_id, fin_attestation) values (x.bail_id, x.mode, nid, x.fin);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function pilotage.assurance_stock_auto() from public, anon, authenticated;

select cron.schedule('pilotage-assurance-stock', '50 5 * * 1-5', $c$ select pilotage.assurance_stock_auto() $c$);

-- 3. Reprise d'une relecture interrompue : le curseur Rivage est transmis (fonction pilotage-sync-rivage à déployer ensuite)
create or replace function public.pilotage_sync_suite(p_depuis jsonb)
returns bigint language sql security definer set search_path to 'public', 'extensions' as $$
  select net.http_post(
    url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-sync-rivage',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
    body := jsonb_build_object('depuis', jsonb_build_object('modele', p_depuis->>'modele', 'page', (p_depuis->>'page')::int,
                                                             'curseur', p_depuis->>'curseur'),
                               'mode', coalesce(p_depuis->>'mode', 'complet')),
    timeout_milliseconds := 300000)
$$;

-- Premier passage : suivis des attestations valables, et les 20 premiers baux à relancer
select pilotage.assurance_stock_auto() as suivis_ouverts;
select mode, count(*) as baux, min(fin_attestation) as plus_ancienne, max(fin_attestation) as plus_recente
  from pilotage.assurance_stock group by mode order by mode;
