-- 090 — Modèles de mails et de SMS modifiables dans l'appli, proposés selon l'avancement du mandat et du bail (Nicolas, 29/10/2026).
-- Repris du module d'UDI Pilot (scripts 026-027 du nouvel UDI PILOT) :
--   1. Catégories : nouveau mandat, mise en location, nouveau bail, EDL d'entrée, congé reçu, EDL de sortie, relances de la gestion.
--      Chaque catégorie a sa fenêtre de proposition (en jours), modifiable sans code.
--   2. Modèles par catégorie, canal (mail ou SMS) et destinataire (bailleur ou locataire), avec des champs remplis depuis Rivage
--      ({adresse}, {locataire}, {date_debut}…). Un champ à saisir à la main ({date_edl}, {heure_edl}…) est demandé à l'envoi.
--   3. Lecture par toute l'équipe ; modification par Nicolas et Romain (direction, superviseur), chaque modification historisée.
--   4. Messages d'un dossier remplis pour la personne connectée ; journal de ce qui a été préparé (mail ouvert dans Gmail,
--      SMS ouvert sur le portable, scanné en QR code, copié, ou « pas nécessaire »).
--   5. Ma journée : messages de l'étape en cours pas encore faits, pour le commercial du dossier (à défaut la gestionnaire).
-- Décisions de Nicolas (29/10) : SMS du commercial depuis son portable (lien sms: ou QR code) ; relances de la gestion toujours
-- par Twilio (expéditeur UDI GESTION, 066) ; mails toujours en brouillon Gmail ; les 55 mails de la gestion restent dans
-- src/mails.js pour ce lot (migration au lot suivant) ; les 2 SMS Twilio existants passent dans les modèles.
-- Données : quatre tables nouvelles ; rien d'existant n'est modifié.
-- Retour arrière : drop function public.pilotage_messages_modeles(), public.pilotage_message_modele_modifier(text, text, text, boolean),
--   public.pilotage_message_categorie_modifier(text, integer, integer), public.pilotage_messages_dossier(text, text),
--   public.pilotage_message_noter(text, text, text, text, text, text, text), public.pilotage_messages_a_envoyer(),
--   pilotage.messages_contexte(text, text), pilotage.messages_categories_actives(text, text), pilotage.message_remplir(text, jsonb),
--   pilotage.euros(numeric), pilotage.peut_modifier_messages() ;
--   drop table pilotage.messages_journal, pilotage.messages_historique, pilotage.messages_modeles, pilotage.messages_categories.
-- À passer en trois blocs, dans l'ordre (chaque bloc est une transaction complète).


-- ============================================================================================================================
-- BLOC 1 / 3 : tables et textes de départ
-- ============================================================================================================================
begin;

create table if not exists pilotage.messages_categories (
  cle text primary key,
  libelle text not null,
  objet text not null check (objet in ('mandat', 'bail')),
  quand text not null,              -- explication affichée dans l'écran des modèles
  jours_avant integer,              -- fenêtre de proposition (sens propre à chaque catégorie, voir « quand »)
  jours_apres integer,
  ordre integer not null default 1);

create table if not exists pilotage.messages_modeles (
  code text primary key,
  categorie text not null references pilotage.messages_categories(cle),
  canal text not null check (canal in ('email', 'sms')),
  cible text not null check (cible in ('bailleur', 'locataire')),
  envoi text not null default 'commercial' check (envoi in ('commercial', 'twilio')),
  libelle text not null,
  objet text,
  texte text not null,
  ordre integer not null default 1,
  actif boolean not null default true,
  modifie_par uuid,
  modifie_le timestamptz);

create table if not exists pilotage.messages_historique (
  id bigserial primary key,
  code text not null,
  avant jsonb,
  apres jsonb,
  par uuid,
  le timestamptz not null default now());

create table if not exists pilotage.messages_journal (
  id bigserial primary key,
  objet text not null check (objet in ('mandat', 'bail')),
  objet_id text not null,
  code text not null,
  canal text not null,
  a text,
  objet_mail text,
  texte text,
  moyen text not null check (moyen in ('gmail', 'telephone', 'qr', 'copie', 'inutile')),
  par uuid,
  le timestamptz not null default now());
