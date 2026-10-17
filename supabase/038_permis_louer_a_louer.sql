-- 038 : permis de louer et liste « À louer » (décisions de Nicolas, 17/10/2026). À exécuter après 037.
--
--   PERMIS DE LOUER
--   1. Table de référence des communes (régime, périmètre, adresse de dépôt), départ :
--        Corbeil-Essonnes : autorisation préalable dans le périmètre « Action cœur de ville » (liste des rues fournie par la mairie,
--          avec les numéros et la parité quand seule une partie de la voie est concernée), déclaration de mise en location ailleurs ;
--        Brétigny-sur-Orge, Mennecy, Ballancourt-sur-Essonne : autorisation préalable, commune entière (à vérifier sur les arrêtés).
--      Le régime se détermine à l'adresse du lot (voie, numéro, parité), pas seulement à la commune.
--      Seuls les logements sont concernés (appartement, chambre, maison) : un local commercial du périmètre ne l'est pas.
--   2. Commune absente de la table : l'IA fait une recherche sur le web et propose « permis détecté » (régime, périmètre, source)
--      ou « aucun permis trouvé » (date de la recherche). La proposition reste « à confirmer » tant que la gestion ne l'a pas validée.
--      Un point du contrôle d'entrée du mandat signale les lots dont le régime n'est pas confirmé.
--   3. Suivi de chaque demande déposée (autorisation préalable) :
--        J+21 sans réponse : relancer la mairie ; J+30 : accord tacite, mail préparé à la mairie pour demander l'attestation
--        (article L232-3 du code des relations entre le public et l'administration) ; J+45 sans attestation : relance ;
--        refus : alerte ; accord : caducité au bout de 2 ans sans bail signé ; bail signé sans permis : alerte critique.
--      Déclaration de mise en location : à faire dans les 15 jours de la signature du bail.
--
--   LISTE « À LOUER »
--   4. Le pilotage propose un lot à mettre en location quand un congé arrive à sa fin ou quand un lot d'un mandat n'a pas de bail ;
--      la gestion confirme d'un clic (date de disponibilité, loyer prévu). Le lot sort de la liste dès qu'un bail est créé dans Rivage.
--      Indicateur « prêt à louer » : DPE valide, état des risques de moins de 6 mois, permis de louer obtenu si exigé.
--      Le passage en « À louer » d'un lot soumis à autorisation préalable crée le rappel de dépôt de la demande.
--      Cette liste servira à alimenter la diffusion des annonces (WeRoof ou autre).

-- ========== Normalisation des adresses ==========
create or replace function pilotage.norm_voie(t text) returns text
language sql immutable as $$
  select trim(regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(lower(pilotage.sans_accents(coalesce(t, ''))), '[''’.,\-]', ' ', 'g'),
             '\m(bd|bld|boul)\M', 'boulevard', 'g'),
           '\m(de|du|des|la|le|les|d|l)\M', ' ', 'g'),
         '\s+', ' ', 'g'))
$$;
create or replace function pilotage.norm_commune(t text) returns text
language sql immutable as $$
  select trim(regexp_replace(regexp_replace(lower(pilotage.sans_accents(coalesce(t, ''))), '[''’\-]', ' ', 'g'), '\s+', ' ', 'g'))
$$;

-- ========== 1. Communes et rues ==========
create table if not exists pilotage.permis_communes (
  commune text primary key,                         -- nom normalisé
  libelle text not null,
  regime text not null check (regime in ('autorisation', 'declaration', 'aucun')),
  perimetre text not null default 'commune' check (perimetre in ('commune', 'rues')),
  regime_hors_perimetre text check (regime_hors_perimetre in ('declaration', 'aucun')),
  email_depot text, adresse_depot text, source text, notes text,
  statut text not null default 'confirme' check (statut in ('confirme', 'a_confirmer')),
  recherche jsonb, recherche_le timestamptz,
  verifie_le date, verifie_par uuid
);
create table if not exists pilotage.permis_rues (
  id bigserial primary key, commune text not null references pilotage.permis_communes(commune) on delete cascade,
  libelle text not null, voie text not null, num_min integer, num_max integer,
  parite text check (parite in ('pair', 'impair')), condition text
);
create index if not exists permis_rues_voie on pilotage.permis_rues (commune, voie);

insert into pilotage.permis_communes (commune, libelle, regime, perimetre, regime_hors_perimetre, email_depot, adresse_depot, source, notes, verifie_le) values
  (pilotage.norm_commune('Corbeil-Essonnes'), 'Corbeil-Essonnes', 'autorisation', 'rues', 'declaration', 'permisdelouer@mairie-corbeil-essonnes.fr',
   'Mairie de Corbeil-Essonnes, 2 place Galignani, 91100 Corbeil-Essonnes', 'Liste des rues du périmètre Action cœur de ville et liste des pièces fournies par la mairie (Nicolas, 17/10/2026)',
   'Autorisation préalable dans le périmètre Action cœur de ville ; déclaration de mise en location sur le reste de la commune.', current_date),
  (pilotage.norm_commune('Brétigny-sur-Orge'), 'Brétigny-sur-Orge', 'autorisation', 'commune', null, null, null, 'Information de Nicolas (17/10/2026), arrêté à vérifier', null, current_date),
  (pilotage.norm_commune('Mennecy'), 'Mennecy', 'autorisation', 'commune', null, null, null, 'Information de Nicolas (17/10/2026), arrêté à vérifier', null, current_date),
  (pilotage.norm_commune('Ballancourt-sur-Essonne'), 'Ballancourt-sur-Essonne', 'autorisation', 'commune', null, null, null, 'Information de Nicolas (17/10/2026), arrêté à vérifier', null, current_date)
