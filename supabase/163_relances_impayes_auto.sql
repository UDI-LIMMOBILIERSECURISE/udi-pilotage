-- 163 : relances automatiques des impayés par le pilotage (décisions de Nicolas du 13/11/2026)
--  Choix du 13/11 : les relances d'impayés de Rivage sont coupées, le pilotage relance seul ; SMS et mails amiables envoyés
--  automatiquement, mise en demeure validée par Audrey ; calendrier serré avant la déclaration Zelok (16-19).
--
--  Point de départ (J0) d'un impayé du mois :
--   - locataire en virement : le lendemain du jour de paiement attendu (le 5, paramètre « jour_virement ») si la dette dépasse le seuil ;
--   - locataire en prélèvement : le jour où Rivage enregistre le rejet (tenant_payin_rejection, rattaché au bail par le compte du
--     locataire) ; à défaut de rejet, « jours_sans_rejet » jours après la date de prélèvement si la dette est toujours là.
--  Calendrier (jours après J0, réglables dans Règles de relance, règle « Relances automatiques des impayés ») :
--   J0 SMS + mail · J+2 SMS · J+3 appel d'Audrey (Ma journée) · J+5 mail ferme, copie au garant ·
--   mise en demeure au plus tôt le 10 et à J+6, au plus tard le 15 (Audrey la valide et l'envoie) · le 15 dernier appel ·
--   16-19 déclaration Zelok (inchangé). Un envoi qui tombe un dimanche ou un jour férié part le lendemain.
--   Si plusieurs envois automatiques sont dus le même jour (rejet tardif, panne), seul le dernier part : pas de rafale.
--  Pas de relance automatique : dossier déclaré ou en procédure, dette ancienne (dossier ouvert avant le mois), dette de plus de
--  « mois_max » mois de loyer, cycle mis en pause par Audrey. Tout s'arrête dès que la dette Rivage repasse sous le seuil.
--  Rien ne part tant que la règle « Relances automatiques des impayés » n'est pas activée (désactivée par ce script) ; à
--  l'activation, seuls les impayés dont le J0 est du jour ou de la veille sont pris : pas de rattrapage du mois en cours.
--  Envoi : fonction pilotage-relances-impayes (tâche planifiée chaque jour à 8 h UTC, 9 h l'hiver), même passage que les envois
--  existants : Zapier → Twilio (UDI GESTION) pour les SMS, Zapier → Gmail (votregestionnaire@udi-immo.com) pour les mails.
--  Textes : Réglages > Modèles de messages, catégorie « Impayés : relances automatiques » (modifiables par Nicolas et Romain).
--
--  Aussi dans ce script :
--   - SMS : les numéros Rivage au format 336XXXXXXXX (351 locataires sur 426) étaient écartés par pilotage_sms_preparer
--     (seuls 06/07 et +33 passaient : 3 SMS envoyés depuis le 20/10). Nouvelle fonction pilotage.tel_portable, reprise partout.
--   - Ancienne tâche « relance-impayes-auto-quotidien » (outil UDIGESTION, tables public.suivi_impayes) arrêtée : elle relançait
--     encore un dossier (dette de mai 2026) par SMS Twilio et mail, en dehors du pilotage. La fonction n'est pas supprimée.
--
--  Retour en arrière : désactiver la règle impaye_relance_auto suffit (plus aucun envoi). Pour tout retirer :
--   select cron.unschedule('pilotage-relances-impayes'); drop table pilotage.relances_impayes cascade; et les fonctions ci-dessous.
--  À passer en trois blocs, dans l'ordre (chaque bloc est une transaction complète). Vérifier « bloc N sur 3 » avant d'exécuter.


-- ============================================================================================================================
-- 163 : relances automatiques des impayés — bloc 1 sur 3 : tables, numéros de portable, jours fériés, textes, règles
-- ============================================================================================================================
begin;

-- Numéro de portable au format international (Twilio) ; null si ce n'est pas un portable exploitable
create or replace function pilotage.tel_portable(p text) returns text
language sql immutable as $$
  select case when t ~ '^\+33[67]\d{8}$' then t
              when t ~ '^\+33' then null                       -- fixe français : pas de SMS
              when t ~ '^\+\d{8,15}$' then t                    -- portable étranger
              when t ~ '^0[67]\d{8}$' then '+33' || substr(t, 2)
              when t ~ '^33[67]\d{8}$' then '+' || t           -- format Rivage le plus courant
              when t ~ '^0033[67]\d{8}$' then '+' || substr(t, 3) end
    from (select regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g') t) x
$$;

-- SMS de la gestion (066-067) : même fonction, numéros lus par pilotage.tel_portable
create or replace function public.pilotage_sms_preparer(p_bail text, p_texte text, p_cle text, p_etape text)
returns jsonb language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare loc jsonb; res jsonb := '[]'::jsonb; nid bigint; tel text; nom text; txt text;
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() = 'comptable') then raise exception 'Accès refusé'; end if;
  if nullif(trim(coalesce(p_texte, '')), '') is null then raise exception 'SMS vide'; end if;
  for loc in select x from jsonb_array_elements(coalesce(pilotage.contacts_bail(p_bail)->'locataires', '[]'::jsonb)) x loop
    tel := pilotage.tel_portable(loc->>'telephone');
    continue when tel is null;
    nom := pilotage.nom_sms(loc->>'nom');
    txt := trim(replace(p_texte, '{nom}', nom));
    if length(txt) > 640 then raise exception 'SMS trop long (640 caractères au plus)'; end if;
    insert into pilotage.sms_envois (bail_id, destinataire, telephone, texte, cle, etape, par)
    values (p_bail, nom, tel, txt, p_cle, p_etape, auth.uid()) returning id into nid;
    res := res || jsonb_build_object('id', nid, 'telephone', tel, 'nom', nom, 'texte', txt);
  end loop;
  if jsonb_array_length(res) = 0 then raise exception 'Aucun numéro de portable du locataire dans Rivage'; end if;
  return res;
end $$;

-- Jours fériés en France métropolitaine (fixes, lundi de Pâques, Ascension, lundi de Pentecôte)
create or replace function pilotage.jour_ferie(p_jour date) returns boolean
language plpgsql immutable as $$
declare y int := extract(year from p_jour)::int; a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int;
  mo int; jo int; paques date;
begin
  a := y % 19; b := y / 100; c := y % 100; d := b / 4; e := b % 4; f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19 * a + b - d - g + 15) % 30; i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  mo := (h + l - 7 * m + 114) / 31; jo := ((h + l - 7 * m + 114) % 31) + 1;
  paques := make_date(y, mo, jo);
  return to_char(p_jour, 'MM-DD') in ('01-01', '05-01', '05-08', '07-14', '08-15', '11-01', '11-11', '12-25')
      or p_jour in (paques + 1, paques + 39, paques + 50);
end $$;

-- Premier jour d'envoi possible à partir d'une date : ni dimanche ni jour férié
create or replace function pilotage.jour_envoi(p_jour date) returns date
language plpgsql immutable as $$
declare j date := p_jour;
begin
  if j is null then return null; end if;
  while extract(isodow from j) = 7 or pilotage.jour_ferie(j) loop j := j + 1; end loop;
  return j;
end $$;

-- Un cycle de relance par bail et par mois
create table if not exists pilotage.relances_impayes (
  id bigint generated always as identity primary key,
  bail_id text not null,
  mois date not null,                      -- premier jour du mois du J0
  j0 date not null,
  origine text not null check (origine in ('virement', 'rejet', 'prelevement')),
  rejet_le date,
  dette_initiale numeric,
  cree_le timestamptz not null default now(),
  pause_le timestamptz, pause_par uuid, pause_motif text,
  clos_le timestamptz, clos_motif text,
  unique (bail_id, mois)
);
create index if not exists relances_impayes_ouverts on pilotage.relances_impayes (bail_id) where clos_le is null;
alter table pilotage.relances_impayes enable row level security;
revoke all on pilotage.relances_impayes from public, anon, authenticated;

-- Modèles : catégorie « Impayés », envoi « pilotage » (mail automatique depuis votregestionnaire@, SMS par Twilio)
alter table pilotage.messages_modeles drop constraint if exists messages_modeles_envoi_check;
alter table pilotage.messages_modeles add constraint messages_modeles_envoi_check check (envoi in ('commercial', 'twilio', 'pilotage'));

insert into pilotage.messages_categories (cle, libelle, objet, quand, jours_avant, jours_apres, ordre) values
('impayes', 'Impayés : relances automatiques', 'bail',
 'Envoyés seuls par le pilotage à un locataire en impayé du mois (virement non reçu le 5, prélèvement rejeté), selon la règle « Relances automatiques des impayés ». Jamais proposés dans Ma journée. La mise en demeure est préparée ici et validée par Audrey. Champs : {nom} (SMS), {locataire}, {dette}, {constat}, {constat_sms}, {adresse}, {reference}, {iban}, {libelle_virement}, {copie_garant}, {suite}, {suite_med}, {signature}.',
 null, null, 8)
on conflict (cle) do nothing;

insert into pilotage.messages_modeles (code, categorie, canal, cible, envoi, libelle, objet, texte, ordre) values
('ri_j0_sms', 'impayes', 'sms', 'locataire', 'twilio', 'Premier SMS (J0)', null,
 'Bonjour {nom}, {constat_sms}. Il reste {dette} à régler pour le logement {adresse}. Merci de faire le virement aujourd''hui (coordonnées dans notre mail) ou de nous répondre si vous rencontrez une difficulté. UDI Gestion', 1),
('ri_j0_email', 'impayes', 'email', 'locataire', 'pilotage', 'Premier mail (J0)', 'Loyer impayé - {adresse}',
 E'Bonjour {locataire},\n\nSauf erreur de notre part, {constat}. À ce jour, votre compte locataire présente un solde impayé de {dette}.\n\nNous vous remercions de régulariser cette somme sans attendre, par virement :\nIBAN : {iban}\nLibellé : {libelle_virement}\n\nSi vous avez réglé entre-temps, merci de ne pas tenir compte de ce message. Si vous rencontrez une difficulté, répondez-nous dès aujourd''hui : une solution est toujours plus simple à trouver au début.\n{signature}', 2),
('ri_j2_sms', 'impayes', 'sms', 'locataire', 'twilio', 'Deuxième SMS (J+2)', null,
 'Bonjour {nom}, nous n''avons toujours pas reçu le règlement de {dette} pour le logement {adresse}. Merci de régulariser sans délai ou de nous contacter aujourd''hui. UDI Gestion', 3),
('ri_j5_email', 'impayes', 'email', 'locataire', 'pilotage', 'Mail ferme, copie au garant (J+5)', 'Second rappel : loyer impayé - {adresse}',
 E'Bonjour {locataire},\n\nMalgré nos précédents messages, votre compte locataire présente toujours un solde impayé de {dette}.\n\nNous vous demandons de régler cette somme sous 48 heures, par virement (IBAN : {iban}, libellé : {libelle_virement}). À défaut, une mise en demeure vous sera adressée par lettre recommandée, puis le dossier sera transmis {suite}.\n{copie_garant}\n{signature}', 4),
('ri_med_email', 'impayes', 'email', 'locataire', 'pilotage', 'Mise en demeure (validée et envoyée par Audrey)', 'Mise en demeure de payer - {adresse}',
 E'Madame, Monsieur,\n\nMalgré nos relances, le loyer et les charges du logement situé {adresse}, que vous occupez en vertu du bail n° {reference}, restent impayés. À ce jour, votre dette s''élève à {dette}.\n\nPar la présente, nous vous mettons en demeure de régler cette somme dans un délai de huit jours à compter de la réception de ce courrier, par virement (IBAN : {iban}, libellé : {libelle_virement}).\n\nÀ défaut de règlement dans ce délai, nous engagerons sans autre avis, pour le compte du propriétaire, les démarches prévues au bail{suite_med}.\n\nCe courrier vous est également adressé par lettre recommandée avec accusé de réception.\n{signature}', 5)
on conflict (code) do nothing;

-- Règle maîtresse (désactivée) et ses délais, puis les alertes à la comptable
insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire) values
('impaye_relance_auto', 'Relances automatiques des impayés (SMS et mails au locataire)', 'impayes', 'haute', 'tache', false,
 'Interrupteur des relances envoyées seules par le pilotage. Désactivée : rien ne part. Activée : chaque matin, SMS et mails aux locataires en impayé du mois selon les délais ci-dessous (virement non reçu le 5, prélèvement rejeté). Rivage ne doit plus relancer de son côté.',
 '[{"nom":"seuil","unite":"€","valeur":15,"libelle":"Dette minimale pour relancer"},
   {"nom":"jour_virement","unite":"jour du mois","valeur":5,"libelle":"Virement attendu au plus tard le"},
   {"nom":"jours_sans_rejet","unite":"jours","valeur":7,"libelle":"Prélèvement sans rejet reçu : relancer si toujours impayé N jours après la date de prélèvement"},
   {"nom":"j_sms2","unite":"jours","valeur":2,"libelle":"Deuxième SMS (jours après le premier envoi)"},
   {"nom":"j_appel","unite":"jours","valeur":3,"libelle":"Appel d''Audrey (jours après le premier envoi)"},
   {"nom":"j_mail_ferme","unite":"jours","valeur":5,"libelle":"Mail ferme, copie au garant (jours après le premier envoi)"},
   {"nom":"med_delai","unite":"jours","valeur":6,"libelle":"Mise en demeure au plus tôt N jours après le premier envoi"},
   {"nom":"med_jour_min","unite":"jour du mois","valeur":10,"libelle":"Mise en demeure au plus tôt le"},
   {"nom":"jour_appel_final","unite":"jour du mois","valeur":15,"libelle":"Dernier appel avant la déclaration (et mise en demeure au plus tard ce jour-là)"},
   {"nom":"mois_max","unite":"mois de loyer","valeur":2,"libelle":"Au-delà de cette dette, pas de relance automatique (dossier suivi à la main)"}]'::jsonb,
 'compta'),