create index if not exists messages_journal_dossier on pilotage.messages_journal (objet, objet_id, code);

alter table pilotage.messages_categories enable row level security;
alter table pilotage.messages_modeles enable row level security;
alter table pilotage.messages_historique enable row level security;
alter table pilotage.messages_journal enable row level security;
revoke all on pilotage.messages_categories, pilotage.messages_modeles, pilotage.messages_historique, pilotage.messages_journal from anon, authenticated;

insert into pilotage.messages_categories (cle, libelle, objet, quand, jours_avant, jours_apres, ordre) values
 ('nouveau_mandat', 'Nouveau mandat', 'mandat', 'Mandat nouveau (signé ou arrivé dans Rivage depuis la date de référence) : proposé pendant « jours après » suivant la signature.', null, 60, 1),
 ('mise_en_location', 'Mise en location', 'mandat', 'Un lot du mandat est dans « À louer » : proposé tant qu''il y reste.', null, null, 2),
 ('nouveau_bail', 'Nouveau bail', 'bail', 'Bail nouveau, pas encore en sortie : proposé jusqu''à « jours après » le début du bail.', null, 30, 3),
 ('edl_entree', 'État des lieux d''entrée', 'bail', 'Bail au statut « Créé » dans Rivage : proposé de « jours avant » le début jusqu''à « jours après ».', 21, 5, 4),
 ('conge', 'Congé reçu', 'bail', 'Bail en sortie dans Rivage (congé reçu) : proposé jusqu''à la date de sortie.', null, null, 5),
 ('edl_sortie', 'État des lieux de sortie', 'bail', 'Bail en sortie : proposé de « jours avant » la date de sortie jusqu''à « jours après ».', 21, 2, 6),
 ('relances_gestion', 'Relances de la gestion (SMS UDI GESTION)', 'bail', 'SMS envoyés par le pilotage (Twilio) depuis les étapes de suivi des baux : jamais proposés dans Ma journée.', null, null, 7)
on conflict (cle) do nothing;