on conflict (commune) do nothing;

delete from pilotage.permis_rues where commune = pilotage.norm_commune('Corbeil-Essonnes');
insert into pilotage.permis_rues (commune, libelle, voie, num_min, num_max, parite, condition)
select pilotage.norm_commune('Corbeil-Essonnes'), v.libelle, pilotage.norm_voie(v.libelle), v.num_min, v.num_max, v.parite, v.condition
from (values
  ('Quai Maurice Riquiez', null, null, null, null),
  ('Rue de la Montagne du Perray', null, null, null, null),
  ('Rue de la Tuilerie', null, null, null, null),
  ('Passage Bourbon', null, null, null, null),
  ('Rue de la Pêcherie', null, null, null, null),
  ('Rue de la Guinguette', null, null, null, null),
  ('Rue de la Jacques Brel', null, null, null, null),
  ('Rue des Fours à Chaux', null, null, null, null),
  ('Route de Saint-Germain', null, null, null, null),
  ('Rue de la Montagne du Vieux Marché', null, null, null, null),
  ('Rue Ferdinand Buisson', null, null, null, null),
  ('Place Saint-Léonard', null, null, null, null),
  ('Rue du 14 Juillet', null, null, null, null),
  ('Rue du Port aux Boulangers', null, null, null, null),
  ('Rue du Port de la Motte', null, null, null, null),
  ('Rue du Port de Bercy', null, null, null, null),
  ('Rue du Barillet', null, null, null, null),
  ('Rue de la Poterie', null, null, null, null),
  ('Rue Audiffred-Bastide', null, null, null, null),
  ('Rue du Paradis', null, null, null, null),
  ('Rue d''Enfer', null, null, null, null),
  ('Rue d''Aligre', null, null, null, null),
  ('Rue de Soisy', null, null, null, null),
  ('Rue Waldeck-Rousseau', null, null, null, null),
  ('Rue du Port des Sabots', null, null, null, null),
  ('Rue du Port de l''Etoile', null, null, null, null),
  ('Rue du Port des Marines', null, null, null, null),
  ('Rue de la Montagne de Saint Germain', null, null, null, null),
  ('Quai Jacques Bourgoin', null, null, null, null),
  ('Chemin de Halage', null, null, null, null),
  ('Rue René Cassin', null, null, null, null),
  ('Allée des Ormes', 2, 4, null, 'du n°2 au n°4'),
  ('Rue Botha', 2, 6, null, 'du n°2 au n°6'),
  ('Rue Charles Jozon', 2, 8, null, 'du n°2 au n°8'),
  ('Rue Krüger', 2, 6, null, 'du n°2 au n°6'),
  ('Rue du Bas Coudray', 34, 102, null, 'du n°34 au n°102'),
  ('Rue Saint-Nicolas', null, null, null, null),
  ('Rue de la Quarantaine', null, null, null, null),
  ('Rue Saint-Spire', null, null, null, null),
  ('Rue des Fossés', null, null, null, null),
  ('Rue de la Triperie', null, null, null, null),
  ('Rue de l''Arquebuse', null, null, null, null),
  ('Rue Albert Mercier', null, null, null, null),
  ('Rue de l''Arche', null, null, null, null),
  ('Rue du Charbon Blanc', null, null, null, null),
  ('Rue de la Boucherie', null, null, null, null),
  ('Rue Charles Drezet', null, null, null, null),
  ('Cloître Saint-Spire', null, null, null, null),
  ('Rue Abélard', null, null, null, null),
  ('Rue du Trou Patrix', null, null, null, null),
  ('Rue Vigier', null, null, null, null),
  ('Rue de la Barre', null, null, null, null),
  ('Rue Cullion', null, null, null, null),
  ('Rue Jean-Jacques Rousseau', null, null, null, null),
  ('Place du Comte-Haymon', null, null, null, null),
  ('Rue Féray', null, null, null, null),
  ('Rue Neuve Notre-Dame', null, null, null, null),
  ('Ruelle des Prêtres', null, null, null, null),
  ('Rue du Port Saint-Guénault', null, null, null, null),
  ('Quai Mauzaisse', null, null, null, null),
  ('Rue Notre-Dame', null, null, null, null),
  ('Place Galignani', null, null, null, null),
  ('Rue aux Tisseurs', null, null, null, null),
  ('Rue des Rosiers', null, null, null, null),
  ('Rue du Grand Pignon', null, null, null, null),
  ('Rue des Remparts', null, null, null, null),
  ('Avenue Darblay', null, null, null, null),
  ('Rue de la République', null, null, null, null),
  ('Quai de l''Apport Paris', null, null, null, null),
  ('Rue Fernand Raynaud', null, null, null, null),
  ('Rue Decauville', null, null, null, null),
  ('Rue du Gaz', null, null, null, null),
  ('Rue de Seine', null, null, null, null),
  ('Rue Lafayette', null, null, null, null),
  ('Rue Emile Zola', 2, 24, 'pair', 'Côté pair du n°2 au n°24'),
  ('Rue de la Sous-Préfecture', null, null, null, null),
  ('Rue du Général Lucotte', null, null, null, null),
  ('Rue du Général Leclerc', null, null, null, null),
  ('Rue Pierre Sémard', null, null, null, null),
  ('Place Henri Barbusse', null, null, null, null),
  ('Boulevard Crété', null, null, null, null),
  ('Rue Champlouis', null, null, null, null),
  ('Quai de l''Essonne', null, null, null, null),
  ('Rue du Tir', null, null, null, null),
  ('Avenue Carnot', null, null, null, null),
  ('Rue Félicien Rops', null, null, null, null),
  ('Rue des Petites Bordes', null, null, null, null),
  ('Rue du Docteur Vignes', null, null, null, null),
  ('Allées Aristide Briand', null, null, null, null),
  ('Rue Salmon', null, null, null, null),
  ('Rue Maurage', null, null, null, null),
  ('Rue du Champ d''Epreuves', null, null, null, null),
  ('Rue de la Commanderie', null, null, null, null),
  ('Rue Villebois-Mareuil', null, null, null, null),
  ('Rue Caillet-Dupont', null, null, null, null),
  ('Rue Edouard Petit', null, null, null, null),
  ('Rue du Capitaine Pasquet', null, null, null, null),
  ('Rue de Nagis', null, null, null, null),
  ('Boulevard Henri Dunant', 2, 46, 'pair', 'Côté pair du n°2 au n°46'),
  ('Rue de Jussy', null, null, null, null),
  ('Rue de Gournay', null, null, null, null),
  ('Rue Emile Gourdet', null, null, null, null),
  ('Rue Lamartine', null, null, null, null),
  ('Rue Sabatier', null, null, null, null),
  ('Rue de la Dauphine', 2, 36, 'pair', 'Côté pair du n°2 au n°36 puis côté pair du n°46 au 106'),
  ('Rue de la Dauphine', 46, 106, 'pair', 'Côté pair du n°2 au n°36 puis côté pair du n°46 au 106'),
  ('Chemin du Parc de Nagis', null, null, null, null),
  ('Ruelle de la Dauphine', null, null, null, null),
  ('Rue Louis Joyeux', 2, 56, 'pair', 'côté pair du n°2 au n°56'),
  ('Rue de Paris', null, null, null, null),
  ('Boulevard Combes Marnes', null, null, null, null),
  ('Rue de Robinson', 2, 20, null, 'du n°2 au n°20'),
  ('Rue Victor Hugo', null, null, null, null),
  ('Rue Marchand', null, null, null, null),
  ('Place d''Essonnes', null, null, null, null),
  ('Rue Ferdinand Seurat', null, null, null, null),
  ('Rue du Père Legris', null, null, null, null),
  ('Ruelle du Mort-Voisin', null, null, null, null),
  ('Passage Pommereau', null, null, null, null),
  ('Rue d''Angoulême', 1, 76, null, 'du n°1 au n°76'),
  ('Rue Saint-Louis', null, null, null, null),
  ('Rue Henri Cherrière', null, null, null, null),
  ('Sentier du Clos du Cygne', null, null, null, null),
  ('Rue Louis Robert', null, null, null, null),
  ('Rue de la Poudrerie', null, null, null, null),
  ('Rue d''Alsace-Lorraine', null, null, null, null),
  ('Rue Berthollet', null, null, null, null),
  ('Rue du Laminoir', null, null, null, null),
  ('Rue Lavoisier', null, null, null, null),
  ('Rue Jeanne d''Arc', null, null, null, null),
  ('Rue Widmer', null, null, null, null),
  ('Rue des Chevaliers Saint Jean', null, null, null, null),
  ('Rue Maurice Berteaux', null, null, null, null),
  ('Rue de la Reine Ingeburge', null, null, null, null),
  ('Rue du Déversoir', null, null, null, null),
  ('Impasse du Parc', null, null, null, null),
  ('Impasse de l''Abreuvoir', null, null, null, null),
  ('Impasse Minerva', null, null, null, null),
  ('Place Léon Cassé', null, null, null, null),
  ('Avenue Paul Doumer', null, null, null, null),
  ('Place Paul Vaillant-Couturier', null, null, null, null),
  ('Rue Jules Lemaire', null, null, null, null),
  ('Rue Oberkampf', null, null, null, null),
  ('Allée des Grands Arbres', null, null, null, null),
  ('Allée Pierre Seghers', null, null, null, null),
  ('Rue du 11 Novembre 1918', null, null, null, null),
  ('Espace Saint-Just', null, null, null, null),
  ('Boulevard Georges Michel', null, null, null, null),
  ('Avenue de Chantemerle', null, null, null, null),
  ('Rue de l''Indienne', null, null, null, null),
  ('Rue du Maréchal de Lattre de Tassigny', null, null, null, null),
  ('Rue de la Planchette', null, null, null, null)) v(libelle, num_min, num_max, parite, condition);

