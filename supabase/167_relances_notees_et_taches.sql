-- 167 : dossier d'impayé, relances d'un côté, tâches de l'autre (décision de Nicolas du 14/11/2026, 8 h 34)
--  Constat : depuis le 166, chaque SMS figurait deux fois (bloc « Relances » et « Sous-éléments / actions »).
--  - Les envois (SMS, mails) ne s'écrivent plus dans les actions du dossier : ils restent dans « Relances » et dans le fil des échanges.
--  - Relance faite hors pilotage (appel, courrier, recommandé, SMS du portable, mail hors pilotage) : table pilotage.relances_notees,
--    saisie depuis le bloc « Relances » (remplace les boutons « Relance amiable faite » / « Mise en demeure envoyée » qui créaient
--    une action). Une mise en demeure notée ferme l'étape du cycle automatique (comme avant).
--  - pilotage.relances_bail : relances notées ajoutées à l'historique ; pilotage.relances_resume(bail, depuis) : relances et mises en
--    demeure datées, lues par la frise du dossier (clé « relances » de pilotage_impayes).
--  - Les actions deviennent les « Tâches du dossier » ; une tâche non faite dont l'échéance est passée remonte dans Ma journée de la
--    comptable (règle impaye_tache_echeance).
--  - Nettoyage : les 2 lignes de SMS du 13/11 (bail 23) sont retirées des actions ; elles restent dans « Relances » et le fil.
--  Bloc unique.

begin;

create table if not exists pilotage.relances_notees (
  id bigint generated always as identity primary key,
  bail_id text not null,
  impaye_id bigint,
  quoi text not null check (quoi in ('relance', 'med')),
  moyen text not null check (moyen in ('appel', 'courrier', 'recommande', 'sms_portable', 'mail', 'autre')),
  le date not null default ((now() at time zone 'Europe/Paris')::date),
  par uuid, note text,
  cree_le timestamptz not null default now()
);
create index if not exists relances_notees_bail on pilotage.relances_notees (bail_id);
alter table pilotage.relances_notees enable row level security;
revoke all on pilotage.relances_notees from public, anon, authenticated;

-- 1. Les envois ne créent plus d'action : seulement la note dans le fil
create or replace function pilotage.envoi_relance_vers_dossier() returns trigger
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_dossier bigint; lib text; canal text := tg_argv[0]; dest text; texte text; qui text;
begin
  if new.statut <> 'transmis' or coalesce(old.statut, '') = 'transmis' or coalesce(new.cle, '') !~ '^rim?:' then return new; end if;
  select id into v_dossier from pilotage.impayes where bail_id = new.bail_id and groupe <> 'Clôturé' order by cree_le desc limit 1;
  if v_dossier is null then return new; end if;
  if canal = 'sms' then dest := new.destinataire; texte := new.texte;
  else dest := array_to_string(new.destinataires, ', '); texte := new.objet || E'\n' || new.corps; end if;
  lib := case when new.etape = 'med' then 'Mise en demeure envoyée par mail'
              when new.cle like 'rim:%' then 'Relance ' || case canal when 'sms' then 'SMS' else 'mail' end || ' envoyée à la main'
              else 'Relance automatique : ' || case new.etape when 'j0_sms' then 'premier SMS' when 'j0_mail' then 'premier mail'
                                                               when 'j2_sms' then 'deuxième SMS' when 'j5_mail' then 'mail ferme' else new.etape end end
         || ' (' || to_char(coalesce(new.transmis_le, now()) at time zone 'Europe/Paris', 'DD/MM HH24"h"MI') || ', à ' || coalesce(nullif(dest, ''), '?') || ')';
  qui := coalesce((select m.prenom from pilotage.membres m where m.user_id = new.par), 'Pilotage (automatique)');
  insert into pilotage.impayes_notes (impaye_id, auteur, auteur_id, contenu)
  values (v_dossier, qui, new.par, lib || E' :\n' || left(texte, 1500));
  return new;
end $$;

-- 2. Relance notée à la main (hors pilotage)
create or replace function public.pilotage_relance_noter(p_dossier bigint, p_quoi text, p_moyen text, p_note text)
returns void language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_bail text; v_cycle bigint; lib text;
begin
  if not pilotage.peut_saisir_impayes() then raise exception 'Accès refusé'; end if;
  select bail_id into v_bail from pilotage.impayes where id = p_dossier;
  if v_bail is null then raise exception 'Dossier sans bail Rivage : relance non enregistrable'; end if;
  insert into pilotage.relances_notees (bail_id, impaye_id, quoi, moyen, par, note)
  values (v_bail, p_dossier, p_quoi, p_moyen, auth.uid(), nullif(trim(coalesce(p_note, '')), ''));
  lib := case p_quoi when 'med' then 'Mise en demeure envoyée' else 'Relance faite' end || ' : '
      || case p_moyen when 'appel' then 'appel' when 'courrier' then 'courrier' when 'recommande' then 'recommandé'
                      when 'sms_portable' then 'SMS du portable' when 'mail' then 'mail hors pilotage' else 'autre moyen' end;
  insert into pilotage.impayes_notes (impaye_id, auteur, auteur_id, contenu)
  values (p_dossier, coalesce(pilotage.prenom_membre(auth.uid()), 'Pilotage'), auth.uid(), lib || coalesce(E'\n' || nullif(trim(coalesce(p_note, '')), ''), ''));
  if p_quoi = 'med' then
    select id into v_cycle from pilotage.relances_impayes where bail_id = v_bail and clos_le is null order by id desc limit 1;
    if v_cycle is not null then
      insert into pilotage.suivis_etapes (cle, etape, par, detail) values ('ri:' || v_cycle, 'med', auth.uid(), lib)
      on conflict (cle, etape) do nothing;
    end if;
  end if;
