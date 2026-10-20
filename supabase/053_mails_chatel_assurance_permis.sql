-- 053 : retours de Nicolas sur les modèles de mails (20/10/2026). À exécuter après 052, à la main dans l'éditeur Supabase.
--
--   1. Échéance du mandat (loi Chatel, art. L215-1 du code de la consommation) : l'information part entre 3 mois et 1 mois
--      avant la DATE LIMITE de non-reconduction, pas avant l'échéance. Le modèle de mandat UDI prévoit un préavis de 3 mois
--      par LRAR : date limite = échéance - 3 mois, donc envoi entre 6 et 4 mois avant l'échéance. Étape passée de J-75 à J-150.
--   2. Assurance habitation : nouvelle étape J+10, mail au bailleur pour obtenir son accord de souscrire une assurance pour
--      le compte du locataire (art. 7 g de la loi de 1989) si la mise en demeure reste sans effet.
--   3. Permis de louer :
--      - accord tacite constaté à J+35 (acquis légalement à J+30, mais une décision datée du dernier jour peut arriver plus tard) ;
--      - au passage en « À louer », on demande d'abord au bailleur qui dépose : l'agence (90 € TTC, barème) ou lui-même ;
--        la réponse ouvre l'un des deux suivis (dépôt par l'agence / dépôt par le bailleur) ;
--      - mails au bailleur : choix, relance du choix, récépissé (dépôt par le bailleur), demande déposée, accord, refus.
--   4. Ma journée : l'alerte renvoie l'identifiant de l'objet (bail), pour préparer les mails « départ d'un colocataire »
--      et « fin d'engagement d'un garant ».
-- Rien n'est écrit dans Rivage. Les textes des mails sont dans src/mails.js.

-- ========== 1. Échéance du mandat ==========
update pilotage.calendriers
   set jours = -150,
       libelle = 'Informer le mandant de sa faculté de ne pas reconduire (loi Chatel) : entre 3 et 1 mois avant la date limite, soit l''échéance moins le préavis de 3 mois'
 where nature = 'mandat_echeance' and ordre = 1;

-- ========== 2. Assurance habitation : accord du bailleur à J+10 ==========
insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele) values
  ('assurance', 7, 10, 'Demander au bailleur s''il accepte de souscrire une assurance pour le compte du locataire si la mise en demeure reste sans effet', 'mail_bailleur', 'assurance_souscription')
on conflict (nature, ordre) do update set jours = excluded.jours, libelle = excluded.libelle, canal = excluded.canal, modele = excluded.modele;

-- ========== 3. Permis de louer ==========
alter table pilotage.permis_demandes add column if not exists depose_par text not null default 'agence';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'permis_demandes_depose_par_check') then
    alter table pilotage.permis_demandes add constraint permis_demandes_depose_par_check check (depose_par in ('agence', 'bailleur'));
  end if;
end $$;

-- Les étapes sont repérées par leur ordre (suivis_etapes.etape) : on garde les ordres existants et on en ajoute.
insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele) values
  -- Passage en « À louer » : choix du bailleur avant tout dépôt
  ('permis_a_demander', 1, 0, 'Demander au bailleur qui dépose la demande de permis de louer : l''agence (90 € TTC, barème) ou lui-même', 'mail_bailleur', 'permis_choix'),
  ('permis_a_demander', 2, 7, 'Relancer le bailleur sur son choix', 'mail_bailleur', 'permis_choix_relance'),
  ('permis_a_demander', 3, 14, 'Sans réponse : appeler le bailleur et enregistrer son choix (bloc Permis de louer)', 'tache', null),
  -- Dépôt par l'agence
  ('permis_depot_agence', 1, 0, 'Préparer et déposer la demande en mairie (Cerfa 15652 et pièces) ; facturer 90 € TTC au bailleur', 'tache', null),
  ('permis_depot_agence', 2, 10, 'Demande toujours pas déposée : la déposer sans attendre, aucun bail ne peut être signé avant l''autorisation', 'tache', null),
  -- Dépôt par le bailleur
  ('permis_depot_bailleur', 1, 10, 'Demander au bailleur le récépissé de dépôt de sa demande', 'mail_bailleur', 'permis_recepisse'),
  ('permis_depot_bailleur', 2, 20, 'Pas de récépissé : appeler le bailleur. Aucun bail ne peut être signé sans autorisation', 'tache', null),
  -- Demande déposée (prochaine = dépôt + 30 jours)
  ('permis_demande', 3, -30, 'Informer le bailleur du dépôt et du délai de réponse de la mairie', 'mail_bailleur', 'permis_depose'),
  ('permis_demande', 2, 5, 'Délai d''un mois écoulé et aucune décision reçue après 5 jours de marge : constater l''accord tacite et demander l''attestation (bloc Permis de louer)', 'tache', null),
  -- Refus
  ('permis_refus', 2, 0, 'Informer le bailleur du refus et du motif', 'mail_bailleur', 'permis_refus'),
  -- Accord (prochaine = accord + 2 ans) : l'étape tombe le jour de l'accord
  ('permis_caducite', 2, -730, 'Informer le bailleur que l''autorisation est acquise', 'mail_bailleur', 'permis_accord')
