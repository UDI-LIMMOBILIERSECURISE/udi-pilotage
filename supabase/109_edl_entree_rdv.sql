-- 109 — État des lieux d'entrée : date = date d'entrée du bail, heure à fixer, alerte « EDL d'entrée à organiser » (Nicolas, 31/10/2026).
-- Constat sur le bail 530 (entrée le 03/11/2026) : le mail « Nouveau bail à signer » au locataire reprenait {date_edl} depuis la date
-- de l'EDL de SORTIE (fiche du congé), vide pour un bail qui commence : le champ restait à saisir à la main et le message était
-- marqué « en attente ». Aucune alerte ne demandait d'organiser l'EDL d'entrée. Rivage ne donne pas de date d'EDL d'entrée
-- (vérifié sur le bail 530 : rien dans le bail ni dans sa situation).
-- Règle de Nicolas : l'EDL d'entrée a lieu le jour de l'entrée ; seule l'heure est à confirmer.
-- 1. Table edl_entree : heure du rendez-vous, et date seulement si elle diffère de la date d'entrée (sinon elle suit Rivage).
-- 2. {date_edl} et {heure_edl} : EDL d'entrée pour un bail qui n'est pas en sortie, EDL de sortie sinon (inchangé).
-- 3. Un message n'attend que le champ qu'il contient vraiment : le mail « Nouveau bail » (date seule) n'attend plus l'heure.
-- 4. Alerte edl_entree_a_organiser au commercial du bail : « à organiser, heure à fixer », puis « rendez-vous à confirmer au
--    locataire » ; fermée quand la confirmation (mail) est notée après la dernière modification du rendez-vous, ou le jour passé.
-- Fonctions modifiées : messages_contexte, pilotage_messages_dossier, etapes_detections (remplacements ciblés, contrôlés).
-- Nouvelles : edl_entree_le, pilotage_edl_entree_maj. Aucune donnée existante modifiée.
-- Retour arrière de l'alerte : update pilotage.regles set actif = false where cle = 'edl_entree_a_organiser'.
-- Un seul bloc.

begin;

create table if not exists pilotage.edl_entree (
  bail_id text primary key,
  edl_le date,          -- null : le jour de l'entrée (date de début du bail dans Rivage)
  edl_heure text,
  maj_par uuid,
  maj_le timestamptz
);
alter table pilotage.edl_entree enable row level security;
revoke all on pilotage.edl_entree from public, anon, authenticated;

create or replace function pilotage.edl_entree_le(p_bail text) returns date
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce((select e.edl_le from pilotage.edl_entree e where e.bail_id = p_bail),
                  (select b.debut from pilotage.v_baux b where b.id = p_bail))
$$;
revoke all on function pilotage.edl_entree_le(text) from public, anon, authenticated;

-- Saisie du rendez-vous depuis les messages du bail (commercial du dossier, gestion, direction)
create or replace function public.pilotage_edl_entree_maj(p_bail text, p_date date, p_heure text) returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
declare r text := pilotage.mon_role(); deb date; h text := nullif(trim(coalesce(p_heure, '')), ''); avant pilotage.edl_entree; d date;
begin
  if r is null then raise exception 'Accès refusé'; end if;
  if r = 'negociateur' and coalesce(pilotage.commercial_dossier('bail', p_bail), auth.uid()) <> auth.uid() then raise exception 'Accès refusé'; end if;
  select b.debut into deb from pilotage.v_baux b where b.id = p_bail;
  if not found then raise exception 'Bail inconnu'; end if;
  if h is not null then
    if h !~ '^\s*([01]?\d|2[0-3])\s*[:hH]\s*([0-5]\d)?\s*$' then raise exception 'Heure de l''état des lieux : format 14:30 ou 14h30'; end if;
    h := lpad(substring(h from '^\s*(\d{1,2})'), 2, '0') || 'h' || coalesce(substring(h from '[:hH]\s*([0-5]\d)'), '00');
  end if;
  d := case when p_date is null or p_date = deb then null else p_date end;
  select * into avant from pilotage.edl_entree where bail_id = p_bail;
  insert into pilotage.edl_entree (bail_id, edl_le, edl_heure, maj_par, maj_le) values (p_bail, d, h, auth.uid(), now())
  on conflict (bail_id) do update set edl_le = excluded.edl_le, edl_heure = excluded.edl_heure, maj_par = excluded.maj_par,
    maj_le = case when pilotage.edl_entree.edl_le is distinct from excluded.edl_le or pilotage.edl_entree.edl_heure is distinct from excluded.edl_heure
                  then excluded.maj_le else pilotage.edl_entree.maj_le end;
  return jsonb_build_object('date', pilotage.edl_entree_le(p_bail), 'heure', h, 'debut', deb);
