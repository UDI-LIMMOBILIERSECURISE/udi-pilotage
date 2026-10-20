-- 063 : demande des pièces manquantes du mandat au bailleur, avec relances programmées (Nicolas, 20/10/2026)
--   Contrôle d'entrée du mandat, bloc « Pièces du dossier » : bouton « Demander les pièces au bailleur » qui prépare le mail
--   « Bienvenue et demande de pièces » (document « Tous les mails et SMS ») avec la liste des pièces encore manquantes.
--   Le mail envoyé ouvre un suivi « Pièces du dossier à obtenir » sur le mandat : relances par mail à J+7 et J+14,
--   appel du bailleur à J+21 (calendrier modifiable dans Règles de relance). Les relances arrivent dans Ma journée
--   (alerte « Suivi du mandat », catégorie Courrier, chez la gestion) et reprennent la liste à jour des pièces manquantes.
--   Mandat validé par la gestion (forcé ou non) avec des pièces manquantes : le suivi s'ouvre tout seul, même sans clic.
--   Le suivi se ferme tout seul quand toutes les pièces sont dans Rivage (ou déclarées sans objet).

-- Calendrier des relances (modifiable ensuite dans Règles de relance)
delete from pilotage.calendriers where nature = 'mandat_pieces';
insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele) values
  ('mandat_pieces', 1, 0, 'Demander au bailleur les pièces manquantes (mail de bienvenue)', 'mail_bailleur', 'mandat_pieces'),
  ('mandat_pieces', 2, 7, 'Relancer le bailleur sur les pièces encore manquantes', 'mail_bailleur', 'mandat_pieces_relance'),
  ('mandat_pieces', 3, 14, 'Deuxième relance du bailleur', 'mail_bailleur', 'mandat_pieces_relance'),
  ('mandat_pieces', 4, 21, 'Sans réponse : appeler le bailleur et noter sa réponse dans le fil du dossier', 'tache', null);

-- Pièces encore manquantes d'un mandat (ni reçues ni sans objet)
create or replace function pilotage.mandat_pieces_manquantes(p_mandat text) returns integer
language sql stable security definer set search_path = pilotage, public as $$
  select count(*)::int from jsonb_array_elements(coalesce(pilotage.controle_mandat(p_mandat)->'items', '[]'::jsonb)) i
  where i->>'bloc' = 'pieces' and coalesce(i->>'statut', '') not in ('ok', 'sans_objet')
$$;

-- Ouvrir le suivi (bouton de la fiche) : renvoie le suivi ouvert, existant ou créé
create or replace function public.pilotage_mandat_pieces_demander(p_mandat text) returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
declare v_id bigint;
begin
  if not pilotage.peut_traiter_dossier('mandat', p_mandat) then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.objets where type = 'ManagementContract' and id = p_mandat and supprime_le is null) then raise exception 'Mandat inconnu'; end if;
  select id into v_id from pilotage.mandats_obligations where mandat_id = p_mandat and nature = 'mandat_pieces' and actif order by id desc limit 1;
  if v_id is null then
    insert into pilotage.mandats_obligations (mandat_id, nature, libelle, prochaine, auto, par)
    values (p_mandat, 'mandat_pieces', 'Pièces du dossier à obtenir du bailleur', current_date, false, auth.uid())
    returning id into v_id;
  end if;
  return pilotage.obligation_mandat_etat(v_id);
end $$;
-- Mail envoyé (demande ou relance) : étape cochée. Ouvert au commercial du dossier, qui n'a pas accès aux autres suivis.
create or replace function public.pilotage_mandat_pieces_envoye(p_mandat text, p_etape text, p_detail text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare ob pilotage.mandats_obligations;
begin
  if not pilotage.peut_traiter_dossier('mandat', p_mandat) then raise exception 'Accès refusé'; end if;
  select * into ob from pilotage.mandats_obligations where mandat_id = p_mandat and nature = 'mandat_pieces' and actif order by id desc limit 1;
  if ob.id is null then raise exception 'Aucune demande de pièces en cours sur ce mandat'; end if;
  insert into pilotage.suivis_etapes (cle, etape, par, detail) values ('m:' || ob.id || ':' || ob.prochaine, p_etape, auth.uid(), p_detail)
  on conflict (cle, etape) do update set fait_le = now(), par = auth.uid(), detail = excluded.detail;
end $$;

revoke all on function public.pilotage_mandat_pieces_demander(text), public.pilotage_mandat_pieces_envoye(text, text, text) from public, anon;
grant execute on function public.pilotage_mandat_pieces_demander(text), public.pilotage_mandat_pieces_envoye(text, text, text) to authenticated;

-- Automatique (toutes les 30 minutes) :
--   - mandat validé par la gestion depuis moins de 60 jours, forcé ou non, avec des pièces manquantes et jamais demandées : suivi ouvert ;
--   - suivi ouvert dont toutes les pièces sont arrivées : suivi fermé.
create or replace function pilotage.mandats_pieces_auto() returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare r record;
begin
  for r in select s.mandat_id from pilotage.mandats_suivi s
           join pilotage.objets m on m.type = 'ManagementContract' and m.id = s.mandat_id and m.supprime_le is null
           where coalesce(s.valide_le, s.go_le) >= now() - interval '60 days' and s.retire_le is null
             and not exists (select 1 from pilotage.mandats_obligations o where o.mandat_id = s.mandat_id and o.nature = 'mandat_pieces')
  loop
    if pilotage.mandat_pieces_manquantes(r.mandat_id) > 0 then
      insert into pilotage.mandats_obligations (mandat_id, nature, libelle, prochaine, auto)
      values (r.mandat_id, 'mandat_pieces', 'Pièces du dossier à obtenir du bailleur', current_date, false);
    end if;
  end loop;
  update pilotage.mandats_obligations o set actif = false, derniere_le = current_date
   where o.nature = 'mandat_pieces' and o.actif and pilotage.mandat_pieces_manquantes(o.mandat_id) = 0;
end $$;

select cron.unschedule(jobid) from cron.job where jobname = 'pilotage-pieces-mandats';
select cron.schedule('pilotage-pieces-mandats', '22,52 * * * *', $$ select pilotage.mandats_pieces_auto() $$);

-- Premier passage et contrôle
select pilotage.mandats_pieces_auto();
select o.mandat_id, o.prochaine, o.actif, pilotage.mandat_pieces_manquantes(o.mandat_id) pieces_manquantes
from pilotage.mandats_obligations o where o.nature = 'mandat_pieces' order by o.id;