alter table pilotage.permis_communes enable row level security;
alter table pilotage.permis_rues enable row level security;
revoke all on pilotage.permis_communes, pilotage.permis_rues from public, anon, authenticated;
revoke all on sequence pilotage.permis_rues_id_seq from public, anon, authenticated;

-- Régime d'un lot : autorisation, declaration, aucun, non_concerne (pas un logement), inconnu (commune jamais vérifiée), a_verifier
create or replace function pilotage.permis_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare a jsonb; c pilotage.permis_communes; num integer; voie text; rue record; dans boolean; regime text; detail text;
begin
  select data into a from pilotage.objets where type = 'Asset' and id = p_asset;
  if a is null then return null; end if;
  if coalesce(a->>'nature', '') not in ('flat', 'room', 'house') then
    return jsonb_build_object('regime', 'non_concerne', 'commune', a->'address'->>'city', 'detail', 'Pas un logement : permis de louer non applicable.');
  end if;
  select * into c from pilotage.permis_communes where commune = pilotage.norm_commune(a->'address'->>'city');
  if c.commune is null then
    return jsonb_build_object('regime', 'inconnu', 'commune', a->'address'->>'city', 'detail', 'Commune jamais vérifiée : recherche à faire.');
  end if;
  if c.perimetre = 'commune' then
    regime := c.regime; detail := 'Toute la commune.';
  else
    voie := pilotage.norm_voie(a->'address'->>'street');
    num := nullif(substring(coalesce(a->'address'->>'number', '') from '^\s*(\d+)'), '')::integer;
    dans := false;
    for rue in select * from pilotage.permis_rues r where r.commune = c.commune and r.voie = voie loop
      if rue.num_min is null then dans := true; detail := 'Voie du périmètre : ' || rue.libelle; exit; end if;
      if num is null then dans := null; detail := 'Voie partiellement dans le périmètre (' || rue.condition || ') : numéro absent dans Rivage, à vérifier.'; continue; end if;
      if num between rue.num_min and rue.num_max and (rue.parite is null or (rue.parite = 'pair') = (num % 2 = 0)) then
        dans := true; detail := 'Dans le périmètre : ' || rue.libelle || ' (' || rue.condition || ')'; exit;
      end if;
    end loop;
    if dans is null then regime := 'a_verifier';
    elsif dans then regime := c.regime;
    else regime := coalesce(c.regime_hors_perimetre, 'aucun');
      detail := 'Hors du périmètre (adresse : ' || coalesce(a->'address'->>'number', '') || ' ' || coalesce(a->'address'->>'street', '') || ').';
    end if;
  end if;
  return jsonb_build_object('regime', regime, 'commune', c.libelle, 'a_confirmer', c.statut = 'a_confirmer', 'detail', detail,
    'email_depot', c.email_depot, 'adresse_depot', c.adresse_depot, 'source', c.source, 'verifie_le', c.verifie_le);
