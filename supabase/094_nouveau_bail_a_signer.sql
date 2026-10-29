-- 094 — Alerte « Nouveau bail à signer » au commercial, avec le récapitulatif et le virement d'entrée (Nicolas, 29/10/2026).
-- Constat sur le bail 509 (lot 14, DOSOL, entrée le 30/10) : aucune alerte tant que le bail n'est pas signé ; les messages
-- « nouveau bail » existaient dans la fiche mais n'apparaissaient que chez la gestionnaire (bail sans commercial rattaché).
-- Décisions de Nicolas (29/10) :
--   1. Un bail créé dans Rivage et pas encore commencé déclenche l'alerte « Nouveau bail à signer ». Elle va au commercial
--      rattaché au bail (« loué par »), sinon à tous les commerciaux (comme les dossiers non attribués), jamais à la gestionnaire.
--   2. C'est à ce moment que sont proposés : au locataire, le récapitulatif du bail et les sommes à virer avant la remise des
--      clés, avec le RIB de l'agence ; au garant, une copie pour information ; au bailleur, l'annonce de la signature à venir.
--   3. Les sommes viennent des lignes de facturation actives de Rivage (« Premier mois » = prorata, dépôt de garantie, honoraires
--      locataire) : rien n'est recalculé. Deux lignes actives au même paramétrage Rivage sont signalées et comptées une fois.
--   L'alerte disparaît quand les mails au locataire et au bailleur sont préparés (ou marqués « pas nécessaire »), ou quand le bail
--   n'est plus au statut « Créé » ; au-delà de 5 jours après le début, l'alerte « Bail commencé mais toujours Créé » prend le relais.
-- Nouveau destinataire d'alerte « commercial » (règles), à côté de gestion, comptabilité et direction. « Messages à envoyer » de
-- Ma journée : même règle pour un bail pas encore commencé sans commercial (commerciaux, plus la gestionnaire).
-- Données : une règle, un modèle (garant) ajoutés ; textes des modèles « nouveau bail » remplacés s'ils n'ont pas été modifiés
-- dans l'appli ; fonctions remplacées : messages_contexte, pilotage_messages_dossier, executer_controles (ajout d'une source
-- de détection), pilotage_journee, pilotage_supervision, pilotage_traiter (visibilité des alertes « commercial »).
-- Retour arrière : update pilotage.regles set actif = false where cle = 'bail_a_signer' suffit à couper l'alerte.
-- À passer en trois blocs, dans l'ordre.


-- ============================================================================================================================
-- BLOC 1 / 3 : règle, destinataire « commercial », modèles
-- ============================================================================================================================
begin;

alter table pilotage.regles drop constraint if exists regles_destinataire_check;
alter table pilotage.regles add constraint regles_destinataire_check check (destinataire = any (array['gestion', 'compta', 'direction', 'commercial']));

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire)
values ('bail_a_signer', 'Nouveau bail à signer : informer le locataire et le bailleur', 'Baux habitation', 'haute', 'courrier', true,
        'Bail créé dans Rivage, pas encore commencé : envoyer au locataire le récapitulatif du bail et les sommes à virer avant la remise des clés (copie au garant), et prévenir le bailleur. L''alerte disparaît quand les deux mails sont préparés ou marqués « pas nécessaire ».',
        '[]'::jsonb, 'commercial')
on conflict (cle) do nothing;

alter table pilotage.messages_modeles drop constraint if exists messages_modeles_cible_check;
alter table pilotage.messages_modeles add constraint messages_modeles_cible_check check (cible in ('bailleur', 'locataire', 'garant'));

update pilotage.messages_categories set libelle = 'Nouveau bail à signer',
       quand = 'Bail nouveau au statut « Créé » ou en cours : proposé jusqu''à « jours après » le début du bail. L''alerte « Nouveau bail à signer » va au commercial du bail (à défaut, à tous les commerciaux).'
 where cle = 'nouveau_bail';

