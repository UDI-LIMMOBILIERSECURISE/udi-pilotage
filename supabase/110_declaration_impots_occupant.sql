-- 110 — Rappel au bailleur de déclarer l'occupant aux impôts (« Biens immobiliers » sur impots.gouv.fr) (Nicolas, 31/10/2026).
-- Ce que demandent les impôts (impots.gouv.fr, vérifié le 31/10) : pour un locataire personne physique, nom, prénom, date et lieu
-- de naissance ; pour une société, dénomination et SIREN ; loyer mensuel hors charges facultatif ; à déclarer dès le changement
-- d'occupant, au plus tard avant le 1er juillet de l'année suivante ; logement vide : « local inoccupé ». Pas de numéro fiscal du
-- locataire : le numéro utile est l'identifiant fiscal du logement (Rivage, fiche du lot, renseigné sur 170 lots sur 420 au 31/10).
-- Rivage n'a ni date ni lieu de naissance des locataires : l'identité est lue dans le bail par l'IA (clé « occupants » de la lecture,
-- ou lecture courte de la seule identité pour un bail déjà lu, table baux_occupants).
-- Décision de Nicolas (31/10) : le rappel complet part avec le mail « Entrée du locataire » (après l'EDL d'entrée, bail signé) et
-- avec un nouveau mail « Départ du locataire » (après l'EDL de sortie) ; une phrase de prévenance dans « Nouveau bail à signer »
-- et dans « Congé reçu ». Ces deux mails au bailleur attendent que l'état des lieux soit passé.
-- Identité incomplète : le paragraphe garde un champ {identite_locataires} à saisir, avec un avertissement (lire le bail par l'IA).
-- Fonctions modifiées : messages_contexte, pilotage_messages_dossier (remplacements ciblés, contrôlés). Nouvelles : occupants_bail,
-- paragraphe_impots, pilotage_lecture_occupants (appelée par la lecture IA). Modèles modifiés : ee_bailleur_email, nb_bailleur_email,
-- cg_bailleur_email (seulement si leur texte d'origine est trouvé, sinon un avis le signale) ; nouveau : es_bailleur_email.
-- Un seul bloc.

begin;

create table if not exists pilotage.baux_occupants (
  bail_id text primary key,
  occupants jsonb not null,
  source text, modele text,
  le timestamptz not null default now(),
  par uuid
);
alter table pilotage.baux_occupants enable row level security;
revoke all on pilotage.baux_occupants from public, anon, authenticated;

-- Écriture par la lecture IA (service uniquement)
create or replace function public.pilotage_lecture_occupants(p_bail text, p_occupants jsonb, p_source text, p_modele text, p_user uuid) returns void
language sql security definer set search_path = pilotage, public as $$
  insert into pilotage.baux_occupants (bail_id, occupants, source, modele, le, par)
  values (p_bail, coalesce(p_occupants, '[]'::jsonb), p_source, p_modele, now(), p_user)
  on conflict (bail_id) do update set occupants = excluded.occupants, source = excluded.source, modele = excluded.modele, le = excluded.le, par = excluded.par
$$;
revoke all on function public.pilotage_lecture_occupants(text, jsonb, text, text, uuid) from public, anon, authenticated;
grant execute on function public.pilotage_lecture_occupants(text, jsonb, text, text, uuid) to service_role;

-- Identité des locataires lue dans le bail : la lecture la plus récente (lecture complète ou lecture de l'identité seule)
create or replace function pilotage.occupants_bail(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  with o as (
    select x.occupants, x.le, x.source from (
      select bo.occupants, bo.le, bo.source from pilotage.baux_occupants bo where bo.bail_id = p_bail
      union all
      select l.resultat->'occupants', l.le, l.source from pilotage.baux_lectures l
       where l.bail_id = p_bail and jsonb_typeof(l.resultat->'occupants') = 'array') x
    order by x.le desc limit 1)
  select case when o.occupants is null then null else jsonb_build_object(
    'occupants', o.occupants, 'le', o.le, 'source', o.source,
    'complet', jsonb_array_length(o.occupants) > 0 and not exists (
      select 1 from jsonb_array_elements(o.occupants) e
       where case when e->>'type' = 'societe'
                  then nullif(trim(e->>'denomination'), '') is null or regexp_replace(coalesce(e->>'siren', ''), '\D', '', 'g') !~ '^\d{9}$'
                  else nullif(trim(e->>'nom'), '') is null or nullif(e->>'date_naissance', '') is null or nullif(trim(e->>'lieu_naissance'), '') is null end)) end
  from (select 1) z left join o on true
$$;
revoke all on function pilotage.occupants_bail(text) from public, anon, authenticated;

-- Paragraphe du mail au bailleur : entrée (déclarer le nouvel occupant) ou sortie (déclarer le départ)
create or replace function pilotage.paragraphe_impots(p_bail text, p_mode text) returns text
language plpgsql stable security definer set search_path = pilotage, public as $$
declare b record; occ jsonb := pilotage.occupants_bail(p_bail); idf text; lignes text; bien text;
begin
  select v.id, v.debut, v.loyer_hc, v.lot_id into b from pilotage.v_baux v where v.id = p_bail;
  if b.id is null then return null; end if;
  idf := (select nullif(trim(o.data->>'fiscal_identifier'), '') from pilotage.objets o where o.type = 'Asset' and o.id = b.lot_id);
  if coalesce((occ->>'complet')::boolean, false) then
    select string_agg('- ' || case when e->>'type' = 'societe'
                                   then trim(e->>'denomination') || ', SIREN ' || regexp_replace(e->>'siren', '\D', '', 'g')
                                   else upper(trim(e->>'nom')) || coalesce(' ' || nullif(trim(e->>'prenoms'), ''), '')
                                        || ', né(e) le ' || to_char((e->>'date_naissance')::date, 'DD/MM/YYYY') || ' à ' || trim(e->>'lieu_naissance') end, E'\n')
      into lignes from jsonb_array_elements(occ->'occupants') e;
  else
    lignes := '{identite_locataires}';
  end if;
  bien := 'sélectionnez le logement' || coalesce(' (identifiant fiscal du logement : ' || idf || ')', '');
  if p_mode = 'entree' then
    return 'Pensez à déclarer ce nouvel occupant aux impôts : sur impots.gouv.fr, dans votre espace, rubrique « Biens immobiliers », '
      || bien || ', puis déclarez qu''il est loué en indiquant le locataire :' || E'\n' || lignes
      || E'\nDate d''entrée : ' || coalesce(to_char(b.debut, 'DD/MM/YYYY'), '{date_debut}')
      || coalesce(E'\nLoyer mensuel hors charges (information facultative) : ' || pilotage.euros(b.loyer_hc), '')
      || E'\nLa déclaration se fait dès le changement d''occupant, et au plus tard avant le 1er juillet de l''année suivante.';
  else
    return 'Pensez également à déclarer ce départ aux impôts : sur impots.gouv.fr, dans votre espace, rubrique « Biens immobiliers », '
      || bien || ', puis indiquez la fin de l''occupation par :' || E'\n' || lignes
      || E'\nDate de départ : ' || coalesce(to_char(pilotage.sortie_prevue(p_bail), 'DD/MM/YYYY'), '{date_sortie}')
      || E'\nSi le logement n''est pas reloué tout de suite, déclarez-le « local inoccupé » ; dès qu''un nouveau locataire entre, nous vous '
      || 'communiquerons ses informations. La déclaration se fait au plus tard avant le 1er juillet de l''année suivante.';
  end if;
end $$;
revoke all on function pilotage.paragraphe_impots(text, text) from public, anon, authenticated;

-- Modèles : prévenance dans « Nouveau bail » et « Congé reçu », rappel complet à l'entrée et au départ
do $do$
declare n int;
begin
  update pilotage.messages_modeles set texte = replace(texte, 'les clés ont été remises à {locataire}.', 'les clés ont été remises à {locataire}.' || E'\r\n\r\n{paragraphe_impots_entree}')
   where code = 'ee_bailleur_email' and position('{paragraphe_impots_entree}' in texte) = 0 and position('les clés ont été remises à {locataire}.' in texte) > 0;
  get diagnostics n = row_count; if n = 0 then raise notice 'ee_bailleur_email : texte modifié entre-temps, ajouter {paragraphe_impots_entree} à la main dans l''écran des modèles'; end if;
  update pilotage.messages_modeles set texte = replace(texte, 'Nous vous adresserons une copie du bail une fois signé.',
           'Nous vous adresserons une copie du bail une fois signé et, à l''entrée du locataire, les informations à déclarer aux impôts (rubrique « Biens immobiliers » de votre espace impots.gouv.fr).')
   where code = 'nb_bailleur_email' and position('Nous vous adresserons une copie du bail une fois signé.' in texte) > 0;
  get diagnostics n = row_count; if n = 0 then raise notice 'nb_bailleur_email : texte modifié entre-temps, phrase sur les impôts non ajoutée'; end if;
  update pilotage.messages_modeles set texte = replace(texte, 'Merci de nous indiquer si vous souhaitez remettre',
           'Après le départ du locataire, ce changement sera à déclarer aux impôts (rubrique « Biens immobiliers » de votre espace impots.gouv.fr) : '
           || 'nous vous enverrons les informations nécessaires après l''état des lieux de sortie.' || E'\r\n\r\n' || 'Merci de nous indiquer si vous souhaitez remettre')
   where code = 'cg_bailleur_email' and position('impots.gouv.fr' in texte) = 0 and position('Merci de nous indiquer si vous souhaitez remettre' in texte) > 0;
  get diagnostics n = row_count; if n = 0 then raise notice 'cg_bailleur_email : texte modifié entre-temps, phrase sur les impôts non ajoutée'; end if;
end $do$;

insert into pilotage.messages_modeles (code, categorie, canal, cible, envoi, libelle, objet, texte, ordre, actif)
values ('es_bailleur_email', 'edl_sortie', 'email', 'bailleur', 'commercial', 'Mail au bailleur : départ du locataire et déclaration aux impôts',
        'Départ du locataire de votre bien {adresse}',
        '{bonjour}' || E'\r\n\r\n' || 'L''état des lieux de sortie de votre bien situé {adresse} a été fait le {date_edl} et {locataire} a rendu les clés.'
        || E'\r\n\r\n{paragraphe_impots_sortie}\r\n\r\n' || 'Nous revenons vers vous pour la suite du dossier (dépôt de garantie, remise en location).' || E'\r\n{signature}',
        6, true)
on conflict (code) do nothing;

do $do$
declare d text; a text;
begin
  -- 1. Contexte : paragraphes impôts, date de l'EDL (AAAA-MM-JJ), identité et identifiant fiscal pour les avertissements
  d := replace(pg_get_functiondef('pilotage.messages_contexte(text,text)'::regprocedure), E'\r\n', E'\n');
  if position('paragraphe_impots' in d) = 0 then
    a := $r$'_doublons', v->'doublons',$r$;
    if position(a in d) = 0 then raise exception 'messages_contexte : point d''insertion introuvable'; end if;
    d := replace(d, a, $r$'paragraphe_impots_entree', pilotage.paragraphe_impots(p_id, 'entree'), 'paragraphe_impots_sortie', pilotage.paragraphe_impots(p_id, 'sortie'),
      '_edl_le', case when r.statut = 'move_out' then pilotage.edl_sortie_le(p_id) else pilotage.edl_entree_le(p_id) end,
      '_identite', pilotage.occupants_bail(p_id),
      '_id_fiscal', (select nullif(trim(o2.data->>'fiscal_identifier'), '') from pilotage.objets o2 where o2.type = 'Asset' and o2.id = r.lot_id),
      '_doublons', v->'doublons',$r$);
    execute d;
  end if;

  -- 2. Messages d'un dossier : avertissements et attente des mails « impôts » ; identité renvoyée à l'écran
  d := replace(pg_get_functiondef('public.pilotage_messages_dossier(text,text)'::regprocedure), E'\r\n', E'\n');
  if position('paragraphe_impots' in d) = 0 then
    a := $r$case when m.cible = 'prestataire' then 'Joindre l''état des lieux d''entrée au brouillon.'$r$;
    if position(a in d) = 0 then raise exception 'pilotage_messages_dossier : avertissements introuvables'; end if;
    d := replace(d, a, $r$case when m.texte like '%{paragraphe_impots_%' then concat_ws(' ',
        case when not coalesce((c->'_identite'->>'complet')::boolean, false)
             then 'Identité des locataires (date et lieu de naissance, ou SIREN) pas encore lue dans le bail : « Lire l''identité dans le bail (IA) » ci-dessus, ou la saisir.' end,
        case when c->>'_id_fiscal' is null then 'Identifiant fiscal du logement absent de Rivage (fiche du lot) : à compléter dans Rivage, le mail s''en passe en attendant.' end) end,
      $r$ || a);
    a := $r$à saisir en haut de l''étape « État des lieux d''entrée ».' end end;$r$;
    if position(a in d) = 0 then raise exception 'pilotage_messages_dossier : attente (109) introuvable'; end if;
    d := replace(d, a, a || $r$
    if attente is null and m.texte like '%{paragraphe_impots_%' and (c->>'_edl_le')::date > current_date then
      attente := 'À envoyer une fois l''état des lieux fait (prévu le ' || to_char((c->>'_edl_le')::date, 'DD/MM/YYYY') || ').';
    end if;$r$);
    a := $r$return jsonb_build_object('actives', to_jsonb(actives),$r$;
    if position(a in d) = 0 then raise exception 'pilotage_messages_dossier : retour introuvable'; end if;
    d := replace(d, a, a || $r$
    'identite', case when p_objet = 'bail' then coalesce(c->'_identite', '{}'::jsonb) || jsonb_build_object('id_fiscal', c->>'_id_fiscal') end,$r$);
    execute d;
  end if;
end $do$;

commit;

-- Vérifications
-- select pilotage.paragraphe_impots('lc_f82226a9d6021e17a736c9fa', 'entree');   -- bail 530 : {identite_locataires} tant que le bail n'est pas lu
-- select code, left(texte, 400) from pilotage.messages_modeles where code in ('ee_bailleur_email', 'nb_bailleur_email', 'cg_bailleur_email', 'es_bailleur_email');
