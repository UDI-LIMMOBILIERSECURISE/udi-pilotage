-- 166 : relances des impayés, trace complète et historique visible (essai de Nicolas du 13/11/2026, retours du 14/11 à 8 h)
--  Constats : deux SMS envoyés au bail 23 le 13/11 (19 h 49 et 22 h 32), un seul noté dans le dossier (trace regroupée par bail
--  et par jour) ; la liste des relances ne montrait pas ce qui avait déjà été envoyé ; les relances faites par Rivage n'apparaissaient
--  nulle part (73 baux passés « Relancé » dans Rivage le 13/11 entre 16 h 21 et 16 h 23).
--  - Chaque SMS ou mail de relance transmis (clés ri: automatiques, rim: à la main) crée sa propre ligne dans le dossier d'impayé,
--    avec l'heure et le destinataire, et le texte dans le fil des échanges. Plus de regroupement par jour.
--  - pilotage.relances_bail(bail) : historique des relances d'un bail, envois du pilotage (SMS, mails, statut, erreur, texte, auteur)
--    et changements de statut du cycle d'impayé Rivage (date de « Relancé », clôture), le plus récent d'abord.
--  - pilotage_relances_impaye : historique ajouté ; pilotage_relances_impayes_apercu : dernière relance de chaque bail
--    (pilotage ou Rivage), nombre d'envois du mois et des dernières 48 h.
--  - Rattrapage : le SMS du 13/11 à 22 h 32 (bail 23) est noté dans son dossier ; la ligne du SMS de 19 h 49 prend le nouveau libellé.
--  L'API Rivage n'a aucune écriture de relance ni de note (vérifié le 14/11 sur api.rivage.immo/llms.txt : messages en lecture
--  et suppression seulement, statut d'impayé en lecture) : les relances du pilotage restent dans le pilotage.
--  Bloc unique.

begin;

-- 1. Une ligne par envoi transmis, posée par l'envoi lui-même (et non plus par l'étape, qui ne garde qu'une trace par jour)
create or replace function pilotage.envoi_relance_vers_dossier() returns trigger
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_dossier bigint; lib text; canal text := tg_argv[0]; dest text; texte text; qui text;
begin
  if new.statut <> 'transmis' or coalesce(old.statut, '') = 'transmis' or coalesce(new.cle, '') !~ '^rim?:' then return new; end if;
  select id into v_dossier from pilotage.impayes where bail_id = new.bail_id and groupe <> 'Clôturé' order by cree_le desc limit 1;
  if v_dossier is null then return new; end if;
  if canal = 'sms' then
    dest := new.destinataire; texte := new.texte;
  else
    dest := array_to_string(new.destinataires, ', '); texte := new.objet || E'\n' || new.corps;
  end if;
  lib := case when new.etape = 'med' then 'Mise en demeure envoyée par mail'
              when new.cle like 'rim:%' then 'Relance ' || case canal when 'sms' then 'SMS' else 'mail' end || ' envoyée à la main'
              else 'Relance automatique : ' || case new.etape when 'j0_sms' then 'premier SMS' when 'j0_mail' then 'premier mail'
                                                               when 'j2_sms' then 'deuxième SMS' when 'j5_mail' then 'mail ferme' else new.etape end end
         || ' (' || to_char(coalesce(new.transmis_le, now()) at time zone 'Europe/Paris', 'HH24"h"MI') || ', à ' || coalesce(nullif(dest, ''), '?') || ')';
  insert into pilotage.impayes_actions (impaye_id, libelle, statut, le, par)
  values (v_dossier, lib, 'Fait', (coalesce(new.transmis_le, now()) at time zone 'Europe/Paris')::date, new.par);
  qui := coalesce((select m.prenom from pilotage.membres m where m.user_id = new.par), 'Pilotage (automatique)');
  insert into pilotage.impayes_notes (impaye_id, auteur, auteur_id, contenu)
  values (v_dossier, qui, new.par, lib || E' :\n' || left(texte, 1500));
  return new;
end $$;
drop trigger if exists envoi_relance_vers_dossier on pilotage.sms_envois;
create trigger envoi_relance_vers_dossier after update of statut on pilotage.sms_envois
  for each row execute function pilotage.envoi_relance_vers_dossier('sms');
drop trigger if exists envoi_relance_vers_dossier on pilotage.mails_envois;
create trigger envoi_relance_vers_dossier after update of statut on pilotage.mails_envois
  for each row execute function pilotage.envoi_relance_vers_dossier('mail');

-- L'ancienne trace par étape (163, 165) ne sert plus : elle doublerait les lignes
drop trigger if exists relance_impaye_vers_dossier on pilotage.suivis_etapes;
drop function if exists pilotage.relance_impaye_vers_dossier();

-- 2. Historique des relances d'un bail : pilotage (SMS, mails) et Rivage (statut du cycle d'impayé)
create or replace function pilotage.relances_bail(p_bail text, p_depuis date default null)
returns jsonb language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce(jsonb_agg(x order by x->>'le' desc), '[]'::jsonb) from (
    select jsonb_build_object('le', e.cree_le, 'source', 'pilotage', 'canal', 'sms', 'manuel', e.cle like 'rim:%', 'etape', e.etape,
             'destinataire', e.destinataire, 'statut', e.statut, 'erreur', e.erreur, 'texte', e.texte,
             'par', (select m.prenom from pilotage.membres m where m.user_id = e.par)) x
      from pilotage.sms_envois e where e.bail_id = p_bail and e.cle ~ '^rim?:' and e.telephone <> ''
       and (p_depuis is null or e.cree_le >= p_depuis)
    union all
    select jsonb_build_object('le', e.cree_le, 'source', 'pilotage', 'canal', 'mail', 'manuel', e.cle like 'rim:%' or e.etape = 'med', 'etape', e.etape,
             'destinataire', array_to_string(e.destinataires, ', '), 'statut', e.statut, 'erreur', e.erreur, 'texte', e.objet,
             'par', (select m.prenom from pilotage.membres m where m.user_id = e.par))
      from pilotage.mails_envois e where e.bail_id = p_bail and e.cle ~ '^rim?:' and e.etape <> 'preparation'
       and (p_depuis is null or e.cree_le >= p_depuis)
    union all
    select jsonb_build_object('le', (h->>'at')::timestamptz, 'source', 'rivage', 'canal', 'rivage', 'manuel', false, 'etape', h->>'status',
             'destinataire', null, 'statut', 'transmis', 'erreur', null,
             'texte', case h->>'status' when 'opened' then 'Impayé détecté par Rivage' when 'reminded' then 'Relance envoyée par Rivage'
                                      when 'formal_notice' then 'Mise en demeure (Rivage)' when 'gli_reported' then 'Déclaré à la GLI (Rivage)'
                                      when 'long_contentious' then 'Contentieux (Rivage)' when 'closed' then 'Impayé clos dans Rivage' else h->>'status' end,
             'par', null)
      from pilotage.objets o, jsonb_array_elements(coalesce(o.data->'rent_arrear'->'status_history', '[]'::jsonb)) h
     where o.type = 'RentArrear' and o.id = p_bail and (p_depuis is null or (h->>'at')::timestamptz >= p_depuis)) z
