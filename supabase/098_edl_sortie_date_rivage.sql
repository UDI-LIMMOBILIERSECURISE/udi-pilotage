-- 098 — Fiche du congé simplifiée : la date de l'EDL de sortie vient de Rivage, seule l'heure est à saisir (Nicolas, 29/10/2026).
-- Décision de Nicolas : ce que Rivage donne ne se ressaisit pas. Date du congé (préavis) et date de l'EDL de sortie
-- (situation du bail, move_out_inventory_date) sont lues dans Rivage ; les champs de la fiche ne servent que si Rivage n'a rien.
-- Date d'EDL retenue partout (messages, alertes) : celle de Rivage, sinon celle de la fiche.
-- Les messages de confirmation et de rappel attendent la date ET l'heure. L'alerte « EDL à commander » se ferme quand l'EDL est
-- commandé ou quand le rendez-vous (date et heure) est connu ; « Rendez-vous à confirmer » s'ouvre dès que l'heure est saisie.
-- Fonctions modifiées : edl_sortie_le (nouvelle), messages_contexte, pilotage_messages_dossier, pilotage_fiche_conge_maj
-- (remplacements ciblés, contrôlés), etapes_detections (remplacée). Aucune donnée modifiée.
-- Un seul bloc.

begin;

create or replace function pilotage.edl_sortie_le(p_bail text) returns date
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce((select nullif(s.data->'move_out'->>'move_out_inventory_date', '')::date from pilotage.baux_situation s where s.bail_id = p_bail),
                  (select f.edl_le from pilotage.fiches_conge f where f.bail_id = p_bail))
$$;
revoke all on function pilotage.edl_sortie_le(text) from public, anon, authenticated;

do $do$
declare d text;
begin
  -- 1. Contexte des messages : date de l'EDL de Rivage, sinon de la fiche
  d := pg_get_functiondef('pilotage.messages_contexte(text,text)'::regprocedure);
  if position('edl_sortie_le' in d) = 0 then
    if position($r$'date_edl', to_char(f.edl_le, dfr)$r$ in d) = 0 then raise exception 'messages_contexte : date_edl introuvable'; end if;
    d := replace(d, $r$'date_edl', to_char(f.edl_le, dfr)$r$, $r$'date_edl', to_char(pilotage.edl_sortie_le(p_id), dfr)$r$);
    execute d;
  end if;
  -- 2. Messages d'un dossier : en attente tant que la date ou l'heure manque
  d := pg_get_functiondef('public.pilotage_messages_dossier(text,text)'::regprocedure);
  if position($r$c->>'heure_edl' is null$r$ in d) = 0 then
    if position($r$and c->>'date_edl' is null$r$ in d) = 0 then raise exception 'pilotage_messages_dossier : condition d''attente introuvable'; end if;
    d := replace(d, $r$and c->>'date_edl' is null$r$, $r$and (c->>'date_edl' is null or c->>'heure_edl' is null)$r$);
    d := replace(d, $r$À préparer quand la date de l''état des lieux sera saisie dans la fiche du congé.$r$,
                    $r$À préparer quand la date (Rivage) et l''heure de l''état des lieux seront connues : heure à saisir dans la fiche du congé.$r$);
    execute d;
  end if;
  -- 3. Fiche : la saisie de l'heure seule (date venant de Rivage) compte comme une modification du rendez-vous
  d := pg_get_functiondef('public.pilotage_fiche_conge_maj(text,jsonb)'::regprocedure);
  if position($r$f.edl_le is null and f.edl_heure is null$r$ in d) = 0 then
    if position($r$f.edl_maj_le := case when f.edl_le is null then null else now() end;$r$ in d) = 0 then raise exception 'pilotage_fiche_conge_maj : edl_maj_le introuvable'; end if;
    d := replace(d, $r$f.edl_maj_le := case when f.edl_le is null then null else now() end;$r$,
                    $r$f.edl_maj_le := case when f.edl_le is null and f.edl_heure is null then null else now() end;$r$);
    execute d;
  end if;
end $do$;

-- Détections des étapes : nouveau bail à signer (094), congé reçu, EDL de sortie à commander, rendez-vous d'EDL à confirmer (096, 098)
create or replace function pilotage.etapes_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  with s as (
    select b.id, b.reference, b.locataires, pilotage.sortie_prevue(b.id) sortie, f.edl_par, f.edl_commande_le,
           pilotage.edl_sortie_le(b.id) edl_le, f.edl_heure, f.edl_maj_le,
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
           || '(logement vide, propre, électricité active), puis saisir l''heure du rendez-vous dans la fiche du congé', s.lien
    from s
   where s.sortie >= current_date and s.edl_commande_le is null and not (s.edl_le is not null and s.edl_heure is not null)
  union all
  select 'edl_sortie_a_confirmer', 'LeasingContract', s.id,
         'État des lieux de sortie le ' || to_char(s.edl_le, 'DD/MM/YYYY') || ' à ' || s.edl_heure || ' : rendez-vous à confirmer au locataire (bail ' || coalesce(s.reference, '') || ')',
         'Locataires : ' || coalesce(s.locataires, '?') || ' — envoyer la confirmation (mail) et le rappel (SMS)', s.lien
    from s
   where s.edl_le >= current_date and s.edl_heure is not null
     and not exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = s.id and j.code = 'es_locataire_email'
                       and j.le >= coalesce(s.edl_maj_le, '-infinity'::timestamptz))
$$;
revoke all on function pilotage.etapes_detections() from public, anon, authenticated;

select pilotage.executer_controles();

commit;

-- Vérification : date d'EDL retenue pour les congés en cours (bail 86 : 28/11/2026, de Rivage)
-- select v.reference, pilotage.edl_sortie_le(v.id) from pilotage.v_baux v where v.statut = 'move_out' and pilotage.sortie_prevue(v.id) >= current_date;
