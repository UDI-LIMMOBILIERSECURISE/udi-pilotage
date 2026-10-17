-- 041 : lectures IA en échec et rythme de l'audit du stock
-- 1. Une lecture automatique qui échoue (réponse illisible, lien expiré, document refusé) est notée ; au 2e échec, le document
--    n'est plus retenté automatiquement : il apparaît dans l'onglet Reprise « lecture impossible », relançable à la main.
--    Avant ce script, un document illisible était relu (et payé) à chaque passage, sans fin.
-- 2. Audit du stock : 2 dossiers au plus par passage (1 bail + 1 mandat), un passage toutes les 5 minutes, et un plafond
--    quotidien de lectures (150 par défaut, réglable) pour que la dépense de chaque jour soit connue d'avance.
-- 3. Les champs Rivage vides sont nommés précisément (ex. « manque : date de signature »).
-- À passer après le 040. La fonction serveur pilotage-lecture-bail est redéployée ensuite par Claude (elle appelle la nouvelle fonction d'échec).

-- ========== 1. Échecs de lecture ==========
create table if not exists pilotage.lectures_echecs (
  cle text primary key,                -- identifiant du bail, du mandat, du document (upload) ou « commune:<nom normalisé> »
  nature text not null check (nature in ('bail', 'mandat', 'edl', 'justificatif', 'commune')),
  nb integer not null default 1,
  erreur text,
  premier_le timestamptz not null default now(),
  dernier_le timestamptz not null default now()
);
alter table pilotage.lectures_echecs enable row level security;
revoke all on pilotage.lectures_echecs from public, anon, authenticated;

create or replace function pilotage.lecture_bloquee(p_cle text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce((select nb >= 2 from pilotage.lectures_echecs where cle = p_cle), false)
$$;

-- Appelée par la fonction serveur (tâches planifiées seulement)
create or replace function public.pilotage_lecture_echec(p_cle text, p_nature text, p_erreur text) returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare k text := case when p_nature = 'commune' then 'commune:' || pilotage.norm_commune(p_cle) else p_cle end; n integer;
begin
  insert into pilotage.lectures_echecs (cle, nature, erreur) values (k, p_nature, left(p_erreur, 300))
  on conflict (cle) do update set nb = lectures_echecs.nb + 1, erreur = excluded.erreur, dernier_le = now()
  returning nb into n;
  return n;
end $$;

-- Une lecture réussie efface l'échec éventuel
create or replace function pilotage.trg_lecture_reussie() returns trigger
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if tg_table_name = 'baux_lectures' then delete from pilotage.lectures_echecs where cle = new.bail_id;
  else delete from pilotage.lectures_echecs where cle = new.upload_id; end if;
  return new;
end $$;
drop trigger if exists lecture_reussie on pilotage.baux_lectures;
create trigger lecture_reussie after insert on pilotage.baux_lectures for each row execute function pilotage.trg_lecture_reussie();
drop trigger if exists lecture_reussie on pilotage.edl_lectures;
create trigger lecture_reussie after insert on pilotage.edl_lectures for each row execute function pilotage.trg_lecture_reussie();

-- Relance à la main (Nicolas ou Romain) : efface le compteur, le document repart au prochain passage
create or replace function public.pilotage_lecture_relancer(p_cle text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Réservé à Nicolas et Romain'; end if;
  delete from pilotage.lectures_echecs where cle = p_cle;
end $$;

-- ========== 2. Les files de lecture ignorent les documents bloqués ==========
create or replace function public.pilotage_baux_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (
    select b.id from pilotage.v_baux b
    where b.statut in ('created','move_in','in_progress') and (b.fin is null or b.fin > current_date)
      and (pilotage.echeance_bail(b.id)->>'type') in ('commercial','derogatoire','professionnel')
      and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = b.id)
      and not pilotage.lecture_bloquee(b.id)
      and public.pilotage_lecture_source(b.id) is not null
    order by b.debut limit p_max) t
$$;

create or replace function public.pilotage_mandats_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (
    select m.id from pilotage.v_mandats m left join pilotage.mandats_suivi s on s.mandat_id = m.id
    where m.debut >= date '2026-01-01' and s.retire_le is null
      and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = m.id)
      and not pilotage.lecture_bloquee(m.id)
      and public.pilotage_mandat_source(m.id) is not null
    order by m.debut desc limit p_max) t
$$;

create or replace function public.pilotage_justificatifs_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('upload_id', j.upload_id, 'obligation_id', j.obligation_id, 'nature', o.nature, 'libelle', o.libelle,
             'categorie', pilotage.categorie_rivage(u.data->>'nature'), 'nom', u.data->>'label', 'url', u.data->>'file_url') x
    from pilotage.obligations_justificatifs j
    join pilotage.baux_obligations o on o.id = j.obligation_id
    join pilotage.objets u on u.type = 'Upload' and u.id = j.upload_id
    where j.lu_le is null and u.data->>'file_url' is not null
      and not pilotage.lecture_bloquee(j.upload_id)
    order by j.applique_le limit p_max) t