$$;

-- 3. Écran du dossier : historique en plus
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
    'peut_sms', pilotage.peut_suivre_baux() or pilotage.mon_role() = 'comptable',
    'candidat', case when c.bail_id is not null then jsonb_build_object('dette', c.dette, 'origine', c.origine, 'j0', c.j0, 'motif', c.motif) end,
    'historique', pilotage.relances_bail(p_bail, ((now() at time zone 'Europe/Paris')::date - 90)),
    'cycle', case when r.id is not null then jsonb_build_object('id', r.id, 'mois', r.mois, 'j0', r.j0, 'origine', r.origine, 'rejet_le', r.rejet_le,
       'dette_initiale', r.dette_initiale, 'pause_le', r.pause_le, 'pause_motif', r.pause_motif,
       'pause_par', (select m.prenom from pilotage.membres m where m.user_id = r.pause_par), 'clos_le', r.clos_le, 'clos_motif', r.clos_motif,
       'etapes', pilotage.relance_impaye_etapes(r.id)) end);
end $$;

-- 4. Aperçu du mois : dernière relance de chaque bail (pilotage ou Rivage), envois du mois et des dernières 48 h
create or replace function public.pilotage_relances_impayes_apercu()
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare d date := (now() at time zone 'Europe/Paris')::date; m date := date_trunc('month', (now() at time zone 'Europe/Paris'))::date;
begin
  if coalesce(pilotage.mon_role(), '') not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'actif', exists (select 1 from pilotage.regles where cle = 'impaye_relance_auto' and actif),
    'jour', d,
    'lignes', coalesce((select jsonb_agg(jsonb_build_object(
        'bail_id', c.bail_id, 'locataires', v.locataires, 'reference', v.reference,
        'dette', c.dette, 'origine', c.origine, 'j0', c.j0, 'motif', c.motif,
        'envois', h.envois, 'envois_48h', h.envois_48h, 'derniere', h.derniere, 'rivage_relance_le', h.rivage_le,
        'cycle', (select jsonb_build_object('id', r.id, 'pause_motif', r.pause_motif,
                    'prochaine', (select x from jsonb_array_elements(pilotage.relance_impaye_etapes(r.id)) x
                                   where x->>'statut' in ('due', 'a_venir', 'erreur') order by (x->>'le')::date limit 1))
                    from pilotage.relances_impayes r where r.bail_id = c.bail_id and r.clos_le is null order by r.id desc limit 1))
      order by c.motif nulls first, (h.derniere is not null), c.j0)
      from pilotage.relances_impayes_candidats(d) c
      left join pilotage.v_baux v on v.id = c.bail_id
      cross join lateral (
        select count(*) filter (where y->>'source' = 'pilotage' and y->>'statut' = 'transmis') envois,
               count(*) filter (where y->>'source' = 'pilotage' and y->>'statut' = 'transmis' and (y->>'le')::timestamptz > now() - interval '48 hours') envois_48h,
               (select z from jsonb_array_elements(pilotage.relances_bail(c.bail_id, m)) z
                 where (z->>'source' = 'pilotage' and z->>'statut' = 'transmis') or z->>'etape' = 'reminded' order by z->>'le' desc limit 1) derniere,
               max((y->>'le')::timestamptz) filter (where y->>'etape' = 'reminded') rivage_le
          from jsonb_array_elements(pilotage.relances_bail(c.bail_id, m)) y) h), '[]'::jsonb));
