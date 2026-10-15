-- Reprise du tableau Monday « UDI Gestion - Suivi IMPAYES » (15/10/2026).
-- Appliqué sur Supabase par les migrations pilotage_impayes_monday et pilotage_import_monday (historique des migrations du projet),
-- puis deux retouches de pilotage_import_monday : maj_par laissé vide à l'import, et date d'activité recalculée
-- uniquement pour les dossiers jamais modifiés dans le pilotage (maj_par is null).
--
-- Schéma :
--   pilotage.impayes : bail_id devient facultatif (dossiers Monday portant sur des baux pas encore dans Rivage) ;
--     ajout monday_id (unique), titre, garantie_bail (colonne GARANTIE liée au bail), intervenants (colonne Personne),
--     coordonnées propres au dossier (bailleur_civilite, bailleur_nom, nature_bien, adresse, mail_bailleur_1/2,
--     locataire_civilite, locataire_nom, tel_locataire) ; dette_remb_loc et indemnisation_a_rembourser passent en texte
--     (statuts Monday : OUI / PARTIEL / NON, OK FAIT…).
--   pilotage.impayes_notes : fil des mises à jour (messages et réponses), monday_post_id unique.
--
-- Fonctions (schéma public, préfixe pilotage_) :
--   pilotage_impayes()                     liste des dossiers (+ nb de commentaires, dernier commentaire)
--   pilotage_impaye_notes(p_impaye)        fil des échanges d'un dossier
--   pilotage_impaye_note(p_impaye, p_contenu, p_parent)   publier un commentaire (direction, superviseur, gestionnaire, comptable)
--   pilotage_impaye_maj(p_id, p_champ, p_valeur)          liste blanche étendue aux coordonnées et à bail_id (contrôlé)
--   pilotage_import_monday(p_items, p_notes)              import d'un export Excel Monday, direction seulement, rejouable sans doublon
--
-- L'export est lu dans le navigateur (src/importMonday.js) : groupes Monday -> sections, colonnes par position,
-- sous-éléments -> actions, onglet « updates » -> commentaires (réponses rattachées au message d'origine).
alter table pilotage.impayes alter column bail_id drop not null;
alter table pilotage.impayes
  add column if not exists monday_id bigint unique, add column if not exists titre text, add column if not exists garantie_bail text,
  add column if not exists intervenants text, add column if not exists bailleur_civilite text, add column if not exists bailleur_nom text,
  add column if not exists nature_bien text, add column if not exists adresse text, add column if not exists mail_bailleur_1 text,
  add column if not exists mail_bailleur_2 text, add column if not exists locataire_civilite text, add column if not exists locataire_nom text,
  add column if not exists tel_locataire text;
alter table pilotage.impayes alter column dette_remb_loc type text using dette_remb_loc::text;
alter table pilotage.impayes alter column indemnisation_a_rembourser type text using indemnisation_a_rembourser::text;
alter table pilotage.impayes alter column groupe set default 'GLI ZELOK';
create table if not exists pilotage.impayes_notes (
  id bigserial primary key,
  impaye_id bigint not null references pilotage.impayes(id) on delete cascade,
  parent_id bigint references pilotage.impayes_notes(id) on delete cascade,
  auteur text, auteur_id uuid, le timestamptz not null default now(), contenu text not null,
  pieces_jointes int not null default 0, monday_post_id bigint unique
);
