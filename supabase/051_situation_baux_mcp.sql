-- 051 : situation des baux lue par le MCP Rivage (outil lire_situation_bail), sans IA
-- Le MCP Rivage, ouvert par la même clé que l'API (RIVAGE_API_KEY), donne pour un bail des informations absentes des webhooks :
-- date de l'état des lieux de sortie, restitution du dépôt présente, arriéré en cours (statut, ouverture, durée),
-- solde du locataire (impayé ou trop-perçu), dernier appel de loyer. Vérifié le 19/10 sur le bail F0F973EF (Mercier).
-- Fonctionnement :
--   - chaque webhook de bail met le bail en file ; la fonction serveur pilotage-sync-rivage (mode « situations ») lit la file
--     toutes les 2 minutes, 40 baux au plus par passage, un appel toutes les 0,65 s (limite Rivage : 100 par minute) ;
--   - chaque matin, les baux en sortie, en impayé ou jamais lus sont remis en file (un encaissement ne déclenche pas
--     forcément de webhook sur le bail) ;
--   - après 3 échecs de suite, un bail sort de la file jusqu'au webhook suivant.
-- Effets : la date de sortie réelle (délais de restitution du dépôt) part de l'état des lieux de sortie quand Rivage le donne ;
-- la page des dépôts affiche le solde du locataire (trop-perçu à rendre, impayé à retenir).
-- À passer après le 050. Ne fait qu'appeler Rivage en lecture.

create table if not exists pilotage.baux_situation (
  bail_id text primary key,
  data jsonb,                       -- réponse de lire_situation_bail (lease.data, situation, move_out)
  lu_le timestamptz,
  demande_le timestamptz not null default now(),
  echecs integer not null default 0,
  erreur text
);
alter table pilotage.baux_situation enable row level security;
revoke all on pilotage.baux_situation from public, anon, authenticated;

-- Mise en file
create or replace function pilotage.situation_demander(p_bail text) returns void
language sql security definer set search_path = pilotage, public as $$
  insert into pilotage.baux_situation (bail_id, demande_le, echecs) values (p_bail, now(), 0)
  on conflict (bail_id) do update set demande_le = now(), echecs = 0
$$;

