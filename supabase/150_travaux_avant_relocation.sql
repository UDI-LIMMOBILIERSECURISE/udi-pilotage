-- 150 : « Travaux avant relocation » comme suite voulue par le bailleur dans la fiche du congé (décision de Nicolas du 12/11/2026)
--  - nouveau choix dans la fiche du congé, à côté de relouer, reprendre, vendre ;
--  - la frise du bien affiche la suite prévue « Travaux avant relocation » pendant la sortie ;
--  - alerte à la gestion « Travaux avant relocation : ticket Travaux à créer dans Rivage » tant qu'aucun ticket ouvert du lot n'a le tag
--    Travaux (Rivage ne permet pas de créer un ticket par l'API : création à la main dans Rivage). L'alerte s'arrête dès que le ticket
--    existe, quand le lot est mis « À louer », quand un nouveau bail commence, ou 6 mois après le départ.
--  Le suivi du chantier reste celui du 140 (phase « Travaux avant relocation » lue sur le ticket Rivage).
--  Les fonctions pilotage.etapes_detections et pilotage.biens sont complétées sur place (texte en ligne, fins de ligne normalisées) :
--  le bloc s'arrête avec une erreur si le texte attendu n'est pas trouvé, sans rien modifier.
-- Retour arrière : update pilotage.regles set actif = false where cle = 'travaux_relocation_sans_ticket';

begin;

alter table pilotage.fiches_conge drop constraint if exists fiches_conge_suite_check;
alter table pilotage.fiches_conge add constraint fiches_conge_suite_check check (suite in ('relouer', 'travaux', 'reprise', 'vente'));

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres, destinataire) values
 ('travaux_relocation_sans_ticket', 'Travaux avant relocation : ticket Travaux à créer dans Rivage', 'Baux habitation', 'haute', 'tache', true,
  'La fiche du congé prévoit des travaux avant de relouer, et aucun ticket ouvert du lot n''a le tag « Travaux » dans Rivage : créer le ticket dans Rivage (tag Travaux) pour suivre le chantier sur la frise du bien. L''alerte disparaît dès que le ticket existe, quand le lot est mis « À louer » ou quand un nouveau bail commence.',
  '[]'::jsonb, 'gestion')
on conflict (cle) do nothing;

do $bloc$
declare d text; ajout text;
begin
  -- 1. Détection de l'alerte
  d := replace(pg_get_functiondef('pilotage.etapes_detections()'::regprocedure), E'\r\n', E'\n');
  if position('travaux_relocation_sans_ticket' in d) = 0 then
    ajout := $a$
  union all
  -- 150 : travaux avant relocation prévus dans la fiche du congé, aucun ticket Travaux ouvert sur le lot dans Rivage
  select 'travaux_relocation_sans_ticket', 'LeasingContract', b.id,
         'Travaux avant relocation : ticket Travaux à créer dans Rivage (bail ' || coalesce(b.reference, '') || ')',
         'Lot ' || coalesce(l.reference, '?') || ' · ' || coalesce(l.adresse, '?') || ' · ' || coalesce(b.locataires, '?')
           || ' — la fiche du congé prévoit des travaux avant de relouer : créer le ticket dans Rivage avec le tag « Travaux »',
         'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id
    from pilotage.fiches_conge f
    join pilotage.v_baux b on b.id = f.bail_id
    join pilotage.v_lots l on l.id = b.lot_id
   where f.suite = 'travaux' and b.statut in ('move_out', 'closed')
     and coalesce(pilotage.sortie_prevue(b.id), b.fin, current_date) >= current_date - 180
     and not exists (select 1 from pilotage.ticket_suivi() t where t.travaux and t.asset_id = l.id)
     and not exists (select 1 from pilotage.lots_a_louer a where a.asset_id = l.id and a.sorti_le is null)
     and not exists (select 1 from pilotage.v_baux x where x.lot_id = l.id and x.id <> b.id
                       and x.statut in ('created', 'move_in', 'in_progress') and coalesce(x.debut, current_date) >= coalesce(b.fin, current_date))
$function$$a$;
    if d !~ '\$function\$\s*$' then raise exception '150 : fin de pilotage.etapes_detections introuvable, rien n''est modifié'; end if;
    d := regexp_replace(d, '\n?\$function\$\s*$', ajout);
    execute d;
  end if;

  -- 2. Suite prévue affichée sur la frise pendant la sortie
  d := replace(pg_get_functiondef('pilotage.biens(uuid)'::regprocedure), E'\r\n', E'\n');
  if position('conge_suite = ''travaux''' in d) = 0 then
    if position('when e.conge_suite = ''relouer'' then ''À relouer''' in d) = 0 then
      raise exception '150 : texte « À relouer » introuvable dans pilotage.biens, rien n''est modifié';
    end if;
    d := replace(d, 'when e.conge_suite = ''relouer'' then ''À relouer''',
                    'when e.conge_suite = ''travaux'' then ''Travaux avant relocation (ticket Travaux à créer dans Rivage)''
               when e.conge_suite = ''relouer'' then ''À relouer''');
    execute d;
  end if;
end $bloc$;

select pilotage.executer_controles();

commit;

-- Vérification après passage :
-- select pg_get_constraintdef(oid) from pg_constraint where conname = 'fiches_conge_suite_check';
-- select regle, titre, statut from pilotage.alertes where regle = 'travaux_relocation_sans_ticket';
