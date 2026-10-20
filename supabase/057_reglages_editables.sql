-- 057 : obligations suivies, règles d'alerte et calendriers de relance visibles et modifiables depuis l'appli (Nicolas, 20/10/2026)
--   Réservé au rôle direction, comme les autres réglages.

-- 1. Les réglages renvoient aussi les calendriers de relance (toutes les natures, toutes les étapes)
create or replace function public.pilotage_reglages() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'regles', (select jsonb_agg(jsonb_build_object('cle', cle, 'libelle', libelle, 'domaine', domaine, 'gravite', gravite, 'categorie', categorie, 'actif', actif, 'explication', explication,
                 'ouvertes', (select count(*) from pilotage.alertes a where a.regle = r.cle and a.statut = 'ouverte')) order by domaine, libelle) from pilotage.regles r),
    'obligations', (select jsonb_agg(to_jsonb(o) order by o.domaine, o.id) from pilotage.obligations o),
    'calendriers', (select jsonb_agg(jsonb_build_object('nature', c.nature, 'ordre', c.ordre, 'jours', c.jours, 'libelle', c.libelle, 'canal', c.canal, 'modele', c.modele)
                 order by c.nature, c.jours, c.ordre) from pilotage.calendriers c),
    'membres', (select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'prenom', m.prenom, 'role', m.role, 'actif', m.actif,
                 'email', (select email from auth.users u where u.id = m.user_id),
                 'mandats', (select coalesce(jsonb_agg(t.mandat_id), '[]'::jsonb) from pilotage.attributions t where t.user_id = m.user_id)) order by m.prenom) from pilotage.membres m),
    'mandats', (select jsonb_agg(jsonb_build_object('id', id, 'reference', reference, 'nom', nom, 'statut', statut) order by lpad(reference, 6, '0')) from pilotage.v_mandats)
  );
end $$;

-- 2. Règle d'alerte : libellé, explication, domaine, gravité, activation (la clé et le contrôle lui-même restent dans le code)
create or replace function public.pilotage_regle_modifier(p_cle text, p_libelle text, p_explication text, p_domaine text, p_gravite text, p_actif boolean)
returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  if nullif(trim(coalesce(p_libelle, '')), '') is null then raise exception 'Libellé obligatoire'; end if;
  update pilotage.regles set libelle = trim(p_libelle), explication = nullif(trim(coalesce(p_explication, '')), ''),
    domaine = coalesce(nullif(trim(coalesce(p_domaine, '')), ''), domaine), gravite = coalesce(p_gravite, gravite), actif = coalesce(p_actif, actif)
   where cle = p_cle;
  if not found then raise exception 'Règle inconnue'; end if;
end $$;

-- 3. Obligation suivie (référentiel) : création, modification, suppression
create or replace function public.pilotage_obligation_enregistrer(p_id integer, p_domaine text, p_moment text, p_types text, p_obligation text, p_texte text,
  p_declencheur text, p_donnee text, p_alerte text, p_statut text, p_manque text, p_supprimer boolean)
returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare nid integer;
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  if p_supprimer then delete from pilotage.obligations where id = p_id; return p_id; end if;
  if nullif(trim(coalesce(p_obligation, '')), '') is null then raise exception 'Intitulé de l''obligation obligatoire'; end if;
  if p_id is null then
    insert into pilotage.obligations (domaine, moment, types, obligation, texte, declencheur, donnee, alerte, statut, manque)
    values (nullif(trim(p_domaine), ''), nullif(trim(p_moment), ''), nullif(trim(p_types), ''), trim(p_obligation), nullif(trim(p_texte), ''),
            nullif(trim(p_declencheur), ''), nullif(trim(p_donnee), ''), nullif(trim(p_alerte), ''), nullif(trim(p_statut), ''), nullif(trim(p_manque), ''))
    returning id into nid;
  else
    update pilotage.obligations set domaine = nullif(trim(p_domaine), ''), moment = nullif(trim(p_moment), ''), types = nullif(trim(p_types), ''),
      obligation = trim(p_obligation), texte = nullif(trim(p_texte), ''), declencheur = nullif(trim(p_declencheur), ''), donnee = nullif(trim(p_donnee), ''),
      alerte = nullif(trim(p_alerte), ''), statut = nullif(trim(p_statut), ''), manque = nullif(trim(p_manque), '')
     where id = p_id;
    if not found then raise exception 'Obligation inconnue'; end if;
    nid := p_id;
  end if;
  return nid;
