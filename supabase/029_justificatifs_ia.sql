-- 029 : l'IA lit chaque justificatif déposé dans Rivage pour un suivi (attestation d'assurance, attestation d'entretien, acte de caution,
--   DPE, avis de régularisation) et en tire la date d'expiration ou la date du document (décision de Nicolas, 16/10/2026).
--   Dépôt reconnu (027) : le suivi avance tout de suite avec l'échéance par défaut ; la lecture IA corrige ensuite l'échéance
--   (date d'expiration lue) ou, si le document n'est pas le bon, annule l'avancement et le note au journal.
--   Lecture par la fonction pilotage-lecture-bail, appelée toutes les 30 minutes (tâche pilotage-lecture-justificatifs).

alter table pilotage.obligations_justificatifs add column if not exists ancienne_prochaine date, add column if not exists ancienne_derniere date,
  add column if not exists ancien_actif boolean, add column if not exists lu_le timestamptz, add column if not exists resultat jsonb;

create or replace function pilotage.appliquer_justificatifs() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare ob record; up record; n integer := 0; suivante date; d date;
begin
  for ob in
    select o.*, b.data->>'asset_id' as lot from pilotage.baux_obligations o
    join pilotage.objets b on b.type = 'LeasingContract' and b.id = o.bail_id
    where o.actif and exists (select 1 from pilotage.obligations_categories c where c.nature = o.nature)
  loop
    -- Document le plus ancien déposé depuis 4 mois avant l'échéance, pas encore utilisé pour ce suivi
    select u.id, u.data->>'nature' as categorie, u.maj_le::date as le into up
      from pilotage.objets u join pilotage.obligations_categories c on c.nature = ob.nature and c.categorie = u.data->>'nature'
     where u.type = 'Upload' and u.supprime_le is null
       and (c.filtre is null or pilotage.sans_accents(ob.libelle) ~ c.filtre)
       and u.maj_le::date >= ob.prochaine - 120
       and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr where rr->>'id' in (ob.bail_id, ob.lot))
       and not exists (select 1 from pilotage.obligations_justificatifs j where j.upload_id = u.id and j.obligation_id = ob.id)
     order by u.maj_le limit 1;
    continue when up.id is null;
    d := up.le;
    -- Échéance suivante : attestation, garantie, caution => échéance + périodicité ; entretien, régularisation => date du justificatif + périodicité ;
    -- DPE sans périodicité => 10 ans après le dépôt ; sans périodicité sinon => suivi clos.
    suivante := case
      when ob.nature in ('assurance', 'garantie', 'caution') and ob.periodicite_mois is not null then pilotage.ajouter_mois(ob.prochaine, ob.periodicite_mois)
      when ob.periodicite_mois is not null then pilotage.ajouter_mois(d, ob.periodicite_mois)
      when ob.nature = 'dpe' then pilotage.ajouter_mois(d, 120) end;
    insert into pilotage.obligations_justificatifs (upload_id, obligation_id, ancienne_prochaine, ancienne_derniere, ancien_actif)
    values (up.id, ob.id, ob.prochaine, ob.derniere_le, ob.actif) on conflict do nothing;
    insert into pilotage.suivis_etapes (cle, etape, par, detail)
    values ('o:' || ob.id || ':' || ob.prochaine, 'realise', null,
            'Justificatif déposé dans Rivage le ' || to_char(d, 'DD/MM/YYYY') || ' (catégorie « ' || pilotage.categorie_rivage(up.categorie) || ' »)')
    on conflict (cle, etape) do nothing;
    update pilotage.baux_obligations set derniere_le = d, prochaine = coalesce(suivante, prochaine), actif = suivante is not null where id = ob.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Justificatifs à lire (rôle service)
create or replace function public.pilotage_justificatifs_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('upload_id', j.upload_id, 'obligation_id', j.obligation_id, 'nature', o.nature, 'libelle', o.libelle,
             'categorie', pilotage.categorie_rivage(u.data->>'nature'), 'nom', u.data->>'label', 'url', u.data->>'file_url') x
    from pilotage.obligations_justificatifs j
    join pilotage.baux_obligations o on o.id = j.obligation_id
    join pilotage.objets u on u.type = 'Upload' and u.id = j.upload_id
    where j.lu_le is null and u.data->>'file_url' is not null
    order by j.applique_le limit p_max) t