$$;

-- États des lieux et communes : ajout de la condition dans la définition en place (passée par le 037 et le 038)
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.pilotage_edl_a_lire(integer)'::regprocedure);
  if position('lecture_bloquee' in d) = 0 then
    n := replace(d, 'and not exists (select 1 from pilotage.edl_lectures l where l.upload_id = u.id)',
                    'and not exists (select 1 from pilotage.edl_lectures l where l.upload_id = u.id) and not pilotage.lecture_bloquee(u.id)');
    if n = d then raise exception '041 : condition introuvable dans pilotage_edl_a_lire'; end if;
    execute n;
  end if;
  d := pg_get_functiondef('public.pilotage_communes_a_rechercher(integer)'::regprocedure);
  if position('lecture_bloquee' in d) = 0 then
    n := replace(d, 'and not exists (select 1 from pilotage.permis_communes c where c.commune = pilotage.norm_commune(a.data->''address''->>''city''))',
                    'and not exists (select 1 from pilotage.permis_communes c where c.commune = pilotage.norm_commune(a.data->''address''->>''city''))
      and not pilotage.lecture_bloquee(''commune:'' || pilotage.norm_commune(a.data->''address''->>''city''))');
    if n = d then raise exception '041 : condition introuvable dans pilotage_communes_a_rechercher'; end if;
    execute n;
  end if;
end $$;

-- ========== 3. Rythme et plafond de l'audit ==========
insert into pilotage.parametres (cle, valeur) values ('audit_max_jour', '150') on conflict (cle) do nothing;

-- Lectures automatiques (baux et mandats) faites aujourd'hui, réussies ou en échec
create or replace function pilotage.audit_lectures_jour() returns integer
language sql stable security definer set search_path = pilotage, public as $$
  select ((select count(*) from pilotage.baux_lectures where par is null and (le at time zone 'Europe/Paris')::date = (now() at time zone 'Europe/Paris')::date)
        + (select count(*) from pilotage.lectures_echecs where nature in ('bail', 'mandat') and (dernier_le at time zone 'Europe/Paris')::date = (now() at time zone 'Europe/Paris')::date))::integer
$$;

create or replace function public.pilotage_audit_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when not pilotage.audit_actif()
              or pilotage.audit_lectures_jour() >= coalesce((select valeur::integer from pilotage.parametres where cle = 'audit_max_jour'), 150)
         then '[]'::jsonb else coalesce((select jsonb_agg(x) from (
    (select jsonb_build_object('type', 'bail', 'id', b.id) x from pilotage.v_baux b
      where b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > current_date)
        and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = b.id)
        and not pilotage.lecture_bloquee(b.id)
        and public.pilotage_lecture_source(b.id) is not null
      order by b.debut desc nulls last limit p_max)
    union all
    (select jsonb_build_object('type', 'mandat', 'id', m.id) from pilotage.objets m
      where m.type = 'ManagementContract' and m.supprime_le is null and m.data->>'status' = 'active'
        and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = m.id)
        and not pilotage.lecture_bloquee(m.id)
        and public.pilotage_mandat_source(m.id) is not null
      limit p_max)) t), '[]'::jsonb) end
$$;

create or replace function public.pilotage_audit_plafond(p_max integer) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Réservé à Nicolas'; end if;
  if p_max is null or p_max < 0 or p_max > 1000 then raise exception 'Plafond entre 0 et 1000 lectures par jour'; end if;
  insert into pilotage.parametres (cle, valeur) values ('audit_max_jour', p_max::text) on conflict (cle) do update set valeur = excluded.valeur;
end $$;