end $$;

-- 4. Étape d'un calendrier de relance : création (p_ordre null), modification, suppression.
--    Une nouvelle étape prend toujours un numéro jamais utilisé, pour ne pas récupérer la coche « fait » d'une étape supprimée.
--    Les étapes s'enchaînent selon leur délai (jours), pas selon leur numéro.
create or replace function public.pilotage_calendrier_etape(p_nature text, p_ordre integer, p_jours integer, p_libelle text, p_canal text, p_modele text, p_supprimer boolean)
returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare nordre integer;
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.calendriers where nature = p_nature) then raise exception 'Calendrier inconnu'; end if;
  if p_supprimer then
    if (select count(*) from pilotage.calendriers where nature = p_nature) <= 1 then raise exception 'Un calendrier doit garder au moins une étape (arrêter plutôt le suivi)'; end if;
    delete from pilotage.calendriers where nature = p_nature and ordre = p_ordre; return p_ordre;
  end if;
  if p_jours is null then raise exception 'Délai (en jours) obligatoire'; end if;
  if nullif(trim(coalesce(p_libelle, '')), '') is null then raise exception 'Libellé de l''étape obligatoire'; end if;
  if p_ordre is null then
    select greatest(coalesce(max(c.ordre), 0), coalesce((select max(se.etape::int) from pilotage.suivis_etapes se where se.etape ~ '^\d+$'), 0)) + 1
      into nordre from pilotage.calendriers c where c.nature = p_nature;
    insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele)
    values (p_nature, nordre, p_jours, trim(p_libelle), p_canal, nullif(trim(coalesce(p_modele, '')), ''));
  else
    update pilotage.calendriers set jours = p_jours, libelle = trim(p_libelle), canal = p_canal, modele = nullif(trim(coalesce(p_modele, '')), '')
     where nature = p_nature and ordre = p_ordre;
    if not found then raise exception 'Étape inconnue'; end if;
    nordre := p_ordre;
  end if;
  return nordre;
end $$;

revoke all on function public.pilotage_regle_modifier(text, text, text, text, text, boolean),
  public.pilotage_obligation_enregistrer(integer, text, text, text, text, text, text, text, text, text, text, boolean),
  public.pilotage_calendrier_etape(text, integer, integer, text, text, text, boolean) from public, anon;
grant execute on function public.pilotage_regle_modifier(text, text, text, text, text, boolean),
  public.pilotage_obligation_enregistrer(integer, text, text, text, text, text, text, text, text, text, text, boolean),
  public.pilotage_calendrier_etape(text, integer, integer, text, text, text, boolean) to authenticated;

