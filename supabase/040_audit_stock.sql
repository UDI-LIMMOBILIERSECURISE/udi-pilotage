-- 040 : audit du stock repris dans Rivage (méthode validée par Nicolas, 17/10/2026). À exécuter après 039.
--   À lancer par Nicolas (bouton de l'onglet « Reprise ») une fois la reprise Rivage terminée (GED comprise), visée au 01/11/2026.
--   Rien n'est envoyé aux équipes pendant l'audit : pas de blocage, pas de circuit de validation pour le stock.
--   1. Dossiers aveugles d'abord : baux en cours sans bail signé dans la GED, mandats actifs sans mandat signé.
--   2. Lecture IA de tous les baux, mandats et états des lieux présents (environ 20 par heure), croisement avec Rivage :
--      les écarts ressortent en rouge dans chaque dossier, les suivis se créent comme pour un dossier neuf.
--   3. Pièces manquantes comptées par nature, pour décider de la campagne de rattrapage.
--   4. Pièce introuvable : statut « introuvable », justifié, posé uniquement par Nicolas ou Romain (sinon le dossier resterait rouge à vie).

insert into pilotage.parametres (cle, valeur) values ('audit_stock', 'inactif') on conflict (cle) do nothing;

create or replace function pilotage.audit_actif() returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce((select valeur from pilotage.parametres where cle = 'audit_stock') = 'actif', false)
$$;

create or replace function public.pilotage_audit_lancer(p_actif boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Réservé à Nicolas'; end if;
  insert into pilotage.parametres (cle, valeur) values ('audit_stock', case when p_actif then 'actif' else 'inactif' end)
  on conflict (cle) do update set valeur = excluded.valeur;
  if p_actif then
    insert into pilotage.parametres (cle, valeur) values ('audit_stock_lance_le', now()::text)
    on conflict (cle) do update set valeur = excluded.valeur;
  end if;
end $$;

-- Cache des mandats (pièces manquantes, écarts) : l'audit lit ce cache plutôt que de recalculer chaque mandat à l'ouverture de l'écran
create table if not exists pilotage.mandats_cache (mandat_id text primary key, ligne jsonb not null, calcule_le timestamptz not null default now());
alter table pilotage.mandats_cache enable row level security;
revoke all on pilotage.mandats_cache from public, anon, authenticated;

create or replace function pilotage.ligne_audit(p_controle jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('restant', (p_controle->>'restant')::int, 'anomalies', (p_controle->>'anomalies')::int,
    'manquantes', coalesce((select jsonb_agg(i->>'cle') from jsonb_array_elements(coalesce(p_controle->'items', '[]'::jsonb)) i
                            where i->>'bloc' = 'pieces' and coalesce(i->>'statut', '') not in ('ok', 'sans_objet')), '[]'::jsonb),
    'ecarts', coalesce((select jsonb_agg(i->>'libelle') from jsonb_array_elements(coalesce(p_controle->'items', '[]'::jsonb)) i
                        where i->>'bloc' = 'rivage' and coalesce(i->>'statut', i->>'auto', '') = 'anomalie'), '[]'::jsonb),
    'lecture_le', p_controle->'lecture_le')
$$;

create or replace function pilotage.rafraichir_audit() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer := 0; r record;
begin
  for r in select m.id from pilotage.objets m where m.type = 'ManagementContract' and m.supprime_le is null and m.data->>'status' = 'active' loop
    insert into pilotage.mandats_cache (mandat_id, ligne, calcule_le) values (r.id, pilotage.ligne_audit(pilotage.controle_mandat(r.id)), now())
    on conflict (mandat_id) do update set ligne = excluded.ligne, calcule_le = now();
    n := n + 1;
  end loop;
  delete from pilotage.mandats_cache c where not exists (select 1 from pilotage.objets m where m.type = 'ManagementContract' and m.id = c.mandat_id and m.supprime_le is null and m.data->>'status' = 'active');
  return n;
end $$;

-- Les baux gardent leurs pièces manquantes dans le cache de la liste
do $do$
declare def text; n text;
begin
  def := pg_get_functiondef('pilotage.ligne_bail(text)'::regprocedure);
  if position('ligne_audit' in def) > 0 then return; end if;
  n := replace(def, $o$'force', (pilotage.forcage_actif('bail', b.id)).id is not null)$o$,
                    $r$'force', (pilotage.forcage_actif('bail', b.id)).id is not null, 'audit', pilotage.ligne_audit(c))$r$);
  if n = def then raise exception '040 : point d''insertion introuvable dans ligne_bail (le 036 est-il passé ?)'; end if;
  execute n;
end $do$;

-- Lectures de l'audit : tous les baux en cours et tous les mandats actifs qui ont leur document dans Rivage et pas encore de lecture
create or replace function public.pilotage_audit_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when not pilotage.audit_actif() then '[]'::jsonb else coalesce((select jsonb_agg(x) from (
    (select jsonb_build_object('type', 'bail', 'id', b.id) x from pilotage.v_baux b
      where b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > current_date)
        and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = b.id)
        and public.pilotage_lecture_source(b.id) is not null
      order by b.debut desc nulls last limit p_max)
    union all
    (select jsonb_build_object('type', 'mandat', 'id', m.id) from pilotage.objets m
      where m.type = 'ManagementContract' and m.supprime_le is null and m.data->>'status' = 'active'
        and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = m.id)
        and public.pilotage_mandat_source(m.id) is not null
      limit p_max)) t), '[]'::jsonb) end
