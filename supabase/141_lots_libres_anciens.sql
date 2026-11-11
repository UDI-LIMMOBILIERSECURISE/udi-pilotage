-- 141 : lot libre depuis plus de 90 jours = donnée à vérifier par la direction, plus une action « à louer » de la gestion (bloc unique)
--  Décision de Nicolas du 11/11/2026 : une quarantaine de lots sans bail et hors liste « À louer » s'affichaient en retard chez Marion
--  (« Mettre le lot dans la liste À louer »), certains libres depuis 2024 (27 appartements, 6 locaux, 4 parkings, 3 maisons). Libre
--  depuis si longtemps, c'est le plus souvent Rivage qui est faux (bail sur un autre lot, bail non saisi, lot à sortir du mandat).
--  Désormais, un lot libre depuis plus de 90 jours (paramètre « jours_libre » de la règle, modifiable sans code), qui n'est ni « À louer »
--  ni en résiliation, part en « Données à corriger » chez la direction ; sa frise n'attend plus la gestion. Mesure du 11/11 : 34 lots.
--  Moins de 90 jours : inchangé, « Mettre le lot dans la liste À louer » pour la gestion.

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, destinataire, explication, parametres) values
 ('lot_libre_ancien', 'Lot libre depuis longtemps : vérifier Rivage', 'Mandat, compta, agence', 'normale', 'controle', true, 'direction',
  'Lot sans bail depuis plus de 90 jours et absent de la liste « À louer » : le plus souvent une erreur de Rivage (bail saisi sur un autre lot, bail manquant, lot à retirer du mandat). Vérifier et faire corriger, ou mettre le lot « À louer ».',
  '[{"nom": "jours_libre", "unite": "jours", "valeur": 90, "libelle": "Lot libre depuis plus de"}]'::jsonb)
on conflict (cle) do nothing;

create or replace function pilotage.lots_libres_detections()
returns table(regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select 'lot_libre_ancien', 'Asset', z.id,
    'Lot ' || coalesce(z.reference, '?') || ' : libre depuis le ' || to_char(z.libre, 'DD/MM/YYYY') || ', ni bail ni « À louer »',
    concat_ws(' · ', z.adresse, 'mandat n°' || z.mref, 'vérifier dans Rivage (bail sur un autre lot ? bail manquant ? lot à retirer du mandat ?) ou mettre le lot « À louer »'),
    'https://rivage.immo/asset_list'
  from (
    select l.id, l.reference, l.adresse, m.data->>'reference' mref,
           coalesce((select max(x.fin) from pilotage.v_baux x where x.lot_id = l.id and x.fin <= current_date), (m.data->>'start_date')::date) libre
      from pilotage.v_lots l
      join pilotage.objets m on m.type = 'ManagementContract' and m.id = l.mandat_id and m.supprime_le is null and m.data->>'status' in ('created', 'active')
     where not exists (select 1 from pilotage.v_baux x where x.lot_id = l.id
                         and ((x.statut in ('created', 'move_in', 'in_progress') and (x.fin is null or x.fin > current_date))
                              or (x.statut = 'move_out' and (x.fin is null or x.fin >= current_date - 60))))
       and not exists (select 1 from pilotage.lots_a_louer al where al.asset_id = l.id and al.sorti_le is null)
       and not exists (select 1 from pilotage.objets t where t.type = 'ManagementTermination' and t.supprime_le is null and t.data->>'status' in ('scheduled', 'effective')
                         and (coalesce(t.data->'asset_ids', '[]'::jsonb) ? l.id or coalesce(t.data->'management_contract_ids', '[]'::jsonb) ? l.mandat_id))
       and not (pilotage.dossier_nouveau('ManagementContract', l.mandat_id)
                and exists (select 1 from pilotage.mandats_suivi s where s.mandat_id = l.mandat_id and s.valide_le is null and s.retire_le is null))
  ) z
  where z.libre < current_date - pilotage.param('lot_libre_ancien', 'jours_libre', 90)::int
$$;
revoke all on function pilotage.lots_libres_detections() from public, anon, authenticated;

-- Moteur des contrôles : nouvelle source ajoutée après celles du 139 (le reste inchangé)
do $do$
declare def text; ancre text := 'select g.regle, g.objet_type, g.objet_id, g.titre, g.detail, g.lien from pilotage.donnees_detections() g';
begin
  def := pg_get_functiondef('pilotage.executer_controles()'::regprocedure);
  if position('lots_libres_detections' in def) > 0 then return; end if;
  if position(ancre in def) = 0 then raise exception 'executer_controles : point d''insertion introuvable (passer le 139 d''abord)'; end if;
  execute replace(def, ancre, ancre || E'\n  union all  -- 141\n  select y.regle, y.objet_type, y.objet_id, y.titre, y.detail, y.lien from pilotage.lots_libres_detections() y');
end $do$;

-- Famille « Données à corriger » dans Ma journée
do $do$
declare def text;
begin
  def := pg_get_functiondef('pilotage.famille_alerte(text,text,text,text)'::regprocedure);
  if position('lot_libre_ancien' in def) > 0 then return; end if;
  execute replace(def, $x$when p_regle = 'donnee_a_corriger' then 'donnees'$x$, $x$when p_regle in ('donnee_a_corriger', 'lot_libre_ancien') then 'donnees'$x$);
end $do$;

-- Frise : au-delà du délai, l'étape « Mis en location » n'attend plus la gestion (vérification par la direction)
do $do$
declare def text; avant text := $x$jsonb_build_object('libelle', 'Mis en location', 'qui', 'gestion',$x$;
begin
  def := pg_get_functiondef('pilotage.biens(uuid)'::regprocedure);
  if position('lot_libre_ancien' in def) > 0 then return; end if;
  if position(avant in def) = 0 then raise exception 'biens : étape « Mis en location » introuvable (passer le 140 d''abord)'; end if;
  def := replace(def, avant, $x$jsonb_build_object('libelle', 'Mis en location',
            'qui', case when r2.en_location is null and coalesce(r2.libre_depuis, r2.mdebut) < j - pilotage.param('lot_libre_ancien', 'jours_libre', 90)::int then null else 'gestion' end,
            'info_direction', case when r2.en_location is null and coalesce(r2.libre_depuis, r2.mdebut) < j - pilotage.param('lot_libre_ancien', 'jours_libre', 90)::int
                                   then 'Libre depuis plus de ' || pilotage.param('lot_libre_ancien', 'jours_libre', 90)::int || ' jours : vérification par la direction (Données à corriger)' end,$x$);
  execute def;
end $do$;

select pilotage.executer_controles() as alertes_ouvertes;
select pilotage.rattacher_alertes();
select count(*) as lots_libres_anciens from pilotage.alertes where statut = 'ouverte' and regle = 'lot_libre_ancien';
select count(*) as mise_en_location_pour_la_gestion from jsonb_array_elements(pilotage.biens(null)) x
 where x->>'phase' = 'location' and x->'a_faire'->>'qui' = 'gestion';
