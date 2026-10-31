-- 112 — Lecture automatique de l'identité des locataires pour la déclaration aux impôts (Nicolas, 31/10/2026).
-- Constat : la lecture IA des nouveaux baux est automatique (tâche pilotage-lecture-baux, toutes les 5 minutes) et relève
-- l'identité depuis la v22 de la fonction (31/10, 15 h 05). Les baux lus avant n'ont pas l'identité : bail 530 lu à 14 h 56.
-- Ajout : tâche pilotage-lecture-occupants (toutes les 5 minutes, 3 baux par passage) qui lit la seule identité des baux
-- dont une étape d'entrée ou de sortie est en cours (bail nouveau qui commence dans les 21 jours ou a commencé il y a moins
-- de 30 jours ; bail en sortie jusqu'à 30 jours après le départ), qui ont un bail déposé dans Rivage et pas encore d'identité.
-- Échecs : notés sous la clé « occ:<bail> », sans bloquer la lecture complète du bail ; au 2e échec, plus de nouvel essai.
-- Le 111 (identité du bail 530 relevée à la main, passé le 31/10 à 15 h 21, hors dépôt car il contient des données personnelles) reste valable.
-- Nouvelle fonction : pilotage_occupants_a_lire. Fonction pilotage-lecture-bail v23 (mode « occupants » des tâches planifiées).
-- Un seul bloc.

begin;

create or replace function public.pilotage_occupants_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (
    select b.id
      from pilotage.v_baux b
     where ((b.statut in ('created', 'move_in', 'in_progress') and pilotage.dossier_nouveau('LeasingContract', b.id)
             and b.debut between current_date - 30 and current_date + 21)
            or (b.statut = 'move_out' and pilotage.sortie_prevue(b.id) >= current_date - 30))
       and pilotage.occupants_bail(b.id) is null
       and not pilotage.lecture_bloquee('occ:' || b.id)
       and public.pilotage_lecture_source(b.id) is not null
     order by coalesce(pilotage.sortie_prevue(b.id), b.debut)
     limit p_max) t
$$;
revoke all on function public.pilotage_occupants_a_lire(integer) from public, anon, authenticated;
grant execute on function public.pilotage_occupants_a_lire(integer) to service_role;

select cron.unschedule('pilotage-lecture-occupants') where exists (select 1 from cron.job where jobname = 'pilotage-lecture-occupants');
select cron.schedule('pilotage-lecture-occupants', '3-59/5 * * * *', $c$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-lecture-bail',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{"occupants": true}'::jsonb, timeout_milliseconds := 300000) $c$);

commit;

-- Vérifications
-- select public.pilotage_occupants_a_lire(10);    -- baux en attente de lecture de l'identité
-- select b.reference, pilotage.occupants_bail(b.id) from pilotage.v_baux b join pilotage.baux_occupants o on o.bail_id = b.id order by o.le desc;
