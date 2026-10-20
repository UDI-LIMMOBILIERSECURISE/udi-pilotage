-- 060 : contrôle d'entrée des baux, retours de Nicolas du 20/10/2026
--   1. Lecture IA du bail et du mandat dès leur arrivée de Rivage, une seule fois (et seulement ces deux documents).
--      Tout bail ou mandat arrivé après le départ du contrôle est lu dans les 5 minutes (le plus récent d'abord),
--      le résultat est enregistré et comparé à Rivage ; un dossier déjà lu n'est jamais relu automatiquement
--      (seul le bouton « Lire » de la fiche relance une lecture). Sans lecture, le croisement avec Rivage
--      restait « à confirmer : non vérifié dans le bail ».
--   2. DPE : repris de Rivage (classe et fin de validité du diagnostic du lot) au lieu d'être demandé.
--      Anomalie si le DPE est expiré à la signature, ou logement classé G pour un bail d'habitation signé depuis 2025.
--   (L'âge du locataire était déjà calculé depuis Rivage : seul l'écran le redemandait, corrigé dans l'appli.)

do $$
declare
  rempl jsonb := '[
    ["pilotage.controle_bail(text)", "    elsif q.mode = ''fiche'' then", "    elsif q.cle in (''h_cl_dpe'', ''c_cl_dpe'') and nullif((select a.data->''energy_diagnostic''->>''expiry_date'' from pilotage.objets a where a.type = ''Asset'' and a.id = o->>''asset_id''), '''') is not null then\r\n      -- 060 : DPE repris de Rivage (diagnostic du lot)\r\n      select ''Rivage : classe '' || coalesce(z.ed->>''overall_class'', z.ed->>''energy_class'', ''?'') || '', valable jusqu''''au '' || to_char((z.ed->>''expiry_date'')::date, ''DD/MM/YYYY''),\r\n             case when (z.ed->>''expiry_date'')::date < coalesce(nullif(o->>''signed_at'', '''')::date, nullif(o->>''start_date'', '''')::date, current_date) then ''anomalie''\r\n                  when v_portee = ''habitation'' and coalesce(z.ed->>''overall_class'', z.ed->>''energy_class'') = ''G''\r\n                       and coalesce(nullif(o->>''signed_at'', '''')::date, nullif(o->>''start_date'', '''')::date, current_date) >= date ''2025-01-01'' then ''anomalie''\r\n                  else ''ok'' end\r\n        into detail, auto\r\n        from (select a.data->''energy_diagnostic'' ed from pilotage.objets a where a.type = ''Asset'' and a.id = o->>''asset_id'') z;\r\n      if auto = ''anomalie'' then detail := detail || '' : DPE expiré à la signature du bail, ou logement classé G (interdit à la location depuis 2025)''; end if;\r\n    elsif q.mode = ''fiche'' then", 1]
  ]';
  fns text[]; f text; def text; x jsonb; n int;
begin
  select array_agg(distinct e->>0) into fns from jsonb_array_elements(rempl) e;
  foreach f in array fns loop
    def := pg_get_functiondef(f::regprocedure);
    for x in select e from jsonb_array_elements(rempl) e where e->>0 = f loop
      n := (length(def) - length(replace(def, x->>1, ''))) / length(x->>1);
      if n <> (x->>3)::int then raise exception 'Code inattendu dans % : « % » trouvé % fois au lieu de %', f, x->>1, n, x->>3; end if;
      def := replace(def, x->>1, x->>2);
    end loop;
    execute def;
  end loop;
end $$;

-- 3. Attribution d'un dossier par une liste déroulante : un commercial, la gestion ou la direction choisit le commercial
--    (remplace « Je le prends »). La liste des commerciaux est renvoyée avec les dossiers.
drop function if exists public.pilotage_dossier_prendre(text, text);
create or replace function public.pilotage_dossier_prendre(p_objet text, p_id text, p_user uuid default null) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare actuel uuid; cible uuid := coalesce(p_user, auth.uid());
begin
  if pilotage.mon_role() not in ('negociateur', 'direction', 'superviseur', 'gestionnaire') then raise exception 'Attribution non autorisée'; end if;
  if not exists (select 1 from pilotage.membres where user_id = cible and actif and role in ('negociateur', 'direction', 'superviseur')) then
    raise exception 'Choisir un commercial de l''équipe'; end if;
  actuel := pilotage.commercial_dossier(p_objet, p_id);
  if actuel is not null then raise exception 'Ce dossier est déjà attribué à %', pilotage.prenom_membre(actuel); end if;
  if p_objet = 'mandat' then
    if not exists (select 1 from pilotage.objets where type = 'ManagementContract' and id = p_id and supprime_le is null) then raise exception 'Mandat inconnu'; end if;
    insert into pilotage.mandats_suivi (mandat_id, negociateur, maj_par, maj_le) values (p_id, cible, auth.uid(), now())
    on conflict (mandat_id) do update set negociateur = cible, maj_par = auth.uid(), maj_le = now() where pilotage.mandats_suivi.negociateur is null;
  elsif p_objet = 'bail' then
    if not exists (select 1 from pilotage.objets where type = 'LeasingContract' and id = p_id and supprime_le is null) then raise exception 'Bail inconnu'; end if;
    insert into pilotage.baux_suivi (bail_id, loue_par, maj_par, maj_le) values (p_id, cible, auth.uid(), now())
    on conflict (bail_id) do update set loue_par = cible, maj_par = auth.uid(), maj_le = now() where pilotage.baux_suivi.loue_par is null;
    update pilotage.baux_cache set ligne = jsonb_set(ligne, '{commercial}', to_jsonb(cible::text)) where bail_id = p_id;
  else raise exception 'Objet inconnu'; end if;
end $$;
revoke all on function public.pilotage_dossier_prendre(text, text, uuid) from public, anon;
grant execute on function public.pilotage_dossier_prendre(text, text, uuid) to authenticated;

do $$
declare def text := pg_get_functiondef('public.pilotage_mes_dossiers()'::regprocedure);
  ancien text := 'return jsonb_build_object(''role'', r, ''gestion'', gestion, ''lecture'', r = ''comptable'', ''dossiers'', res);';
begin
  if position(ancien in def) = 0 then raise exception 'Code inattendu dans pilotage_mes_dossiers (script 059 passé ?)'; end if;
  execute replace(def, ancien, 'return jsonb_build_object(''role'', r, ''gestion'', gestion, ''lecture'', r = ''comptable'', ''dossiers'', res, ''moi'', moi,
    ''peut_attribuer'', r in (''negociateur'', ''direction'', ''superviseur'', ''gestionnaire''),
    ''commerciaux'', (select coalesce(jsonb_agg(jsonb_build_object(''id'', mb.user_id, ''prenom'', mb.prenom) order by mb.role <> ''negociateur'', mb.prenom), ''[]''::jsonb)
                    from pilotage.membres mb where mb.actif and mb.role in (''negociateur'', ''direction'', ''superviseur'')));');
end $$;

-- 1. Baux et mandats à lire : ceux arrivés de Rivage après le départ du contrôle (pilotage.objets.recu_le), les plus récents d'abord.
--    « Une seule fois » : un bail ou un mandat déjà lu (baux_lectures) n'est plus proposé.
--    Un document en échec répété est bloqué (lecture_bloquee) au lieu d'être relu en boucle.
create or replace function pilotage.upload_recent(p_upload text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce((select u.recu_le >= (select valeur::date from pilotage.parametres where cle = 'controle_entree_depuis')
                     from pilotage.objets u where u.type = 'Upload' and u.id = p_upload), false)
$$;

create or replace function public.pilotage_baux_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (
    select b.id, (select u.recu_le from pilotage.objets u where u.type = 'Upload' and u.id = public.pilotage_lecture_source(b.id)->>'upload_id') recu
    from pilotage.v_baux b
    where b.statut in ('created','move_in','in_progress') and (b.fin is null or b.fin > current_date)
      and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = b.id)
      and not pilotage.lecture_bloquee(b.id)
      and public.pilotage_lecture_source(b.id) is not null
      and ((pilotage.echeance_bail(b.id)->>'type') in ('commercial','derogatoire','professionnel')
           or pilotage.bail_soumis(b.id)
           or pilotage.upload_recent(public.pilotage_lecture_source(b.id)->>'upload_id'))
    order by recu desc nulls last, b.debut desc limit p_max) t
$$;

create or replace function public.pilotage_mandats_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (
    select m.id from pilotage.v_mandats m left join pilotage.mandats_suivi s on s.mandat_id = m.id
    where s.retire_le is null
      and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = m.id)
      and not pilotage.lecture_bloquee(m.id)
      and public.pilotage_mandat_source(m.id) is not null
      and (m.debut >= date '2026-01-01' or pilotage.dossier_recu('ManagementContract', m.id))
    order by (select o.recu_le from pilotage.objets o where o.type = 'ManagementContract' and o.id = m.id) desc nulls last, m.debut desc limit p_max) t
$$;

-- Passages toutes les 5 minutes, décalés : rien à lire = appel immédiatement terminé
select cron.alter_job((select jobid from cron.job where jobname = 'pilotage-lecture-baux'), schedule := '1-59/5 * * * *');
select cron.alter_job((select jobid from cron.job where jobname = 'pilotage-lecture-mandats'), schedule := '2-59/5 * * * *');

-- Recalcul immédiat de la liste des baux
select pilotage.rafraichir_baux('0 minutes');

-- Contrôle : DPE du bail 33, documents en attente de lecture
select public.pilotage_baux_a_lire(10) baux_a_lire, public.pilotage_mandats_a_lire(10) mandats_a_lire;
select i->>'detail' dpe_bail_33, i->>'auto' etat from jsonb_array_elements(pilotage.controle_bail('lc_aff9fcdd7e7ad65c56ae17e2')->'items') i where i->>'cle' = 'h_cl_dpe';