on conflict (nature, ordre) do update set jours = excluded.jours, libelle = excluded.libelle, canal = excluded.canal, modele = excluded.modele;

-- Saisie : ajoute le choix du bailleur (choix_agence, choix_bailleur) ; le dépôt retient qui a déposé.
create or replace function public.pilotage_permis_action(p_asset text, p_demande bigint, p_action text, p_le date, p_numero text, p_notes text) returns bigint
language plpgsql security definer set search_path = pilotage, public as $$
declare d pilotage.permis_demandes; m text; reg jsonb; nid bigint; lot text; v_par text;
begin
  if not pilotage.peut_traiter_lot(p_asset) then raise exception 'Accès refusé'; end if;
  select data->>'management_contract_id', coalesce(nullif(data->>'reference', ''), id) into m, lot from pilotage.objets where type = 'Asset' and id = p_asset;
  if m is null then raise exception 'Lot inconnu ou sans mandat'; end if;
  if p_action in ('choix_agence', 'choix_bailleur') then
    reg := pilotage.permis_lot(p_asset);
    if reg->>'regime' not in ('autorisation', 'a_verifier') then raise exception 'Ce lot n''est pas soumis à autorisation préalable d''après la table des communes'; end if;
    perform pilotage.permis_clore(p_asset, array['permis_a_demander', 'permis_depot_agence', 'permis_depot_bailleur']);
    if p_action = 'choix_agence' then
      perform pilotage.permis_suivi(m, p_asset, 'permis_depot_agence', 'Permis de louer du lot ' || lot || ' : dépôt par l''agence (90 € TTC)', coalesce(p_le, current_date), null);
    else
      perform pilotage.permis_suivi(m, p_asset, 'permis_depot_bailleur', 'Permis de louer du lot ' || lot || ' : dépôt par le bailleur', coalesce(p_le, current_date), null);
    end if;
    return null;
  end if;
  if p_action = 'deposer' then
    reg := pilotage.permis_lot(p_asset);
    if reg->>'regime' not in ('autorisation', 'declaration', 'a_verifier') then raise exception 'Ce lot n''est pas soumis au permis de louer d''après la table des communes'; end if;
    v_par := case when exists (select 1 from pilotage.mandats_obligations where asset_id = p_asset and nature = 'permis_depot_bailleur' and actif) then 'bailleur' else 'agence' end;
    insert into pilotage.permis_demandes (asset_id, regime, depot_le, numero, notes, par, depose_par)
    values (p_asset, case when reg->>'regime' = 'declaration' then 'declaration' else 'autorisation' end, coalesce(p_le, current_date), nullif(p_numero, ''), nullif(p_notes, ''), auth.uid(), v_par)
    returning id into nid;
    perform pilotage.permis_clore(p_asset, array['permis_a_demander', 'permis_refus', 'permis_declaration', 'permis_depot_agence', 'permis_depot_bailleur']);
    if reg->>'regime' <> 'declaration' then
      perform pilotage.permis_suivi(m, p_asset, 'permis_demande', 'Permis de louer du lot ' || lot || ' : réponse de la mairie', coalesce(p_le, current_date) + 30, nid);
    end if;
    return nid;
  end if;
  select * into d from pilotage.permis_demandes where id = p_demande and asset_id = p_asset;
  if d.id is null then raise exception 'Demande introuvable'; end if;
  if p_action in ('accord', 'refus', 'tacite') then
    update pilotage.permis_demandes set reponse = p_action,
      reponse_le = case when p_action = 'tacite' then d.depot_le + 30 else coalesce(p_le, current_date) end,
      numero = coalesce(nullif(p_numero, ''), numero), notes = coalesce(nullif(p_notes, ''), notes) where id = d.id;
    perform pilotage.permis_clore(p_asset, array['permis_demande']);
    if p_action = 'refus' then
      update pilotage.permis_demandes set close_le = current_date where id = d.id;
      perform pilotage.permis_suivi(m, p_asset, 'permis_refus', 'Permis de louer refusé (lot ' || lot || ')', current_date, d.id);
    else
      perform pilotage.permis_suivi(m, p_asset, 'permis_caducite', 'Validité du permis de louer du lot ' || lot || ' (caduc sans bail signé)',
        pilotage.ajouter_mois(case when p_action = 'tacite' then d.depot_le + 30 else coalesce(p_le, current_date) end, 24), d.id);
      if p_action = 'tacite' then
        perform pilotage.permis_suivi(m, p_asset, 'permis_attestation', 'Attestation d''accord tacite du permis de louer (lot ' || lot || ')', current_date + 15, d.id);
      end if;
    end if;
  elsif p_action = 'attestation_demandee' then
    update pilotage.permis_demandes set attestation_demandee_le = coalesce(p_le, current_date) where id = d.id;
    update pilotage.mandats_obligations set prochaine = coalesce(p_le, current_date) + 15 where asset_id = p_asset and nature = 'permis_attestation' and actif;
  elsif p_action = 'attestation_recue' then
    update pilotage.permis_demandes set attestation_recue_le = coalesce(p_le, current_date) where id = d.id;
    perform pilotage.permis_clore(p_asset, array['permis_attestation']);
  elsif p_action = 'annuler' then
    update pilotage.permis_demandes set close_le = current_date where id = d.id;
    perform pilotage.permis_clore(p_asset, array['permis_demande', 'permis_attestation', 'permis_caducite']);
  else raise exception 'Action inconnue'; end if;
  return d.id;