end $$;

-- ========== 2. Recherche IA des communes nouvelles ==========
-- Communes des logements gérés absentes de la table (la recherche est lancée par la fonction serveur, 2 par passage)
create or replace function public.pilotage_communes_a_rechercher(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select distinct on (pilotage.norm_commune(a.data->'address'->>'city'))
           jsonb_build_object('commune', a.data->'address'->>'city', 'code_postal', a.data->'address'->>'zip_code') x
    from pilotage.objets a
    where a.type = 'Asset' and a.supprime_le is null and a.data->>'nature' in ('flat', 'room', 'house')
      and nullif(a.data->'address'->>'city', '') is not null
      and not exists (select 1 from pilotage.permis_communes c where c.commune = pilotage.norm_commune(a.data->'address'->>'city'))
    order by pilotage.norm_commune(a.data->'address'->>'city') limit p_max) t
$$;

-- Résultat d'une recherche : enregistré « à confirmer » (jamais confirmé par l'IA seule)
create or replace function public.pilotage_permis_recherche_ecrire(p_commune text, p_resultat jsonb) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare reg text := case when p_resultat->>'resultat' = 'detecte' and p_resultat->>'regime' in ('autorisation', 'declaration') then p_resultat->>'regime' else 'aucun' end;
begin
  insert into pilotage.permis_communes (commune, libelle, regime, perimetre, regime_hors_perimetre, source, notes, statut, recherche, recherche_le)
  values (pilotage.norm_commune(p_commune), p_commune, reg,
          case when p_resultat->>'perimetre' = 'partiel' then 'rues' else 'commune' end,
          case when p_resultat->>'perimetre' = 'partiel' then 'aucun' end,
          left(p_resultat->>'source', 500),
          case when reg = 'aucun' then 'Aucun permis de louer trouvé lors de la recherche du ' || to_char(now(), 'DD/MM/YYYY') else left(p_resultat->>'detail', 1000) end,
          'a_confirmer', p_resultat, now())
  on conflict (commune) do update set recherche = excluded.recherche, recherche_le = now()
    where pilotage.permis_communes.statut = 'a_confirmer';
end $$;

-- Recherche demandée depuis l'écran (le lot d'un dossier) : la commune est retirée si elle n'est pas confirmée, la recherche repart
create or replace function public.pilotage_permis_commune_rechercher(p_commune text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  delete from pilotage.permis_communes where commune = pilotage.norm_commune(p_commune) and statut = 'a_confirmer';
end $$;

-- Confirmation ou correction par la gestion
create or replace function public.pilotage_permis_commune_maj(p_commune text, p_libelle text, p_regime text, p_perimetre text, p_hors text,
  p_email text, p_adresse text, p_source text, p_notes text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Réservé à la gestion'; end if;
  if p_regime not in ('autorisation', 'declaration', 'aucun') then raise exception 'Régime inconnu'; end if;
  insert into pilotage.permis_communes (commune, libelle, regime, perimetre, regime_hors_perimetre, email_depot, adresse_depot, source, notes, statut, verifie_le, verifie_par)
  values (pilotage.norm_commune(p_commune), coalesce(nullif(p_libelle, ''), p_commune), p_regime, coalesce(nullif(p_perimetre, ''), 'commune'), nullif(p_hors, ''),
          nullif(p_email, ''), nullif(p_adresse, ''), nullif(p_source, ''), nullif(p_notes, ''), 'confirme', current_date, auth.uid())
  on conflict (commune) do update set libelle = excluded.libelle, regime = excluded.regime, perimetre = excluded.perimetre,
    regime_hors_perimetre = excluded.regime_hors_perimetre, email_depot = excluded.email_depot, adresse_depot = excluded.adresse_depot,
    source = excluded.source, notes = excluded.notes, statut = 'confirme', verifie_le = current_date, verifie_par = auth.uid();
end $$;

create or replace function public.pilotage_permis_communes() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(to_jsonb(c) - 'verifie_par' || jsonb_build_object('verifie_par', pilotage.prenom_membre(c.verifie_par),
           'rues', (select count(*) from pilotage.permis_rues r where r.commune = c.commune)) order by c.statut desc, c.libelle)
    from pilotage.permis_communes c), '[]'::jsonb);
end $$;