('impaye_relance_appel', 'Impayé : appeler le locataire', 'impayes', 'haute', 'tache', true,
 'Relances automatiques en cours sans règlement : appel du locataire (J+3). Marquer l''alerte traitée une fois l''appel passé.', '[]'::jsonb, 'compta'),
('impaye_relance_med', 'Impayé : mise en demeure à envoyer', 'impayes', 'haute', 'tache', true,
 'Mise en demeure préparée dans le dossier d''impayé (bloc « Relances automatiques ») : la relire, l''envoyer par mail et en recommandé. Fermée quand « Mise en demeure envoyée » est noté.', '[]'::jsonb, 'compta'),
('impaye_relance_appel_final', 'Impayé : dernier appel avant la déclaration', 'impayes', 'haute', 'tache', true,
 'Dernier appel du locataire avant la déclaration à la GLI (16-19). Une promesse de paiement ne bloque pas la déclaration.', '[]'::jsonb, 'compta'),
('impaye_relance_contact', 'Impayé : relance automatique non envoyée', 'impayes', 'normale', 'tache', true,
 'Le pilotage n''a pas pu envoyer une relance (pas de portable ou d''e-mail du locataire dans Rivage, erreur d''envoi) : compléter Rivage ou relancer à la main.', '[]'::jsonb, 'compta')