-- Textes remplacés seulement s'ils n'ont pas été modifiés dans l'appli (modifie_le vide)
update pilotage.messages_modeles set libelle = 'Mail au locataire : récapitulatif et virement d''entrée',
  objet = 'Votre location au {adresse} : récapitulatif avant la signature',
  texte = '{bonjour}

Votre dossier a été retenu pour le logement situé {adresse}. Voici le récapitulatif avant la signature de votre bail.

Le bail commence le {date_debut}. Le loyer est de {loyer} hors charges, plus {charges} de provision sur charges, soit {loyer_cc} par mois, payable le {jour_echeance} de chaque mois.

Avant la remise des clés, merci de nous virer la somme de {total_virement}, qui comprend :
{detail_virement}

Coordonnées bancaires UDI GESTION :
IBAN : {iban}
Libellé du virement : {libelle_virement}

Avant votre entrée, merci également de nous transmettre votre attestation d''assurance habitation, valable à compter du {date_debut}, à l''adresse {email_gestion}, et de souscrire un contrat d''électricité à votre nom.

Sans réception de cette somme et de l''attestation d''assurance, les clés ne pourront pas vous être remises.

L''état des lieux d''entrée est prévu le {date_edl} ; l''horaire vous sera confirmé.
{signature}'
 where code = 'nb_locataire_email' and modifie_le is null;

update pilotage.messages_modeles set libelle = 'SMS au locataire : virement d''entrée',
  texte = 'Bonjour {nom}, votre dossier pour {adresse} est retenu. Avant la remise des clés : virement de {total_virement} (détail et RIB envoyés par mail) et attestation d''assurance à {email_gestion}. {commercial}, UDI Gestion'
 where code = 'nb_locataire_sms' and modifie_le is null;

update pilotage.messages_modeles set libelle = 'Mail au bailleur : un bail va être signé',
  objet = 'Votre bien {adresse} : un bail va être signé',
  texte = '{bonjour}

Bonne nouvelle : nous avons retenu un locataire pour votre bien situé {adresse}. Le bail va être signé avec {locataire}, pour une entrée le {date_debut}.

Le loyer sera de {loyer} hors charges, plus {charges} de provision sur charges, et le dépôt de garantie de {depot}.

Si vous occupiez le logement, pensez à résilier vos contrats d''énergie avant l''entrée du locataire. Nous vous adresserons une copie du bail une fois signé.
{signature}'
 where code = 'nb_bailleur_email' and modifie_le is null;

update pilotage.messages_modeles set libelle = 'SMS au bailleur : un bail va être signé',
  texte = 'Bonjour {nom}, nous avons retenu un locataire pour votre bien {adresse} : signature du bail avec {locataire}, entrée le {date_debut}. Détail par mail. {commercial}, UDI Gestion'
 where code = 'nb_bailleur_sms' and modifie_le is null;