$$;

-- Résultat de la lecture IA d'un justificatif (rôle service)
create or replace function public.pilotage_justificatif_ia(p_upload text, p_obligation bigint, p_resultat jsonb) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare j pilotage.obligations_justificatifs; ob pilotage.baux_obligations; v_cle text; expi date; ddoc date; suivante date; texte text;
begin
  select * into j from pilotage.obligations_justificatifs where upload_id = p_upload and obligation_id = p_obligation;
  select * into ob from pilotage.baux_obligations where id = p_obligation;
  if j.upload_id is null or ob.id is null then return; end if;
  v_cle := 'o:' || ob.id || ':' || coalesce(j.ancienne_prochaine, ob.prochaine);
  begin expi := nullif(p_resultat->>'date_expiration', '')::date; exception when others then expi := null; end;
  begin ddoc := nullif(p_resultat->>'date_document', '')::date; exception when others then ddoc := null; end;
  update pilotage.obligations_justificatifs set lu_le = now(), resultat = p_resultat where upload_id = p_upload and obligation_id = p_obligation;

  if coalesce((p_resultat->>'conforme')::boolean, true) = false then
    -- Pas le bon document : le suivi revient à son état d'avant le dépôt, les relances reprennent
    update pilotage.baux_obligations set prochaine = coalesce(j.ancienne_prochaine, prochaine), derniere_le = j.ancienne_derniere, actif = coalesce(j.ancien_actif, true)
    where id = ob.id;
    delete from pilotage.suivis_etapes where cle = v_cle and etape = 'realise' and par is null;
    insert into pilotage.suivis_etapes (cle, etape, par, detail)
    values (v_cle, 'refus_ia_' || p_upload, null, 'Document déposé dans Rivage non retenu par l''IA : ' || coalesce(p_resultat->>'type_document', 'document différent')
            || coalesce(' (' || (p_resultat->>'raison') || ')', '') || '. Relances maintenues.')
    on conflict (cle, etape) do nothing;
    return;
  end if;

  -- Bon document : échéance d'après la date lue
  suivante := case
    when ob.nature in ('assurance', 'garantie', 'caution', 'dpe') and expi is not null then expi
    when ddoc is not null and ob.periodicite_mois is not null then pilotage.ajouter_mois(ddoc, ob.periodicite_mois)
    when ob.nature = 'dpe' and ddoc is not null then pilotage.ajouter_mois(ddoc, 120) end;
  if suivante is not null then
    update pilotage.baux_obligations set prochaine = suivante, derniere_le = coalesce(ddoc, derniere_le), actif = true where id = ob.id;
  end if;
  texte := 'Lu par l''IA : ' || coalesce(p_resultat->>'type_document', 'justificatif')
        || coalesce(' du ' || to_char(ddoc, 'DD/MM/YYYY'), '') || coalesce(', valable jusqu''au ' || to_char(expi, 'DD/MM/YYYY'), '')
        || case when suivante is not null then ' · prochaine échéance le ' || to_char(suivante, 'DD/MM/YYYY') else ' · date non lue : échéance par défaut conservée' end;
  update pilotage.suivis_etapes set detail = detail || ' · ' || texte where cle = v_cle and etape = 'realise';
end $$;

revoke all on function public.pilotage_justificatifs_a_lire(integer), public.pilotage_justificatif_ia(text, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.pilotage_justificatifs_a_lire(integer), public.pilotage_justificatif_ia(text, bigint, jsonb) to service_role;
revoke all on all functions in schema pilotage from public, anon, authenticated;

select cron.unschedule('pilotage-lecture-justificatifs') where exists (select 1 from cron.job where jobname = 'pilotage-lecture-justificatifs');
select cron.schedule('pilotage-lecture-justificatifs', '10,40 * * * *', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-lecture-bail',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{"justificatifs": true}'::jsonb, timeout_milliseconds := 300000) $$);