-- ========== 3. Demandes et suivi ==========
create table if not exists pilotage.permis_demandes (
  id bigserial primary key, asset_id text not null,
  regime text not null check (regime in ('autorisation', 'declaration')),
  depot_le date not null, numero text, bail_id text,
  reponse text check (reponse in ('accord', 'refus', 'tacite')), reponse_le date,
  attestation_demandee_le date, attestation_recue_le date,
  notes text, par uuid, cree_le timestamptz not null default now(), close_le date
);
create index if not exists permis_demandes_lot on pilotage.permis_demandes (asset_id);
alter table pilotage.permis_demandes enable row level security;
revoke all on pilotage.permis_demandes from public, anon, authenticated;
revoke all on sequence pilotage.permis_demandes_id_seq from public, anon, authenticated;

alter table pilotage.mandats_obligations add column if not exists permis_id bigint;

insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele) values
  ('permis_a_demander', 1, 0, 'Lot à louer soumis à autorisation préalable : déposer la demande en mairie (Cerfa 15652) avant toute signature', 'tache', null),
  ('permis_demande', 1, -9, 'Trois semaines sans réponse de la mairie : relancer', 'tache', null),
  ('permis_demande', 2, 0, 'Un mois sans réponse : accord tacite. Constater et demander l''attestation à la mairie (bouton du bloc Permis de louer)', 'tache', null),
  ('permis_attestation', 1, 0, 'Attestation d''accord tacite non reçue : relancer la mairie', 'tache', null),
  ('permis_refus', 1, 0, 'Permis de louer refusé : voir avec le bailleur les travaux demandés par la mairie, puis déposer une nouvelle demande', 'tache', null),
  ('permis_caducite', 1, -60, 'Permis de louer sans bail signé : il devient caduc à l''échéance (2 ans)', 'tache', null),
  ('permis_declaration', 1, -10, 'Déclarer la mise en location en mairie (Cerfa 15651), dans les 15 jours de la signature du bail', 'tache', null),
  ('permis_declaration', 2, 0, 'Délai de déclaration atteint : déclaration à faire immédiatement', 'tache', null),
  ('permis_absent', 1, 0, 'Bail signé sans permis de louer : régulariser immédiatement (amende jusqu''à 15 000 €)', 'tache', null)
on conflict (nature, ordre) do update set jours = excluded.jours, libelle = excluded.libelle, canal = excluded.canal, modele = excluded.modele;

create or replace function pilotage.permis_suivi(p_mandat text, p_asset text, p_nature text, p_libelle text, p_prochaine date, p_permis bigint) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if exists (select 1 from pilotage.mandats_obligations where asset_id = p_asset and nature = p_nature and actif
             and coalesce(permis_id, -1) = coalesce(p_permis, -1)) then return; end if;
  insert into pilotage.mandats_obligations (mandat_id, asset_id, nature, libelle, prochaine, auto, permis_id)
  values (p_mandat, p_asset, p_nature, p_libelle, p_prochaine, true, p_permis);
end $$;

create or replace function pilotage.permis_clore(p_asset text, p_natures text[]) returns void
language sql security definer set search_path = pilotage, public as $$
  update pilotage.mandats_obligations set actif = false where asset_id = p_asset and nature = any(p_natures) and actif
$$;

-- Saisie : dépôt d'une demande, réponse (accord, refus, accord tacite constaté), attestation demandée ou reçue
create or replace function public.pilotage_permis_action(p_asset text, p_demande bigint, p_action text, p_le date, p_numero text, p_notes text) returns bigint
language plpgsql security definer set search_path = pilotage, public as $$
declare d pilotage.permis_demandes; m text; reg jsonb; nid bigint; lot text;
begin
  if not pilotage.peut_traiter_lot(p_asset) then raise exception 'Accès refusé'; end if;
  select data->>'management_contract_id', coalesce(nullif(data->>'reference', ''), id) into m, lot from pilotage.objets where type = 'Asset' and id = p_asset;
  if m is null then raise exception 'Lot inconnu ou sans mandat'; end if;
  if p_action = 'deposer' then
    reg := pilotage.permis_lot(p_asset);
    if reg->>'regime' not in ('autorisation', 'declaration', 'a_verifier') then raise exception 'Ce lot n''est pas soumis au permis de louer d''après la table des communes'; end if;
    insert into pilotage.permis_demandes (asset_id, regime, depot_le, numero, notes, par)
    values (p_asset, case when reg->>'regime' = 'declaration' then 'declaration' else 'autorisation' end, coalesce(p_le, current_date), nullif(p_numero, ''), nullif(p_notes, ''), auth.uid())
    returning id into nid;
    perform pilotage.permis_clore(p_asset, array['permis_a_demander', 'permis_refus', 'permis_declaration']);
    if reg->>'regime' <> 'declaration' then
      perform pilotage.permis_suivi(m, p_asset, 'permis_demande', 'Permis de louer du lot ' || lot || ' : réponse de la mairie', coalesce(p_le, current_date) + 30, nid);
    end if;
    return nid;
  end if;
  select * into d from pilotage.permis_demandes where id = p_demande and asset_id = p_asset;
  if d.id is null then raise exception 'Demande introuvable'; end if;
  if p_action in ('accord', 'refus', 'tacite') then
    update pilotage.permis_demandes set reponse = p_action,
      reponse_le = case when p_action = 'tacite' then d.depot_le + 30 else coalesce(p_le, current_date) end,
      numero = coalesce(nullif(p_numero, ''), numero), notes = coalesce(nullif(p_notes, ''), notes) where id = d.id;
    perform pilotage.permis_clore(p_asset, array['permis_demande']);
    if p_action = 'refus' then
      update pilotage.permis_demandes set close_le = current_date where id = d.id;
      perform pilotage.permis_suivi(m, p_asset, 'permis_refus', 'Permis de louer refusé (lot ' || lot || ')', current_date, d.id);
    else
      perform pilotage.permis_suivi(m, p_asset, 'permis_caducite', 'Validité du permis de louer du lot ' || lot || ' (caduc sans bail signé)',
        pilotage.ajouter_mois(case when p_action = 'tacite' then d.depot_le + 30 else coalesce(p_le, current_date) end, 24), d.id);
      if p_action = 'tacite' then
        perform pilotage.permis_suivi(m, p_asset, 'permis_attestation', 'Attestation d''accord tacite du permis de louer (lot ' || lot || ')', current_date + 15, d.id);
      end if;
    end if;
  elsif p_action = 'attestation_demandee' then
    update pilotage.permis_demandes set attestation_demandee_le = coalesce(p_le, current_date) where id = d.id;
    update pilotage.mandats_obligations set prochaine = coalesce(p_le, current_date) + 15 where asset_id = p_asset and nature = 'permis_attestation' and actif;
  elsif p_action = 'attestation_recue' then
    update pilotage.permis_demandes set attestation_recue_le = coalesce(p_le, current_date) where id = d.id;
    perform pilotage.permis_clore(p_asset, array['permis_attestation']);
  elsif p_action = 'annuler' then
    update pilotage.permis_demandes set close_le = current_date where id = d.id;
    perform pilotage.permis_clore(p_asset, array['permis_demande', 'permis_attestation', 'permis_caducite']);
  else raise exception 'Action inconnue'; end if;
  return d.id;