-- Champs : {bonjour} {nom} {bailleur} {locataire} {adresse} {reference} {date_debut} {date_fin} {date_sortie} {loyer} {charges}
--          {loyer_cc} {depot} {jour_echeance} {date_signature} {loyer_prevu} {date_disponible} {commercial} {email_commercial}
--          {email_gestion} {signature} ; à saisir à l'envoi : tout autre champ ({date_edl}, {heure_edl}, {retours_visites}…).
insert into pilotage.messages_modeles (code, categorie, canal, cible, envoi, libelle, objet, texte, ordre) values
 ('nm_bailleur_email', 'nouveau_mandat', 'email', 'bailleur', 'commercial', 'Mail de bienvenue au bailleur', 'Votre mandat de gestion avec UDI Gestion',
'{bonjour}

Merci pour votre confiance. Votre mandat de gestion n°{reference} pour le bien situé {adresse} est enregistré.

Votre dossier est désormais suivi par notre service gestion, joignable à l''adresse {email_gestion}. Pour la mise en location, je reste votre interlocuteur et je vous tiendrai informé à chaque étape.

Si des pièces du dossier nous manquent encore, nous vous les demanderons dans un message séparé.
{signature}', 1),
 ('nm_bailleur_sms', 'nouveau_mandat', 'sms', 'bailleur', 'commercial', 'SMS de bienvenue au bailleur', null,
'Bonjour {nom}, merci pour votre confiance : votre mandat de gestion pour {adresse} est enregistré chez UDI Gestion. Je reste à votre disposition. {commercial}, UDI Gestion', 2),

 ('ml_bailleur_email', 'mise_en_location', 'email', 'bailleur', 'commercial', 'Mail au bailleur : début de la commercialisation', 'Mise en location de votre bien {adresse}',
'{bonjour}

Nous commençons la recherche d''un locataire pour votre bien situé {adresse}, au loyer de {loyer_prevu}, pour une disponibilité au {date_disponible}.

Je vous tiendrai informé des visites et des dossiers reçus. Chaque candidat retenu vous sera présenté avant la signature.
{signature}', 1),
 ('ml_bailleur_sms', 'mise_en_location', 'sms', 'bailleur', 'commercial', 'SMS au bailleur : début de la commercialisation', null,
'Bonjour {nom}, la recherche d''un locataire pour votre bien {adresse} est lancée. Je vous tiens informé des visites. {commercial}, UDI Gestion', 2),
 ('ml_point_email', 'mise_en_location', 'email', 'bailleur', 'commercial', 'Mail au bailleur : point sur les visites', 'Location de votre bien {adresse} : point sur les visites',
'{bonjour}

Voici où en est la location de votre bien situé {adresse}.

{retours_visites}

N''hésitez pas à m''appeler si vous souhaitez en parler.
{signature}', 3),
 ('ml_candidat_email', 'mise_en_location', 'email', 'bailleur', 'commercial', 'Mail au bailleur : candidat proposé', 'Location de votre bien {adresse} : candidat proposé',
'{bonjour}

Nous avons reçu un dossier que nous vous proposons de retenir pour votre bien situé {adresse} : {candidat}, pour une entrée prévue le {date_entree}.

Le dossier a été étudié par nos soins. Pouvez-vous me donner votre accord pour que nous préparions le bail ?
{signature}', 4),

 ('nb_locataire_email', 'nouveau_bail', 'email', 'locataire', 'commercial', 'Mail de bienvenue au locataire', 'Bienvenue dans votre logement {adresse}',
'{bonjour}

Bienvenue chez UDI Gestion. Votre bail pour le logement situé {adresse} commence le {date_debut}.

Pour rappel, le loyer est de {loyer_cc} charges comprises, payable le {jour_echeance} de chaque mois.

Avant la remise des clés, merci de nous transmettre votre attestation d''assurance habitation à l''adresse {email_gestion}. Pendant toute la location, notre service gestion est votre interlocuteur à cette même adresse.
{signature}', 1),
 ('nb_locataire_sms', 'nouveau_bail', 'sms', 'locataire', 'commercial', 'SMS de bienvenue au locataire', null,
'Bonjour {nom}, bienvenue chez UDI Gestion. Votre bail pour {adresse} commence le {date_debut}. Pensez à nous envoyer votre attestation d''assurance avant la remise des clés : {email_gestion}. {commercial}', 2),
 ('nb_bailleur_email', 'nouveau_bail', 'email', 'bailleur', 'commercial', 'Mail au bailleur : bien loué', 'Votre bien {adresse} est loué',
'{bonjour}

Bonne nouvelle : le bail de votre bien situé {adresse} est signé avec {locataire}, pour une entrée le {date_debut}.

Le loyer est de {loyer} hors charges, plus {charges} de charges, et le dépôt de garantie de {depot}.

Notre service gestion prend le relais pour la suite ({email_gestion}).
{signature}', 3),
 ('nb_bailleur_sms', 'nouveau_bail', 'sms', 'bailleur', 'commercial', 'SMS au bailleur : bien loué', null,
'Bonjour {nom}, votre bien {adresse} est loué : bail signé avec {locataire}, entrée le {date_debut}. Je vous envoie le détail par mail. {commercial}, UDI Gestion', 4),

 ('ee_locataire_email', 'edl_entree', 'email', 'locataire', 'commercial', 'Mail au locataire : rendez-vous d''état des lieux', 'État des lieux d''entrée : {adresse}',
'{bonjour}

L''état des lieux d''entrée de votre logement situé {adresse} aura lieu le {date_edl} à {heure_edl}, sur place. Les clés vous seront remises à cette occasion.

Si vous ne nous avez pas encore transmis votre attestation d''assurance habitation, merci de l''envoyer avant le rendez-vous à {email_gestion}.

En cas d''empêchement, merci de me prévenir au plus vite.
{signature}', 1),
 ('ee_locataire_sms', 'edl_entree', 'sms', 'locataire', 'commercial', 'SMS au locataire : rappel du rendez-vous', null,
'Bonjour {nom}, rappel : état des lieux d''entrée de votre logement {adresse} le {date_edl} à {heure_edl}. Pensez à votre attestation d''assurance. {commercial}, UDI Gestion', 2),
 ('ee_bailleur_email', 'edl_entree', 'email', 'bailleur', 'commercial', 'Mail au bailleur : entrée du locataire faite', 'Entrée du locataire dans votre bien {adresse}',
'{bonjour}

L''état des lieux d''entrée de votre bien situé {adresse} a été fait le {date_edl} et les clés ont été remises à {locataire}.

La gestion du bail est désormais suivie par notre service gestion ({email_gestion}).
{signature}', 3),

 ('cg_locataire_email', 'conge', 'email', 'locataire', 'commercial', 'Mail au locataire : congé bien reçu', 'Votre congé pour le logement {adresse}',
'{bonjour}

Nous accusons réception de votre congé pour le logement situé {adresse}. La fin de votre location est fixée au {date_sortie}.

Le loyer et les charges restent dus jusqu''à cette date. Nous allons vous contacter pour organiser les visites du logement, puis l''état des lieux de sortie.

Merci de nous indiquer dès que possible votre nouvelle adresse, pour l''envoi de votre dépôt de garantie.
{signature}', 1),
 ('cg_locataire_sms', 'conge', 'sms', 'locataire', 'commercial', 'SMS au locataire : congé bien reçu', null,
'Bonjour {nom}, nous avons bien reçu votre congé pour {adresse} (fin de location le {date_sortie}). Je vous recontacte pour les visites et l''état des lieux. {commercial}, UDI Gestion', 2),
 ('cg_bailleur_email', 'conge', 'email', 'bailleur', 'commercial', 'Mail au bailleur : congé du locataire', 'Congé de votre locataire : {adresse}',
'{bonjour}

Votre locataire {locataire} nous a donné son congé pour le bien situé {adresse}. Son départ est prévu le {date_sortie}.

Nous vous proposons de lancer la remise en location sans attendre, pour limiter la vacance. Pouvez-vous me confirmer votre accord, et me dire si vous souhaitez revoir le loyer ou faire des travaux avant la relocation ?
{signature}', 3),
 ('cg_bailleur_sms', 'conge', 'sms', 'bailleur', 'commercial', 'SMS au bailleur : congé du locataire', null,
'Bonjour {nom}, votre locataire de {adresse} a donné son congé, départ prévu le {date_sortie}. Je vous propose de relancer la location sans attendre : je vous envoie un mail. {commercial}, UDI Gestion', 4),

 ('es_locataire_email', 'edl_sortie', 'email', 'locataire', 'commercial', 'Mail au locataire : rendez-vous d''état des lieux de sortie', 'État des lieux de sortie : {adresse}',
'{bonjour}

L''état des lieux de sortie de votre logement situé {adresse} aura lieu le {date_edl} à {heure_edl}.

Le jour du rendez-vous, le logement doit être entièrement vidé et nettoyé. Merci de prévoir toutes les clés et badges, et de nous indiquer votre nouvelle adresse pour l''envoi du dépôt de garantie.

En cas d''empêchement, merci de me prévenir au plus vite.
{signature}', 1),
 ('es_locataire_sms', 'edl_sortie', 'sms', 'locataire', 'commercial', 'SMS au locataire : rappel du rendez-vous de sortie', null,
'Bonjour {nom}, rappel : état des lieux de sortie de {adresse} le {date_edl} à {heure_edl}. Logement vide et propre, toutes les clés à rendre. {commercial}, UDI Gestion', 2),

 -- SMS de la gestion déjà en place (065-067, textes de src/mails.js), toujours envoyés par Twilio
 ('assurance_sms', 'relances_gestion', 'sms', 'locataire', 'twilio', 'SMS au locataire : attestation d''assurance', null,
'Bonjour {nom}, votre attestation d''assurance expire le {date_echeance}. Merci d''envoyer la nouvelle à {email_gestion}', 1),
 ('compteur_sms', 'relances_gestion', 'sms', 'locataire', 'twilio', 'SMS au locataire : relevé des compteurs', null,
'Bonjour {nom}, merci de nous envoyer le relevé et la photo de vos compteurs. Réponse par mail : {email_gestion}', 2)
on conflict (code) do nothing;

commit;


-- ============================================================================================================================
-- BLOC 2 / 3 : remplissage, étapes en cours, lecture
-- ============================================================================================================================
begin;

create or replace function pilotage.peut_modifier_messages() returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(pilotage.mon_role() in ('direction', 'superviseur'), false)
$$;

create or replace function pilotage.euros(p numeric) returns text
language sql immutable as $$
  select case when p is null then null
    else replace(replace(to_char(p, 'FM999,999,990.00'), ',', ' '), '.', ',') || ' €' end
$$;

-- Remplace chaque {champ} connu ; les champs inconnus ou vides restent pour être saisis à l'envoi
create or replace function pilotage.message_remplir(p_texte text, p_ctx jsonb) returns text
language plpgsql immutable as $$
declare k text; v text; t text := p_texte;
begin
  if t is null then return null; end if;
  for k, v in select key, value from jsonb_each_text(p_ctx) loop
    continue when v is null or v = '' or left(k, 1) = '_';
    t := replace(t, '{' || k || '}', v);
  end loop;
  return t;
end $$;

create or replace function pilotage.messages_contexte(p_objet text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare moi uuid := auth.uid(); c jsonb; prenom text := pilotage.prenom_membre(auth.uid()); r record; contacts jsonb;
  dfr constant text := 'DD/MM/YYYY';
begin
  c := jsonb_build_object('commercial', prenom, 'email_commercial', (select lower(email) from auth.users where id = moi),
    'email_gestion', 'votregestionnaire@udi-immo.com', 'signature', E'\nBien cordialement,\n' || coalesce(prenom, '') || E'\nUDI Gestion');
  if p_objet = 'bail' then
    select v.*, l.adresse adr,
           (select max(nullif(t->>'exit_date', '')::date) from jsonb_array_elements(o.data->'tenants') t) sortie
      into r
      from pilotage.v_baux v join pilotage.objets o on o.type = 'LeasingContract' and o.id = v.id
      left join pilotage.v_lots l on l.id = v.lot_id
     where v.id = p_id;
    if r.id is null then raise exception 'Bail inconnu'; end if;
    contacts := pilotage.contacts_bail(p_id);
    c := c || jsonb_build_object('adresse', r.adr, 'reference', r.reference,
      'date_debut', to_char(r.debut, dfr), 'date_fin', to_char(r.fin, dfr), 'date_sortie', to_char(coalesce(r.sortie, r.fin), dfr),
      'loyer', pilotage.euros(r.loyer_hc), 'charges', pilotage.euros(r.charges), 'loyer_cc', pilotage.euros(coalesce(r.loyer_hc, 0) + coalesce(r.charges, 0)),
      'depot', pilotage.euros(r.depot_garantie), 'jour_echeance', r.jour_echeance::text,
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
    '_contacts', contacts);
  return c;
end $$;

-- Étapes en cours d'un dossier, selon Rivage et les fenêtres réglées dans messages_categories
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
      if k.cle = 'edl_sortie' and c->>'_statut' = 'move_out'
         and sortie between d - coalesce(k.jours_apres, 2) and d + coalesce(k.jours_avant, 21) then res := res || k.cle; end if;
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

create or replace function public.pilotage_messages_modeles() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'peut_modifier', pilotage.peut_modifier_messages(),
    'champs', jsonb_build_array(
      jsonb_build_array('{bonjour}', '« Bonjour Prénom Nom, » (ou « Bonjour, » s''il y a plusieurs destinataires)'),
      jsonb_build_array('{nom}', 'prénom et nom du destinataire, sans civilité'),
      jsonb_build_array('{bailleur}', 'bailleurs du mandat ou du bail'), jsonb_build_array('{locataire}', 'locataires du bail'),
      jsonb_build_array('{adresse}', 'adresse du lot (ou des lots du mandat)'), jsonb_build_array('{reference}', 'n° du mandat ou du bail'),
      jsonb_build_array('{date_debut}', 'début du bail'), jsonb_build_array('{date_fin}', 'fin du bail'),
      jsonb_build_array('{date_sortie}', 'sortie du dernier locataire dans Rivage, à défaut fin du bail'),
      jsonb_build_array('{loyer}', 'loyer hors charges'), jsonb_build_array('{charges}', 'provision sur charges'),
      jsonb_build_array('{loyer_cc}', 'loyer charges comprises'), jsonb_build_array('{depot}', 'dépôt de garantie'),
      jsonb_build_array('{jour_echeance}', 'jour d''échéance du loyer'), jsonb_build_array('{date_signature}', 'signature du mandat'),
      jsonb_build_array('{loyer_prevu}', 'loyer prévu du lot « À louer »'), jsonb_build_array('{date_disponible}', 'disponibilité du lot « À louer »'),
      jsonb_build_array('{commercial}', 'prénom de la personne qui envoie'), jsonb_build_array('{email_commercial}', 'son adresse e-mail'),
      jsonb_build_array('{email_gestion}', 'votregestionnaire@udi-immo.com'),
      jsonb_build_array('{signature}', '« Bien cordialement, », prénom, UDI Gestion'),
      jsonb_build_array('{date_echeance}', 'échéance de l''obligation (SMS de la gestion)'),
      jsonb_build_array('{…}', 'tout autre champ ({date_edl}, {heure_edl}, {retours_visites}…) est demandé au moment de l''envoi')),
    'categories', coalesce((select jsonb_agg(to_jsonb(k) order by k.ordre) from pilotage.messages_categories k), '[]'::jsonb),
    'modeles', coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('modifie_par_prenom', pilotage.prenom_membre(m.modifie_par)) order by m.ordre)
                           from pilotage.messages_modeles m), '[]'::jsonb));
end $$;

-- Messages d'un dossier, remplis pour la personne connectée : un SMS par destinataire, un mail pour tous les destinataires
create or replace function public.pilotage_messages_dossier(p_objet text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); c jsonb; actives text[]; m pilotage.messages_modeles; dest jsonb; x jsonb; res jsonb := '[]'::jsonb;
  ctx jsonb; nb int; depuis timestamptz;
begin
  if r is null or p_objet not in ('mandat', 'bail') then raise exception 'Accès refusé'; end if;
  if r = 'negociateur' and coalesce(pilotage.commercial_dossier(p_objet, p_id), auth.uid()) <> auth.uid() then raise exception 'Accès refusé'; end if;
  c := pilotage.messages_contexte(p_objet, p_id);
  actives := pilotage.messages_categories_actives(p_objet, p_id);
  depuis := case when 'mise_en_location' = any(actives) then (c->>'_a_louer_depuis')::timestamptz end;
  for m in select mm.* from pilotage.messages_modeles mm join pilotage.messages_categories k on k.cle = mm.categorie
            where mm.actif and mm.envoi = 'commercial' and k.objet = p_objet order by k.ordre, mm.ordre loop
    dest := coalesce(c->'_contacts'->(case m.cible when 'bailleur' then 'bailleurs' else 'locataires' end), '[]'::jsonb);
    nb := jsonb_array_length(dest);
    if m.canal = 'email' then
      ctx := c || jsonb_build_object('nom', (select string_agg(pilotage.nom_sms(y->>'nom'), ', ') from jsonb_array_elements(dest) y),
        'bonjour', case when nb = 1 then 'Bonjour ' || pilotage.nom_sms(dest->0->>'nom') || ',' else 'Bonjour,' end);
      res := res || jsonb_build_object('code', m.code, 'categorie', m.categorie, 'canal', m.canal, 'cible', m.cible, 'libelle', m.libelle,
        'a', (select string_agg(lower(trim(y->>'email')), ', ') from jsonb_array_elements(dest) y where nullif(trim(y->>'email'), '') is not null),
        'objet', pilotage.message_remplir(m.objet, ctx), 'texte', pilotage.message_remplir(m.texte, ctx),
        'fait', (select jsonb_build_object('le', j.le, 'moyen', j.moyen, 'par', pilotage.prenom_membre(j.par)) from pilotage.messages_journal j
                  where j.objet = p_objet and j.objet_id = p_id and j.code = m.code and (depuis is null or m.categorie <> 'mise_en_location' or j.le >= depuis)
                  order by j.le desc limit 1));
    else
      for x in select y from jsonb_array_elements(case when nb = 0 then '[{}]'::jsonb else dest end) y loop
        -- Sans destinataire dans Rivage, {nom} reste à saisir à l'envoi
        ctx := c || jsonb_build_object('nom', nullif(pilotage.nom_sms(x->>'nom'), ''),
                                       'bonjour', 'Bonjour ' || nullif(pilotage.nom_sms(x->>'nom'), '') || ',');
        res := res || jsonb_build_object('code', m.code, 'categorie', m.categorie, 'canal', m.canal, 'cible', m.cible,
          'libelle', m.libelle || case when nb > 1 then ' · ' || pilotage.nom_sms(x->>'nom') else '' end,
          'a', nullif(trim(x->>'telephone'), ''), 'texte', pilotage.message_remplir(m.texte, ctx),
          'fait', (select jsonb_build_object('le', j.le, 'moyen', j.moyen, 'par', pilotage.prenom_membre(j.par)) from pilotage.messages_journal j
                    where j.objet = p_objet and j.objet_id = p_id and j.code = m.code
                      and (nb <= 1 or j.a is null or regexp_replace(j.a, '[^0-9]', '', 'g') = regexp_replace(coalesce(x->>'telephone', ''), '[^0-9]', '', 'g'))
                      and (depuis is null or m.categorie <> 'mise_en_location' or j.le >= depuis)
                    order by j.le desc limit 1));
      end loop;
    end if;
  end loop;
  return jsonb_build_object('actives', to_jsonb(actives),
    'categories', (select jsonb_agg(jsonb_build_object('cle', k.cle, 'libelle', k.libelle, 'active', k.cle = any(actives)) order by k.ordre)
                     from pilotage.messages_categories k where k.objet = p_objet and k.cle <> 'relances_gestion'),
    'messages', res);
end $$;

commit;


-- ============================================================================================================================
-- BLOC 3 / 3 : modification des modèles, journal, Ma journée, droits
-- ============================================================================================================================
begin;

create or replace function public.pilotage_message_modele_modifier(p_code text, p_objet text, p_texte text, p_actif boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare m pilotage.messages_modeles;
begin
  if not pilotage.peut_modifier_messages() then raise exception 'Seuls Nicolas et Romain peuvent modifier les modèles'; end if;
  select * into m from pilotage.messages_modeles where code = p_code;
  if m.code is null then raise exception 'Modèle inconnu'; end if;
  if coalesce(trim(p_texte), '') = '' then raise exception 'Le texte ne peut pas être vide'; end if;
  if m.canal = 'email' and coalesce(trim(p_objet), '') = '' then raise exception 'L''objet du mail ne peut pas être vide'; end if;
  if m.canal = 'sms' and length(p_texte) > 640 then raise exception 'SMS trop long (640 caractères au plus)'; end if;
  update pilotage.messages_modeles set objet = case when m.canal = 'email' then trim(p_objet) end, texte = p_texte,
         actif = coalesce(p_actif, m.actif), modifie_par = auth.uid(), modifie_le = now()
   where code = p_code;
  insert into pilotage.messages_historique (code, avant, apres, par)
  values (p_code, jsonb_build_object('objet', m.objet, 'texte', m.texte, 'actif', m.actif),
          jsonb_build_object('objet', p_objet, 'texte', p_texte, 'actif', coalesce(p_actif, m.actif)), auth.uid());
end $$;

create or replace function public.pilotage_message_categorie_modifier(p_cle text, p_avant integer, p_apres integer) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare k pilotage.messages_categories;
begin
  if not pilotage.peut_modifier_messages() then raise exception 'Seuls Nicolas et Romain peuvent modifier les modèles'; end if;
  select * into k from pilotage.messages_categories where cle = p_cle;
  if k.cle is null then raise exception 'Catégorie inconnue'; end if;
  if (p_avant is not null and (p_avant < 0 or p_avant > 365)) or (p_apres is not null and (p_apres < 0 or p_apres > 365)) then
    raise exception 'Fenêtre entre 0 et 365 jours'; end if;
  update pilotage.messages_categories
     set jours_avant = case when k.jours_avant is not null then coalesce(p_avant, k.jours_avant) end,
         jours_apres = case when k.jours_apres is not null then coalesce(p_apres, k.jours_apres) end
   where cle = p_cle;
  insert into pilotage.messages_historique (code, avant, apres, par)
  values ('categorie:' || p_cle, jsonb_build_object('jours_avant', k.jours_avant, 'jours_apres', k.jours_apres),
          jsonb_build_object('jours_avant', p_avant, 'jours_apres', p_apres), auth.uid());
end $$;

-- Trace d'un message préparé (le texte part du portable ou de Gmail : le pilotage n'envoie rien lui-même)
create or replace function public.pilotage_message_noter(p_objet text, p_id text, p_code text, p_a text, p_objet_mail text, p_texte text, p_moyen text)
returns void language plpgsql security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); m pilotage.messages_modeles;
begin
  if r is null or p_objet not in ('mandat', 'bail') then raise exception 'Accès refusé'; end if;
  if r = 'negociateur' and coalesce(pilotage.commercial_dossier(p_objet, p_id), auth.uid()) <> auth.uid() then raise exception 'Accès refusé'; end if;
  select * into m from pilotage.messages_modeles where code = p_code;
  if m.code is null or m.envoi <> 'commercial' then raise exception 'Modèle inconnu'; end if;
  insert into pilotage.messages_journal (objet, objet_id, code, canal, a, objet_mail, texte, moyen, par)
  values (p_objet, p_id, p_code, m.canal, nullif(trim(p_a), ''), p_objet_mail, p_texte, p_moyen, auth.uid());
end $$;

-- Ma journée : dossiers dont l'étape en cours a des messages pas encore faits, pour le commercial du dossier
-- (à défaut, pour la gestionnaire). La direction et le superviseur ne reçoivent rien ici (ils supervisent).
create or replace function public.pilotage_messages_a_envoyer() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); moi uuid := auth.uid(); res jsonb := '[]'::jsonb; x record; d jsonb; restants jsonb;
begin
  if r is null then raise exception 'Accès refusé'; end if;
  if r not in ('negociateur', 'gestionnaire') then return '[]'::jsonb; end if;
  for x in
    select 'bail' objet, v.id, 'Bail ' || coalesce(v.reference, '') titre, l.adresse
      from pilotage.v_baux v left join pilotage.v_lots l on l.id = v.lot_id
     where v.statut in ('created', 'in_progress', 'move_out')
       and (pilotage.commercial_dossier('bail', v.id) = moi or (pilotage.commercial_dossier('bail', v.id) is null and r = 'gestionnaire'))
       and (v.statut <> 'in_progress' or v.debut >= current_date - 60)
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
     where mm->>'categorie' in (select jsonb_array_elements_text(d->'actives')) and (mm->'fait' is null or mm->'fait' = 'null'::jsonb);
    continue when jsonb_array_length(restants) = 0;
    res := res || jsonb_build_object('objet', x.objet, 'id', x.id, 'titre', x.titre, 'adresse', x.adresse,
      'etapes', (select jsonb_agg(k.libelle order by k.ordre) from pilotage.messages_categories k where k.cle in (select jsonb_array_elements_text(d->'actives'))),
      'restants', restants);
  end loop;
  return res;
end $$;

revoke all on function public.pilotage_messages_modeles(), public.pilotage_message_modele_modifier(text, text, text, boolean),
  public.pilotage_message_categorie_modifier(text, integer, integer), public.pilotage_messages_dossier(text, text),
  public.pilotage_message_noter(text, text, text, text, text, text, text), public.pilotage_messages_a_envoyer() from public, anon;
grant execute on function public.pilotage_messages_modeles(), public.pilotage_message_modele_modifier(text, text, text, boolean),
  public.pilotage_message_categorie_modifier(text, integer, integer), public.pilotage_messages_dossier(text, text),
  public.pilotage_message_noter(text, text, text, text, text, text, text), public.pilotage_messages_a_envoyer() to authenticated;
revoke all on function pilotage.messages_contexte(text, text), pilotage.messages_categories_actives(text, text) from public, anon, authenticated;

commit;

-- Vérification après passage : doit renvoyer 7 catégories et 21 modèles
-- select (select count(*) from pilotage.messages_categories) categories, (select count(*) from pilotage.messages_modeles) modeles;
