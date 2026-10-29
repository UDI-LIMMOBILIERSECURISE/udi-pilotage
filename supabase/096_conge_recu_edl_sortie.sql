-- 096 — Congé reçu et état des lieux de sortie : alertes à la gestionnaire, fiche du congé, mails et SMS corrigés (Nicolas, 29/10/2026).
-- Constat : un congé saisi dans Rivage (bail 86) ne créait qu'une alerte « reversement du dépôt » à la comptable ; rien pour Marion.
-- Les modèles « congé » de 091 parlaient de relocation au bailleur et ne demandaient pas le dépôt.
-- Décisions de Nicolas (29/10) :
--   1. À la réception du congé (bail en sortie dans Rivage, départ à venir) : alerte « Congé reçu » à la gestionnaire.
--      Au bailleur : on l'informe du congé et de la date de sortie, et on lui demande de reverser le dépôt de garantie s'il le
--      détient (IBAN de l'agence, paramètre iban_agence). Au locataire : accusé de réception du congé et de la date de sortie.
--   2. La gestionnaire commande l'état des lieux de sortie : mail au prestataire (sauf EDL fait en interne) et mail au locataire
--      pour le prévenir qu'il va être contacté, en rappelant que le logement doit être vide, propre et l'électricité active.
--   3. Une fois la date de l'EDL saisie dans la fiche du congé : mail de confirmation et SMS de rappel au locataire.
--      Le SMS au locataire part de UDI GESTION (Twilio) quand c'est la gestion qui l'envoie.
-- Fiche du congé (nouvelle table) : réception, nouvelle adresse du locataire, pré-visite (Marion décide), EDL (interne ou
-- prestataire, commandé le, date, heure, intervenant), suite voulue par le bailleur (relouer, reprendre, vendre), notes.
-- Le mail au bailleur préparé (pas « pas nécessaire ») avec un dépôt chez le bailleur note la demande de reversement dans le
-- suivi du dépôt (dg_suivi.demande_le) : l'alerte de la comptable passe alors aux relances, sans double demande.
-- Retour arrière : update pilotage.regles set actif = false where cle in ('conge_recu', 'edl_sortie_a_commander', 'edl_sortie_a_confirmer').
-- Données : une table, trois règles, deux paramètres (prestataire EDL), trois modèles ajoutés, six modèles réécrits s'ils n'ont
-- pas été modifiés dans l'appli ; fonctions remplacées : messages_contexte, messages_categories_actives, pilotage_messages_dossier,
-- pilotage_messages_a_envoyer, etapes_detections, pilotage_message_noter. Aucune donnée Rivage modifiée.
-- À passer en quatre blocs, dans l'ordre.


-- ============================================================================================================================
-- BLOC 1 / 4 : fiche du congé, règles, paramètres, modèles
-- ============================================================================================================================
begin;

create table if not exists pilotage.fiches_conge (
  bail_id text primary key,
  recu_le date,
  nouvelle_adresse text,
  previsite boolean,
  previsite_le date,
  previsite_heure text,
  edl_par text check (edl_par in ('interne', 'prestataire')),
  edl_commande_le date,
  edl_le date,
  edl_heure text,
  edl_intervenant text,
  edl_maj_le timestamptz,
  suite text check (suite in ('relouer', 'reprise', 'vente')),
  notes text,
  maj_par uuid,
  maj_le timestamptz not null default now()
);
alter table pilotage.fiches_conge enable row level security;
revoke all on pilotage.fiches_conge from public, anon, authenticated;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire) values
 ('conge_recu', 'Congé reçu : informer le bailleur et accuser réception au locataire', 'Baux habitation', 'haute', 'courrier', true,
  'Bail en sortie dans Rivage, départ à venir : informer le bailleur du congé et de la date de sortie (et lui demander de reverser le dépôt de garantie s''il le détient), accuser réception au locataire. Décider s''il y a une pré-visite. L''alerte disparaît quand les deux mails sont préparés ou marqués « pas nécessaire ».',
  '[]'::jsonb, 'gestion'),
 ('edl_sortie_a_commander', 'État des lieux de sortie à commander', 'Baux habitation', 'haute', 'tache', true,
  'Bail en sortie, départ à venir, EDL ni commandé ni daté dans la fiche du congé : commander l''EDL (prestataire ou interne) et prévenir le locataire qu''il va être contacté (logement vide, propre, électricité active). L''alerte disparaît quand le mail au prestataire est préparé ou quand une date d''EDL est saisie.',
  '[]'::jsonb, 'gestion'),
 ('edl_sortie_a_confirmer', 'État des lieux de sortie : rendez-vous à confirmer au locataire', 'Baux habitation', 'normale', 'courrier', true,
  'Date d''EDL de sortie saisie dans la fiche du congé : envoyer au locataire la confirmation du rendez-vous (mail) et le rappel (SMS). L''alerte disparaît quand le mail est préparé après la dernière modification de la date.',
  '[]'::jsonb, 'gestion')
on conflict (cle) do nothing;

insert into pilotage.parametres (cle, valeur) values ('edl_prestataire_nom', 'France EDL'), ('edl_prestataire_email', '')
on conflict (cle) do nothing;

alter table pilotage.messages_journal drop constraint if exists messages_journal_moyen_check;
alter table pilotage.messages_journal add constraint messages_journal_moyen_check check (moyen in ('gmail', 'telephone', 'qr', 'copie', 'inutile', 'twilio'));
alter table pilotage.messages_modeles drop constraint if exists messages_modeles_cible_check;
alter table pilotage.messages_modeles add constraint messages_modeles_cible_check check (cible in ('bailleur', 'locataire', 'garant', 'prestataire'));