end $$;

-- Permis de louer des lots d'un mandat (pour l'écran)
create or replace function public.pilotage_mandat_permis(p_mandat text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_traiter_dossier('mandat', p_mandat) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('asset_id', a.id, 'lot', coalesce(nullif(a.data->>'reference', ''), a.id),
      'adresse', concat_ws(' ', a.data->'address'->>'number', a.data->'address'->>'street', a.data->'address'->>'zip_code', a.data->'address'->>'city'),
      'permis', pilotage.permis_lot(a.id),
      'demandes', coalesce((select jsonb_agg(to_jsonb(d) - 'par' order by d.depot_le desc) from pilotage.permis_demandes d where d.asset_id = a.id), '[]'::jsonb))
    order by a.data->>'reference')
    from pilotage.objets a where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat
      and a.data->>'nature' in ('flat', 'room', 'house')), '[]'::jsonb);
end $$;

-- ========== 4. Liste « À louer » ==========
create table if not exists pilotage.lots_a_louer (
  asset_id text primary key,
  depuis date not null default current_date, disponible_le date, loyer_prevu numeric(12,2),
  motif text, note text, par uuid,
  sorti_le date, sorti_motif text
);
alter table pilotage.lots_a_louer enable row level security;
revoke all on pilotage.lots_a_louer from public, anon, authenticated;

-- Propositions : congé qui arrive à sa fin (bail en sortie ou fin dans les 3 mois), ou lot d'un mandat actif sans bail en cours
create or replace function pilotage.a_louer_propositions() returns table (asset_id text, motif text, disponible_le date)
language sql stable security definer set search_path = pilotage, public as $$
  select a.id,
         case when b.id is not null then 'Fin de bail le ' || to_char(b.fin, 'DD/MM/YYYY') || coalesce(' (' || b.statut || ')', '')
              when (select m.debut from pilotage.v_mandats m where m.id = a.data->>'management_contract_id') >= current_date - 365 then 'Nouveau mandat : lot sans bail'
              else 'Lot vacant (aucun bail en cours)' end,
         coalesce(b.fin + 1, current_date)
  from pilotage.objets a
  join pilotage.objets mc on mc.type = 'ManagementContract' and mc.id = a.data->>'management_contract_id' and mc.supprime_le is null and mc.data->>'status' = 'active'
  left join lateral (select x.id, x.fin, x.statut from pilotage.v_baux x
                     where x.lot_id = a.id and x.statut in ('created', 'move_in', 'in_progress', 'move_out') and (x.fin is null or x.fin >= current_date)
                     order by x.debut desc limit 1) b on true
  where a.type = 'Asset' and a.supprime_le is null and a.data->>'nature' not in ('box', 'basement')
    and (b.id is null or b.statut = 'move_out' or b.fin <= current_date + 90)
    and not exists (select 1 from pilotage.lots_a_louer l where l.asset_id = a.id and l.sorti_le is null)
    and not exists (select 1 from pilotage.v_baux y where y.lot_id = a.id and y.statut in ('created', 'move_in', 'in_progress')
                    and y.debut > coalesce(b.fin, current_date - 1) and y.id is distinct from b.id)
$$;

