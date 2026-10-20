-- 064 : mails assurance, entretien et compteurs remis en conformité avec la loi du 6 juillet 1989 (revue du bail type, 20/10/2026).
-- À exécuter après 063, à la main.
--
-- Assurance (art. 7 g) : la mise en demeure doit annoncer la volonté du bailleur de souscrire pour le compte du locataire,
-- et elle vaut alors renonciation à la clause résolutoire. Le choix du bailleur est donc demandé AVANT, à J-15
-- (nouvelle étape 8), et la mise en demeure de J+1 est rédigée selon ce choix. Sans réponse : souscription pour compte.
-- L'ancienne demande d'accord à J+10 (étape 7) devient, à J+32, le point au bailleur sur la suite.
--
-- Entretien (art. 4 g) : en habitation, la clause résolutoire ne peut pas viser l'entretien. L'étape 6 propose désormais
-- de faire réaliser l'entretien à la place du locataire, coût refacturé (décret 87-713, art. 3 ; C. civ. art. 1222).
-- La mise en demeure laisse un mois au lieu de 15 jours en habitation, comme la clause du bail type corrigé (texte dans mails.js).

-- 1. Calendrier assurance
insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele) values
  ('assurance', 8, -15, 'Demander au bailleur son choix si l''attestation ne vient pas : souscription pour compte du locataire (par défaut) ou commandement', 'mail_bailleur', 'assurance_choix')
on conflict (nature, ordre) do update set jours = excluded.jours, libelle = excluded.libelle, canal = excluded.canal, modele = excluded.modele;

update pilotage.calendriers set libelle = 'Mise en demeure en recommandé, rédigée selon le choix du bailleur (délai d''un mois)'
where nature = 'assurance' and ordre = 4;

update pilotage.calendriers set jours = 32, modele = 'assurance_suite',
  libelle = 'Point au bailleur : assurance souscrite pour compte du locataire, ou commandement à faire délivrer'
where nature = 'assurance' and ordre = 7;

update pilotage.calendriers set libelle = 'Souscrire l''assurance pour compte (copie du contrat au locataire, prime par douzième sur l''avis d''échéance dans Rivage) ou missionner le commissaire de justice'
where nature = 'assurance' and ordre = 6;

-- 2. Calendrier entretien
-- La mise en demeure part toujours à J-15 ; son délai d'un mois expire vers J+15, avant la proposition au bailleur à J+21.
update pilotage.calendriers set libelle = 'Mise en demeure en recommandé (un mois)'
where nature = 'entretien' and ordre = 3;
update pilotage.calendriers set modele = 'entretien_suite',
  libelle = 'Proposer au bailleur de faire réaliser l''entretien à la place du locataire, coût refacturé (bail commercial : clause résolutoire si elle vise ce manquement)'
where nature = 'entretien' and ordre = 6;

-- 3. Choix du bailleur pour l'assurance : rangé comme une étape « choix » du suivi (détail = compte ou commandement)
create or replace function public.pilotage_assurance_choix(p_cle text, p_choix text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_cle !~ '^o:' then raise exception 'Clé de suivi invalide'; end if;
  if p_choix not in ('compte', 'commandement') then raise exception 'Choix invalide'; end if;
  insert into pilotage.suivis_etapes (cle, etape, par, detail) values (p_cle, 'choix', auth.uid(), p_choix)
  on conflict (cle, etape) do update set fait_le = now(), par = auth.uid(), detail = excluded.detail;
  -- l'étape 8 (demande du choix) est réputée faite
  insert into pilotage.suivis_etapes (cle, etape, par, detail) values (p_cle, '8', auth.uid(), 'Choix du bailleur : ' || p_choix)
  on conflict (cle, etape) do nothing;
end $$;
revoke all on function public.pilotage_assurance_choix(text, text) from public, anon;
grant execute on function public.pilotage_assurance_choix(text, text) to authenticated;

-- 4. État d'un suivi de bail : ajoute le choix du bailleur (définition en base reprise telle quelle, plus 'choix')
create or replace function pilotage.obligation_etat(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $function$
declare ob pilotage.baux_obligations; v_cle text; etapes jsonb; afaire jsonb; suivante jsonb; j date := current_date;
begin
  select * into ob from pilotage.baux_obligations where id = p_id;
  if not found then return null; end if;
  v_cle := 'o:' || ob.id || ':' || ob.prochaine;
  select coalesce(jsonb_agg(jsonb_build_object('ordre', c.ordre, 'date', ob.prochaine + c.jours, 'libelle', c.libelle, 'canal', c.canal, 'modele', c.modele,
           'fait_le', se.fait_le, 'du', (ob.prochaine + c.jours) <= j) order by c.jours, c.ordre), '[]'::jsonb)
    into etapes
  from pilotage.calendriers c left join lateral (
      select coalesce(se.fait_le, (select min(bl.maj_le) from pilotage.objets bl
                where c.canal = 'tache' and (c.libelle ilike 'appeler%' or c.libelle ilike '%refacturer%')
                  and bl.type = 'BillingLine' and bl.supprime_le is null and bl.data->>'leasing_contract_id' = ob.bail_id
                  and (bl.data->>'name') ilike any (case ob.nature when 'tsb' then array['%bureau%','%TSB%'] when 'surprime' then array['%surprime%'] else array['§'] end)
                  and coalesce((bl.data->>'start_date')::date, bl.maj_le::date) >= ob.prochaine - 120)) fait_le
      from (select 1) z left join pilotage.suivis_etapes se on se.cle = v_cle and se.etape = c.ordre::text) se on true
  where c.nature = ob.nature;
  select x into afaire from jsonb_array_elements(etapes) x where (x->>'du')::boolean and x->>'fait_le' is null order by (x->>'date')::date limit 1;
  select x into suivante from jsonb_array_elements(etapes) x where not (x->>'du')::boolean order by (x->>'date')::date limit 1;
  return jsonb_build_object('id', ob.id, 'nature', ob.nature, 'libelle', ob.libelle, 'periodicite_mois', ob.periodicite_mois,
    'prochaine', ob.prochaine, 'derniere_le', ob.derniere_le, 'actif', ob.actif, 'cle', v_cle,
    'etapes', etapes, 'a_faire', afaire, 'suivante', suivante,
    'choix', (select se.detail from pilotage.suivis_etapes se where se.cle = v_cle and se.etape = 'choix'),
    'en_retard', ob.actif and j > ob.prochaine + pilotage.param('bail_suivi_retard','jours_retard',30)::int,
    'gravite', case when not ob.actif then 'normale' when j > ob.prochaine + pilotage.param('bail_suivi_retard','jours_retard',30)::int then 'critique' when afaire is not null and (afaire->>'canal') = 'lrar' then 'haute'
                    when afaire is not null then 'normale' else 'normale' end);
end $function$;

-- Contrôle
select nature, ordre, jours, canal, modele, libelle from pilotage.calendriers where nature in ('assurance', 'entretien') order by nature, jours, ordre;