-- Écran Reprise : plafond, lectures du jour et documents en échec
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.pilotage_audit()'::regprocedure);
  if position('lectures_jour' in d) = 0 then
    n := replace(d, '''mandats_calcule_le'', (select max(calcule_le) from pilotage.mandats_cache));',
      '''mandats_calcule_le'', (select max(calcule_le) from pilotage.mandats_cache),
    ''plafond'', coalesce((select valeur::integer from pilotage.parametres where cle = ''audit_max_jour''), 150),
    ''lectures_jour'', pilotage.audit_lectures_jour(),
    ''echecs'', coalesce((select jsonb_agg(jsonb_build_object(''cle'', e.cle, ''nature'', e.nature, ''nb'', e.nb, ''erreur'', e.erreur, ''le'', e.dernier_le,
                  ''libelle'', case e.nature when ''bail'' then (select c.ligne->>''locataires'' || '' · '' || (c.ligne->>''adresse'') from pilotage.baux_cache c where c.bail_id = e.cle)
                                             when ''mandat'' then (select ''mandat n° '' || (m.data->>''reference'') || '' · '' || coalesce(pilotage.bailleurs_mandat(m.id), '''') from pilotage.objets m where m.id = e.cle)
                                             when ''commune'' then substr(e.cle, 9)
                                             else (select u.data->>''label'' from pilotage.objets u where u.type = ''Upload'' and u.id = e.cle) end)
                  order by e.dernier_le desc) from pilotage.lectures_echecs e where e.nb >= 2), ''[]''::jsonb));');
    if n = d then raise exception '041 : fin de pilotage_audit introuvable'; end if;
    execute n;
  end if;
end $$;

-- ========== 4. Champs Rivage vides : nommer exactement ce qui manque ==========
-- Avant : « Date de signature, début et fin du mandat » alors que seule la signature manquait (mandat DREZET, 17/10).
-- Après : « Date de signature, début et fin du mandat (manque : date de signature) ».
create or replace function pilotage.manque_rivage(p_detail text) returns text
language sql immutable as $$
  select string_agg(case trim(regexp_replace(x, '\s*—\s*$', ''))
                      when 'Signé le' then 'date de signature' when 'début' then 'date de début' when 'fin' then 'date de fin'
                      when 'prochaine le' then 'date de la prochaine échéance'
                      else lower(trim(regexp_replace(x, '\s*—\s*$', ''))) end, ', ')
  from regexp_split_to_table(split_part(p_detail, ' : non renseigné dans Rivage', 1), ',\s*') x
  where x like '%—%'
$$;

create or replace function pilotage.champs_vides(p_controle jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(i->>'libelle' || coalesce(' (manque : ' || pilotage.manque_rivage(i->>'detail') || ')', '') order by i->>'libelle'), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_controle->'items', '[]'::jsonb)) i
  where i->>'detail' like '% : non renseigné dans Rivage%'
$$;

-- Passage toutes les 5 minutes pendant l'audit (2 dossiers au plus par passage : la fonction serveur demande 1 bail + 1 mandat)
select cron.unschedule('pilotage-audit-lectures') where exists (select 1 from cron.job where jobname = 'pilotage-audit-lectures');
select cron.schedule('pilotage-audit-lectures', '*/5 * * * *', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-lecture-bail',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{"audit": true}'::jsonb, timeout_milliseconds := 300000) where pilotage.audit_actif() $$);

-- ========== Droits ==========
revoke all on function pilotage.lecture_bloquee(text), pilotage.audit_lectures_jour() from public, anon, authenticated;
revoke all on function public.pilotage_lecture_echec(text, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_lecture_echec(text, text, text) to service_role;
revoke all on function public.pilotage_baux_a_lire(integer), public.pilotage_mandats_a_lire(integer), public.pilotage_justificatifs_a_lire(integer),
  public.pilotage_audit_a_lire(integer) from public, anon, authenticated;
grant execute on function public.pilotage_baux_a_lire(integer), public.pilotage_mandats_a_lire(integer), public.pilotage_justificatifs_a_lire(integer),
  public.pilotage_audit_a_lire(integer) to service_role;
revoke all on function public.pilotage_lecture_relancer(text), public.pilotage_audit_plafond(integer) from public, anon;
grant execute on function public.pilotage_lecture_relancer(text), public.pilotage_audit_plafond(integer) to authenticated;

-- Contrôle : doit renvoyer 6 lignes à true
select 'table' t, to_regclass('pilotage.lectures_echecs') is not null ok
union all select 'edl', position('lecture_bloquee' in pg_get_functiondef('public.pilotage_edl_a_lire(integer)'::regprocedure)) > 0
union all select 'communes', position('lecture_bloquee' in pg_get_functiondef('public.pilotage_communes_a_rechercher(integer)'::regprocedure)) > 0
union all select 'audit', position('lectures_jour' in pg_get_functiondef('public.pilotage_audit()'::regprocedure)) > 0
union all select 'cron', exists (select 1 from cron.job where jobname = 'pilotage-audit-lectures' and schedule = '*/5 * * * *')
union all select 'libelle', pilotage.manque_rivage('Signé le —, début 08/10/2026, fin 08/10/2027 : non renseigné dans Rivage') = 'date de signature';
