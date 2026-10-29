-- 095 — Permis de louer : « Permis déjà obtenu » parmi les choix (Nicolas, 29/10/2026).
-- Jusqu'ici le lot soumis à autorisation préalable ne proposait que « L'agence dépose (90 € TTC) » ou « Le bailleur dépose ».
-- Nouveau choix : le bailleur a déjà le permis. On enregistre la date d'accord (et le n° si connu) comme une demande accordée ;
-- cela clôt les suivis « à demander », « dépôt » et « bail signé sans permis de louer » du lot, et ouvre le suivi de caducité
-- (24 mois sans bail signé), que la signature d'un bail clôt comme pour un permis obtenu par l'agence.
-- Données : une action ajoutée à pilotage_permis_action ; rien d'existant n'est modifié.
-- Retour arrière : relancer la définition précédente de pilotage_permis_action (scripts 052 et suivants).
-- Un seul bloc.

begin;

do $do$
declare d text;
begin
  d := pg_get_functiondef('public.pilotage_permis_action(text,bigint,text,date,text,text)'::regprocedure);
  if position('deja_obtenu' in d) = 0 then
    if position('  if p_action = ''deposer'' then' in d) = 0 then raise exception 'pilotage_permis_action : point d''insertion introuvable'; end if;
    d := replace(d, '  if p_action = ''deposer'' then',
      '  if p_action = ''deja_obtenu'' then' || chr(10) ||
      '    reg := pilotage.permis_lot(p_asset);' || chr(10) ||
      '    if reg->>''regime'' not in (''autorisation'', ''a_verifier'') then raise exception ''Ce lot n''''est pas soumis à autorisation préalable d''''après la table des communes''; end if;' || chr(10) ||
      '    if p_le is null then raise exception ''Indiquez la date d''''obtention du permis''; end if;' || chr(10) ||
      '    if p_le > current_date then raise exception ''La date d''''obtention ne peut pas être dans le futur''; end if;' || chr(10) ||
      '    insert into pilotage.permis_demandes (asset_id, regime, depot_le, numero, notes, par, reponse, reponse_le, close_le)' || chr(10) ||
      '    values (p_asset, ''autorisation'', p_le, nullif(p_numero, ''''), coalesce(nullif(p_notes, ''''), ''Permis déjà obtenu (saisi dans le pilotage)''), auth.uid(), ''accord'', p_le, null)' || chr(10) ||
      '    returning id into nid;' || chr(10) ||
      '    perform pilotage.permis_clore(p_asset, array[''permis_a_demander'', ''permis_depot_agence'', ''permis_depot_bailleur'', ''permis_absent'', ''permis_refus'', ''permis_demande'']);' || chr(10) ||
      '    perform pilotage.permis_suivi(m, p_asset, ''permis_caducite'', ''Validité du permis de louer du lot '' || lot || '' (caduc sans bail signé)'', pilotage.ajouter_mois(p_le, 24), nid);' || chr(10) ||
      '    return nid;' || chr(10) ||
      '  end if;' || chr(10) ||
      '  if p_action = ''deposer'' then');
    execute d;
  end if;
end $do$;

commit;

-- Vérification : doit renvoyer true
-- select prosrc like '%deja_obtenu%' from pg_proc where proname = 'pilotage_permis_action';
