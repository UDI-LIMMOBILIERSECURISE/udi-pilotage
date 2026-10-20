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
