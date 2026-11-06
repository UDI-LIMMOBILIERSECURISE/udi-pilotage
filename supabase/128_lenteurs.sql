-- 128 : lenteurs (« canceling statement due to statement timeout ») (bloc 1 sur 1)
--  Constat du 06/11/2026 (journaux de la base, 24 h) : limite de 8 s dépassée
--   - toutes les 5 minutes, jour et nuit, par pilotage_occupants_a_lire (21 s) et pilotage_audit_a_lire (14 s) : ces deux tâches ne
--     finissaient jamais, donc la lecture de l'identité des occupants (110) et l'audit du stock ne tournaient plus ;
--   - à l'ouverture de « Sorties et DG » (pilotage_dg, 8,4 s, 31 échecs) et, plus rarement, pilotage_baux, pilotage_a_louer,
--     pilotage_mandats_a_lire, pilotage_baux_a_lire.
--  Causes mesurées :
--   - pilotage_dg : recherche du remboursement du dépôt (AccountingEventGroup) et des incidents d'un bail sans index (3,5 s), historique
--     des webhooks d'un bail sans index sur object_id (1,2 s) ;
--   - listes « à lire » : le document source (pilotage_lecture_source, 12 à 50 ms) était cherché pour tous les baux candidats (200),
--     alors qu'il en faut 3 : désormais les candidats sont parcourus dans le même ordre et la recherche s'arrête au nombre demandé.
--     Mêmes critères, même ordre, même résultat.
--  Index créés sans bloquer l'écriture longtemps (tables de 88 000 et 21 000 lignes).

create index if not exists objets_aeg_bail on pilotage.objets ((data->>'leasing_contract_id')) where type = 'AccountingEventGroup';
create index if not exists objets_incident_bail on pilotage.objets ((data->>'leasing_contract_id')) where type = 'Incident';
create index if not exists rivage_webhook_events_objet on public.rivage_webhook_events (object_id, received_at);
analyze pilotage.objets;
analyze public.rivage_webhook_events;

create or replace function public.pilotage_occupants_a_lire(p_max integer) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare r record; res jsonb := '[]'::jsonb; n integer := 0;
begin
  for r in
    select b.id from pilotage.v_baux b
     where ((b.statut in ('created', 'move_in', 'in_progress') and pilotage.dossier_nouveau('LeasingContract', b.id)
             and b.debut between current_date - 30 and current_date + 21)
            or (b.statut = 'move_out' and pilotage.sortie_prevue(b.id) >= current_date - 30))
       and pilotage.occupants_bail(b.id) is null
       and not pilotage.lecture_bloquee('occ:' || b.id)
     order by coalesce(pilotage.sortie_prevue(b.id), b.debut)
  loop
    exit when n >= p_max;
    if public.pilotage_lecture_source(r.id) is not null then res := res || to_jsonb(r.id); n := n + 1; end if;
  end loop;
  return res;
end $$;

create or replace function public.pilotage_audit_a_lire(p_max integer) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare r record; res jsonb := '[]'::jsonb; n integer := 0;
begin
  if not pilotage.audit_actif()
     or pilotage.audit_lectures_jour() >= coalesce((select valeur::integer from pilotage.parametres where cle = 'audit_max_jour'), 150) then
    return '[]'::jsonb;
  end if;
  for r in
    select b.id from pilotage.v_baux b
     where b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > current_date)
       and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = b.id)
       and not pilotage.lecture_bloquee(b.id)
     order by b.debut desc nulls last
  loop
    exit when n >= p_max;
    if public.pilotage_lecture_source(r.id) is not null then res := res || jsonb_build_object('type', 'bail', 'id', r.id); n := n + 1; end if;
  end loop;
  n := 0;
  for r in
    select m.id from pilotage.objets m
     where m.type = 'ManagementContract' and m.supprime_le is null and m.data->>'status' = 'active'
       and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = m.id)
       and not pilotage.lecture_bloquee(m.id)
  loop
    exit when n >= p_max;
    if public.pilotage_mandat_source(r.id) is not null then res := res || jsonb_build_object('type', 'mandat', 'id', r.id); n := n + 1; end if;
  end loop;
  return res;
end $$;

create or replace function public.pilotage_mandats_a_lire(p_max integer) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare r record; res jsonb := '[]'::jsonb; n integer := 0;
begin
  for r in
    select m.id from pilotage.v_mandats m left join pilotage.mandats_suivi s on s.mandat_id = m.id
     where s.retire_le is null
       and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = m.id)
       and not pilotage.lecture_bloquee(m.id)
       and pilotage.dossier_nouveau('ManagementContract', m.id)
     order by (select o.recu_le from pilotage.objets o where o.type = 'ManagementContract' and o.id = m.id) desc nulls last, m.debut desc
  loop
    exit when n >= p_max;
    if public.pilotage_mandat_source(r.id) is not null then res := res || to_jsonb(r.id); n := n + 1; end if;
  end loop;
  return res;
end $$;

select indexname from pg_indexes where indexname in ('objets_aeg_bail', 'objets_incident_bail', 'rivage_webhook_events_objet');
