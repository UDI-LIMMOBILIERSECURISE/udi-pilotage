-- 116 — Relecture automatique d'un bail quand un nouveau PDF de bail arrive dans Rivage (Nicolas, 02/11/2026).
-- Avant : un bail n'était lu qu'une fois ; un bail corrigé ou re-signé déposé ensuite dans Rivage n'était jamais relu.
-- Désormais, la tâche pilotage-lecture-baux (toutes les 5 minutes, 3 baux au plus) prend aussi :
--   - tout bail en cours déjà lu dont le PDF de bail retenu dans Rivage a été reçu après la dernière lecture
--     (y compris un bail lu depuis un PDF de l'ordinateur, quand le bail arrive ensuite dans Rivage) ;
-- et un bail bloqué après 2 échecs est repris si un nouveau PDF de bail est arrivé depuis le dernier échec.
-- La lecture précédente est conservée (historique) ; le contrôle d'entrée, l'identité des locataires et les concordances
-- prennent la plus récente. Premières lectures : critères inchangés (commercial, dérogatoire, professionnel, soumis, nouveau dossier).
-- Inclut le déblocage des baux en échec pendant la coupure de crédit IA du 02/11 (00 h 45 – 02 h 35), s'il n'a pas déjà été fait.
-- Un seul bloc.

begin;

create or replace function public.pilotage_baux_a_lire(p_max integer)
returns jsonb language sql stable security definer set search_path = pilotage, public as $function$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (
    select b.id, u.recu_le recu
      from pilotage.v_baux b
      cross join lateral (select public.pilotage_lecture_source(b.id)->>'upload_id' up) s
      left join pilotage.objets u on u.type = 'Upload' and u.id = s.up
      left join lateral (select max(x.le) lu from pilotage.baux_lectures x where x.bail_id = b.id) l on true
      left join pilotage.lectures_echecs e on e.cle = b.id
     where b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > current_date)
       and s.up is not null
       -- bloqué après 2 échecs, sauf si un nouveau PDF de bail est arrivé depuis le dernier échec (116)
       and (coalesce(e.nb, 0) < 2 or e.dernier_le < u.recu_le)
       and ((l.lu is null
             and ((pilotage.echeance_bail(b.id)->>'type') in ('commercial', 'derogatoire', 'professionnel')
                  or pilotage.bail_soumis(b.id)
                  or pilotage.dossier_nouveau('LeasingContract', b.id)))
            -- 116 : PDF de bail reçu dans Rivage après la dernière lecture
            or l.lu < u.recu_le)
     order by recu desc nulls last, b.debut desc
     limit p_max) t
$function$;
revoke all on function public.pilotage_baux_a_lire(integer) from public, anon, authenticated;
grant execute on function public.pilotage_baux_a_lire(integer) to service_role;

-- Déblocage après la coupure de crédit IA (sans effet si déjà fait)
delete from pilotage.lectures_echecs
 where nature = 'bail' and erreur like 'Le service IA n%'
   and dernier_le between '2026-11-01 23:40+00' and '2026-11-02 01:40+00';

commit;

-- Vérification : script passé (vrai) et baux qui vont être lus ou relus aux prochains passages
select position('116 : PDF de bail' in pg_get_functiondef('public.pilotage_baux_a_lire(integer)'::regprocedure)) > 0 as script_116_passe,
       public.pilotage_baux_a_lire(50) as prochains;