-- Webhook de bail : mise en file (ne bloque jamais l'enregistrement du webhook)
create or replace function pilotage.trg_webhook_situation() returns trigger
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if new.model_name = 'LeasingContract' and new.object_id like 'lc\_%' then
    begin perform pilotage.situation_demander(new.object_id);
    exception when others then raise warning 'situation bail non demandée : %', sqlerrm; end;
  end if;
  return null;
end $$;
drop trigger if exists pilotage_situation on public.rivage_webhook_events;
create trigger pilotage_situation after insert on public.rivage_webhook_events
  for each row execute function pilotage.trg_webhook_situation();

-- File à lire (appelée par la fonction serveur)
create or replace function public.pilotage_situations_a_lire(p_max integer default 40) returns text[]
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(array_agg(bail_id), '{}') from (
    select s.bail_id from pilotage.baux_situation s
    join pilotage.objets b on b.type = 'LeasingContract' and b.id = s.bail_id and b.supprime_le is null
    where (s.lu_le is null or s.demande_le > s.lu_le) and s.echecs < 3
    order by s.demande_le limit greatest(1, least(p_max, 80))) x
$$;

-- Résultat d'une lecture
create or replace function public.pilotage_situation_noter(p_bail text, p_data jsonb, p_erreur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if p_erreur is null then
    update pilotage.baux_situation set data = p_data, lu_le = now(), echecs = 0, erreur = null where bail_id = p_bail;
  else
    update pilotage.baux_situation set echecs = echecs + 1, erreur = left(p_erreur, 500) where bail_id = p_bail;
  end if;
end $$;

-- Fin d'un passage : signal aux écrans ouverts (050)
create or replace function public.pilotage_situations_signal() returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  perform realtime.send(jsonb_build_object('type', 'BailSituation'), 'rivage', 'pilotage', true);
exception when others then raise warning 'signal non envoyé : %', sqlerrm;
end $$;

revoke all on function public.pilotage_situations_a_lire(integer), public.pilotage_situation_noter(text, jsonb, text),
  public.pilotage_situations_signal() from public, anon, authenticated;
grant execute on function public.pilotage_situations_a_lire(integer), public.pilotage_situation_noter(text, jsonb, text),
  public.pilotage_situations_signal() to service_role;

-- Remise en file quotidienne : baux en sortie, en impayé, ou jamais lus
create or replace function pilotage.situations_quotidiennes() returns integer
language sql security definer set search_path = pilotage, public as $$
  with c as (
    select b.id from pilotage.v_baux b
    left join pilotage.baux_situation s on s.bail_id = b.id
    where s.bail_id is null or b.statut = 'move_out' or coalesce(b.impaye, 0) > 0
       or coalesce((s.data->'situation'->'current_arrear'->>'status'), '') = 'open'),
  i as (insert into pilotage.baux_situation (bail_id, demande_le, echecs) select id, now(), 0 from c
        on conflict (bail_id) do update set demande_le = now(), echecs = 0 returning 1)
  select count(*)::integer from i
$$;

-- Lecture compacte pour les écrans
create or replace function pilotage.situation_bail(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when s.data is null then null else jsonb_build_object(
    'lu_le', s.lu_le,
    'edl_sortie', nullif(s.data->'move_out'->>'move_out_inventory_date', '')::date,
    'restitution_presente', (s.data->'move_out'->>'refund_deposit_event_group_present')::boolean,
    'impaye', round(coalesce((s.data->'lease'->'data'->'unpaid_amount'->>'value_in_cents')::numeric, 0) / 100, 2),
    'trop_percu', round(coalesce((s.data->'lease'->'data'->'overpaid_amount'->>'value_in_cents')::numeric, 0) / 100, 2),
    'arriere_statut', s.data->'situation'->'current_arrear'->>'status',
    'arriere_depuis', nullif(s.data->'situation'->'current_arrear'->>'opened_at', '')::date,
    'arriere_jours', (s.data->'situation'->'current_arrear'->>'duration_days')::integer,
    'paiement', s.data->'situation'->>'rent_payment_status') end
  from pilotage.baux_situation s where s.bail_id = p_bail
$$;

-- Date de sortie réelle : l'état des lieux de sortie lu dans Rivage prime ; à défaut, la sortie de tous les locataires (046)
create or replace function pilotage.date_sortie_reelle(p_bail text) returns date
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(
    (select e from (select (pilotage.situation_bail(p_bail)->>'edl_sortie')::date e) z where e <= current_date),
    (select case when (x->>'tous_sortis')::boolean and (x->>'derniere_sortie')::date <= current_date then (x->>'derniere_sortie')::date end
       from (select pilotage.sortie_locataires(p_bail) x) y))
$$;

-- Page des dépôts : situation lue par le MCP (injection une seule fois)
do $$
declare def text;
begin
  def := pg_get_functiondef('public.pilotage_dg()'::regprocedure);
  if position('''situation'', pilotage.situation_bail' in def) > 0 then raise notice 'déjà fait'; return; end if;
  def := replace(def, $a$'sortie_reelle', pilotage.date_sortie_reelle(b.id),$a$,
                      $b$'sortie_reelle', pilotage.date_sortie_reelle(b.id), 'situation', pilotage.situation_bail(b.id),$b$);
  if position('''situation'', pilotage.situation_bail' in def) = 0 then raise exception 'pilotage_dg : point d''injection introuvable'; end if;
  execute def;
end $$;

-- Tâches planifiées : file toutes les 2 minutes (appel seulement s'il y a des baux à lire), remise en file chaque matin
select cron.unschedule(jobid) from cron.job where jobname in ('pilotage-situations-baux', 'pilotage-situations-quotidien');
select cron.schedule('pilotage-situations-baux', '*/2 * * * *', $c$
  select net.http_post(
    url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-sync-rivage',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
    body := '{"mode": "situations"}'::jsonb, timeout_milliseconds := 120000)
  where cardinality(public.pilotage_situations_a_lire(1)) > 0 $c$);
select cron.schedule('pilotage-situations-quotidien', '0 5 * * *', $c$ select pilotage.situations_quotidiennes() $c$);

-- Premier remplissage : tous les baux en file (lus par lots de 40 toutes les 2 minutes)
select pilotage.situations_quotidiennes() as baux_en_file;

-- Contrôle (dans quelques minutes) : baux lus, en attente, en échec
-- select count(*) filter (where lu_le is not null) lus, count(*) filter (where lu_le is null or demande_le > lu_le) en_attente,
--        count(*) filter (where echecs > 0) en_echec from pilotage.baux_situation;