-- Sortie automatique : un nouveau bail est créé dans Rivage sur le lot
create or replace function pilotage.a_louer_auto() returns integer
language plpgsql security definer set search_path = pilotage, public as $$
declare n integer;
begin
  update pilotage.lots_a_louer l set sorti_le = current_date, sorti_motif = 'Bail créé dans Rivage : ' || coalesce(b.reference, b.id)
  from pilotage.v_baux b
  where l.sorti_le is null and b.lot_id = l.asset_id and b.statut in ('created', 'move_in', 'in_progress')
    and coalesce(b.debut, current_date) >= l.depuis - 30;
  get diagnostics n = row_count;
  -- Permis : bail signé sur un lot en autorisation préalable sans permis obtenu, déclaration à faire dans les 15 jours
  insert into pilotage.mandats_obligations (mandat_id, asset_id, nature, libelle, prochaine, auto)
  select a.data->>'management_contract_id', a.id, case when pilotage.permis_lot(a.id)->>'regime' = 'declaration' then 'permis_declaration' else 'permis_absent' end,
         case when pilotage.permis_lot(a.id)->>'regime' = 'declaration' then 'Déclaration de mise en location (bail ' || coalesce(b.reference, '') || ')'
              else 'Bail ' || coalesce(b.reference, '') || ' signé sans permis de louer' end,
         case when pilotage.permis_lot(a.id)->>'regime' = 'declaration' then coalesce(b.signe_le, b.debut) + 15 else current_date end, true
  from pilotage.v_baux b join pilotage.objets a on a.type = 'Asset' and a.id = b.lot_id
  where b.statut in ('created', 'move_in', 'in_progress') and coalesce(b.signe_le, b.debut) >= date '2026-10-17'
    and pilotage.permis_lot(a.id)->>'regime' in ('autorisation', 'declaration')
    and not exists (select 1 from pilotage.mandats_obligations o where o.asset_id = a.id and o.nature in ('permis_declaration', 'permis_absent') and o.libelle like '%' || coalesce(b.reference, b.id) || '%')
    and (pilotage.permis_lot(a.id)->>'regime' = 'declaration'
         or not exists (select 1 from pilotage.permis_demandes d where d.asset_id = a.id and d.reponse in ('accord', 'tacite')
                        and d.reponse_le >= coalesce(b.signe_le, b.debut) - interval '2 years' and d.reponse_le <= coalesce(b.signe_le, b.debut)));
  -- Permis utilisé : un bail signé après l'accord clôt le suivi de caducité
  update pilotage.mandats_obligations o set actif = false
  from pilotage.permis_demandes d
  where o.nature = 'permis_caducite' and o.actif and o.permis_id = d.id
    and exists (select 1 from pilotage.v_baux b where b.lot_id = d.asset_id and b.statut in ('created', 'move_in', 'in_progress') and coalesce(b.signe_le, b.debut) >= d.reponse_le);
  return n;
end $$;