on conflict (cle) do nothing;

commit;


-- ============================================================================================================================
-- 163 : relances automatiques des impayés — bloc 2 sur 3 : candidats, calendrier, envois, alertes, écrans
-- ============================================================================================================================
begin;

-- Baux en dette au-delà du seuil, avec le J0 du mois et la raison d'une exclusion éventuelle
create or replace function pilotage.relances_impayes_candidats(p_jour date)
returns table(bail_id text, dette numeric, loyer_cc numeric, sepa boolean, jour_prlv integer, rejet_le date, j0 date,
              origine text, motif text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with p as (
    select p_jour jour, date_trunc('month', p_jour)::date m0,
           pilotage.param('impaye_relance_auto', 'seuil', 15) seuil,
           pilotage.param('impaye_relance_auto', 'jour_virement', 5)::int jv,
           pilotage.param('impaye_relance_auto', 'jours_sans_rejet', 7)::int jsr,
           pilotage.param('impaye_relance_auto', 'mois_max', 2) mmax),
  b as (
    select o.id, o.data, round(coalesce((o.data->>'unpaid_amount')::numeric, 0) / 100, 2) dette
      from pilotage.objets o, p
     where o.type = 'LeasingContract' and o.supprime_le is null and o.data->>'status' in ('in_progress', 'move_out')
       and coalesce((o.data->>'unpaid_amount')::numeric, 0) > p.seuil * 100),
  pc as (
    select b.id, bool_or(c->>'payment_method' = 'sepa_debit') sepa,
           max(case when c->>'payment_method' = 'sepa_debit' then nullif(c->>'sepa_debit_day', '')::int end) jour
      from b, jsonb_array_elements(coalesce(b.data->'edit_attributes'->'profile_contracts_attributes', '[]'::jsonb)) c
     where c->>'profile_id' in (select t->>'id' from jsonb_array_elements(coalesce(b.data->'tenants', '[]'::jsonb)) t)
       and nullif(c->>'exit_date', '') is null
     group by b.id),
  rj as (
    select a.data->>'leasing_contract_id' bail, min((e.data->>'processed_at')::date) le
      from p, pilotage.objets e, jsonb_array_elements(coalesce(e.data->'accounting_entries', '[]'::jsonb)) x
      join pilotage.objets a on a.type = 'AccountingAccount' and a.id = x->>'accounting_account_id'
     where e.type = 'AccountingEvent' and e.supprime_le is null and e.data->>'nature' = 'tenant_payin_rejection'
       and coalesce((x->>'debit_in_cents')::numeric, 0) > 0 and a.data->>'holder_type' = 'tenant'
       and (e.data->>'processed_at')::date >= p.m0
     group by 1),
  c as (
    select b.id bail_id, b.dette, coalesce(v.loyer_hc, 0) + coalesce(v.charges, 0) loyer_cc,
           coalesce(pc.sepa, false) sepa, pc.jour jour_prlv, rj.le rejet_le,
           case when coalesce(pc.sepa, false)
                then coalesce(rj.le, make_date(extract(year from p.m0)::int, extract(month from p.m0)::int, least(greatest(coalesce(pc.jour, p.jv), 1), 28)) + p.jsr)
                else make_date(extract(year from p.m0)::int, extract(month from p.m0)::int, least(greatest(p.jv, 1), 28)) + 1 end j0,
           case when coalesce(pc.sepa, false) then case when rj.le is not null then 'rejet' else 'prelevement' end else 'virement' end origine,
           (select i from pilotage.impayes i where i.bail_id = b.id and i.groupe <> 'Clôturé' order by i.cree_le desc limit 1) dossier,
           p.mmax, p.jour, p.m0
      from b cross join p left join pc on pc.id = b.id left join rj on rj.bail = b.id left join pilotage.v_baux v on v.id = b.id)
  select c.bail_id, c.dette, c.loyer_cc, c.sepa, c.jour_prlv, c.rejet_le, c.j0, c.origine,
         case when (c.dossier).declaration_le is not null or nullif(trim(coalesce((c.dossier).procedure, '')), '') is not null
                   or (c.dossier).groupe in ('HUISSIER', 'AVOCAT', 'LIQUIDATION')
                then 'Dossier déclaré ou en procédure : suivi par Audrey'
              when (c.dossier).cree_le < c.m0
                then 'Dette ancienne (dossier ouvert le ' || to_char((c.dossier).cree_le at time zone 'Europe/Paris', 'DD/MM/YYYY') || ') : suivie à la main'
              when c.loyer_cc > 0 and c.dette > c.mmax * c.loyer_cc
                then 'Dette de plus de ' || replace(rtrim(rtrim(c.mmax::text, '0'), '.'), '.', ',') || ' mois de loyer : suivie à la main'
              when c.j0 > c.jour then 'Pas encore : premier envoi prévu le ' || to_char(pilotage.jour_envoi(c.j0), 'DD/MM/YYYY')
         end
    from c
$$;

-- Calendrier d'un cycle à partir de son J0 (dates déjà décalées hors dimanches et jours fériés)
create or replace function pilotage.relance_impaye_plan(p_j0 date)
returns table(ordre integer, etape text, libelle text, canal text, auto boolean, le date)
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare y int := extract(year from p_j0)::int; mo int := extract(month from p_j0)::int;
  j2 int := pilotage.param('impaye_relance_auto', 'j_sms2', 2)::int;
  j3 int := pilotage.param('impaye_relance_auto', 'j_appel', 3)::int;
  j5 int := pilotage.param('impaye_relance_auto', 'j_mail_ferme', 5)::int;
  md int := pilotage.param('impaye_relance_auto', 'med_delai', 6)::int;
  mj int := least(greatest(pilotage.param('impaye_relance_auto', 'med_jour_min', 10)::int, 1), 28);
  af int := least(greatest(pilotage.param('impaye_relance_auto', 'jour_appel_final', 15)::int, 1), 28);
  b date := pilotage.jour_envoi(p_j0); med date; fin date;   -- délais comptés depuis le premier envoi réel (J0 décalé)
begin
  med := pilotage.jour_envoi(least(greatest(b + md, make_date(y, mo, mj)), greatest(b + j3, make_date(y, mo, af))));
  fin := pilotage.jour_envoi(make_date(y, mo, af));
  return query values
    (1, 'j0_sms', 'Premier SMS', 'sms', true, b),
    (2, 'j0_mail', 'Premier mail', 'mail', true, b),
    (3, 'j2_sms', 'Deuxième SMS', 'sms', true, pilotage.jour_envoi(b + j2)),
    (4, 'j3_appel', 'Appel d''Audrey', 'appel', false, pilotage.jour_envoi(b + j3));
  if pilotage.jour_envoi(b + j5) < med then
    return query values (5, 'j5_mail', 'Mail ferme, copie au garant', 'mail', true, pilotage.jour_envoi(b + j5));
  end if;
  return query values (6, 'med', 'Mise en demeure (Audrey)', 'med', false, med);
  if fin > med and fin > pilotage.jour_envoi(b + j3) then
    return query values (7, 'j15_appel', 'Dernier appel avant la déclaration', 'appel', false, fin);
  end if;
end $$;

-- Ouverture et clôture des cycles (appelée chaque matin par la fonction d'envoi, avant les envois)
create or replace function pilotage.relances_impayes_detecter(p_jour date default null)
returns integer language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare d date := coalesce(p_jour, (now() at time zone 'Europe/Paris')::date); n int := 0;
  seuil numeric := pilotage.param('impaye_relance_auto', 'seuil', 15);
begin
  update pilotage.relances_impayes r set clos_le = now(), clos_motif = x.motif
    from (select r2.id, case
            when coalesce((o.data->>'unpaid_amount')::numeric, 0) <= seuil * 100 then 'Dette réglée selon Rivage'
            when o.id is null or o.supprime_le is not null or o.data->>'status' not in ('in_progress', 'move_out') then 'Bail terminé dans Rivage'
            when exists (select 1 from pilotage.impayes i where i.bail_id = r2.bail_id and i.groupe <> 'Clôturé'
                           and (i.declaration_le is not null or nullif(trim(coalesce(i.procedure, '')), '') is not null))
              then 'Dossier déclaré ou en procédure'
            when d >= (r2.mois + interval '1 month')::date then 'Fin du mois' end motif
            from pilotage.relances_impayes r2 left join pilotage.objets o on o.type = 'LeasingContract' and o.id = r2.bail_id
           where r2.clos_le is null) x
   where r.id = x.id and x.motif is not null;

  if not exists (select 1 from pilotage.regles where cle = 'impaye_relance_auto' and actif) then return 0; end if;
  insert into pilotage.relances_impayes (bail_id, mois, j0, origine, rejet_le, dette_initiale)
  select c.bail_id, date_trunc('month', c.j0)::date, c.j0, c.origine, c.rejet_le, c.dette
    from pilotage.relances_impayes_candidats(d) c
   where c.motif is null and c.j0 between d - 2 and d    -- pas de rattrapage : seulement les impayés du jour (ou de la veille)
     and not exists (select 1 from pilotage.relances_impayes r where r.bail_id = c.bail_id and r.clos_le is null)
  on conflict (bail_id, mois) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- État de chaque étape d'un cycle : fait, sautée, en erreur, à venir, due
create or replace function pilotage.relance_impaye_etapes(p_id bigint)
returns jsonb language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object('etape', pl.etape, 'libelle', pl.libelle, 'canal', pl.canal, 'auto', pl.auto, 'le', pl.le,
           'fait_le', s.fait_le, 'detail', s.detail,
           'statut', case when s.id is not null and s.detail like 'Non envoyé%' then 'sautee'
                          when s.id is not null then 'fait'
                          when r.clos_le is not null then 'annulee'
                          when exists (select 1 from pilotage.sms_envois e where e.cle = 'ri:' || r.id and e.etape = pl.etape and e.statut = 'erreur')
                            or exists (select 1 from pilotage.mails_envois e where e.cle = 'ri:' || r.id and e.etape = pl.etape and e.statut = 'erreur') then 'erreur'
                          when r.pause_le is not null then 'pause'
                          when pl.le <= (now() at time zone 'Europe/Paris')::date then 'due'
                          else 'a_venir' end) order by pl.ordre), '[]'::jsonb)
    from pilotage.relances_impayes r
    cross join lateral pilotage.relance_impaye_plan(r.j0) pl
    left join pilotage.suivis_etapes s on s.cle = 'ri:' || r.id and s.etape = pl.etape
   where r.id = p_id
