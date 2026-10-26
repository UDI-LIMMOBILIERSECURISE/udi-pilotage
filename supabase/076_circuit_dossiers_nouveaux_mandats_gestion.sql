-- 076 — Même vue pour toute la gestion (décision de Nicolas du 26/10) :
-- 1. Le circuit (« À finaliser / En attente / À valider ») et le contrôle d'entrée ne portent que sur les dossiers
--    nouveaux (date de référence de la reprise, 20/10/2026). Avant ce script, plusieurs fonctions gardaient d'anciens
--    critères (début du mandat depuis le 01/01/2026, bail commencé depuis le 16/10/2026, tout bail commercial) : Marion
--    voyait 307 baux « à valider » et les 88 mandats de 2026 dans son circuit. Le stock reste à l'audit (Reprise).
-- 2. L'onglet Mandats est ouvert à la gestionnaire et à la comptable, en lecture : avancement, contrôle, GO.
--    Les montants de commission (versements, factures, totaux) restent réservés à Nicolas et Romain (confidentialité
--    de la rémunération des commerciaux). Les modifications (GO, négociateur, loyer prévu) restent à la direction.
-- Le suivi des commissions (mandats et baux de 2026) n'est pas modifié.

begin;

create or replace function pilotage.bail_soumis(p_bail text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select pilotage.dossier_nouveau('LeasingContract', p_bail)
$$;

do $$
declare
  t record; def text; n int;
begin
  for t in select * from (values
    ('pilotage', 'ligne_bail',
     $a$coalesce((e.ech->>'type') in ('commercial', 'derogatoire', 'professionnel'), false) or coalesce(b.debut >= date '2026-10-16', false) or pilotage.dossier_recu('LeasingContract', b.id)$a$,
     $a$pilotage.dossier_nouveau('LeasingContract', b.id)$a$),
    ('pilotage', 'controle_mandat',
     $a$((o->>'start_date')::date >= date '2026-01-01' or pilotage.dossier_recu('ManagementContract', p_mandat))$a$,
     $a$pilotage.dossier_nouveau('ManagementContract', p_mandat)$a$),
    ('public', 'pilotage_mes_dossiers',
     $a$(m.debut >= date '2026-01-01' or pilotage.dossier_recu('ManagementContract', m.id))$a$,
     $a$pilotage.dossier_nouveau('ManagementContract', m.id)$a$),
    ('public', 'pilotage_mandats',
     $a$if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;$a$,
     $a$if pilotage.mon_role() not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Accès refusé'; end if;$a$),
    ('public', 'pilotage_mandats',
     $a$jsonb_agg(pilotage.dossier_mandat(m.id) order by$a$,
     $a$jsonb_agg(case when pilotage.mon_role() in ('direction', 'superviseur') then pilotage.dossier_mandat(m.id)
                       else pilotage.dossier_mandat(m.id) - array['versements', 'factures', 'total_prev', 'total_reel', 'honoraires_mois_ht', 'mois'] end order by$a$)
  ) v(schema, fonction, ancien, nouveau) loop
    select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = t.schema and p.proname = t.fonction;
    if def is null then raise exception 'Fonction %.% introuvable', t.schema, t.fonction; end if;
    n := (length(def) - length(replace(def, t.ancien, ''))) / length(t.ancien);
    if n <> 1 then raise exception 'Critère attendu trouvé % fois dans %.% (1 attendu) : rien n''est modifié', n, t.schema, t.fonction; end if;
    execute replace(def, t.ancien, t.nouveau);
  end loop;
end $$;

-- Recalcul immédiat de la liste des baux (sinon au prochain passage, sous 30 minutes)
select pilotage.rafraichir_baux('0 seconds');

commit;

-- Vérification : baux et mandats dans le circuit (attendu : 0 tant qu'aucun dossier n'est signé depuis le 20/10)
select (select count(*) from pilotage.baux_cache where (ligne->'controle'->>'soumis')::boolean and ligne->'controle'->>'go_le' is null) baux_a_valider,
       (select count(*) from pilotage.v_mandats m left join pilotage.mandats_suivi s on s.mandat_id = m.id
         where pilotage.dossier_nouveau('ManagementContract', m.id) and s.retire_le is null and s.valide_le is null) mandats_dans_le_circuit;