end $$;
revoke all on function public.pilotage_edl_entree_maj(text, date, text) from public, anon;
grant execute on function public.pilotage_edl_entree_maj(text, date, text) to authenticated;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire)
values ('edl_entree_a_organiser', 'État des lieux d''entrée à organiser', 'Bail', 'haute', 'tache', true,
        'Nouveau bail qui commence dans les 21 jours : l''état des lieux d''entrée a lieu le jour de l''entrée (date de début du bail dans Rivage), seule l''heure est à fixer, dans les messages du bail (étape « État des lieux d''entrée »). L''alerte passe ensuite à « rendez-vous à confirmer au locataire » et se ferme quand la confirmation par mail est notée après la dernière modification du rendez-vous, ou une fois le jour passé.',
        '[]'::jsonb, 'commercial')
on conflict (cle) do nothing;

do $do$
declare d text; n int; a text; b text;
begin
  -- 1. Contexte des messages : EDL d'entrée pour un bail qui n'est pas en sortie
  d := replace(pg_get_functiondef('pilotage.messages_contexte(text,text)'::regprocedure), E'\r\n', E'\n');
  if position('edl_entree_le' in d) = 0 then
    a := $r$'date_edl', to_char(pilotage.edl_sortie_le(p_id), dfr), 'heure_edl', f.edl_heure,$r$;
    if position(a in d) = 0 then raise exception 'messages_contexte : date_edl introuvable'; end if;
    d := replace(d, a, $r$'date_edl', to_char(case when r.statut = 'move_out' then pilotage.edl_sortie_le(p_id) else pilotage.edl_entree_le(p_id) end, dfr),
      'heure_edl', case when r.statut = 'move_out' then f.edl_heure else (select e.edl_heure from pilotage.edl_entree e where e.bail_id = p_id) end,
      '_edl_entree_le', pilotage.edl_entree_le(p_id),$r$);
    a := $r$'_edl_maj_le', f.edl_maj_le,$r$;
    if position(a in d) = 0 then raise exception 'messages_contexte : _edl_maj_le introuvable'; end if;
    d := replace(d, a, $r$'_edl_maj_le', case when r.statut = 'move_out' then f.edl_maj_le else (select e.maj_le from pilotage.edl_entree e where e.bail_id = p_id) end,$r$);
    execute d;
  end if;

  -- 2. Messages d'un dossier : attente sur le champ réellement utilisé ; rendez-vous d'entrée renvoyé à l'écran
  d := replace(pg_get_functiondef('public.pilotage_messages_dossier(text,text)'::regprocedure), E'\r\n', E'\n');
  if position('edl_entree' in d) = 0 then
    a := $r$attente := case when coalesce(m.objet, '') || m.texte like '%{date_edl}%' and (c->>'date_edl' is null or c->>'heure_edl' is null)
                    then 'À préparer quand la date (Rivage) et l''heure de l''état des lieux seront connues : heure à saisir dans la fiche du congé.' end;$r$;
    if position(a in d) = 0 then raise exception 'pilotage_messages_dossier : condition d''attente introuvable'; end if;
    d := replace(d, a, $r$attente := case when (coalesce(m.objet, '') || m.texte like '%{date_edl}%' and c->>'date_edl' is null)
                         or (coalesce(m.objet, '') || m.texte like '%{heure_edl}%' and c->>'heure_edl' is null)
                    then case when c->>'_statut' = 'move_out'
                              then 'À préparer quand la date (Rivage) et l''heure de l''état des lieux de sortie seront connues : heure à saisir dans la fiche du congé.'
                              else 'À préparer quand l''heure de l''état des lieux d''entrée sera fixée : à saisir en haut de l''étape « État des lieux d''entrée ».' end end;$r$);
    -- Un message déjà fait redevient à faire si le rendez-vous change : seulement ceux qui donnent l'heure
    a := $r$(m.texte not like '%{date_edl}%' or c->>'_edl_maj_le' is null$r$;
    n := (length(d) - length(replace(d, a, ''))) / length(a);
    if n <> 2 then raise exception 'pilotage_messages_dossier : condition « fait » trouvée % fois (2 attendues)', n; end if;
    d := replace(d, a, $r$(m.texte not like '%{heure_edl}%' or c->>'_edl_maj_le' is null$r$);
    a := $r$return jsonb_build_object('actives', to_jsonb(actives),$r$;
    if position(a in d) = 0 then raise exception 'pilotage_messages_dossier : retour introuvable'; end if;
    d := replace(d, a, $r$return jsonb_build_object('actives', to_jsonb(actives),
    'edl_entree', case when p_objet = 'bail' and c->>'_statut' <> 'move_out'
                       then jsonb_build_object('date', c->>'_edl_entree_le', 'heure', c->>'heure_edl', 'debut', c->>'_debut') end,$r$);
    execute d;
  end if;

  -- 3. Détections des étapes : EDL d'entrée à organiser, puis à confirmer
  d := replace(pg_get_functiondef('pilotage.etapes_detections()'::regprocedure), E'\r\n', E'\n');
  if position('edl_entree_a_organiser' in d) = 0 then
    a := $r$    from n where n.debut <= current_date
$function$$r$;
    if position(a in d) = 0 then raise exception 'etapes_detections : fin de requête introuvable'; end if;
    b := $r$    from n where n.debut <= current_date
  union all
  -- 109 : EDL d'entrée le jour de l'entrée, heure à fixer, puis rendez-vous à confirmer au locataire
  select 'edl_entree_a_organiser', 'LeasingContract', b.id,
         case when e.edl_heure is null
              then 'État des lieux d''entrée à organiser : bail ' || coalesce(b.reference, '') || ', le ' || to_char(coalesce(e.edl_le, b.debut), 'DD/MM/YYYY') || ', heure à fixer'
              else 'État des lieux d''entrée le ' || to_char(coalesce(e.edl_le, b.debut), 'DD/MM/YYYY') || ' à ' || e.edl_heure
                   || ' : rendez-vous à confirmer au locataire (bail ' || coalesce(b.reference, '') || ')' end,
         'Locataires : ' || coalesce(b.locataires, '?')
           || case when e.edl_heure is null
                   then ' — le jour de l''entrée par défaut ; fixer l''heure dans les messages du bail (étape « État des lieux d''entrée »), puis envoyer la confirmation (mail) et le rappel (SMS)'
                   else ' — envoyer la confirmation (mail) et le rappel (SMS), étape « État des lieux d''entrée »' end,
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
    from pilotage.v_baux b left join pilotage.edl_entree e on e.bail_id = b.id
   where b.statut in ('created', 'move_in', 'in_progress') and pilotage.dossier_nouveau('LeasingContract', b.id)
     and coalesce(e.edl_le, b.debut) between current_date
         and current_date + coalesce((select k.jours_avant from pilotage.messages_categories k where k.cle = 'edl_entree'), 21)
     and not (e.edl_heure is not null
              and exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = b.id and j.code = 'ee_locataire_email'
                            and j.le >= coalesce(e.maj_le, '-infinity'::timestamptz)))
$function$$r$;
    d := replace(d, a, b);
    execute d;
  end if;
end $do$;

select pilotage.executer_controles();

commit;

-- Vérifications
-- select public.pilotage_messages_dossier('bail', 'lc_f82226a9d6021e17a736c9fa')->'edl_entree';   -- bail 530 : date 2026-11-03, heure null
-- select statut, titre, detail from pilotage.alertes where regle = 'edl_entree_a_organiser' order by premiere_detection desc;
