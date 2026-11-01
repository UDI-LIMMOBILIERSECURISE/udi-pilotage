-- 115 — Liste « Dossiers des commerciaux » : un bail n'est « en cours chez le commercial » que s'il reste des points du commercial
-- (Nicolas, 01/11/2026).
-- Constat : baux 510 et 529 (Mathilde) rangés dans « En cours chez les commerciaux » alors que le seul point restant est à la
-- gestion (Exécution substitutive). La fiche (etat_dossier, bandeau du circuit) les donnait déjà « En attente de validation » :
-- seule la liste comptait tous les points restants (cache des baux), sans regarder à qui ils reviennent.
-- Correction : dans pilotage_mes_dossiers, l'état d'un bail se calcule sur les points du commercial (bail_restants), comme etat_dossier.
-- Effet au 01/11, 19 h 25 : 510 et 529 passent dans « À valider » ; 517, 528 (Mathilde) et 530 (Nicolas) restent chez le commercial.
-- Les mandats sont inchangés. Le reste de la fonction est repris à l'identique de la version en base. Un seul bloc.

begin;

create or replace function public.pilotage_mes_dossiers()
returns jsonb language plpgsql security definer set search_path = pilotage, public as $function$
declare r text := pilotage.mon_role(); gestion boolean; moi uuid := auth.uid(); res jsonb := '[]'::jsonb; x record; e jsonb;
begin
  if r is null then raise exception 'Accès refusé'; end if;
  gestion := r in ('direction', 'superviseur', 'gestionnaire', 'comptable');
  if not gestion and r <> 'negociateur' then return jsonb_build_object('role', r, 'dossiers', '[]'::jsonb); end if;

  -- Mandats soumis (début à partir du 01/01/2026), non retirés, non validés
  for x in select m.id, coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference) titre, pilotage.bailleurs_mandat(m.id) bailleur, m.debut
             from pilotage.v_mandats m left join pilotage.mandats_suivi s on s.mandat_id = m.id
            where pilotage.dossier_nouveau('ManagementContract', m.id) and s.retire_le is null and s.valide_le is null
              and (gestion or s.negociateur = moi or s.negociateur is null) loop
    e := pilotage.etat_dossier('mandat', x.id);
    if e->>'etat' in ('a_finaliser', 'en_attente') then
      res := res || jsonb_build_object('objet', 'mandat', 'id', x.id, 'titre', x.titre, 'sous_titre', x.bailleur, 'date', x.debut,
        'etat', e->>'etat', 'restant', e->'restant', 'vides', e->'vides', 'force', e->'forcage' is not null and e->'forcage' <> 'null'::jsonb,
        'commercial', e->>'commercial_prenom', 'a_attribuer', e->>'commercial' is null);
    end if;
  end loop;

  -- Baux soumis, non validés (depuis le cache de la liste des baux)
  perform pilotage.rafraichir_baux('30 minutes');
  for x in select c.ligne l from pilotage.baux_cache c
            where (c.ligne->'controle'->>'soumis')::boolean and c.ligne->'controle'->>'go_le' is null
              and (gestion or (c.ligne->>'commercial')::uuid = moi or c.ligne->>'commercial' is null) loop
    res := res || jsonb_build_object('objet', 'bail', 'id', x.l->>'bail_id',
      'titre', 'Bail ' || coalesce(x.l->>'reference', '') || ' · ' || coalesce(x.l->>'locataires', ''), 'sous_titre', x.l->>'adresse', 'date', x.l->'debut',
      -- 115 : état calculé sur les points du commercial seulement (comme etat_dossier) ; les points de la gestion n'empêchent pas « À valider »
      'etat', pilotage.etat_calcule(true, false, coalesce((pilotage.bail_restants(x.l->>'bail_id')->>'commercial')::int, 0),
                                    jsonb_array_length(coalesce(x.l->'controle'->'vides', '[]'::jsonb)),
                                    coalesce((x.l->'controle'->>'force')::boolean, false)),
      'restant', x.l->'controle'->'restant', 'vides', coalesce(x.l->'controle'->'vides', '[]'::jsonb), 'force', coalesce((x.l->'controle'->>'force')::boolean, false),
      'commercial', pilotage.prenom_membre((x.l->>'commercial')::uuid), 'a_attribuer', x.l->>'commercial' is null, 'ligne', x.l);
  end loop;

  -- Messages non lus et demandes de correction ouvertes
  select coalesce(jsonb_agg(d || jsonb_build_object(
           'non_lus', (select count(*) from pilotage.dossiers_messages mm
                        where mm.objet = d->>'objet' and mm.objet_id = d->>'id' and mm.auteur <> moi
                          and mm.le > coalesce((select v.vu_le from pilotage.dossiers_vus v where v.user_id = moi and v.objet = mm.objet and v.objet_id = mm.objet_id), '-infinity')),
           'demandes', (select count(*) from pilotage.dossiers_messages mm where mm.objet = d->>'objet' and mm.objet_id = d->>'id' and mm.demande and mm.traite_le is null))
         order by (d->>'etat') = 'en_attente', d->>'date'), '[]'::jsonb)
    into res from jsonb_array_elements(res) d;
  return jsonb_build_object('role', r, 'gestion', gestion, 'lecture', r = 'comptable', 'dossiers', res, 'moi', moi,
    'peut_attribuer', r in ('negociateur', 'direction', 'superviseur', 'gestionnaire'),
    'commerciaux', (select coalesce(jsonb_agg(jsonb_build_object('id', mb.user_id, 'prenom', mb.prenom) order by mb.role <> 'negociateur', mb.prenom), '[]'::jsonb)
                    from pilotage.membres mb where mb.actif and mb.role in ('negociateur', 'direction', 'superviseur')));
end $function$;

commit;

-- Vérification : doit renvoyer vrai
select position('115 : état calculé' in pg_get_functiondef('public.pilotage_mes_dossiers()'::regprocedure)) > 0 as script_115_passe;