update pilotage.messages_categories set libelle = 'Congé reçu',
       quand = 'Bail en sortie dans Rivage (congé reçu) : proposé jusqu''à la date de sortie. Alerte « Congé reçu » à la gestionnaire.'
 where cle = 'conge';
update pilotage.messages_categories set libelle = 'État des lieux de sortie', jours_avant = null, jours_apres = 2,
       quand = 'Bail en sortie : proposé dès le congé (commande de l''EDL, avis au locataire) jusqu''à « jours après » la sortie. La confirmation et le rappel au locataire attendent la date de l''EDL saisie dans la fiche du congé.'
 where cle = 'edl_sortie';

-- Textes remplacés seulement s'ils n'ont pas été modifiés dans l'appli (modifie_le vide)
update pilotage.messages_modeles set libelle = 'Mail au locataire : accusé de réception du congé',
  objet = 'Accusé de réception de votre congé : {adresse}',
  texte = '{bonjour}

Nous accusons réception de votre congé pour le logement situé {adresse}. La fin de votre location est fixée au {date_sortie}.

Le loyer et les charges restent dus jusqu''à cette date.

L''état des lieux de sortie sera organisé avant votre départ : vous serez contacté pour convenir du rendez-vous.

Merci de nous communiquer votre nouvelle adresse, pour l''envoi du solde de votre dépôt de garantie.
{signature}', ordre = 1
 where code = 'cg_locataire_email' and modifie_le is null;

update pilotage.messages_modeles set libelle = 'SMS au locataire : congé bien reçu',
  texte = 'Bonjour {nom}, nous accusons réception de votre congé pour {adresse}, fin de location le {date_sortie}. Vous allez recevoir un mail avec la suite. UDI Gestion', ordre = 2
 where code = 'cg_locataire_sms' and modifie_le is null;

update pilotage.messages_modeles set libelle = 'Mail au bailleur : congé du locataire et dépôt de garantie',
  objet = 'Congé de votre locataire : {adresse}',
  texte = '{bonjour}

Nous avons reçu le congé de votre locataire {locataire} pour le bien situé {adresse}. Son départ est fixé au {date_sortie}.

{paragraphe_dg}

Merci de nous indiquer si vous souhaitez remettre le bien en location ou le reprendre. En cas de relocation, nous pouvons lancer la recherche d''un nouveau locataire dès maintenant, pour limiter la vacance.
{signature}', ordre = 3
 where code = 'cg_bailleur_email' and modifie_le is null;

update pilotage.messages_modeles set libelle = 'SMS au bailleur : congé du locataire',
  texte = 'Bonjour {nom}, votre locataire de {adresse} nous a donné son congé, départ le {date_sortie}. Je vous envoie le détail par mail. {commercial}, UDI Gestion', ordre = 4
 where code = 'cg_bailleur_sms' and modifie_le is null;

update pilotage.messages_modeles set libelle = 'Mail au locataire : confirmation du rendez-vous d''état des lieux',
  objet = 'État des lieux de sortie le {date_edl} : {adresse}',
  texte = '{bonjour}

L''état des lieux de sortie de votre logement situé {adresse} aura lieu le {date_edl} à {heure_edl}.

Le jour du rendez-vous, le logement doit être :
- entièrement vidé de vos meubles et effets personnels ;
- propre et nettoyé (sols, sanitaires, cuisine, placards) ;
- avec l''électricité active, pour le contrôle des équipements et le relevé des compteurs : ne résiliez pas votre contrat avant l''état des lieux.

Merci de prévoir toutes les clés, badges et télécommandes, et de nous indiquer votre nouvelle adresse pour l''envoi du dépôt de garantie.

En cas de retard ou d''empêchement, merci de nous prévenir au plus vite : le rendez-vous pourra devoir être reporté.
{signature}', ordre = 4
 where code = 'es_locataire_email' and modifie_le is null;

update pilotage.messages_modeles set libelle = 'SMS au locataire : rappel du rendez-vous d''état des lieux',
  texte = 'Bonjour {nom}, rappel : état des lieux de sortie de {adresse} le {date_edl} à {heure_edl}. Logement vide et propre, électricité active, toutes les clés à rendre. UDI Gestion', ordre = 5
 where code = 'es_locataire_sms' and modifie_le is null;