-- 5. Référentiel : obligations déjà suivies par un calendrier de relance mais absentes de la liste (à relire et compléter depuis l'écran)
insert into pilotage.obligations (domaine, moment, types, obligation, texte, declencheur, donnee, alerte, statut, manque)
select v.* from (values
  ('Baux habitation', 'En cours de bail', 'Tous', 'Relevé des compteurs divisionnaires (eau, chauffage) : relevé semestriel à date fixe, calé sur l''exercice de charges',
   'Décret n° 87-713 (charges récupérables) ; clauses du bail', 'Date fixe de relevé (fin d''exercice et intermédiaire 6 mois après)', 'Compteurs du lot et relevés datés (pilotage)',
   'Prévenance J-7, puis relances J0 à J+15 (mail et SMS en alternance), relevé sur place et information du bailleur à J+20', 'saisie', 'Compteurs à déclarer sur chaque lot à la rentrée du mandat'),
  ('Entretien et contrats', 'En cours de bail', 'Habitation', 'Fosse septique / assainissement non collectif : vidange et entretien, justificatif à réclamer',
   'Décret n° 87-712 (réparations locatives) ; clauses du bail', 'Échéance annuelle de l''entretien', 'Équipements du lot (pilotage)',
   'Calendrier entretien : J-45, J-30, mise en demeure J-15, puis bailleur', 'saisie', 'Équipement à déclarer sur le lot'),
  ('Entretien et contrats', 'En cours de bail', 'Tous', 'Citerne gaz : entretien et contrôle, justificatif à réclamer',
   'Clauses du bail ; contrat du fournisseur', 'Échéance annuelle de l''entretien', 'Équipements du lot (pilotage)',
   'Calendrier entretien : J-45, J-30, mise en demeure J-15, puis bailleur', 'saisie', 'Équipement à déclarer sur le lot'),
  ('Mandat, compta, agence', 'Annuel', 'Lots en copropriété', 'Assurance propriétaire non occupant (PNO) : attestation annuelle du bailleur',
   'Loi du 10 juillet 1965, art. 9-1 (copropriété)', 'Échéance de l''attestation', 'Suivi PNO du mandat (pilotage)',
   'Demande J-30, relance à l''échéance, appel au bailleur J+15', 'saisie', 'Date d''échéance de l''attestation à saisir'),
  ('Mandat, compta, agence', 'Avant relocation', 'Tous', 'Validité du DPE (10 ans) : nouveau diagnostic avant toute nouvelle location',
   'Code de la construction et de l''habitation (DPE)', 'Fin de validité du DPE', 'Date du DPE (pilotage / documents Rivage)',
   'Information bailleur J-90, relance J-60, commande du diagnostic J-30', 'partiel', null),
  ('Copropriété', 'Tous les 5 ans', 'Immeubles gérés avec ascenseur', 'Ascenseur : contrôle technique quinquennal',
   'Code de la construction et de l''habitation (sécurité des ascenseurs)', 'Échéance du contrôle', 'Suivi du mandat (pilotage)',
   'Commande du contrôle J-60, vérification du rapport à l''échéance', 'saisie', 'Date du dernier contrôle à saisir')
) v(domaine, moment, types, obligation, texte, declencheur, donnee, alerte, statut, manque)
where not exists (select 1 from pilotage.obligations o where o.obligation = v.obligation);

-- =====================================================================================================
-- 6. Délais des règles d'alerte modifiables depuis l'appli (sans repasser par le code)
--    Chaque règle porte la liste de ses délais (pilotage.regles.parametres) ; les contrôles les lisent avec pilotage.param().
--    Les délais LÉGAUX (date limite du congé, délai de restitution du DG, délai de réponse L145-10...) restent fixes.
-- =====================================================================================================
alter table pilotage.regles add column if not exists parametres jsonb not null default '[]'::jsonb;

create or replace function pilotage.param(p_regle text, p_nom text, p_defaut numeric) returns numeric
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce((select (x->>'valeur')::numeric from pilotage.regles r, jsonb_array_elements(r.parametres) x
                    where r.cle = p_regle and x->>'nom' = p_nom), p_defaut)
$$;
-- Durée en mois (4,5 = 4 mois et 15 jours)
create or replace function pilotage.param_mois(p_regle text, p_nom text, p_defaut numeric) returns interval
language sql stable security definer set search_path = pilotage, public as $$
  select make_interval(months => floor(v)::int, days => round((v - floor(v)) * 30)::int) from (select pilotage.param(p_regle, p_nom, p_defaut) v) z
$$;

-- Valeurs actuelles (identiques au code d'aujourd'hui : rien ne change tant qu'on ne les modifie pas)
update pilotage.regles r set parametres = v.p::jsonb from (values
  ('bail_non_entre', '[{"nom":"jours_apres_debut","libelle":"Alerte si le bail est toujours « Créé » après la date de début depuis","unite":"jours","valeur":5}]'),
  ('chaudiere_gaz_entretien', '[{"nom":"jours_depuis_entretien","libelle":"Alerte si le dernier entretien date de plus de","unite":"jours","valeur":365}]'),
  ('document_supprime', '[{"nom":"jours_affichage","libelle":"Signaler les documents supprimés depuis moins de","unite":"jours","valeur":30}]'),
  ('bail_palier', '[{"nom":"jours_avant_palier","libelle":"Prévenir avant le début d''un palier ou d''une franchise","unite":"jours","valeur":30}]'),
  ('bail_douze_ans', '[{"nom":"jours_avant","libelle":"Prévenir avant les 12 ans du bail","unite":"jours","valeur":365}]'),
  ('bail_acte_delai', '[{"nom":"jours_apres_delai","libelle":"Garder l''alerte après la fin du délai de réponse de 3 mois pendant","unite":"jours","valeur":15}]'),
  ('dg_reversement', '[{"nom":"jours_avant_depart","libelle":"Commencer les relances du bailleur avant le départ du locataire","unite":"jours","valeur":15},{"nom":"jours_entre_relances","libelle":"Relancer le bailleur tous les","unite":"jours","valeur":7}]'),
  ('dg_delai', '[{"nom":"jours_avant_limite","libelle":"Alerte avant la date limite de restitution","unite":"jours","valeur":10}]'),
  ('impaye_zelok_declarer', '[{"nom":"jour_debut","libelle":"Alerte à partir du (jour du mois)","unite":"jour du mois","valeur":16},{"nom":"jour_fin","libelle":"Dernier jour de déclaration (jour du mois)","unite":"jour du mois","valeur":19}]'),
  ('impaye_zelok_urgent', '[{"nom":"jour_urgent","libelle":"Passer en urgent à partir du (jour du mois)","unite":"jour du mois","valeur":18}]'),
  ('impaye_actualisation', '[{"nom":"jour_debut","libelle":"Alerte à partir du (jour du mois)","unite":"jour du mois","valeur":16}]'),
  ('loyer_modifie', '[{"nom":"jours_affichage","libelle":"Garder l''alerte après le changement de loyer pendant","unite":"jours","valeur":45}]'),
  ('colocataire_sorti', '[{"nom":"jours_avant_sortie","libelle":"Prévenir avant la sortie annoncée d''un colocataire","unite":"jours","valeur":30}]'),
  ('bail_suivi_retard', '[{"nom":"jours_retard","libelle":"Obligation en retard (critique) après l''échéance au bout de","unite":"jours","valeur":30}]'),
  ('mandat_suivi_retard', '[{"nom":"jours_retard","libelle":"Suivi en retard (critique) après l''échéance au bout de","unite":"jours","valeur":30}]'),
  ('bail_echeance', '[{"nom":"info_commercial","libelle":"Bail commercial : informer le bailleur avant l''échéance","unite":"mois","valeur":12},{"nom":"relance_commercial","libelle":"Bail commercial : relancer le bailleur avant l''échéance","unite":"mois","valeur":10},{"nom":"decision_commercial","libelle":"Bail commercial : décision attendue avant l''échéance","unite":"mois","valeur":8},{"nom":"info_vide","libelle":"Habitation vide (et autres baux) : informer avant l''échéance","unite":"mois","valeur":9},{"nom":"relance_vide","libelle":"Habitation vide : relancer avant l''échéance","unite":"mois","valeur":8},{"nom":"decision_vide","libelle":"Habitation vide : décision attendue avant l''échéance","unite":"mois","valeur":7},{"nom":"info_meuble","libelle":"Meublé : informer avant l''échéance","unite":"mois","valeur":5},{"nom":"relance_meuble","libelle":"Meublé : relancer avant l''échéance (4,5 = 4 mois et demi)","unite":"mois","valeur":4.5},{"nom":"decision_meuble","libelle":"Meublé : décision attendue avant l''échéance","unite":"mois","valeur":4},{"nom":"jours_entre_relances","libelle":"Écart minimum entre deux relances du bailleur","unite":"jours","valeur":15},{"nom":"jours_attente_acte","libelle":"Après la décision de congé, attendre l''acte avant de relancer","unite":"jours","valeur":10}]'),
  ('bail_echeance_urgente', '[{"nom":"jours_avant_limite","libelle":"Passer en urgent avant la date limite du congé","unite":"jours","valeur":30}]')
) v(cle, p) where r.cle = v.cle;

-- Réécriture des contrôles : chaque chiffre figé est remplacé par la lecture du réglage. Le script s'arrête si le code
-- en base ne correspond pas exactement à celui attendu (rien n'est alors modifié).
do $$
declare
  rempl jsonb := '[
    ["pilotage.executer_controles()", "debut < current_date - 5", "debut < current_date - pilotage.param(''bail_non_entre'',''jours_apres_debut'',5)::int", 1],
    ["pilotage.executer_controles()", "entretien_chaudiere < current_date - 365", "entretien_chaudiere < current_date - pilotage.param(''chaudiere_gaz_entretien'',''jours_depuis_entretien'',365)::int", 1],
    ["pilotage.executer_controles()", "o.supprime_le > now() - interval ''30 days''", "o.supprime_le > now() - make_interval(days => pilotage.param(''document_supprime'',''jours_affichage'',30)::int)", 1],
    ["pilotage.suivi_detections()", "p.debut between current_date and current_date + 30", "p.debut between current_date and current_date + pilotage.param(''bail_palier'',''jours_avant_palier'',30)::int", 1],
    ["pilotage.suivi_detections()", "between current_date and current_date + 365 and", "between current_date and current_date + pilotage.param(''bail_douze_ans'',''jours_avant'',365)::int and", 1],
    ["pilotage.suivi_detections()", "pilotage.ajouter_mois(a.signifie_le, 3) + 15", "pilotage.ajouter_mois(a.signifie_le, 3) + pilotage.param(''bail_acte_delai'',''jours_apres_delai'',15)::int", 1],
    ["pilotage.suivi_detections_dg()", "current_date >= d.depart - 15", "current_date >= d.depart - pilotage.param(''dg_reversement'',''jours_avant_depart'',15)::int", 1],
    ["pilotage.suivi_detections_dg()", "<= current_date - 7))", "<= current_date - pilotage.param(''dg_reversement'',''jours_entre_relances'',7)::int))", 1],
    ["pilotage.suivi_detections_dg()", "current_date >= d.limite - 10", "current_date >= d.limite - pilotage.param(''dg_delai'',''jours_avant_limite'',10)::int", 1],
    ["pilotage.suivi_detections_impayes()", "pilotage.jour_paris() >= 18", "pilotage.jour_paris() >= pilotage.param(''impaye_zelok_urgent'',''jour_urgent'',18)", 1],
    ["pilotage.suivi_detections_impayes()", "pilotage.jour_paris() between 16 and 19", "pilotage.jour_paris() between pilotage.param(''impaye_zelok_declarer'',''jour_debut'',16) and pilotage.param(''impaye_zelok_declarer'',''jour_fin'',19)", 1],
    ["pilotage.suivi_detections_impayes()", "''Impayé à déclarer à Zelok avant le 19 : ''", "''Impayé à déclarer à Zelok avant le '' || pilotage.param(''impaye_zelok_declarer'',''jour_fin'',19)::int || '' : ''", 1],
    ["pilotage.suivi_detections_impayes()", "pilotage.jour_paris() >= 16", "pilotage.jour_paris() >= pilotage.param(''impaye_actualisation'',''jour_debut'',16)", 1],
    ["pilotage.suivi_detections_loyers()", "now() - interval ''45 days''", "now() - make_interval(days => pilotage.param(''loyer_modifie'',''jours_affichage'',45)::int)", 1],
    ["pilotage.suivi_detections_sorties()", "l.s <= current_date + 30", "l.s <= current_date + pilotage.param(''colocataire_sorti'',''jours_avant_sortie'',30)::int", 1],
    ["pilotage.obligation_etat(bigint)", "ob.prochaine + 30", "ob.prochaine + pilotage.param(''bail_suivi_retard'',''jours_retard'',30)::int", 2],
    ["pilotage.obligation_mandat_etat(bigint)", "ob.prochaine + 30", "ob.prochaine + pilotage.param(''mandat_suivi_retard'',''jours_retard'',30)::int", 2],
    ["pilotage.echeance_bail(text)", "array[''12 months'',''10 months'',''8 months'',''6 months'']::interval[]", "array[pilotage.param_mois(''bail_echeance'',''info_commercial'',12), pilotage.param_mois(''bail_echeance'',''relance_commercial'',10), pilotage.param_mois(''bail_echeance'',''decision_commercial'',8), interval ''6 months'']", 1],
    ["pilotage.echeance_bail(text)", "array[''5 months'',''4 months 15 days'',''4 months'',''3 months'']::interval[]", "array[pilotage.param_mois(''bail_echeance'',''info_meuble'',5), pilotage.param_mois(''bail_echeance'',''relance_meuble'',4.5), pilotage.param_mois(''bail_echeance'',''decision_meuble'',4), interval ''3 months'']", 1],
    ["pilotage.echeance_bail(text)", "array[''9 months'',''8 months'',''7 months'',''6 months'']::interval[]", "array[pilotage.param_mois(''bail_echeance'',''info_vide'',9), pilotage.param_mois(''bail_echeance'',''relance_vide'',8), pilotage.param_mois(''bail_echeance'',''decision_vide'',7), interval ''6 months'']", 1],
    ["pilotage.echeance_bail(text)", "greatest(rel, informe + 15)", "greatest(rel, informe + pilotage.param(''bail_echeance'',''jours_entre_relances'',15)::int)", 1],
    ["pilotage.echeance_bail(text)", "coalesce(relance, informe) + 15", "coalesce(relance, informe) + pilotage.param(''bail_echeance'',''jours_entre_relances'',15)::int", 1],
    ["pilotage.echeance_bail(text)", "e.decision_le::date + 10", "e.decision_le::date + pilotage.param(''bail_echeance'',''jours_attente_acte'',10)::int", 1],
    ["pilotage.echeance_bail(text)", "lim - j <= 30", "lim - j <= pilotage.param(''bail_echeance_urgente'',''jours_avant_limite'',30)", 4],
    ["pilotage.echeance_bail(text)", "lim - j > 30", "lim - j > pilotage.param(''bail_echeance_urgente'',''jours_avant_limite'',30)", 1]
  ]';
  fns text[]; f text; def text; x jsonb; n int;
begin
  select array_agg(distinct e->>0) into fns from jsonb_array_elements(rempl) e;
  foreach f in array fns loop
    def := pg_get_functiondef(f::regprocedure);
    for x in select e from jsonb_array_elements(rempl) e where e->>0 = f loop
      n := (length(def) - length(replace(def, x->>1, ''))) / length(x->>1);
      if n <> (x->>3)::int then raise exception 'Code inattendu dans % : « % » trouvé % fois au lieu de %', f, x->>1, n, x->>3; end if;
      def := replace(def, x->>1, x->>2);
    end loop;
    execute def;
  end loop;
end $$;

-- Les réglages renvoient les délais de chaque règle
create or replace function public.pilotage_reglages() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'regles', (select jsonb_agg(jsonb_build_object('cle', cle, 'libelle', libelle, 'domaine', domaine, 'gravite', gravite, 'categorie', categorie, 'actif', actif, 'explication', explication,
                 'parametres', parametres, 'ouvertes', (select count(*) from pilotage.alertes a where a.regle = r.cle and a.statut = 'ouverte')) order by domaine, libelle) from pilotage.regles r),
    'obligations', (select jsonb_agg(to_jsonb(o) order by o.domaine, o.id) from pilotage.obligations o),
    'calendriers', (select jsonb_agg(jsonb_build_object('nature', c.nature, 'ordre', c.ordre, 'jours', c.jours, 'libelle', c.libelle, 'canal', c.canal, 'modele', c.modele)
                 order by c.nature, c.jours, c.ordre) from pilotage.calendriers c),
    'membres', (select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'prenom', m.prenom, 'role', m.role, 'actif', m.actif,
                 'email', (select email from auth.users u where u.id = m.user_id),
                 'mandats', (select coalesce(jsonb_agg(t.mandat_id), '[]'::jsonb) from pilotage.attributions t where t.user_id = m.user_id)) order by m.prenom) from pilotage.membres m),
    'mandats', (select jsonb_agg(jsonb_build_object('id', id, 'reference', reference, 'nom', nom, 'statut', statut) order by lpad(reference, 6, '0')) from pilotage.v_mandats)
  );