end $$;
revoke all on function public.pilotage_relance_noter(bigint, text, text, text) from public, anon;
grant execute on function public.pilotage_relance_noter(bigint, text, text, text) to authenticated;

-- 3. Historique : relances notées en plus
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
    union all  -- 167 : relances faites hors pilotage
    select jsonb_build_object('le', n.cree_le, 'source', 'pilotage', 'canal', 'note', 'manuel', true, 'etape', case when n.quoi = 'med' then 'med' else 'relance' end,
             'moyen', n.moyen, 'destinataire', null, 'statut', 'transmis', 'erreur', null, 'texte', n.note,
             'par', (select m.prenom from pilotage.membres m where m.user_id = n.par))
      from pilotage.relances_notees n where n.bail_id = p_bail and (p_depuis is null or n.cree_le >= p_depuis)
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

-- 4. Résumé pour la frise : relances et mises en demeure faites (pilotage, notées) depuis l'ouverture du dossier
create or replace function pilotage.relances_resume(p_bail text, p_depuis timestamptz)
returns jsonb language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object('libelle', l, 'statut', 'Fait', 'le', le) order by le), '[]'::jsonb) from (
    select case when e.etape = 'med' then 'Mise en demeure envoyée' else 'Relance envoyée' end l, (e.cree_le at time zone 'Europe/Paris')::date le
      from pilotage.sms_envois e where e.bail_id = p_bail and e.cle ~ '^rim?:' and e.statut = 'transmis' and e.cree_le >= p_depuis - interval '7 days'
    union all
    select case when e.etape = 'med' then 'Mise en demeure envoyée' else 'Relance envoyée' end, (e.cree_le at time zone 'Europe/Paris')::date
      from pilotage.mails_envois e where e.bail_id = p_bail and e.cle ~ '^rim?:' and e.statut = 'transmis' and e.cree_le >= p_depuis - interval '7 days'
    union all
    select case when n.quoi = 'med' then 'Mise en demeure envoyée' else 'Relance faite' end, n.le
      from pilotage.relances_notees n where n.bail_id = p_bail and n.cree_le >= p_depuis - interval '7 days') z
$$;

do $bloc$
declare d text; a text;
begin
  d := replace(pg_get_functiondef('public.pilotage_impayes()'::regprocedure), E'\r\n', E'\n');
  if position('relances_resume' in d) = 0 then
    a := 'from pilotage.impayes_actions a where a.impaye_id = d.id)';
    if position(a in d) = 0 then raise exception '167 : liste des actions introuvable dans pilotage_impayes, rien n''est modifié'; end if;
    d := replace(d, a, a || E',\n        ''relances'', case when d.bail_id is not null then pilotage.relances_resume(d.bail_id, d.cree_le) else ''[]''::jsonb end');
    execute d;
  end if;
end $bloc$;

-- 5. Tâche du dossier en retard : dans Ma journée de la comptable
insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire) values
('impaye_tache_echeance', 'Impayé : tâche du dossier à faire', 'impayes', 'normale', 'tache', true,
 'Tâche notée dans un dossier d''impayé, pas encore faite, dont la date « Pour le » est arrivée. Fermée quand la tâche passe à « Fait ».', '[]'::jsonb, 'compta')
on conflict (cle) do nothing;

create or replace function pilotage.impayes_taches_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select 'impaye_tache_echeance', 'ImpayeAction', a.id::text,
         'Impayé : ' || a.libelle || ' · ' || coalesce((select v.locataires from pilotage.v_baux v where v.id = d.bail_id), d.titre, d.locataire_nom, 'dossier ' || d.id),
         'Pour le ' || to_char(a.le, 'DD/MM/YYYY') || ' · ' || a.statut || '. Dossier d''impayé, « Tâches du dossier ».',
         case when d.bail_id is not null then 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || d.bail_id end
    from pilotage.impayes_actions a join pilotage.impayes d on d.id = a.impaye_id
   where a.statut <> 'Fait' and a.le is not null and a.le <= (now() at time zone 'Europe/Paris')::date and d.groupe <> 'Clôturé'
$$;

do $bloc$
declare d text; a text;
begin
  d := replace(pg_get_functiondef('pilotage.suivi_detections_impayes()'::regprocedure), E'\r\n', E'\n');
  if position('impayes_taches_detections' in d) = 0 then
    a := 'select x.regle, x.objet_type, x.objet_id, x.titre, x.detail, x.lien from pilotage.relances_impayes_detections() x';
    if position(a in d) = 0 then raise exception '167 : détections des relances introuvables, rien n''est modifié'; end if;
    d := replace(d, a, a || E'\n  union all  -- 167\n  select t.regle, t.objet_type, t.objet_id, t.titre, t.detail, t.lien from pilotage.impayes_taches_detections() t');
    execute d;
  end if;
end $bloc$;

-- 6. Nettoyage : les lignes d'envoi écrites par le 166 sortent des actions (elles sont dans « Relances » et le fil)
delete from pilotage.impayes_actions
 where statut = 'Fait' and (libelle like 'Relance SMS envoyée à la main (%' or libelle like 'Relance mail envoyée à la main (%'
        or libelle like 'Relance automatique : %' or libelle like 'Mise en demeure envoyée par mail (%');

commit;
