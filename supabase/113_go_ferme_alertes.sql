-- 113 — Le GO du contrôle d'entrée ferme tout de suite les alertes du circuit du bail, s'il n'y a plus rien à corriger (Nicolas, 31/10/2026).
-- Constat : bail 509, GO donné à 22 h 21, alertes « Dossier à compléter » (Nolhan) et « dossier incomplet chez le commercial »
-- (Marion) encore ouvertes jusqu'au contrôle suivant (toutes les 30 minutes).
-- Ajout dans pilotage_bail_go : au GO, si plus aucun point à traiter (commercial et gestion), aucun champ Rivage vide,
-- les alertes ouvertes bail_dossier_a_completer, bail_incomplet_entree et bail_controle_entree du bail passent « résolues ».
-- GO forcé avec des points restants : rien n'est fermé au clic, le contrôle suivant décide comme avant.
-- Le reste de la fonction est inchangé (version en base au 31/10, vérifiée). Un seul bloc.
-- Retour arrière : repasser la définition précédente (sans le bloc « 113 »).

begin;

create or replace function public.pilotage_bail_go(p_bail text, p_oui boolean)
returns void language plpgsql security definer set search_path = pilotage, public as $function$
declare c jsonb; vides jsonb; force boolean; r jsonb;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_oui then
    force := (pilotage.forcage_actif('bail', p_bail)).id is not null;
    c := pilotage.controle_bail(p_bail);
    if not force then
      if (c->>'restant')::int > 0 then raise exception 'Il reste % point(s) à traiter avant le GO', c->>'restant'; end if;
      vides := pilotage.champs_vides(c);
      if coalesce(pilotage.bail_soumis(p_bail), false) and jsonb_array_length(vides) > 0 then
        raise exception 'Champ(s) non rempli(s) dans Rivage : % (à corriger dans Rivage, ou dossier à faire forcer par Nicolas ou Romain)',
          (select string_agg(x, ', ') from jsonb_array_elements_text(vides) x);
      end if;
    end if;
    if not exists (select 1 from pilotage.baux_fiche where bail_id = p_bail and type_bail is not null) then raise exception 'Confirmez d''abord le type de bail'; end if;
  end if;
  insert into pilotage.baux_fiche (bail_id) values (p_bail) on conflict do nothing;
  update pilotage.baux_fiche set go_le = case when p_oui then now() end, go_par = case when p_oui then auth.uid() end where bail_id = p_bail;

  -- 113 : plus rien à corriger → alertes du circuit fermées tout de suite
  if p_oui then
    r := pilotage.bail_restants(p_bail);
    if coalesce((c->>'restant')::int, 0) = 0
       and coalesce((r->>'commercial')::int, 0) = 0 and coalesce((r->>'gestion')::int, 0) = 0
       and jsonb_array_length(coalesce(pilotage.champs_vides(c), '[]'::jsonb)) = 0 then
      update pilotage.alertes set statut = 'resolue', resolue_le = now()
       where objet_type = 'LeasingContract' and objet_id = p_bail and statut in ('ouverte', 'traitee')
         and regle in ('bail_dossier_a_completer', 'bail_incomplet_entree', 'bail_controle_entree');
    end if;
  end if;
end $function$;

commit;

-- Vérification : doit renvoyer vrai
select position('113 : plus rien' in pg_get_functiondef('public.pilotage_bail_go(text,boolean)'::regprocedure)) > 0 as script_113_passe;