create or replace function public.pilotage_a_louer() returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  perform pilotage.a_louer_auto();
  return jsonb_build_object('peut', pilotage.peut_suivre_baux(),
    'lots', coalesce((select jsonb_agg(jsonb_build_object('asset_id', l.asset_id, 'depuis', l.depuis, 'disponible_le', l.disponible_le, 'loyer_prevu', l.loyer_prevu,
        'motif', l.motif, 'note', l.note, 'lot', v.reference, 'nature', v.nature, 'adresse', v.adresse, 'surface', v.surface, 'mandat_id', v.mandat_id,
        'bailleur', pilotage.bailleurs_mandat(v.mandat_id), 'permis', pilotage.permis_lot(l.asset_id),
        'pret', jsonb_build_object(
          'dpe', coalesce((a.data->'energy_diagnostic'->>'expiry_date')::date > current_date, false)
                 or exists (select 1 from pilotage.objets u where u.type = 'Upload' and u.supprime_le is null and u.data->>'nature' = 'energy_performance_diagnosis'
                            and u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', l.asset_id)) and u.maj_le > now() - interval '10 years'),
          'dpe_classe', a.data->'energy_diagnostic'->>'overall_class',
          'erp', exists (select 1 from pilotage.objets u where u.type = 'Upload' and u.supprime_le is null and u.data->>'nature' = 'natural_risks_and_pollution_state'
                         and u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', l.asset_id)) and u.maj_le > now() - interval '6 months'),
          'permis', case when pilotage.permis_lot(l.asset_id)->>'regime' = 'autorisation'
                         then exists (select 1 from pilotage.permis_demandes d where d.asset_id = l.asset_id and d.reponse in ('accord', 'tacite') and d.close_le is null
                                      and d.reponse_le > current_date - interval '2 years')
                         else true end))
      order by coalesce(l.disponible_le, l.depuis))
      from pilotage.lots_a_louer l join pilotage.v_lots v on v.id = l.asset_id left join pilotage.objets a on a.type = 'Asset' and a.id = l.asset_id
      where l.sorti_le is null), '[]'::jsonb),
    'propositions', case when pilotage.peut_suivre_baux() then coalesce((select jsonb_agg(jsonb_build_object('asset_id', p.asset_id, 'motif', p.motif, 'disponible_le', p.disponible_le,
        'lot', v.reference, 'nature', v.nature, 'adresse', v.adresse, 'bailleur', pilotage.bailleurs_mandat(v.mandat_id),
        'loyer_dernier', (select x.loyer_hc + coalesce(x.charges, 0) from pilotage.v_baux x where x.lot_id = p.asset_id order by x.debut desc nulls last limit 1)) order by p.disponible_le)
      from pilotage.a_louer_propositions() p join pilotage.v_lots v on v.id = p.asset_id), '[]'::jsonb) else '[]'::jsonb end);
end $$;

create or replace function public.pilotage_a_louer_maj(p_asset text, p_action text, p_disponible date, p_loyer numeric, p_motif text, p_note text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare m text; lot text;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Réservé à la gestion'; end if;
  select data->>'management_contract_id', coalesce(nullif(data->>'reference', ''), id) into m, lot from pilotage.objets where type = 'Asset' and id = p_asset;
  if m is null then raise exception 'Lot inconnu ou sans mandat'; end if;
  if p_action = 'ajouter' then
    insert into pilotage.lots_a_louer (asset_id, disponible_le, loyer_prevu, motif, note, par) values (p_asset, p_disponible, p_loyer, p_motif, p_note, auth.uid())
    on conflict (asset_id) do update set depuis = current_date, disponible_le = excluded.disponible_le, loyer_prevu = excluded.loyer_prevu, motif = excluded.motif,
      note = excluded.note, par = auth.uid(), sorti_le = null, sorti_motif = null;
    -- Autorisation préalable : rappel de dépôt dès le passage en « À louer », sauf permis en cours de validité
    if pilotage.permis_lot(p_asset)->>'regime' in ('autorisation', 'a_verifier')
       and not exists (select 1 from pilotage.permis_demandes d where d.asset_id = p_asset and d.close_le is null
                       and (d.reponse is null or (d.reponse in ('accord', 'tacite') and d.reponse_le > current_date - interval '2 years'))) then
      perform pilotage.permis_suivi(m, p_asset, 'permis_a_demander', 'Permis de louer à demander (lot ' || lot || ')', current_date, null);
    end if;
  elsif p_action = 'modifier' then
    update pilotage.lots_a_louer set disponible_le = p_disponible, loyer_prevu = p_loyer, note = p_note where asset_id = p_asset;
  elsif p_action = 'retirer' then
    update pilotage.lots_a_louer set sorti_le = current_date, sorti_motif = coalesce(nullif(p_motif, ''), 'Retiré de la location') where asset_id = p_asset and sorti_le is null;
    perform pilotage.permis_clore(p_asset, array['permis_a_demander']);
  else raise exception 'Action inconnue'; end if;
end $$;

-- ========== 5. Point du contrôle d'entrée du mandat ==========
insert into pilotage.controle_questions (cle, portee, bloc, ordre, libelle, aide, mode, ref) values
('m_rv_permis', 'mandat', 'rivage', 110, 'Permis de louer des logements (d''après la commune et l''adresse)',
  'Régime confirmé par la gestion dans la table des communes. Commune inconnue : recherche automatique, puis confirmation.', 'rivage', 'lots_permis')
on conflict (cle) do update set portee = excluded.portee, bloc = excluded.bloc, ordre = excluded.ordre, libelle = excluded.libelle, aide = excluded.aide,
  mode = excluded.mode, ref = excluded.ref;

do $do$
declare def text; n text;
begin
  def := pg_get_functiondef('pilotage.controle_mandat(text)'::regprocedure);
  if position('lots_permis' in def) > 0 then return; end if;
  n := regexp_replace(def, '(\s)else null;(\s+)end case;', $r$\1when 'lots_permis' then
          detail := (select string_agg('lot ' || coalesce(nullif(a.data->>'reference', ''), a.id) || ' : '
                       || case p->>'regime' when 'autorisation' then 'autorisation préalable' when 'declaration' then 'déclaration de mise en location'
                            when 'aucun' then 'pas de permis' when 'inconnu' then 'commune non vérifiée' when 'a_verifier' then 'adresse à vérifier' else p->>'regime' end
                       || case when (p->>'a_confirmer')::boolean then ' (à confirmer)' else '' end, ', ' order by a.data->>'reference')
                     from pilotage.objets a cross join lateral (select pilotage.permis_lot(a.id) p) x
                     where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat and a.data->>'nature' in ('flat', 'room', 'house'));
          if detail is null then auto := 'sans_objet'; detail := 'Aucun logement dans ce mandat.';
          elsif exists (select 1 from pilotage.objets a cross join lateral (select pilotage.permis_lot(a.id) p) x
                        where a.type = 'Asset' and a.supprime_le is null and a.data->>'management_contract_id' = p_mandat and a.data->>'nature' in ('flat', 'room', 'house')
                          and (p->>'regime' in ('inconnu', 'a_verifier') or coalesce((p->>'a_confirmer')::boolean, false))) then
            auto := 'anomalie'; detail := detail || ' · régime à confirmer par la gestion (table des communes)';
          else auto := 'ok'; end if;
        else null;\2end case;$r$);
  if n = def then raise exception '038 : point d''insertion introuvable dans controle_mandat'; end if;
  execute n;
end $do$;

-- Automatismes : sorties de la liste et suivis de permis (avec les suivis de mandat, toutes les 30 minutes)
select cron.unschedule('pilotage-suivis-mandats') where exists (select 1 from cron.job where jobname = 'pilotage-suivis-mandats');
select cron.schedule('pilotage-suivis-mandats', '20,50 * * * *', $$ select pilotage.mandats_suivis_auto(); select pilotage.immeubles_suivis_auto(); select pilotage.a_louer_auto(); $$);
select cron.unschedule('pilotage-permis-communes') where exists (select 1 from cron.job where jobname = 'pilotage-permis-communes');
select cron.schedule('pilotage-permis-communes', '25 * * * *', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-lecture-bail',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{"communes": true}'::jsonb, timeout_milliseconds := 300000) $$);

-- Tableau « À louer » visible par toute l'équipe
revoke all on all functions in schema pilotage from public, anon, authenticated;
revoke all on function public.pilotage_communes_a_rechercher(integer), public.pilotage_permis_recherche_ecrire(text, jsonb) from public, anon, authenticated;
revoke all on function public.pilotage_permis_commune_rechercher(text), public.pilotage_permis_commune_maj(text, text, text, text, text, text, text, text, text),
  public.pilotage_permis_communes(), public.pilotage_permis_action(text, bigint, text, date, text, text), public.pilotage_mandat_permis(text),
  public.pilotage_a_louer(), public.pilotage_a_louer_maj(text, text, date, numeric, text, text) from public, anon;
grant execute on function public.pilotage_permis_commune_rechercher(text), public.pilotage_permis_commune_maj(text, text, text, text, text, text, text, text, text),
  public.pilotage_permis_communes(), public.pilotage_permis_action(text, bigint, text, date, text, text), public.pilotage_mandat_permis(text),
  public.pilotage_a_louer(), public.pilotage_a_louer_maj(text, text, date, numeric, text, text) to authenticated;