insert into pilotage.messages_modeles (code, categorie, canal, cible, envoi, libelle, objet, texte, ordre) values
 ('nb_garant_email', 'nouveau_bail', 'email', 'garant', 'commercial', 'Mail au garant : copie pour information', 'Location au {adresse} : information du garant',
'{bonjour}

Vous vous êtes porté garant de {locataire} pour la location du logement situé {adresse}, qui commence le {date_debut}. Pour votre information, voici ce que nous lui avons communiqué.

Le loyer est de {loyer_cc} par mois, charges comprises. Avant la remise des clés, la somme de {total_virement} est à régler :
{detail_virement}

Nous restons à votre disposition pour toute question.
{signature}', 2)
on conflict (code) do nothing;

commit;


-- ============================================================================================================================
-- BLOC 2 / 3 : virement d'entrée, contexte des messages, messages d'un dossier, détection, visibilité
-- ============================================================================================================================
begin;

-- Sommes à virer à l'entrée : lignes de facturation actives du bail, côté locataire, ponctuelles (pas les loyers mensuels)
create or replace function pilotage.virement_entree(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  with l as (
    select o.data->>'name' nom, (o.data->>'amount_in_cents')::numeric / 100 montant, o.data->>'transaction_configuration_id' tc,
           nullif(o.data->>'end_date', '')::date fin
      from pilotage.objets o
     where o.type = 'BillingLine' and o.supprime_le is null and o.data->>'leasing_contract_id' = p_bail
       and o.data->>'type' = 'tenant' and nullif(o.data->>'frequency_in_months', '') is null
       and coalesce(o.data->>'name', '') !~* '^(remboursement|dernier mois|solde ant)'),
  u as (select distinct on (coalesce(tc, nom), montant) * , count(*) over (partition by coalesce(tc, nom), montant) n from l order by coalesce(tc, nom), montant),
  b as (select v.debut from pilotage.v_baux v where v.id = p_bail)
  select jsonb_build_object(
    'lignes', coalesce((select jsonb_agg(jsonb_build_object('libelle',
                 case when u.nom ilike 'premier mois - loyer%' then 'Loyer au prorata' || coalesce(' du ' || to_char((select debut from b), 'DD/MM') || ' au ' || to_char(u.fin, 'DD/MM'), '')
                      when u.nom ilike 'premier mois - charges%' then 'Provision sur charges au prorata'
                      when u.nom ilike 'honoraires de location - locataire%' then 'Honoraires de location'
                      when u.nom ilike 'honoraires d''état des lieux - locataire%' then 'Honoraires d''état des lieux'
                      else u.nom end, 'montant', u.montant)
               order by case when u.nom ilike 'premier mois - loyer%' then 1 when u.nom ilike 'premier mois - charges%' then 2
                             when u.nom ilike 'dépôt%' then 3 else 4 end, u.nom) from u), '[]'::jsonb),
    'total', (select sum(montant) from u),
    'doublons', coalesce((select jsonb_agg(u.nom || ' (' || pilotage.euros(u.montant) || ')') from u where u.n > 1), '[]'::jsonb))
$$;

create or replace function pilotage.messages_contexte(p_objet text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare moi uuid := auth.uid(); c jsonb; prenom text := pilotage.prenom_membre(auth.uid()); r record; contacts jsonb; v jsonb;
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
    c := c || jsonb_build_object('adresse', r.adr, 'reference', r.reference,
      'date_debut', to_char(r.debut, dfr), 'date_fin', to_char(r.fin, dfr), 'date_sortie', to_char(coalesce(r.sortie, r.fin), dfr),
      'loyer', pilotage.euros(r.loyer_hc), 'charges', pilotage.euros(r.charges), 'loyer_cc', pilotage.euros(coalesce(r.loyer_hc, 0) + coalesce(r.charges, 0)),
      'depot', pilotage.euros(r.depot_garantie), 'jour_echeance', r.jour_echeance::text,
      'detail_virement', (select string_agg('- ' || (x->>'libelle') || ' : ' || pilotage.euros((x->>'montant')::numeric), E'\n')
                            from jsonb_array_elements(v->'lignes') x),
      'total_virement', pilotage.euros((v->>'total')::numeric),
      '_doublons', v->'doublons',
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
  return c;
end $$;

-- Messages d'un dossier, remplis pour la personne connectée : un SMS par destinataire, un mail pour tous les destinataires.
-- 094 : destinataire « garant » ; avertissement sur les messages du virement si Rivage a des lignes en double ou aucune ligne.
create or replace function public.pilotage_messages_dossier(p_objet text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); c jsonb; actives text[]; m pilotage.messages_modeles; dest jsonb; x jsonb; res jsonb := '[]'::jsonb;
  ctx jsonb; nb int; depuis timestamptz; avert text;
begin
  if r is null or p_objet not in ('mandat', 'bail') then raise exception 'Accès refusé'; end if;
  if r = 'negociateur' and coalesce(pilotage.commercial_dossier(p_objet, p_id), auth.uid()) <> auth.uid() then raise exception 'Accès refusé'; end if;
  c := pilotage.messages_contexte(p_objet, p_id);
  actives := pilotage.messages_categories_actives(p_objet, p_id);
  depuis := case when 'mise_en_location' = any(actives) then (c->>'_a_louer_depuis')::timestamptz end;
  avert := case when p_objet = 'bail' and c->>'detail_virement' is null then 'Rivage n''a pas encore les lignes de facturation de l''entrée (prorata, dépôt, honoraires) : montants à saisir à la main ou à attendre.'
                when p_objet = 'bail' and jsonb_array_length(coalesce(c->'_doublons', '[]'::jsonb)) > 0
                  then 'Ligne en double dans Rivage, comptée une seule fois : ' || (select string_agg(d, ', ') from jsonb_array_elements_text(c->'_doublons') d) || '. À vérifier dans Rivage.' end;
  for m in select mm.* from pilotage.messages_modeles mm join pilotage.messages_categories k on k.cle = mm.categorie
            where mm.actif and mm.envoi = 'commercial' and k.objet = p_objet order by k.ordre, mm.ordre loop
    dest := coalesce(c->'_contacts'->(case m.cible when 'bailleur' then 'bailleurs' when 'garant' then 'garants' else 'locataires' end), '[]'::jsonb);
    nb := jsonb_array_length(dest);
    continue when m.cible = 'garant' and nb = 0;
    if m.canal = 'email' then
      ctx := c || jsonb_build_object('nom', (select string_agg(pilotage.nom_sms(y->>'nom'), ', ') from jsonb_array_elements(dest) y),
        'bonjour', case when nb = 1 then 'Bonjour ' || pilotage.nom_sms(dest->0->>'nom') || ',' else 'Bonjour,' end);
      res := res || jsonb_build_object('code', m.code, 'categorie', m.categorie, 'canal', m.canal, 'cible', m.cible, 'libelle', m.libelle,
        'a', (select string_agg(lower(trim(y->>'email')), ', ') from jsonb_array_elements(dest) y where nullif(trim(y->>'email'), '') is not null),
        'objet', pilotage.message_remplir(m.objet, ctx), 'texte', pilotage.message_remplir(m.texte, ctx),
        'avertissement', case when m.texte like '%{total_virement}%' or m.texte like '%{detail_virement}%' then avert end,
        'fait', (select jsonb_build_object('le', j.le, 'moyen', j.moyen, 'par', pilotage.prenom_membre(j.par)) from pilotage.messages_journal j
                  where j.objet = p_objet and j.objet_id = p_id and j.code = m.code and (depuis is null or m.categorie <> 'mise_en_location' or j.le >= depuis)
                  order by j.le desc limit 1));
    else
      for x in select y from jsonb_array_elements(case when nb = 0 then '[{}]'::jsonb else dest end) y loop
        ctx := c || jsonb_build_object('nom', nullif(pilotage.nom_sms(x->>'nom'), ''),
                                       'bonjour', 'Bonjour ' || nullif(pilotage.nom_sms(x->>'nom'), '') || ',');
        res := res || jsonb_build_object('code', m.code, 'categorie', m.categorie, 'canal', m.canal, 'cible', m.cible,
          'libelle', m.libelle || case when nb > 1 then ' · ' || pilotage.nom_sms(x->>'nom') else '' end,
          'a', nullif(trim(x->>'telephone'), ''), 'texte', pilotage.message_remplir(m.texte, ctx),
          'avertissement', case when m.texte like '%{total_virement}%' or m.texte like '%{detail_virement}%' then avert end,
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

-- Détections des étapes (source ajoutée à executer_controles) : nouveau bail à signer
create or replace function pilotage.etapes_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  select 'bail_a_signer'::text, 'LeasingContract'::text, b.id,
         'Bail ' || coalesce(b.reference, '') || ' à signer : entrée le ' || to_char(b.debut, 'DD/MM/YYYY'),
         'Locataires : ' || coalesce(b.locataires, '?') || ' — envoyer au locataire le récapitulatif et le virement d''entrée, prévenir le bailleur',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
    from pilotage.v_baux b
   where b.statut = 'created' and b.debut >= current_date - 5 and pilotage.dossier_nouveau('LeasingContract', b.id)
     and not (exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = b.id and j.code = 'nb_locataire_email')
          and exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = b.id and j.code = 'nb_bailleur_email'))
$$;

-- Visibilité d'une alerte « commercial » : le commercial du dossier, sinon tous les commerciaux ; les autres règles inchangées
create or replace function pilotage.alerte_visible_objet(p_regle text, p_mandat text, p_user uuid, p_type text, p_objet text) returns boolean
language plpgsql stable security definer set search_path = pilotage, public as $$
declare c uuid;
begin
  if coalesce((select r.destinataire from pilotage.regles r where r.cle = p_regle), 'gestion') <> 'commercial' then
    return pilotage.alerte_visible(p_regle, p_mandat, p_user);
  end if;
  c := case p_type when 'LeasingContract' then pilotage.commercial_dossier('bail', p_objet)
                   when 'ManagementContract' then pilotage.commercial_dossier('mandat', p_objet) end;
  if c is not null then return c = p_user; end if;
  return exists (select 1 from pilotage.membres m where m.user_id = p_user and m.actif and m.role = 'negociateur');
end $$;

-- Ma journée, « Messages à envoyer » (091) : un bail pas encore commencé (« Créé ») sans commercial va aux commerciaux, plus à la gestionnaire
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
       and (pilotage.commercial_dossier('bail', v.id) = moi
            or (pilotage.commercial_dossier('bail', v.id) is null and r = case when v.statut = 'created' then 'negociateur' else 'gestionnaire' end))
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

revoke all on function pilotage.virement_entree(text), pilotage.etapes_detections() from public, anon, authenticated;

commit;


-- ============================================================================================================================
-- BLOC 3 / 3 : branchements (contrôles et visibilité des alertes), puis contrôle immédiat
-- ============================================================================================================================
begin;

do $do$
declare d text; f text; n int;
begin
  -- 1. executer_controles : les détections des étapes s'ajoutent aux autres
  d := pg_get_functiondef('pilotage.executer_controles()'::regprocedure);
  if position('etapes_detections' in d) = 0 then
    n := (length(d) - length(replace(d, 'from pilotage.suivi_detections() d;', ''))) / length('from pilotage.suivi_detections() d;');
    if n <> 1 then raise exception 'executer_controles : point d''insertion introuvable (% occurrence(s))', n; end if;
    d := replace(d, 'from pilotage.suivi_detections() d;',
      'from pilotage.suivi_detections() d' || chr(10) || '  union all' || chr(10)
      || '  select e.regle, e.objet_type, e.objet_id, e.titre, e.detail, e.lien from pilotage.etapes_detections() e;');
    execute d;
  end if;
  -- 2. Visibilité : journée, supervision et traitement passent par alerte_visible_objet
  foreach f in array array['public.pilotage_journee(uuid)', 'public.pilotage_supervision()', 'public.pilotage_traiter(bigint,boolean)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('alerte_visible_objet' in d) = 0 then
      d := regexp_replace(d, '(pilotage\.)?alerte_visible\(a\.regle, a\.mandat_id, (auth\.uid\(\)|cible|m\.user_id)\)',
                          'pilotage.alerte_visible_objet(a.regle, a.mandat_id, \2, a.objet_type, a.objet_id)', 'g');
      if position('alerte_visible_objet' in d) = 0 then raise exception '% : appel de alerte_visible introuvable', f; end if;
      execute d;
    end if;
  end loop;
end $do$;

select pilotage.executer_controles();

commit;

-- Vérification après passage : l'alerte du bail 509 (si les mails ne sont pas encore préparés)
-- select regle, titre, statut from pilotage.alertes where regle = 'bail_a_signer';