end $$;

-- 5. Rattrapage des envois du 13/11 : le SMS de 22 h 32 (bail 23) n'avait pas de ligne ; l'autre prend le nouveau libellé
update pilotage.impayes_actions a
   set libelle = 'Relance SMS envoyée à la main (' || to_char(e.transmis_le at time zone 'Europe/Paris', 'HH24"h"MI') || ', à ' || e.destinataire || ')'
  from pilotage.sms_envois e
 where a.libelle = 'Relance SMS envoyée à la main' and e.cle like 'rim:%' and e.statut = 'transmis' and a.cree_le = e.transmis_le;
insert into pilotage.impayes_actions (impaye_id, libelle, statut, le, par)
select (select i.id from pilotage.impayes i where i.bail_id = e.bail_id and i.groupe <> 'Clôturé' order by i.cree_le desc limit 1),
       'Relance SMS envoyée à la main (' || to_char(e.transmis_le at time zone 'Europe/Paris', 'HH24"h"MI') || ', à ' || e.destinataire || ')',
       'Fait', (e.transmis_le at time zone 'Europe/Paris')::date, e.par
  from pilotage.sms_envois e
 where e.cle like 'rim:%' and e.statut = 'transmis'
   and exists (select 1 from pilotage.impayes i where i.bail_id = e.bail_id and i.groupe <> 'Clôturé')
   and not exists (select 1 from pilotage.impayes_actions a where a.libelle like 'Relance SMS envoyée à la main (' || to_char(e.transmis_le at time zone 'Europe/Paris', 'HH24"h"MI') || '%');

commit;
