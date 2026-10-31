-- 105 — Mails à l'organisme des ordures ménagères (redevance) : arrivée et départ du locataire (Nicolas, 31/10/2026).
-- Rappel de la demande du 29/10 : quand le lot relève d'un organisme externe (redevance, et non taxe incluse dans la taxe
-- foncière), déclarer à l'organisme l'arrivée du locataire (avec le bail) et son départ. Le 092 a créé la liste des organismes
-- et la réponse par lot, mais aucun modèle de mail. Au 31/10 : 13 lots en organisme externe (CCVE : 11, Vendée Grand Littoral : 2),
-- tous deux avec une adresse e-mail.
-- Ajouts :
--   - destinataire « organisme » : l'organisme des ordures du lot du bail, proposé seulement si le lot est en organisme externe ;
--   - « Nouveau bail à signer » : mail à l'organisme, déclaration d'arrivée (bail à joindre au brouillon) ;
--   - « Congé reçu » : mail à l'organisme, déclaration de départ (date de sortie, nouvelle adresse du locataire).
--   Modèles modifiables dans Réglages > Modèles de messages, comme les autres.
-- Fonction modifiée : pilotage_messages_dossier (remplacements ciblés, contrôlés). Un seul bloc.

begin;

alter table pilotage.messages_modeles drop constraint if exists messages_modeles_cible_check;
alter table pilotage.messages_modeles add constraint messages_modeles_cible_check check (cible in ('bailleur', 'locataire', 'garant', 'prestataire', 'organisme'));

insert into pilotage.messages_modeles (code, categorie, canal, cible, envoi, libelle, objet, texte, ordre) values
 ('nb_organisme_email', 'nouveau_bail', 'email', 'organisme', 'commercial', 'Mail à l''organisme des ordures ménagères : arrivée du locataire',
  'Arrivée d''un locataire : {adresse}',
'{bonjour}

Nous vous informons de l''arrivée d''un nouveau locataire dans le logement situé {adresse}, dont nous assurons la gestion pour le compte de {bailleur}.

Locataire(s) :
{locataire_contacts}
Date d''entrée : {date_debut}

Merci d''ouvrir le dossier de redevance d''enlèvement des ordures ménagères à son nom à compter de cette date. Vous trouverez le bail en pièce jointe.
{signature}', 5),
 ('cg_organisme_email', 'conge', 'email', 'organisme', 'commercial', 'Mail à l''organisme des ordures ménagères : départ du locataire',
  'Départ d''un locataire : {adresse}',
'{bonjour}

Nous vous informons du départ du locataire {locataire} du logement situé {adresse}, dont nous assurons la gestion pour le compte de {bailleur}.

Date de sortie : {date_sortie}
Nouvelle adresse du locataire : {nouvelle_adresse}

Merci de clôturer le dossier de redevance d''enlèvement des ordures ménagères à son nom à compter de cette date. Nous vous informerons de l''arrivée du prochain occupant.
{signature}', 5)
on conflict (code) do nothing;

do $do$
declare d text;
begin
  d := pg_get_functiondef('public.pilotage_messages_dossier(text,text)'::regprocedure);
  if position('ordures' in d) = 0 then
    if position($r$ctx jsonb; nb int; depuis timestamptz; avert text; av text; attente text; presta jsonb;$r$ in d) = 0
       or position($r$for m in select mm.* from pilotage.messages_modeles mm$r$ in d) = 0
       or position($r$continue when m.cible = 'prestataire' and c->>'_edl_par' = 'interne';$r$ in d) = 0
       or position($r$dest := case m.cible when 'prestataire' then presta$r$ in d) = 0
       or position($r$'bonjour', case when m.cible = 'prestataire' then 'Bonjour,'$r$ in d) = 0
       or position($r$case when m.cible = 'prestataire' then 'Joindre$r$ in d) = 0 then
      raise exception 'pilotage_messages_dossier : point de modification introuvable';
    end if;
    d := replace(d, $r$ctx jsonb; nb int; depuis timestamptz; avert text; av text; attente text; presta jsonb;$r$,
                    $r$ctx jsonb; nb int; depuis timestamptz; avert text; av text; attente text; presta jsonb; ordures jsonb;$r$);
    -- Organisme des ordures du lot du bail, seulement s'il est en organisme externe (redevance)
    d := replace(d, $r$for m in select mm.* from pilotage.messages_modeles mm$r$,
                    $r$ordures := case when p_objet = 'bail' then (select jsonb_build_array(jsonb_build_object('nom', o.nom, 'email', nullif(trim(o.email), '')))
                                                 from pilotage.v_baux b join pilotage.lots_ordures lo on lo.asset_id = b.lot_id
                                                 join pilotage.organismes_ordures o on o.id = lo.organisme_id
                                                where b.id = p_id and lo.mode = 'organisme_externe') end;
  for m in select mm.* from pilotage.messages_modeles mm$r$);
    d := replace(d, $r$continue when m.cible = 'prestataire' and c->>'_edl_par' = 'interne';$r$,
                    $r$continue when m.cible = 'prestataire' and c->>'_edl_par' = 'interne';
    continue when m.cible = 'organisme' and ordures is null;$r$);
    d := replace(d, $r$dest := case m.cible when 'prestataire' then presta$r$, $r$dest := case m.cible when 'prestataire' then presta when 'organisme' then ordures$r$);
    d := replace(d, $r$'bonjour', case when m.cible = 'prestataire' then 'Bonjour,'$r$, $r$'bonjour', case when m.cible in ('prestataire', 'organisme') then 'Bonjour,'$r$);
    d := replace(d, $r$case when m.cible = 'prestataire' then 'Joindre$r$,
                    $r$case when m.cible = 'organisme' then case when m.code like 'nb_%' then 'Joindre le bail au brouillon.' else '' end
        || case when ordures->0->>'email' is null then ' E-mail de l''organisme absent : à saisir dans Gmail et à compléter dans la liste des organismes.' else '' end end,
      case when m.cible = 'prestataire' then 'Joindre$r$);
    execute d;
  end if;
end $do$;

commit;

-- Vérification : modèles et lots concernés
-- select code, libelle from pilotage.messages_modeles where cible = 'organisme';
-- select count(*) from pilotage.lots_ordures where mode = 'organisme_externe';