end $$;

-- Permis des lots d'un mandat : ajoute le choix en cours (agence / bailleur) et la question du choix ouverte
create or replace function public.pilotage_mandat_permis(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_traiter_dossier('mandat', p_mandat) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('asset_id', a.id, 'lot', coalesce(nullif(a.data->>'reference', ''), a.id),
      'adresse', concat_ws(' ', a.data->'address'->>'number', a.data->'address'->>'street', a.data->'address'->>'zip_code', a.data->'address'->>'city'),
      'permis', pilotage.permis_lot(a.id),
      'choix', (select case o.nature when 'permis_depot_agence' then 'agence' else 'bailleur' end from pilotage.mandats_obligations o
                where o.asset_id = a.id and o.nature in ('permis_depot_agence', 'permis_depot_bailleur') and o.actif order by o.id desc limit 1),
      'choix_a_demander', exists (select 1 from pilotage.mandats_obligations o where o.asset_id = a.id and o.nature = 'permis_a_demander' and o.actif),
      'demandes', coalesce((select jsonb_agg(to_jsonb(d) - 'par' order by d.depot_le desc) from pilotage.permis_demandes d where d.asset_id = a.id), '[]'::jsonb))
    order by a.data->>'reference')
    from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
      and a.data->>'nature' in ('flat', 'room', 'house')), '[]'::jsonb);
end $$;