end $$;

-- Modifier un délai d'une règle (contrôles de cohérence : jour du mois entre 1 et 28, échéance des baux dans l'ordre et avant la limite légale)
create or replace function public.pilotage_regle_parametre(p_cle text, p_nom text, p_valeur numeric) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare u text; t text; legal numeric;
begin
  if pilotage.mon_role() <> 'direction' then raise exception 'Accès refusé'; end if;
  select x->>'unite' into u from pilotage.regles r, jsonb_array_elements(r.parametres) x where r.cle = p_cle and x->>'nom' = p_nom;
  if u is null then raise exception 'Réglage inconnu'; end if;
  if p_valeur is null or p_valeur < 0 then raise exception 'Valeur invalide'; end if;
  if u = 'jour du mois' and (p_valeur < 1 or p_valeur > 28 or p_valeur <> trunc(p_valeur)) then raise exception 'Jour du mois entre 1 et 28'; end if;
  if u = 'jours' and p_valeur <> trunc(p_valeur) then raise exception 'Nombre de jours entier attendu'; end if;
  update pilotage.regles r set parametres = (select jsonb_agg(case when x->>'nom' = p_nom then jsonb_set(x, '{valeur}', to_jsonb(p_valeur)) else x end order by o)
                                             from jsonb_array_elements(r.parametres) with ordinality e(x, o))
   where r.cle = p_cle;
  if p_cle = 'bail_echeance' then
    foreach t in array array['commercial', 'vide', 'meuble'] loop
      legal := case t when 'meuble' then 3 else 6 end;
      if not (pilotage.param(p_cle, 'info_' || t, 0) >= pilotage.param(p_cle, 'relance_' || t, 0)
              and pilotage.param(p_cle, 'relance_' || t, 0) >= pilotage.param(p_cle, 'decision_' || t, 0)
              and pilotage.param(p_cle, 'decision_' || t, 0) > legal) then
        raise exception 'Bail %: il faut information ≥ relance ≥ décision, et décision avant la limite légale du congé (% mois)', t, legal;
      end if;
    end loop;
  end if;
  if p_cle = 'impaye_zelok_declarer' and pilotage.param(p_cle, 'jour_debut', 16) > pilotage.param(p_cle, 'jour_fin', 19) then
    raise exception 'Le jour de début doit précéder le dernier jour';
  end if;
end $$;
revoke all on function public.pilotage_regle_parametre(text, text, numeric) from public, anon;
grant execute on function public.pilotage_regle_parametre(text, text, numeric) to authenticated;

-- Contrôle : chaque règle avec délais, et preuve que les contrôles lisent bien les réglages
select cle, jsonb_array_length(parametres) nb_delais from pilotage.regles where parametres <> '[]'::jsonb order by cle;