$$;

-- Écran de la reprise
create or replace function public.pilotage_audit() returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Réservé à Nicolas et Romain'; end if;
  perform pilotage.rafraichir_baux('30 minutes');
  return jsonb_build_object(
    'actif', pilotage.audit_actif(),
    'lance_le', (select valeur from pilotage.parametres where cle = 'audit_stock_lance_le'),
    'baux', jsonb_build_object(
      'total', (select count(*) from pilotage.baux_cache),
      'lus', (select count(*) from pilotage.baux_cache c where exists (select 1 from pilotage.baux_lectures l where l.bail_id = c.bail_id)),
      'avec_ecarts', (select count(*) from pilotage.baux_cache c where jsonb_array_length(coalesce(c.ligne->'controle'->'audit'->'ecarts', '[]'::jsonb)) > 0),
      'aveugles', coalesce((select jsonb_agg(jsonb_build_object('id', c.bail_id, 'reference', c.ligne->>'reference', 'locataires', c.ligne->>'locataires',
                    'adresse', c.ligne->>'adresse', 'bailleur', c.ligne->>'bailleur', 'type', c.ligne->'echeance'->>'type', 'lien', c.ligne->>'lien',
                    'introuvable', exists (select 1 from pilotage.baux_reponses r where r.bail_id = c.bail_id and r.cle in ('c_doc_bail', 'h_doc_bail') and r.suivi = 'introuvable'))
                    order by c.ligne->>'adresse')
                  from pilotage.baux_cache c where public.pilotage_lecture_source(c.bail_id) is null), '[]'::jsonb)),
    'mandats', jsonb_build_object(
      'total', (select count(*) from pilotage.objets m where m.type = 'ManagementContract' and m.supprime_le is null and m.data->>'status' = 'active'),
      'lus', (select count(*) from pilotage.objets m where m.type = 'ManagementContract' and m.supprime_le is null and m.data->>'status' = 'active'
                and exists (select 1 from pilotage.baux_lectures l where l.bail_id = m.id)),
      'avec_ecarts', (select count(*) from pilotage.mandats_cache c where jsonb_array_length(coalesce(c.ligne->'ecarts', '[]'::jsonb)) > 0),
      'aveugles', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'reference', m.data->>'reference', 'nom', m.data->>'name', 'bailleur', pilotage.bailleurs_mandat(m.id),
                    'introuvable', exists (select 1 from pilotage.baux_reponses r where r.bail_id = m.id and r.cle = 'm_doc_mandat' and r.suivi = 'introuvable'))
                    order by pilotage.bailleurs_mandat(m.id))
                  from pilotage.objets m where m.type = 'ManagementContract' and m.supprime_le is null and m.data->>'status' = 'active'
                    and public.pilotage_mandat_source(m.id) is null), '[]'::jsonb)),
    'edl', jsonb_build_object('lus', (select count(*) from pilotage.edl_lectures),
                              'propositions', (select count(*) from pilotage.lots_propositions where statut = 'propose')),
    'pieces', coalesce((select jsonb_agg(jsonb_build_object('cle', x.cle, 'libelle', q.libelle, 'portee', q.portee, 'n', x.n) order by x.n desc)
                from (select v cle, count(*) n from (
                        select jsonb_array_elements_text(coalesce(c.ligne->'controle'->'audit'->'manquantes', '[]'::jsonb)) v from pilotage.baux_cache c
                        union all
                        select jsonb_array_elements_text(coalesce(c.ligne->'manquantes', '[]'::jsonb)) from pilotage.mandats_cache c) y group by v) x
                join pilotage.controle_questions q on q.cle = x.cle), '[]'::jsonb),
    'mandats_calcule_le', (select max(calcule_le) from pilotage.mandats_cache));