-- Onglet À louer (052) : accord tacite constaté à 35 jours, choix du bailleur affiché. Remplacements ciblés dans la fonction en place ;
-- le script s'arrête si un passage attendu n'est plus trouvé (fonction modifiée depuis le 052).
do $$
declare def text; n text;
begin
  def := pg_get_functiondef('public.pilotage_permis_suivi()'::regprocedure);
  n := def;
  n := replace(n, 'current_date - o.depot_le >= 30 then ''Accord tacite à constater''', 'current_date - o.depot_le >= 35 then ''Accord tacite à constater''');
  n := replace(n, 'relance à 21 jours, accord tacite à 1 mois.', 'relance à 21 jours ; accord tacite acquis à 1 mois, constaté à 35 jours.');
  n := replace(n, 'when ''Autorisation à demander'' then ''Déposer le Cerfa 15652 et les pièces en mairie, avant toute mise en location.''',
                  'when ''Autorisation à demander'' then ''Demander au bailleur qui dépose (agence 90 € TTC ou lui-même), puis déposer le Cerfa 15652 et les pièces avant toute mise en location.''');
  n := replace(n, '''peut'', pilotage.peut_traiter_lot(l.id),',
    '''peut'', pilotage.peut_traiter_lot(l.id),
        ''choix'', (select case ob.nature when ''permis_depot_agence'' then ''agence'' else ''bailleur'' end from pilotage.mandats_obligations ob
                    where ob.asset_id = l.id and ob.nature in (''permis_depot_agence'', ''permis_depot_bailleur'') and ob.actif order by ob.id desc limit 1),
        ''choix_a_demander'', exists (select 1 from pilotage.mandats_obligations ob where ob.asset_id = l.id and ob.nature = ''permis_a_demander'' and ob.actif),');
  if n = def or position('>= 35 then ''Accord tacite' in n) = 0 or position('''choix_a_demander''' in n) = 0 or position('constaté à 35 jours' in n) = 0
     or position('agence 90 € TTC ou lui-même' in n) = 0 then
    raise exception '053 : pilotage_permis_suivi ne correspond plus au 052, remplacement impossible';
  end if;
  execute n;
end $$;

-- ========== 4. Ma journée : identifiant de l'objet de l'alerte ==========
create or replace function public.pilotage_journee(p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare cible uuid := coalesce(p_user, auth.uid()); r text := pilotage.mon_role();
begin
  if r is null then raise exception 'Accès refusé'; end if;
  if cible <> auth.uid() and r not in ('direction','superviseur') then raise exception 'Accès refusé'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'regle', a.regle, 'libelle', g.libelle, 'categorie', g.categorie, 'domaine', g.domaine,
      'gravite', a.gravite, 'titre', a.titre, 'detail', a.detail, 'explication', g.explication,
      'lien', a.lien_rivage, 'statut', a.statut, 'depuis', a.premiere_detection,
      'traitee_par', a.traitee_par, 'traitee_le', a.traitee_le,
      'objet_type', a.objet_type, 'objet_id', a.objet_id,
      'mandat_id', a.mandat_id, 'bailleur', pilotage.bailleurs_mandat(a.mandat_id),
      'mandat', (select coalesce(nullif(mc.data->>'name',''), 'Mandat n°' || (mc.data->>'reference')) from pilotage.objets mc where mc.type = 'ManagementContract' and mc.id = a.mandat_id),
      'dossier', case a.objet_type
        when 'LeasingContract' then (select jsonb_build_object('type','bail','ref', b.reference, 'locataires', b.locataires, 'adresse', l.adresse, 'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id)
                                     from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id where b.id = a.objet_id)
        when 'Asset' then (select jsonb_build_object('type','lot','ref', l.reference, 'adresse', l.adresse, 'lien', 'https://rivage.immo/asset_list') from pilotage.v_lots l where l.id = a.objet_id)
        else jsonb_build_object('type', lower(a.objet_type), 'ref', a.objet_id, 'lien', a.lien_rivage) end
    ) order by case a.gravite when 'critique' then 0 when 'haute' then 1 else 2 end, a.premiere_detection)
    from pilotage.alertes a join pilotage.regles g on g.cle = a.regle
    where pilotage.alerte_visible_par(a.mandat_id, cible)
      and (a.statut = 'ouverte' or (a.statut = 'traitee' and a.traitee_le > now() - interval '7 days'))
  ), '[]'::jsonb);
end $$;

-- Contacts d'un bail pour un mail préparé depuis Ma journée (mêmes droits que la lecture du dossier du bail)
create or replace function public.pilotage_contacts_bail(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_traiter_dossier('bail', p_bail) then raise exception 'Accès refusé'; end if;
  return pilotage.contacts_bail(p_bail) || jsonb_build_object('adresse', (select l.adresse from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id where b.id = p_bail));
end $$;
revoke all on function public.pilotage_contacts_bail(text) from public, anon;
grant execute on function public.pilotage_contacts_bail(text) to authenticated;

-- ========== Contrôle ==========
select nature, ordre, jours, canal, modele from pilotage.calendriers
 where (nature = 'mandat_echeance' and ordre = 1) or (nature = 'assurance' and ordre = 7) or nature like 'permis_%'
 order by nature, jours, ordre;