insert into pilotage.messages_modeles (code, categorie, canal, cible, envoi, libelle, objet, texte, ordre) values
 ('es_prestataire_email', 'edl_sortie', 'email', 'prestataire', 'commercial', 'Mail au prestataire : commande de l''état des lieux de sortie',
  'Commande d''état des lieux de sortie : {adresse}',
'Bonjour,

Nous vous confirmons la commande d''un état des lieux de sortie pour le logement situé {adresse} (bail {reference}).

Départ du locataire : {date_sortie}
Locataire(s) :
{locataire_contacts}

Merci de prendre contact directement avec le locataire pour fixer le rendez-vous avant son départ, et de nous confirmer la date retenue. Vous trouverez l''état des lieux d''entrée en pièce jointe.
{signature}', 1),
 ('es_avis_email', 'edl_sortie', 'email', 'locataire', 'commercial', 'Mail au locataire : vous allez être contacté pour l''état des lieux',
  'Votre état des lieux de sortie : {adresse}',
'{bonjour}

Votre départ du logement situé {adresse} est prévu le {date_sortie}. L''état des lieux de sortie est commandé : vous allez être contacté prochainement pour fixer le rendez-vous.

Le jour de l''état des lieux, le logement doit être :
- entièrement vidé de vos meubles et effets personnels ;
- propre et nettoyé (sols, sanitaires, cuisine, placards) ;
- avec l''électricité active, pour le contrôle des équipements et le relevé des compteurs : ne résiliez pas votre contrat avant l''état des lieux.

Merci de prévoir toutes les clés, badges et télécommandes.
{signature}', 2),
 ('es_avis_sms', 'edl_sortie', 'sms', 'locataire', 'commercial', 'SMS au locataire : vous allez être contacté pour l''état des lieux', null,
  'Bonjour {nom}, l''état des lieux de sortie de {adresse} est commandé : vous allez être contacté pour fixer le rendez-vous. Le logement devra être vide, propre, électricité active. UDI Gestion', 3)
on conflict (code) do nothing;

commit;


-- ============================================================================================================================
-- BLOC 2 / 4 : fiche du congé, contexte des messages
-- ============================================================================================================================
begin;

-- Date de départ d'un bail en sortie : dernière sortie annoncée des locataires, sinon fin du bail (même règle que 094)
create or replace function pilotage.sortie_prevue(p_bail text) returns date
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce((select max(nullif(t->>'exit_date', '')::date) from jsonb_array_elements(o.data->'tenants') t), v.fin)
    from pilotage.v_baux v join pilotage.objets o on o.type = 'LeasingContract' and o.id = v.id
   where v.id = p_bail
$$;

-- Détenteur du dépôt : saisie de la gestion (Sorties et DG), sinon Rivage
create or replace function pilotage.dg_detenteur(p_bail text) returns text
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce((select s.detenu_par from pilotage.dg_suivi s where s.bail_id = p_bail), pilotage.dg_detenteur_rivage(p_bail))
$$;

create or replace function public.pilotage_fiche_conge(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare f pilotage.fiches_conge;
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() = 'comptable') then raise exception 'Accès refusé'; end if;
  select * into f from pilotage.fiches_conge where bail_id = p_bail;
  return jsonb_build_object(
    'fiche', case when f.bail_id is null then null else to_jsonb(f) - 'maj_par' || jsonb_build_object('maj_par_prenom', pilotage.prenom_membre(f.maj_par)) end,
    'statut', (select v.statut from pilotage.v_baux v where v.id = p_bail),
    'sortie', pilotage.sortie_prevue(p_bail),
    'dg', jsonb_build_object('detenteur', pilotage.dg_detenteur(p_bail), 'rivage', pilotage.dg_detenteur_rivage(p_bail),
                             'demande_le', (select s.demande_le from pilotage.dg_suivi s where s.bail_id = p_bail)),
    'prestataire', jsonb_build_object('nom', (select nullif(valeur, '') from pilotage.parametres where cle = 'edl_prestataire_nom'),
                                      'email', (select nullif(valeur, '') from pilotage.parametres where cle = 'edl_prestataire_email')),
    'peut', pilotage.peut_suivre_baux());
end $$;

-- Enregistrement d'une partie des champs de la fiche ; une valeur vide efface le champ
create or replace function public.pilotage_fiche_conge_maj(p_bail text, p_valeurs jsonb) returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
declare f pilotage.fiches_conge; avant pilotage.fiches_conge; v jsonb;
  champs constant text[] := array['recu_le', 'nouvelle_adresse', 'previsite', 'previsite_le', 'previsite_heure', 'edl_par', 'edl_commande_le',
                                  'edl_le', 'edl_heure', 'edl_intervenant', 'suite', 'notes'];
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.v_baux where id = p_bail) then raise exception 'Bail inconnu'; end if;
  select coalesce(jsonb_object_agg(key, case when value in ('""'::jsonb, 'null'::jsonb) or (jsonb_typeof(value) = 'string' and trim(value #>> '{}') = '') then 'null'::jsonb
                                             when jsonb_typeof(value) = 'string' then to_jsonb(trim(value #>> '{}')) else value end), '{}'::jsonb)
    into v from jsonb_each(coalesce(p_valeurs, '{}'::jsonb)) where key = any(champs);
  select * into avant from pilotage.fiches_conge where bail_id = p_bail;
  if avant.bail_id is null then f.bail_id := p_bail; else f := avant; end if;
  f := jsonb_populate_record(f, v);
  if f.edl_heure is not null then
    if f.edl_heure !~ '^\s*([01]?\d|2[0-3])\s*[:hH]\s*([0-5]\d)?\s*$' then raise exception 'Heure de l''état des lieux : format 14:30 ou 14h30'; end if;
    f.edl_heure := lpad(substring(f.edl_heure from '^\s*(\d{1,2})'), 2, '0') || 'h' || coalesce(substring(f.edl_heure from '[:hH]\s*([0-5]\d)'), '00');
  end if;
  if f.previsite_heure is not null and f.previsite_heure !~ '^\s*([01]?\d|2[0-3])\s*[:hH]\s*([0-5]\d)?\s*$' then raise exception 'Heure de la pré-visite : format 14:30 ou 14h30'; end if;
  if f.edl_commande_le > current_date or f.recu_le > current_date then raise exception 'Date dans le futur'; end if;
  if f.edl_le < coalesce(f.edl_commande_le, f.edl_le) then raise exception 'La date de l''état des lieux est avant sa commande'; end if;
  if f.previsite is not true then f.previsite_le := null; f.previsite_heure := null; end if;
  if avant.bail_id is null or f.edl_le is distinct from avant.edl_le or f.edl_heure is distinct from avant.edl_heure then
    f.edl_maj_le := case when f.edl_le is null then null else now() end;
  end if;
  f.maj_par := auth.uid(); f.maj_le := now();
  insert into pilotage.fiches_conge values (f.*)
  on conflict (bail_id) do update set recu_le = excluded.recu_le, nouvelle_adresse = excluded.nouvelle_adresse, previsite = excluded.previsite,
    previsite_le = excluded.previsite_le, previsite_heure = excluded.previsite_heure, edl_par = excluded.edl_par, edl_commande_le = excluded.edl_commande_le,
    edl_le = excluded.edl_le, edl_heure = excluded.edl_heure, edl_intervenant = excluded.edl_intervenant, edl_maj_le = excluded.edl_maj_le,
    suite = excluded.suite, notes = excluded.notes, maj_par = excluded.maj_par, maj_le = excluded.maj_le;
  return public.pilotage_fiche_conge(p_bail);
end $$;

-- 096 : champs du congé et de l'EDL de sortie (fiche du congé), paragraphe du dépôt pour le bailleur, contacts du locataire
create or replace function pilotage.messages_contexte(p_objet text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare moi uuid := auth.uid(); c jsonb; prenom text := pilotage.prenom_membre(auth.uid()); r record; contacts jsonb; v jsonb;
  f pilotage.fiches_conge; dg text;
  dfr constant text := 'DD/MM/YYYY';
begin
  c := jsonb_build_object('commercial', prenom, 'email_commercial', (select lower(email) from auth.users where id = moi),
    'email_gestion', 'votregestionnaire@udi-immo.com', 'signature', E'\nBien cordialement,\n' || coalesce(prenom, '') || E'\nUDI Gestion',
    'iban', (select valeur from pilotage.parametres where cle = 'iban_agence'));
  if p_objet = 'bail' then
    select v2.*, l.adresse adr,
           (select max(nullif(t->>'exit_date', '')::date) from jsonb_array_elements(o.data->'tenants') t) sortie,
           o.data->'guarantors' garants
      into r
      from pilotage.v_baux v2 join pilotage.objets o on o.type = 'LeasingContract' and o.id = v2.id
      left join pilotage.v_lots l on l.id = v2.lot_id
     where v2.id = p_id;
    if r.id is null then raise exception 'Bail inconnu'; end if;
    contacts := pilotage.contacts_bail(p_id)
      || jsonb_build_object('garants', coalesce((select jsonb_agg(jsonb_build_object('nom', pilotage.nom_profil(g->>'id'), 'email', p.data->>'email', 'telephone', p.data->>'phone_number'))
                                                   from jsonb_array_elements(coalesce(r.garants, '[]'::jsonb)) g
                                                   left join pilotage.objets p on p.type = 'Profile' and p.id = g->>'id'
                                                  where nullif(g->>'exit_date', '') is null), '[]'::jsonb));
    v := pilotage.virement_entree(p_id);
    select * into f from pilotage.fiches_conge where bail_id = p_id;
    dg := pilotage.dg_detenteur(p_id);
    c := c || jsonb_build_object('adresse', r.adr, 'reference', r.reference,
      'date_debut', to_char(r.debut, dfr), 'date_fin', to_char(r.fin, dfr), 'date_sortie', to_char(coalesce(r.sortie, r.fin), dfr),
      'loyer', pilotage.euros(r.loyer_hc), 'charges', pilotage.euros(r.charges), 'loyer_cc', pilotage.euros(coalesce(r.loyer_hc, 0) + coalesce(r.charges, 0)),
      'depot', pilotage.euros(r.depot_garantie), 'jour_echeance', r.jour_echeance::text,
      'detail_virement', (select string_agg('- ' || (x->>'libelle') || ' : ' || pilotage.euros((x->>'montant')::numeric), E'\n')
                            from jsonb_array_elements(v->'lignes') x),
      'total_virement', pilotage.euros((v->>'total')::numeric),
      'date_edl', to_char(f.edl_le, dfr), 'heure_edl', f.edl_heure, 'nouvelle_adresse', f.nouvelle_adresse,
      'locataire_contacts', (select string_agg('- ' || pilotage.nom_sms(x->>'nom') || coalesce(' · ' || nullif(trim(x->>'telephone'), ''), '')
                                               || coalesce(' · ' || nullif(lower(trim(x->>'email')), ''), ''), E'\n')
                               from jsonb_array_elements(coalesce(contacts->'locataires', '[]'::jsonb)) x),
      '_doublons', v->'doublons', '_edl_par', f.edl_par, '_edl_maj_le', f.edl_maj_le, '_dg', dg,
      '_statut', r.statut, '_debut', r.debut, '_sortie', coalesce(r.sortie, r.fin));
  else
    select m.*, (select string_agg(l.adresse, ' ; ' order by l.adresse) from pilotage.v_lots l where l.mandat_id = m.id) adr into r
      from pilotage.v_mandats m where m.id = p_id;
    if r.id is null then raise exception 'Mandat inconnu'; end if;
    contacts := pilotage.contacts_mandat(p_id);
    c := c || jsonb_build_object('adresse', r.adr, 'reference', r.reference, 'date_signature', to_char(r.signe_le, dfr))
           || coalesce((select jsonb_build_object('adresse', coalesce(l.adresse, r.adr), 'loyer_prevu', pilotage.euros(a.loyer_prevu),
                                                  'date_disponible', to_char(a.disponible_le, dfr), '_a_louer_depuis', a.depuis)
                          from pilotage.lots_a_louer a join pilotage.v_lots l on l.id = a.asset_id
                         where l.mandat_id = p_id and a.sorti_le is null order by a.depuis limit 1), '{}'::jsonb);
  end if;
  c := c || jsonb_build_object(
    'locataire', (select string_agg(pilotage.nom_sms(x->>'nom'), ', ') from jsonb_array_elements(coalesce(contacts->'locataires', '[]'::jsonb)) x),
    'bailleur', (select string_agg(pilotage.nom_sms(x->>'nom'), ', ') from jsonb_array_elements(coalesce(contacts->'bailleurs', '[]'::jsonb)) x),
    'libelle_virement', 'Bail ' || coalesce(c->>'reference', '') || ' - ' ||
        coalesce((select string_agg(distinct upper(split_part(pilotage.nom_sms(x->>'nom'), ' ', -1)), ' ') from jsonb_array_elements(coalesce(contacts->'locataires', '[]'::jsonb)) x), ''),
    '_contacts', contacts);
  if p_objet = 'bail' then
    -- Paragraphe du dépôt dans le mail au bailleur : vide (le champ reste à saisir) si le détenteur est inconnu ou l'IBAN absent
    c := c || jsonb_build_object('paragraphe_dg', case
      when dg = 'bailleur' and nullif(c->>'iban', '') is not null then
        'Vous détenez le dépôt de garantie de ' || coalesce(c->>'depot', '?') || '. Pour que nous puissions le restituer au locataire dans le délai légal '
        || '(un mois après la remise des clés si l''état des lieux de sortie est conforme, deux mois sinon), merci de nous le reverser avant son départ, '
        || 'sur le compte de l''agence :' || E'\nIBAN : ' || (c->>'iban') || E'\nLibellé du virement : DG ' || (c->>'libelle_virement')
      when dg = 'agence' then
        'Le dépôt de garantie est détenu par l''agence : nous nous chargeons de sa restitution au locataire après l''état des lieux de sortie, '
        || 'déduction faite des sommes éventuellement dues.' end);
  end if;
  return c;
end $$;

commit;


-- ============================================================================================================================
-- BLOC 3 / 4 : étapes actives, messages d'un dossier, messages à envoyer, détections
-- ============================================================================================================================
begin;

-- Étapes actives d'un dossier : 096, l'EDL de sortie est proposé dès le congé (commande, avis au locataire)
create or replace function pilotage.messages_categories_actives(p_objet text, p_id text) returns text[]
language plpgsql stable security definer set search_path = pilotage, public as $$
declare res text[] := '{}'; c jsonb := pilotage.messages_contexte(p_objet, p_id); k pilotage.messages_categories; d date := current_date;
  debut date; sortie date; signe date;
begin
  for k in select * from pilotage.messages_categories loop
    if p_objet = 'bail' and k.objet = 'bail' then
      debut := (c->>'_debut')::date; sortie := (c->>'_sortie')::date;
      if k.cle = 'nouveau_bail' and pilotage.dossier_nouveau('LeasingContract', p_id) and c->>'_statut' in ('created', 'in_progress')
         and debut >= d - coalesce(k.jours_apres, 30) then res := res || k.cle; end if;
      if k.cle = 'edl_entree' and c->>'_statut' = 'created'
         and debut between d - coalesce(k.jours_apres, 5) and d + coalesce(k.jours_avant, 21) then res := res || k.cle; end if;
      if k.cle = 'conge' and c->>'_statut' = 'move_out' and sortie >= d then res := res || k.cle; end if;
      if k.cle = 'edl_sortie' and c->>'_statut' = 'move_out' and sortie >= d - coalesce(k.jours_apres, 2) then res := res || k.cle; end if;
    elsif p_objet = 'mandat' and k.objet = 'mandat' then
      if k.cle = 'nouveau_mandat' and pilotage.dossier_nouveau('ManagementContract', p_id)
         and not exists (select 1 from pilotage.mandats_suivi s where s.mandat_id = p_id and s.retire_le is not null) then
        signe := coalesce((select m.signe_le from pilotage.v_mandats m where m.id = p_id),
                          (select o.recu_le::date from pilotage.objets o where o.type = 'ManagementContract' and o.id = p_id));
        if signe >= d - coalesce(k.jours_apres, 60) then res := res || k.cle; end if;
      end if;
      if k.cle = 'mise_en_location' and c ? '_a_louer_depuis' then res := res || k.cle; end if;
    end if;
  end loop;
  return res;
end $$;

-- Messages d'un dossier : 096, destinataire « prestataire » (paramètres edl_prestataire_*, sauf EDL fait en interne),
-- message « en attente » tant que la date de l'EDL n'est pas saisie, texte prêt pour l'envoi UDI GESTION (Twilio) des SMS au locataire.
create or replace function public.pilotage_messages_dossier(p_objet text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); c jsonb; actives text[]; m pilotage.messages_modeles; dest jsonb; x jsonb; res jsonb := '[]'::jsonb;
  ctx jsonb; nb int; depuis timestamptz; avert text; av text; attente text; presta jsonb;
begin
  if r is null or p_objet not in ('mandat', 'bail') then raise exception 'Accès refusé'; end if;
  if r = 'negociateur' and coalesce(pilotage.commercial_dossier(p_objet, p_id), auth.uid()) <> auth.uid() then raise exception 'Accès refusé'; end if;
  c := pilotage.messages_contexte(p_objet, p_id);
  actives := pilotage.messages_categories_actives(p_objet, p_id);
  depuis := case when 'mise_en_location' = any(actives) then (c->>'_a_louer_depuis')::timestamptz end;
  avert := case when p_objet = 'bail' and c->>'detail_virement' is null then 'Rivage n''a pas encore les lignes de facturation de l''entrée (prorata, dépôt, honoraires) : montants à saisir à la main ou à attendre.'
                when p_objet = 'bail' and jsonb_array_length(coalesce(c->'_doublons', '[]'::jsonb)) > 0
                  then 'Ligne en double dans Rivage, comptée une seule fois : ' || (select string_agg(d, ', ') from jsonb_array_elements_text(c->'_doublons') d) || '. À vérifier dans Rivage.' end;
  presta := jsonb_build_array(jsonb_build_object('nom', (select nullif(valeur, '') from pilotage.parametres where cle = 'edl_prestataire_nom'),
                                                 'email', (select nullif(valeur, '') from pilotage.parametres where cle = 'edl_prestataire_email')));
  for m in select mm.* from pilotage.messages_modeles mm join pilotage.messages_categories k on k.cle = mm.categorie
            where mm.actif and mm.envoi = 'commercial' and k.objet = p_objet order by k.ordre, mm.ordre loop
    continue when m.cible = 'prestataire' and c->>'_edl_par' = 'interne';
    dest := case m.cible when 'prestataire' then presta
                 else coalesce(c->'_contacts'->(case m.cible when 'bailleur' then 'bailleurs' when 'garant' then 'garants' else 'locataires' end), '[]'::jsonb) end;
    nb := jsonb_array_length(dest);
    continue when m.cible = 'garant' and nb = 0;
    attente := case when coalesce(m.objet, '') || m.texte like '%{date_edl}%' and c->>'date_edl' is null
                    then 'À préparer quand la date de l''état des lieux sera saisie dans la fiche du congé.' end;
    av := concat_ws(' ',
      case when m.texte like '%{total_virement}%' or m.texte like '%{detail_virement}%' then avert end,
      case when m.texte like '%{paragraphe_dg}%' and c->>'paragraphe_dg' is null then
        case when c->>'_dg' is null then 'Détenteur du dépôt de garantie inconnu (ni Rivage ni l''onglet Sorties et DG) : le préciser, ou rédiger le paragraphe à la main.'
             else 'IBAN de l''agence absent des paramètres : paragraphe du dépôt à rédiger à la main.' end end,
      case when m.cible = 'prestataire' then 'Joindre l''état des lieux d''entrée au brouillon.'
        || case when presta->0->>'email' is null then ' Adresse e-mail du prestataire à saisir dans Gmail (paramètre edl_prestataire_email vide).' else '' end end);
    if m.canal = 'email' then
      ctx := c || jsonb_build_object('nom', (select string_agg(pilotage.nom_sms(y->>'nom'), ', ') from jsonb_array_elements(dest) y),
        'bonjour', case when m.cible = 'prestataire' then 'Bonjour,' when nb = 1 then 'Bonjour ' || pilotage.nom_sms(dest->0->>'nom') || ',' else 'Bonjour,' end);
      res := res || jsonb_build_object('code', m.code, 'categorie', m.categorie, 'canal', m.canal, 'cible', m.cible, 'libelle', m.libelle,
        'a', (select string_agg(lower(trim(y->>'email')), ', ') from jsonb_array_elements(dest) y where nullif(trim(y->>'email'), '') is not null),
        'objet', pilotage.message_remplir(m.objet, ctx), 'texte', pilotage.message_remplir(m.texte, ctx),
        'avertissement', nullif(av, ''), 'attente', attente,
        'fait', (select jsonb_build_object('le', j.le, 'moyen', j.moyen, 'par', pilotage.prenom_membre(j.par)) from pilotage.messages_journal j
                  where j.objet = p_objet and j.objet_id = p_id and j.code = m.code and (depuis is null or m.categorie <> 'mise_en_location' or j.le >= depuis)
                    and (m.texte not like '%{date_edl}%' or c->>'_edl_maj_le' is null or j.le >= (c->>'_edl_maj_le')::timestamptz)
                  order by j.le desc limit 1));
    else
      for x in select y from jsonb_array_elements(case when nb = 0 then '[{}]'::jsonb else dest end) y loop
        ctx := c || jsonb_build_object('nom', nullif(pilotage.nom_sms(x->>'nom'), ''),
                                       'bonjour', 'Bonjour ' || nullif(pilotage.nom_sms(x->>'nom'), '') || ',');
        res := res || jsonb_build_object('code', m.code, 'categorie', m.categorie, 'canal', m.canal, 'cible', m.cible,
          'libelle', m.libelle || case when nb > 1 then ' · ' || pilotage.nom_sms(x->>'nom') else '' end,
          'a', nullif(trim(x->>'telephone'), ''), 'texte', pilotage.message_remplir(m.texte, ctx),
          -- SMS au locataire envoyé par UDI GESTION : un envoi pour tous les locataires du bail, « {nom} » remplacé pour chacun
          'texte_twilio', case when m.cible = 'locataire' and p_objet = 'bail' then pilotage.message_remplir(m.texte, c) end,
          'avertissement', nullif(av, ''), 'attente', attente,
          'fait', (select jsonb_build_object('le', j.le, 'moyen', j.moyen, 'par', pilotage.prenom_membre(j.par)) from pilotage.messages_journal j
                    where j.objet = p_objet and j.objet_id = p_id and j.code = m.code
                      and (nb <= 1 or j.a is null or regexp_replace(j.a, '[^0-9]', '', 'g') = regexp_replace(coalesce(x->>'telephone', ''), '[^0-9]', '', 'g'))
                      and (depuis is null or m.categorie <> 'mise_en_location' or j.le >= depuis)
                      and (m.texte not like '%{date_edl}%' or c->>'_edl_maj_le' is null or j.le >= (c->>'_edl_maj_le')::timestamptz)
                    order by j.le desc limit 1));
      end loop;
    end if;
  end loop;
  return jsonb_build_object('actives', to_jsonb(actives),
    'categories', (select jsonb_agg(jsonb_build_object('cle', k.cle, 'libelle', k.libelle, 'active', k.cle = any(actives)) order by k.ordre)
                     from pilotage.messages_categories k where k.objet = p_objet and k.cle <> 'relances_gestion'),
    'messages', res);
end $$;

-- Trace d'un message : 096, moyen « twilio » (SMS UDI GESTION envoyé depuis la fiche)
create or replace function public.pilotage_message_noter(p_objet text, p_id text, p_code text, p_a text, p_objet_mail text, p_texte text, p_moyen text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); m pilotage.messages_modeles;
begin
  if r is null or p_objet not in ('mandat', 'bail') then raise exception 'Accès refusé'; end if;
  if r = 'negociateur' and coalesce(pilotage.commercial_dossier(p_objet, p_id), auth.uid()) <> auth.uid() then raise exception 'Accès refusé'; end if;
  if p_moyen = 'twilio' and not (pilotage.peut_suivre_baux() or r = 'comptable') then raise exception 'Accès refusé'; end if;
  select * into m from pilotage.messages_modeles where code = p_code;
  if m.code is null or m.envoi <> 'commercial' then raise exception 'Modèle inconnu'; end if;
  insert into pilotage.messages_journal (objet, objet_id, code, canal, a, objet_mail, texte, moyen, par)
  values (p_objet, p_id, p_code, m.canal, nullif(trim(p_a), ''), p_objet_mail, p_texte, p_moyen, auth.uid());
end $$;

-- Ma journée, « Messages à envoyer » : 096, un bail en sortie va à la gestionnaire (même avec un commercial rattaché) ;
-- les messages en attente de la date de l'EDL ne comptent pas.
create or replace function public.pilotage_messages_a_envoyer() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); moi uuid := auth.uid(); res jsonb := '[]'::jsonb; x record; d jsonb; restants jsonb;
begin
  if r is null then raise exception 'Accès refusé'; end if;
  if r not in ('negociateur', 'gestionnaire') then return '[]'::jsonb; end if;
  for x in
    select 'bail' objet, v.id, 'Bail ' || coalesce(v.reference, '') titre, l.adresse
      from pilotage.v_baux v left join pilotage.v_lots l on l.id = v.lot_id
     where (v.statut = 'move_out' and r = 'gestionnaire')
        or (v.statut in ('created', 'in_progress')
            and (pilotage.commercial_dossier('bail', v.id) = moi
                 or (pilotage.commercial_dossier('bail', v.id) is null and r = case when v.statut = 'created' then 'negociateur' else 'gestionnaire' end))
            and (v.statut <> 'in_progress' or v.debut >= current_date - 60))
    union all
    select 'mandat', m.id, coalesce(nullif(m.nom, ''), 'Mandat n°' || m.reference), (select string_agg(l.adresse, ' ; ') from pilotage.v_lots l where l.mandat_id = m.id)
      from pilotage.v_mandats m
     where (pilotage.commercial_dossier('mandat', m.id) = moi or (pilotage.commercial_dossier('mandat', m.id) is null and r = 'gestionnaire'))
       and (pilotage.dossier_nouveau('ManagementContract', m.id)
            or exists (select 1 from pilotage.lots_a_louer a join pilotage.v_lots l on l.id = a.asset_id where l.mandat_id = m.id and a.sorti_le is null))
  loop
    continue when cardinality(pilotage.messages_categories_actives(x.objet, x.id)) = 0;
    d := public.pilotage_messages_dossier(x.objet, x.id);
    select coalesce(jsonb_agg(jsonb_build_object('libelle', mm->>'libelle', 'canal', mm->>'canal')), '[]'::jsonb) into restants
      from jsonb_array_elements(d->'messages') mm
     where mm->>'categorie' in (select jsonb_array_elements_text(d->'actives')) and (mm->'fait' is null or mm->'fait' = 'null'::jsonb)
       and (mm->'attente' is null or mm->'attente' = 'null'::jsonb);
    continue when jsonb_array_length(restants) = 0;
    res := res || jsonb_build_object('objet', x.objet, 'id', x.id, 'titre', x.titre, 'adresse', x.adresse,
      'etapes', (select jsonb_agg(k.libelle order by k.ordre) from pilotage.messages_categories k where k.cle in (select jsonb_array_elements_text(d->'actives'))),
      'restants', restants);
  end loop;
  return res;
end $$;

-- Détections des étapes : nouveau bail à signer (094), congé reçu, EDL de sortie à commander, rendez-vous d'EDL à confirmer (096)
create or replace function pilotage.etapes_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  with s as (
    select b.id, b.reference, b.locataires, pilotage.sortie_prevue(b.id) sortie, f.edl_par, f.edl_commande_le, f.edl_le, f.edl_heure, f.edl_maj_le,
           'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id lien
      from pilotage.v_baux b left join pilotage.fiches_conge f on f.bail_id = b.id
     where b.statut = 'move_out')
  select 'bail_a_signer'::text, 'LeasingContract'::text, b.id,
         'Bail ' || coalesce(b.reference, '') || ' à signer : entrée le ' || to_char(b.debut, 'DD/MM/YYYY'),
         'Locataires : ' || coalesce(b.locataires, '?') || ' — envoyer au locataire le récapitulatif et le virement d''entrée, prévenir le bailleur',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
    from pilotage.v_baux b
   where b.statut = 'created' and b.debut >= current_date - 5 and pilotage.dossier_nouveau('LeasingContract', b.id)
     and not (exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = b.id and j.code = 'nb_locataire_email')
          and exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = b.id and j.code = 'nb_bailleur_email'))
  union all
  select 'conge_recu', 'LeasingContract', s.id,
         'Congé reçu : bail ' || coalesce(s.reference, '') || ', départ le ' || to_char(s.sortie, 'DD/MM/YYYY'),
         'Locataires : ' || coalesce(s.locataires, '?') || ' — accuser réception au locataire, informer le bailleur'
           || case when pilotage.dg_detenteur(s.id) = 'bailleur' then ' et lui demander de reverser le dépôt de garantie' else '' end
           || ' ; décider s''il y a une pré-visite (fiche du congé)', s.lien
    from s
   where s.sortie >= current_date
     and not (exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = s.id and j.code = 'cg_locataire_email')
          and exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = s.id and j.code = 'cg_bailleur_email'))
  union all
  select 'edl_sortie_a_commander', 'LeasingContract', s.id,
         'État des lieux de sortie à commander : bail ' || coalesce(s.reference, '') || ', départ le ' || to_char(s.sortie, 'DD/MM/YYYY'),
         'Locataires : ' || coalesce(s.locataires, '?') || ' — commander l''EDL (prestataire ou interne), prévenir le locataire qu''il va être contacté '
           || '(logement vide, propre, électricité active), puis saisir la date dans la fiche du congé', s.lien
    from s
   where s.sortie >= current_date and s.edl_commande_le is null and s.edl_le is null
  union all
  select 'edl_sortie_a_confirmer', 'LeasingContract', s.id,
         'État des lieux de sortie le ' || to_char(s.edl_le, 'DD/MM/YYYY') || coalesce(' à ' || s.edl_heure, '') || ' : rendez-vous à confirmer au locataire (bail ' || coalesce(s.reference, '') || ')',
         'Locataires : ' || coalesce(s.locataires, '?') || ' — envoyer la confirmation (mail) et le rappel (SMS)', s.lien
    from s
   where s.edl_le >= current_date
     and not exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = s.id and j.code = 'es_locataire_email'
                       and j.le >= coalesce(s.edl_maj_le, '-infinity'::timestamptz))
$$;

revoke all on function pilotage.sortie_prevue(text), pilotage.dg_detenteur(text), pilotage.etapes_detections() from public, anon, authenticated;
revoke all on function public.pilotage_fiche_conge(text), public.pilotage_fiche_conge_maj(text, jsonb) from public, anon;
grant execute on function public.pilotage_fiche_conge(text), public.pilotage_fiche_conge_maj(text, jsonb) to authenticated;

commit;


-- ============================================================================================================================
-- BLOC 4 / 4 : effets d'un message préparé (demande de reversement du dépôt, EDL commandé), puis contrôle immédiat
-- ============================================================================================================================
begin;

create or replace function pilotage.messages_journal_effets() returns trigger
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if new.objet <> 'bail' or new.moyen = 'inutile' then return new; end if;
  -- Mail au bailleur préparé avec un dépôt chez lui : la demande de reversement est faite
  if new.code = 'cg_bailleur_email' and pilotage.dg_detenteur(new.objet_id) = 'bailleur' then
    insert into pilotage.dg_suivi (bail_id, detenu_par, demande_le, par, maj_le)
    values (new.objet_id, 'bailleur', current_date, new.par, now())
    on conflict (bail_id) do update set demande_le = coalesce(pilotage.dg_suivi.demande_le, excluded.demande_le),
      par = case when pilotage.dg_suivi.demande_le is null then excluded.par else pilotage.dg_suivi.par end,
      maj_le = case when pilotage.dg_suivi.demande_le is null then now() else pilotage.dg_suivi.maj_le end;
  end if;
  -- Mail au prestataire préparé : l'EDL est commandé
  if new.code = 'es_prestataire_email' then
    insert into pilotage.fiches_conge (bail_id, edl_par, edl_commande_le, maj_par, maj_le)
    values (new.objet_id, 'prestataire', current_date, new.par, now())
    on conflict (bail_id) do update set edl_par = coalesce(pilotage.fiches_conge.edl_par, 'prestataire'),
      edl_commande_le = coalesce(pilotage.fiches_conge.edl_commande_le, current_date), maj_par = excluded.maj_par, maj_le = now();
  end if;
  return new;
end $$;
revoke all on function pilotage.messages_journal_effets() from public, anon, authenticated;

drop trigger if exists messages_journal_effets on pilotage.messages_journal;
create trigger messages_journal_effets after insert on pilotage.messages_journal
  for each row execute function pilotage.messages_journal_effets();

select pilotage.executer_controles();

commit;

-- Vérification après passage : alertes de congé et d'EDL ouvertes
-- select regle, titre, statut from pilotage.alertes where regle in ('conge_recu', 'edl_sortie_a_commander', 'edl_sortie_a_confirmer') order by regle, titre;
-- Adresse du prestataire EDL (à renseigner une fois) :
-- update pilotage.parametres set valeur = '<adresse e-mail du prestataire>' where cle = 'edl_prestataire_email';
