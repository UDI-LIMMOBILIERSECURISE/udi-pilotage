-- 118 — Baux jamais lus par l'IA à cause d'un délai dépassé (« Bail introuvable ») (Nicolas, 02/11/2026).
-- Constat : la fonction de lecture demande d'abord la liste des questions du bail (pilotage_questions_bail). Celle-ci recalculait
-- tout le contrôle d'entrée (pilotage.controle_bail) pour n'en garder que la portée (habitation ou commercial) : 9 à 24 secondes
-- mesurées le 02/11 sur les baux 529 et 509, au-delà du délai de 8 secondes de l'API. La lecture échouait avec « Bail introuvable »
-- et le bail était bloqué au 2e échec : 28 baux concernés au 02/11, dont les nouveaux baux 509 et 529.
-- Correction : la portée est calculée directement (même règle que controle_bail : type de la fiche, sinon type Rivage, sinon type
-- suggéré par le lot), en moins d'une seconde. Vérifié identique au calcul complet sur 509, 529, 36 et 161.
-- Les 28 baux bloqués pour ce motif sont débloqués ; ceux qui relèvent de la lecture automatique (nouveaux dossiers, baux soumis,
-- baux commerciaux) sont lus dans les passages suivants. Un seul bloc.

begin;

create or replace function pilotage.portee_bail_id(p_bail text) returns text
language sql stable security definer set search_path = pilotage, public as $function$
  select coalesce(pilotage.portee_bail(coalesce(f.type_bail, pilotage.type_bail_rivage(o.id),
                    pilotage.type_bail_suggere(l.nature, nullif(o.data->>'duration_in_months', '')::integer))), 'habitation')
    from pilotage.objets o
    left join pilotage.v_lots l on l.id = o.data->>'asset_id'
    left join pilotage.baux_fiche f on f.bail_id = o.id
   where o.type = 'LeasingContract' and o.id = p_bail
$function$;
revoke all on function pilotage.portee_bail_id(text) from public, anon, authenticated;

create or replace function public.pilotage_questions_bail(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $function$
  -- 118 : portée calculée directement, sans recalculer tout le contrôle d'entrée
  select coalesce(jsonb_agg(jsonb_build_object('cle', cle, 'libelle', libelle, 'aide', aide) order by bloc, ordre), '[]'::jsonb)
  from pilotage.controle_questions where portee = pilotage.portee_bail_id(p_bail) and mode <> 'document'
$function$;

-- Déblocage des baux en échec pour ce motif
delete from pilotage.lectures_echecs where nature = 'bail' and erreur = 'Bail introuvable';

commit;

-- Vérification : script passé (vrai), plus aucun blocage « Bail introuvable » (0), et baux qui vont être lus
select position('118 : portée' in pg_get_functiondef('public.pilotage_questions_bail(text)'::regprocedure)) > 0 as script_118_passe,
       (select count(*) from pilotage.lectures_echecs where erreur = 'Bail introuvable') as blocages_restants,
       (select jsonb_agg(b.reference) from jsonb_array_elements_text(public.pilotage_baux_a_lire(50)) x join pilotage.v_baux b on b.id = x) as a_lire;