end $$;

-- Pièce introuvable (Nicolas ou Romain) : justifiée, elle sort des pièces manquantes ; « Revenir » la remet en manquante
create or replace function public.pilotage_piece_introuvable(p_dossier text, p_cle text, p_justification text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_forcer() then raise exception 'Seuls Nicolas et Romain peuvent déclarer une pièce introuvable'; end if;
  if length(trim(coalesce(p_justification, ''))) < 10 then raise exception 'Justification obligatoire (10 caractères au moins)'; end if;
  if not exists (select 1 from pilotage.controle_questions where cle = p_cle and mode = 'document') then raise exception 'Pièce inconnue'; end if;
  insert into pilotage.baux_reponses (bail_id, cle, statut, suivi, valeur, commentaire, par)
  values (p_dossier, p_cle, 'sans_objet', 'introuvable', null, 'Introuvable : ' || trim(p_justification), auth.uid())
  on conflict (bail_id, cle) do update set statut = 'sans_objet', suivi = 'introuvable', valeur = null, commentaire = excluded.commentaire, par = auth.uid(), le = now();
  if p_dossier like 'lc\_%' then perform public.pilotage_bail_rafraichir(p_dossier); end if;
end $$;

-- Lectures de l'audit toutes les 10 minutes (3 baux et 3 mandats au plus) ; cache des mandats toutes les heures
select cron.unschedule('pilotage-audit-lectures') where exists (select 1 from cron.job where jobname = 'pilotage-audit-lectures');
select cron.schedule('pilotage-audit-lectures', '*/10 * * * *', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-lecture-bail',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{"audit": true}'::jsonb, timeout_milliseconds := 300000) where pilotage.audit_actif() $$);
select cron.unschedule('pilotage-cache-mandats') where exists (select 1 from cron.job where jobname = 'pilotage-cache-mandats');
select cron.schedule('pilotage-cache-mandats', '55 * * * *', $$ select pilotage.rafraichir_audit() $$);

revoke all on all functions in schema pilotage from public, anon, authenticated;
revoke all on function public.pilotage_audit_a_lire(integer) from public, anon, authenticated;
revoke all on function public.pilotage_audit_lancer(boolean), public.pilotage_audit(), public.pilotage_piece_introuvable(text, text, text) from public, anon;
grant execute on function public.pilotage_audit_lancer(boolean), public.pilotage_audit(), public.pilotage_piece_introuvable(text, text, text) to authenticated;

select pilotage.rafraichir_baux();
select pilotage.rafraichir_audit();
