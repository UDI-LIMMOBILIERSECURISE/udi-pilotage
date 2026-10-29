-- 090 — Impayés : garantie contrôlée contre Rivage, ouverture automatique des dossiers, huissier et avocat sans garantie (décisions de Nicolas du 27/10).
-- 1. « CDT VIA HUISSIER » et « AVOCAT » valent « Sans garantie » ; le libellé d'origine est conservé.
-- 2. Écart de garantie : la garantie du dossier est comparée à la GLI du bail dans Rivage. « Transfert Mila » est compatible
--    avec Zelok (Mila est l'assureur de Zelok). Une caution (Visale, Smart Garant, Garantme) absente de Rivage n'est pas un écart.
-- 3. Ouverture automatique : chaque matin à 7 h 30 (après la lecture des cycles d'impayé Rivage de 7 h 15), un dossier est ouvert
--    pour tout bail dont Rivage a ouvert un cycle d'impayé, s'il n'a pas déjà un dossier pour ce cycle. Dossier pré-rempli :
--    bail, montant de la dette Rivage, garantie du bail dans Rivage, section selon la garantie, responsable Audrey, note d'ouverture.
--    Au 27/10 Rivage ne signale aucun bail en impayé (facturation des baux repris non démarrée) : rien ne s'ouvrira avant.
begin;

-- 1. Huissier et avocat
create or replace function pilotage.organisme_de_garantie(p_garantie text) returns text
language sql immutable as $$
  select case upper(trim(coalesce(p_garantie, '')))
    when 'GLI ZELOK' then 'zelok' when 'TRANSFERT MILA' then 'mila' when 'CAUTION SMARTGARANT' then 'smartgarant'
    when 'CAUTION GARANTME' then 'garantme' when 'VISALE' then 'visale'
    when 'PAS DE GARANTIE' then 'aucun' when 'CDT VIA HUISSIER' then 'aucun' when 'AVOCAT' then 'aucun' end
$$;

create or replace function pilotage.impayes_synchro_garantie() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.garantie is distinct from old.garantie then
    if pilotage.organisme_de_garantie(new.garantie) is not null then new.organisme := pilotage.organisme_de_garantie(new.garantie); end if;
  elsif new.organisme is distinct from old.organisme and new.organisme is not null
        and pilotage.organisme_de_garantie(new.garantie) is distinct from new.organisme then
    new.garantie := pilotage.garantie_d_organisme(new.organisme);
  end if;
  if new.organisme is null and new.garantie is null and new.bail_id is not null then
    new.organisme := pilotage.organisme_bail(new.bail_id);
    new.garantie := pilotage.garantie_d_organisme(new.organisme);
  end if;
  return new;
end $$;

update pilotage.impayes set organisme = 'aucun' where organisme is null and upper(trim(garantie)) in ('CDT VIA HUISSIER', 'AVOCAT');

-- 2. Écart de garantie avec Rivage
create or replace function pilotage.libelle_organisme(p_organisme text) returns text
language sql immutable as $$
  select case p_organisme when 'zelok' then 'Zelok' when 'mila' then 'Mila' when 'smartgarant' then 'Smart Garant'
    when 'garantme' then 'Garantme' when 'visale' then 'Visale' when 'aucun' then 'sans garantie' end
$$;

create or replace function pilotage.ecart_garantie(p_organisme text, p_bail text) returns text
language plpgsql stable security definer set search_path = pilotage, public as $$
declare r text;
begin
  if p_bail is null then return null; end if;
  r := pilotage.organisme_bail(p_bail);
  if p_organisme is null then
    return case when r is not null then 'Garantie non renseignée dans le pilotage ; le bail Rivage est garanti ' || pilotage.libelle_organisme(r) || '.' end;
  end if;
  if r is null then
    return case when p_organisme in ('zelok', 'mila') then 'Garantie ' || pilotage.libelle_organisme(p_organisme) || ' dans le pilotage, mais aucune GLI sur le bail dans Rivage.' end;
  end if;
  if p_organisme = r or (p_organisme = 'mila' and r = 'zelok') then return null; end if;
  return 'Pilotage : ' || pilotage.libelle_organisme(p_organisme) || ' ; Rivage : GLI ' || pilotage.libelle_organisme(r) || '. À corriger dans Rivage ou dans le dossier.';
end $$;

do $$
declare
  def text; n int;
  ancien text := $a$'cycle', case when d.bail_id is not null then pilotage.cycle_impaye(d.bail_id) end,$a$;
  nouveau text := $a$'cycle', case when d.bail_id is not null then pilotage.cycle_impaye(d.bail_id) end,
        'ecart_garantie', pilotage.ecart_garantie(d.organisme, d.bail_id),$a$;
begin
  select pg_get_functiondef('public.pilotage_impayes'::regproc) into def;
  n := (length(def) - length(replace(def, ancien, ''))) / length(ancien);
  if n <> 1 then raise exception 'Critère trouvé % fois dans pilotage_impayes (1 attendu) : rien n''est modifié', n; end if;
  execute replace(def, ancien, nouveau);
end $$;

-- 3. Ouverture automatique des dossiers
create or replace function pilotage.impayes_ouverture_auto() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n int := 0; r record; v_id bigint; v_org text; v_resp uuid;
begin
  select user_id into v_resp from pilotage.membres where role = 'comptable' and actif order by prenom limit 1;
  for r in
    select b.id bail_id, pilotage.cycle_impaye(b.id) c
    from pilotage.objets b
    where b.type = 'LeasingContract' and b.supprime_le is null
      and coalesce((pilotage.cycle_impaye(b.id)->>'ouvert')::boolean, false)
      and not exists (select 1 from pilotage.impayes d where d.bail_id = b.id
                      and (d.groupe <> 'Clôturé' or d.cree_le >= coalesce((pilotage.cycle_impaye(b.id)->>'ouvert_le')::timestamptz, now())))
  loop
    v_org := pilotage.organisme_bail(r.bail_id);
    insert into pilotage.impayes (bail_id, groupe, responsable, montant_impaye, cause, garantie)
    values (r.bail_id,
            case v_org when 'zelok' then 'GLI ZELOK' when 'mila' then 'TRANSFERT MILA' when 'smartgarant' then 'SMARTGARANT' when 'visale' then 'VISALE' else 'SANS GARANTIE' end,
            v_resp, nullif((r.c->>'dette')::numeric, 0), 'Impayé loyer', coalesce(pilotage.garantie_d_organisme(v_org), 'PAS DE GARANTIE'))
    returning id into v_id;
    insert into pilotage.impayes_notes (impaye_id, auteur, contenu)
    values (v_id, 'Pilotage (automatique)',
      'Dossier ouvert automatiquement : impayé détecté par Rivage' || coalesce(' le ' || to_char((r.c->>'ouvert_le')::timestamptz, 'DD/MM/YYYY'), '')
      || coalesce(', dette de ' || (r.c->>'dette') || ' €', '')
      || coalesce(', bail garanti ' || pilotage.libelle_organisme(v_org) || ' dans Rivage', ', aucune GLI sur le bail dans Rivage') || '.');
    n := n + 1;
  end loop;
  return n;
end $$;

-- 7 h 30 heure de Paris en hiver (pg_cron tourne en GMT), après la lecture des cycles de 6 h 15 GMT
select cron.schedule('pilotage-impayes-ouverture', '30 6 * * *', $c$ select pilotage.impayes_ouverture_auto() $c$);

commit;

-- Contrôles (attendu : 12 huissier/avocat « aucun » ; écarts : 3 dossiers clôturés « sans garantie » contre Rivage Zelok ; 0 dossier ouvert aujourd'hui)
select (select count(*) from pilotage.impayes where organisme = 'aucun' and upper(trim(garantie)) in ('CDT VIA HUISSIER', 'AVOCAT')) huissier_avocat_sans_garantie,
       (select count(*) from pilotage.impayes d where pilotage.ecart_garantie(d.organisme, d.bail_id) is not null) ecarts_garantie,
       pilotage.impayes_ouverture_auto() dossiers_ouverts_maintenant;