$$;

-- Texte d'un modèle rempli pour un bail (contexte des messages + dette, constat, suite selon la garantie)
create or replace function pilotage.relance_impaye_texte(p_bail text, p_code text, p_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare ctx jsonb; mdl pilotage.messages_modeles; r pilotage.relances_impayes; dette numeric; org text; garants jsonb;
  objet text; texte text; constat text; constat_sms text;
begin
  select * into mdl from pilotage.messages_modeles where code = p_code;
  if not found then raise exception 'Modèle % introuvable', p_code; end if;
  select * into r from pilotage.relances_impayes where id = p_id;
  ctx := pilotage.messages_contexte('bail', p_bail);
  dette := (select round(coalesce((o.data->>'unpaid_amount')::numeric, 0) / 100, 2) from pilotage.objets o where o.type = 'LeasingContract' and o.id = p_bail);
  org := pilotage.organisme_bail(p_bail);
  garants := coalesce(ctx->'_contacts'->'garants', '[]'::jsonb);
  constat := case r.origine when 'rejet' then 'le prélèvement de votre loyer' || coalesce(' du ' || to_char(r.rejet_le, 'DD/MM/YYYY'), '') || ' a été rejeté par votre banque'
                            when 'prelevement' then 'le prélèvement de votre loyer n''a pas pu être encaissé'
                            else 'nous n''avons pas reçu le règlement de votre loyer' end;
  constat_sms := case r.origine when 'rejet' then 'votre prélèvement de loyer a été rejeté par votre banque'
                                when 'prelevement' then 'votre loyer n''a pas pu être prélevé'
                                else 'sauf erreur, votre loyer n''est pas réglé' end;
  ctx := ctx || jsonb_build_object('dette', pilotage.euros(dette), 'constat', constat, 'constat_sms', constat_sms,
    'suite', case when org is not null then 'à l''assurance loyers impayés du propriétaire' else 'en recouvrement' end,
    'suite_med', case when org is not null then ', notamment la déclaration à l''assurance loyers impayés' else ', notamment la délivrance d''un commandement de payer par commissaire de justice' end);
  objet := pilotage.message_remplir(mdl.objet, ctx);
  texte := pilotage.message_remplir(mdl.texte, ctx);
  texte := replace(texte, '{copie_garant}', case when jsonb_array_length(garants) > 0 then 'Une copie de ce message est adressée à la personne qui s''est portée caution.' else '' end);
  texte := regexp_replace(texte, '\n{3,}', E'\n\n', 'g');
  return jsonb_build_object('actif', mdl.actif, 'objet', objet, 'texte', texte, 'manquants',
    (select coalesce(jsonb_agg(distinct m[1]), '[]'::jsonb) from regexp_matches(coalesce(objet, '') || ' ' || texte, '\{([a-z_]+)\}', 'g') m where m[1] <> 'nom'),
    'locataires', coalesce(ctx->'_contacts'->'locataires', '[]'::jsonb), 'garants', garants);
end $$;

-- Mention RGPD au bas des mails (même texte que src/mails.js, 109)
create or replace function pilotage.mention_rgpd() returns text language sql immutable as $$
  select 'Protection des données personnelles : UDI Gestion traite les données vous concernant pour la gestion de votre dossier '
    || '(location, gestion du bien), sur la base du contrat qui nous lie et de nos obligations légales. Elles ne sont communiquées qu''aux '
    || 'personnes qui interviennent dans le dossier et sont conservées pendant la durée de notre relation, puis pendant les durées de '
    || 'prescription légales. Vous pouvez y accéder, les faire rectifier ou effacer, en demander la limitation ou vous opposer à leur '
    || 'traitement en écrivant à votregestionnaire@udi-immo.com. Vous pouvez également adresser une réclamation à la CNIL (www.cnil.fr).'
$$;

-- Envois du jour, préparés et tracés (réservé à la fonction pilotage-relances-impayes, clé de service)
create or replace function public.pilotage_relances_impayes_preparer()
returns jsonb language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare d date := (now() at time zone 'Europe/Paris')::date; r pilotage.relances_impayes; dmax date; st record;
  t jsonb; loc jsonb; tel text; nom text; txt text; dest text[]; nid bigint; code text;
  sms jsonb := '[]'::jsonb; mails jsonb := '[]'::jsonb; nouveaux int;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Réservé à la tâche planifiée'; end if;
  nouveaux := pilotage.relances_impayes_detecter(d);
  if not exists (select 1 from pilotage.regles where cle = 'impaye_relance_auto' and actif) then
    return jsonb_build_object('actif', false, 'sms', sms, 'mails', mails);
  end if;
  for r in select * from pilotage.relances_impayes where clos_le is null and pause_le is null order by id loop
    begin
      -- étapes automatiques dues, ni faites ni déjà tentées aujourd'hui
      select max(pl.le) into dmax from pilotage.relance_impaye_plan(r.j0) pl
       where pl.auto and pl.le <= d
         and not exists (select 1 from pilotage.suivis_etapes s where s.cle = 'ri:' || r.id and s.etape = pl.etape)
         and not exists (select 1 from pilotage.sms_envois e where e.cle = 'ri:' || r.id and e.etape = pl.etape and e.cree_le::date = current_date)
         and not exists (select 1 from pilotage.mails_envois e where e.cle = 'ri:' || r.id and e.etape = pl.etape and e.cree_le::date = current_date);
      continue when dmax is null;
      for st in select pl.* from pilotage.relance_impaye_plan(r.j0) pl
                 where pl.auto and pl.le <= d
                   and not exists (select 1 from pilotage.suivis_etapes s where s.cle = 'ri:' || r.id and s.etape = pl.etape)
                   and not exists (select 1 from pilotage.sms_envois e where e.cle = 'ri:' || r.id and e.etape = pl.etape and e.cree_le::date = current_date)
                   and not exists (select 1 from pilotage.mails_envois e where e.cle = 'ri:' || r.id and e.etape = pl.etape and e.cree_le::date = current_date) loop
        if st.le < dmax then   -- une étape plus récente est due : celle-ci ne part plus (pas de rafale)
          insert into pilotage.suivis_etapes (cle, etape, detail) values ('ri:' || r.id, st.etape, 'Non envoyé : étape suivante déjà due')
          on conflict (cle, etape) do nothing;
          continue;
        end if;
        code := case st.etape when 'j0_sms' then 'ri_j0_sms' when 'j0_mail' then 'ri_j0_email' when 'j2_sms' then 'ri_j2_sms' when 'j5_mail' then 'ri_j5_email' end;
        t := pilotage.relance_impaye_texte(r.bail_id, code, r.id);
        if not (t->>'actif')::boolean then
          insert into pilotage.suivis_etapes (cle, etape, detail) values ('ri:' || r.id, st.etape, 'Non envoyé : modèle désactivé')
          on conflict (cle, etape) do nothing;
          continue;
        end if;
        if st.canal = 'sms' then
          for loc in select x from jsonb_array_elements(t->'locataires') x loop
            tel := pilotage.tel_portable(loc->>'telephone');
            continue when tel is null;
            nom := pilotage.nom_sms(loc->>'nom');
            txt := trim(replace(t->>'texte', '{nom}', nom));
            insert into pilotage.sms_envois (bail_id, destinataire, telephone, texte, cle, etape, statut, erreur)
            values (r.bail_id, nom, tel, txt, 'ri:' || r.id, st.etape,
                    case when jsonb_array_length(t->'manquants') > 0 then 'erreur' else 'a_envoyer' end,
                    case when jsonb_array_length(t->'manquants') > 0 then 'Champ non rempli : ' || (t->'manquants')::text end)
            returning id into nid;
            if jsonb_array_length(t->'manquants') = 0 then sms := sms || jsonb_build_object('id', nid, 'telephone', tel, 'texte', txt, 'nom', nom, 'bail', r.bail_id); end if;
          end loop;
          if not exists (select 1 from pilotage.sms_envois e where e.cle = 'ri:' || r.id and e.etape = st.etape and e.cree_le::date = current_date) then
            insert into pilotage.sms_envois (bail_id, destinataire, telephone, texte, cle, etape, statut, erreur)
            values (r.bail_id, 'locataire', '', coalesce(t->>'texte', ''), 'ri:' || r.id, st.etape, 'erreur', 'Aucun numéro de portable du locataire dans Rivage');
          end if;
        else
          select coalesce(array_agg(distinct lower(trim(x->>'email'))), '{}') into dest
            from jsonb_array_elements(t->'locataires' || case when st.etape = 'j5_mail' then t->'garants' else '[]'::jsonb end) x
           where nullif(trim(x->>'email'), '') is not null;
          txt := rtrim(t->>'texte') || E'\n\n--\n' || pilotage.mention_rgpd();
          insert into pilotage.mails_envois (bail_id, destinataires, objet, corps, cle, etape, statut, erreur)
          values (r.bail_id, dest, coalesce(t->>'objet', 'Loyer impayé'), txt, 'ri:' || r.id, st.etape,
                  case when cardinality(dest) = 0 or jsonb_array_length(t->'manquants') > 0 then 'erreur' else 'prepare' end,
                  case when cardinality(dest) = 0 then 'Aucune adresse e-mail du locataire dans Rivage'
                       when jsonb_array_length(t->'manquants') > 0 then 'Champ non rempli : ' || (t->'manquants')::text end)
          returning id into nid;
          if cardinality(dest) > 0 and jsonb_array_length(t->'manquants') = 0 then
            mails := mails || jsonb_build_object('id', nid, 'to', to_jsonb(dest), 'objet', t->>'objet', 'corps', txt, 'bail', r.bail_id);
          end if;
        end if;
      end loop;
    exception when others then
      insert into pilotage.mails_envois (bail_id, destinataires, objet, corps, cle, etape, statut, erreur)
      values (r.bail_id, '{}', 'Relance automatique', '-', 'ri:' || r.id, 'preparation', 'erreur', left(sqlerrm, 300));
    end;
  end loop;
  return jsonb_build_object('actif', true, 'nouveaux', nouveaux, 'sms', sms, 'mails', mails);
end $$;

-- Relance automatique réussie : notée dans le dossier d'impayé (fait avancer la frise, comme le bouton « Relance amiable faite »)
create or replace function pilotage.relance_impaye_vers_dossier() returns trigger
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_bail text; v_dossier bigint; lib text;
begin
  if new.cle not like 'ri:%' or coalesce(new.detail, '') like 'Non envoyé%' then return new; end if;
  select bail_id into v_bail from pilotage.relances_impayes where id = nullif(split_part(new.cle, ':', 2), '')::bigint;
  select id into v_dossier from pilotage.impayes where bail_id = v_bail and groupe <> 'Clôturé' order by cree_le desc limit 1;
  if v_dossier is null then return new; end if;
  lib := case new.etape when 'j0_sms' then 'Relance automatique : premier SMS' when 'j0_mail' then 'Relance automatique : premier mail'
                        when 'j2_sms' then 'Relance automatique : deuxième SMS' when 'j5_mail' then 'Relance automatique : mail ferme'
                        when 'med' then 'Mise en demeure envoyée' end;
  if lib is null then return new; end if;
  if not exists (select 1 from pilotage.impayes_actions a where a.impaye_id = v_dossier and a.libelle = lib and a.le = current_date) then
    insert into pilotage.impayes_actions (impaye_id, libelle, statut, le, par) values (v_dossier, lib, 'Fait', current_date, new.par);
  end if;
  return new;
end $$;
drop trigger if exists relance_impaye_vers_dossier on pilotage.suivis_etapes;
create trigger relance_impaye_vers_dossier after insert on pilotage.suivis_etapes
  for each row execute function pilotage.relance_impaye_vers_dossier();

-- « Mise en demeure envoyée » noté dans le dossier : étape du cycle en cours faite (ferme l'alerte)
create or replace function pilotage.dossier_vers_relance_impaye() returns trigger
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_cycle bigint;
begin
  if new.statut <> 'Fait' or new.libelle !~* 'mise en demeure' then return new; end if;
  select r.id into v_cycle from pilotage.relances_impayes r join pilotage.impayes i on i.bail_id = r.bail_id
   where i.id = new.impaye_id and r.clos_le is null order by r.id desc limit 1;
  if v_cycle is null then return new; end if;
  insert into pilotage.suivis_etapes (cle, etape, par, detail)
  values ('ri:' || v_cycle, 'med', new.par, 'Notée dans le dossier d''impayé')
  on conflict (cle, etape) do nothing;
  return new;
end $$;
drop trigger if exists dossier_vers_relance_impaye on pilotage.impayes_actions;
create trigger dossier_vers_relance_impaye after insert or update of statut on pilotage.impayes_actions
  for each row execute function pilotage.dossier_vers_relance_impaye();

-- Alertes à la comptable (ajoutées aux détections des impayés)
create or replace function pilotage.relances_impayes_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with r as (
    select r.*, coalesce((select v.locataires from pilotage.v_baux v where v.id = r.bail_id), r.bail_id) loc,
           (select round(coalesce((o.data->>'unpaid_amount')::numeric, 0) / 100, 2) from pilotage.objets o where o.type = 'LeasingContract' and o.id = r.bail_id) dette,
           (now() at time zone 'Europe/Paris')::date d
      from pilotage.relances_impayes r
     where r.clos_le is null and r.pause_le is null
       and exists (select 1 from pilotage.regles g where g.cle = 'impaye_relance_auto' and g.actif)),
  e as (select r.*, x from r, jsonb_array_elements(pilotage.relance_impaye_etapes(r.id)) x)
  select case x->>'etape' when 'j3_appel' then 'impaye_relance_appel' when 'med' then 'impaye_relance_med' else 'impaye_relance_appel_final' end,
         'LeasingContract', bail_id,
         case x->>'etape' when 'j3_appel' then 'Impayé : appeler ' when 'med' then 'Impayé : mise en demeure à envoyer à ' else 'Impayé : dernier appel avant la déclaration à ' end || loc,
         'Dette ' || pilotage.euros(dette) || ', relances automatiques depuis le ' || to_char(j0, 'DD/MM/YYYY')
           || case x->>'etape' when 'med' then '. Texte prêt dans le dossier d''impayé (bloc « Relances automatiques »).'
                               when 'j15_appel' then '. Une promesse de paiement ne bloque pas la déclaration.' else '.' end,
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || bail_id
    from e
   where x->>'etape' in ('j3_appel', 'med', 'j15_appel') and x->>'statut' = 'due'
     and (x->>'etape' <> 'j3_appel' or d < coalesce((select (y->>'le')::date from jsonb_array_elements(pilotage.relance_impaye_etapes(e.id)) y where y->>'etape' = 'med'), d + 1))
     and (x->>'etape' <> 'j15_appel' or d <= make_date(extract(year from d)::int, extract(month from d)::int, least(pilotage.param('impaye_zelok_declarer', 'jour_fin', 19)::int, 28)))
  union all
  select 'impaye_relance_contact', 'LeasingContract', bail_id, 'Impayé : relance automatique non envoyée à ' || loc,
         'Étape « ' || (x->>'libelle') || ' » : ' || coalesce((select e2.erreur from pilotage.sms_envois e2 where e2.cle = 'ri:' || e.id and e2.etape = x->>'etape' and e2.statut = 'erreur' order by e2.id desc limit 1),
                                                       (select e2.erreur from pilotage.mails_envois e2 where e2.cle = 'ri:' || e.id and e2.etape = x->>'etape' and e2.statut = 'erreur' order by e2.id desc limit 1), 'erreur d''envoi')
           || '. Compléter Rivage ou relancer à la main.',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || bail_id
    from e where x->>'statut' = 'erreur'
$$;

-- Détections des impayés (155-162) : mêmes alertes qu'avant, plus celles des relances automatiques
create or replace function pilotage.suivi_detections_impayes()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select case when pilotage.jour_paris() >= pilotage.param('impaye_zelok_urgent','jour_urgent',18) then 'impaye_zelok_urgent' else 'impaye_zelok_declarer' end, 'LeasingContract', a.bail_id,
         'Impayé à déclarer à Zelok avant le ' || pilotage.param('impaye_zelok_declarer','jour_fin',19)::int || ' : ' || coalesce((select v.locataires from pilotage.v_baux v where v.id = a.bail_id), a.bail_id),
         'Dette ' || a.dette || ' €' || coalesce(', impayé ouvert le ' || to_char(a.ouvert_le, 'DD/MM/YYYY'), '') || '. Pièces : onglet Impayés, « Ce mois-ci ».',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || a.bail_id
  from pilotage.impayes_a_declarer() a where pilotage.jour_paris() between pilotage.param('impaye_zelok_declarer','jour_debut',16) and pilotage.param('impaye_zelok_declarer','jour_fin',19)
  union all
  select 'impaye_actualisation', 'Organisme', o.organisme,
         'Actualiser les dossiers ' || initcap(o.organisme) || ' du mois (' || o.n || ' dossier(s))',
         'Extrait de compte à jour de chaque dossier ouvert à transmettre. Onglet Impayés, « Ce mois-ci ».', null
  from (select coalesce(case when procedure ilike '%avocat%' then 'avocats' end, organisme) organisme, count(*) n
        from pilotage.impayes where groupe <> 'Clôturé' and organisme is not null and organisme <> 'aucun' group by 1) o
  where pilotage.jour_paris() >= pilotage.param('impaye_actualisation','jour_debut',16)
    and not exists (select 1 from pilotage.impayes_actualisations x where x.organisme = o.organisme and x.mois = pilotage.mois_paris())
  union all
  select 'impaye_reglement', 'LeasingContract', r.bail_id,
         'Règlement reçu sur un impayé déclaré à ' || initcap(r.organisme) || ' : ' || coalesce((select v.locataires from pilotage.v_baux v where v.id = r.bail_id), ''),
         'Règlement de ' || r.montant || ' € le ' || to_char(r.recu_le, 'DD/MM/YYYY') || ' : prévenir l''organisme avec l''extrait de compte.'
           || case when coalesce(r.indemnisation_compte, 0) <> 0 then ' Indemnisation déjà reçue (compte GLI du bail : ' || r.indemnisation_compte || ' €) : calculer le montant à reverser.' else '' end,
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || r.bail_id
  from pilotage.impayes_reglements() r
  union all  -- 163
  select x.regle, x.objet_type, x.objet_id, x.titre, x.detail, x.lien from pilotage.relances_impayes_detections() x
$$;

-- Écran : relances automatiques d'un bail (bloc du dossier d'impayé)
create or replace function public.pilotage_relances_impaye(p_bail text)
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare r pilotage.relances_impayes; c record;
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  select * into r from pilotage.relances_impayes where bail_id = p_bail order by (clos_le is null) desc, mois desc, id desc limit 1;
  select * into c from pilotage.relances_impayes_candidats((now() at time zone 'Europe/Paris')::date) x where x.bail_id = p_bail;
  return jsonb_build_object(
    'actif', exists (select 1 from pilotage.regles where cle = 'impaye_relance_auto' and actif),
    'peut', pilotage.peut_saisir_impayes(),
    'candidat', case when c.bail_id is not null then jsonb_build_object('dette', c.dette, 'origine', c.origine, 'j0', c.j0, 'motif', c.motif) end,
    'cycle', case when r.id is not null then jsonb_build_object('id', r.id, 'mois', r.mois, 'j0', r.j0, 'origine', r.origine, 'rejet_le', r.rejet_le,
       'dette_initiale', r.dette_initiale, 'pause_le', r.pause_le, 'pause_motif', r.pause_motif,
       'pause_par', (select m.prenom from pilotage.membres m where m.user_id = r.pause_par), 'clos_le', r.clos_le, 'clos_motif', r.clos_motif,
       'etapes', pilotage.relance_impaye_etapes(r.id)) end);
end $$;

-- Mise en demeure préparée pour le cycle en cours (texte et adresses des locataires ; envoi par la fonction pilotage-mail, qui n'accepte
--  que les adresses des locataires et des bailleurs : le garant n'est pas destinataire du mail)
create or replace function public.pilotage_relance_impaye_med(p_bail text)
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare r pilotage.relances_impayes; t jsonb;
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  select * into r from pilotage.relances_impayes where bail_id = p_bail and clos_le is null order by id desc limit 1;
  t := pilotage.relance_impaye_texte(p_bail, 'ri_med_email', r.id);
  return jsonb_build_object('cle', case when r.id is not null then 'ri:' || r.id end, 'objet', t->>'objet',
    'corps', rtrim(t->>'texte') || E'\n\n--\n' || pilotage.mention_rgpd(), 'manquants', t->'manquants',
    'garants', t->'garants',
    'to', (select coalesce(jsonb_agg(distinct lower(trim(x->>'email'))), '[]'::jsonb) from jsonb_array_elements(t->'locataires') x
            where nullif(trim(x->>'email'), '') is not null));
end $$;

-- Pause / reprise par la comptable (plan d'apurement, erreur Rivage…) : plus aucun envoi ni alerte tant que la pause dure
create or replace function public.pilotage_relance_impaye_pause(p_bail text, p_pause boolean, p_motif text)
returns void language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_id bigint;
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  select id into v_id from pilotage.relances_impayes where bail_id = p_bail and clos_le is null order by id desc limit 1;
  if v_id is null then raise exception 'Aucune relance automatique en cours pour ce bail'; end if;
  if p_pause and nullif(trim(coalesce(p_motif, '')), '') is null then raise exception 'Motif de la pause obligatoire'; end if;
  update pilotage.relances_impayes set pause_le = case when p_pause then now() end, pause_par = case when p_pause then auth.uid() end,
         pause_motif = case when p_pause then trim(p_motif) end
   where id = v_id;
  insert into pilotage.impayes_notes (impaye_id, auteur, auteur_id, contenu)
  select i.id, coalesce((select m.prenom from pilotage.membres m where m.user_id = auth.uid()), 'Pilotage'), auth.uid(),
         case when p_pause then 'Relances automatiques mises en pause : ' || trim(p_motif) else 'Relances automatiques reprises.' end
    from pilotage.impayes i where i.bail_id = p_bail and i.groupe <> 'Clôturé' order by i.cree_le desc limit 1;
end $$;

-- Aperçu du mois (onglet « À faire ce mois-ci ») : ce qui part, ce qui est en pause, ce qui est écarté et pourquoi
create or replace function public.pilotage_relances_impayes_apercu()
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare d date := (now() at time zone 'Europe/Paris')::date;
begin
  if coalesce(pilotage.mon_role(), '') not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'actif', exists (select 1 from pilotage.regles where cle = 'impaye_relance_auto' and actif),
    'jour', d,
    'lignes', coalesce((select jsonb_agg(jsonb_build_object(
        'bail_id', c.bail_id, 'locataires', (select v.locataires from pilotage.v_baux v where v.id = c.bail_id),
        'reference', (select v.reference from pilotage.v_baux v where v.id = c.bail_id),
        'dette', c.dette, 'origine', c.origine, 'j0', c.j0, 'motif', c.motif,
        'cycle', (select jsonb_build_object('id', r.id, 'pause_motif', r.pause_motif,
                    'prochaine', (select x from jsonb_array_elements(pilotage.relance_impaye_etapes(r.id)) x
                                   where x->>'statut' in ('due', 'a_venir', 'erreur') order by (x->>'le')::date limit 1))
                    from pilotage.relances_impayes r where r.bail_id = c.bail_id and r.clos_le is null order by r.id desc limit 1))
      order by c.motif nulls first, c.j0) from pilotage.relances_impayes_candidats(d) c), '[]'::jsonb));
end $$;

revoke all on function public.pilotage_relances_impayes_preparer() from public, anon, authenticated;
grant execute on function public.pilotage_relances_impayes_preparer() to service_role;
revoke all on function public.pilotage_relances_impaye(text), public.pilotage_relance_impaye_med(text),
  public.pilotage_relance_impaye_pause(text, boolean, text), public.pilotage_relances_impayes_apercu() from public, anon;
grant execute on function public.pilotage_relances_impaye(text), public.pilotage_relance_impaye_med(text),
  public.pilotage_relance_impaye_pause(text, boolean, text), public.pilotage_relances_impayes_apercu() to authenticated;

commit;


-- ============================================================================================================================
-- 163 : relances automatiques des impayés — bloc 3 sur 3 : tâches planifiées
-- ============================================================================================================================
begin;

-- Ancienne relance UDIGESTION (public.suivi_impayes) : arrêtée, le pilotage relance seul
select cron.unschedule(jobid) from cron.job where jobname = 'relance-impayes-auto-quotidien';

-- Envoi chaque jour à 8 h UTC (9 h l'hiver, 10 h l'été), après la relecture des impayés de 6 h 15
select cron.unschedule(jobid) from cron.job where jobname = 'pilotage-relances-impayes';
select cron.schedule('pilotage-relances-impayes', '0 8 * * *', $cron$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-relances-impayes',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{}'::jsonb) $cron$);

commit;
