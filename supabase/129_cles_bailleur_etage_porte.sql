-- 129 : tableau des clés, bailleur, étage et porte du lot (bloc 1 sur 1)
--  Demande de Nicolas du 06/11/2026 : ajouter au tableau des clés le nom du bailleur, l'étage et la porte.
--   - Bailleur : celui du mandat du lot (pilotage.bailleurs_mandat, comme ailleurs dans le pilotage).
--   - Étage : lu dans Rivage (fiche du lot, champ floor ; renseigné pour 308 lots sur 421 au 06/11). Ce que Rivage donne ne se ressaisit
--     pas : un étage manquant ou faux se corrige dans Rivage.
--   - Porte : Rivage n'a pas de champ porte (seulement un complément d'adresse, rempli pour 14 lots et souvent avec autre chose) :
--     saisie dans le pilotage, par lot (table pilotage.lots_portes), par la gestion et la direction. Le complément d'adresse Rivage
--     est affiché à côté pour aider.
--  Rien n'est écrit dans Rivage.

create table if not exists pilotage.lots_portes (
  asset_id text primary key,
  porte text not null check (nullif(trim(porte), '') is not null),
  par uuid,
  le timestamptz not null default now()
);
alter table pilotage.lots_portes enable row level security;
revoke all on pilotage.lots_portes from public, anon, authenticated;

create or replace function public.pilotage_lot_porte(p_asset text, p_porte text) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Réservé à la gestion et à la direction'; end if;
  if not exists (select 1 from pilotage.objets where type = 'Asset' and id = p_asset and supprime_le is null) then raise exception 'Lot inconnu dans Rivage'; end if;
  if nullif(trim(p_porte), '') is null then
    delete from pilotage.lots_portes where asset_id = p_asset;
  else
    insert into pilotage.lots_portes (asset_id, porte, par) values (p_asset, trim(p_porte), auth.uid())
    on conflict (asset_id) do update set porte = excluded.porte, par = excluded.par, le = now();
  end if;
end $$;
revoke all on function public.pilotage_lot_porte(text, text) from public, anon;
grant execute on function public.pilotage_lot_porte(text, text) to authenticated;

-- Texte du 125 repris tel quel, quatre champs ajoutés (bailleur, étage, complément, porte)
create or replace function pilotage.cles_json(p_asset text, p_trousseau bigint, p_histo boolean) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with mv as (
    select m.*, case m.qui when 'membre' then coalesce((select mb.prenom from pilotage.membres mb where mb.user_id = m.membre_id), 'Membre') else m.nom end as detenteur,
      (select mb.prenom from pilotage.membres mb where mb.user_id = m.par) as saisi_par
    from pilotage.cles_mouvements m where m.supprime_le is null
      and (m.asset_id = p_asset or (p_asset is null and m.asset_id is null and m.trousseau_id = p_trousseau))),
  tr as (select t.* from pilotage.cles_trousseaux t where t.supprime_le is null
      and (t.asset_id = p_asset or (p_asset is null and t.asset_id is null and t.id = p_trousseau))),
  etats as (  -- dernier mouvement par trousseau ; clé 0 = mouvements notés sans trousseau
    select distinct on (coalesce(trousseau_id, 0)) coalesce(trousseau_id, 0) as k, type_mouvement as type, date_mouvement as date, qui, detenteur, motif
    from mv order by coalesce(trousseau_id, 0), date_mouvement desc, id desc)
  select jsonb_build_object(
    'asset_id', l.id, 'cle', coalesce(l.id, 't' || p_trousseau), 'libre', l.id is null,
    'lot', coalesce(nullif(l.reference, ''), l.id), 'nature', l.nature, 'adresse', l.adresse,
    'libelle', case when l.id is null then (select t.libelle from tr t limit 1) end,
    'mandat', (select o.data->>'reference' from pilotage.objets o where o.type = 'ManagementContract' and o.id = l.mandat_id),
    -- 129 : bailleur du mandat, étage lu dans Rivage, complément d'adresse Rivage, porte saisie dans le pilotage (Rivage n'a pas ce champ)
    'bailleur', case when l.id is not null then pilotage.bailleurs_mandat(l.mandat_id) end,
    'etage', (select a.data->'floor' from pilotage.objets a where a.type = 'Asset' and a.id = l.id),
    'complement', (select nullif(a.data->'address'->>'complement', '') from pilotage.objets a where a.type = 'Asset' and a.id = l.id),
    'porte', (select p.porte from pilotage.lots_portes p where p.asset_id = l.id),
    'trousseaux', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'numero', t.numero, 'agence', t.agence, 'agence_nom', a.nom,
         'composition', t.composition, 'note', t.note, 'a_verifier', t.a_verifier, 'libelle', t.libelle,
         'etat', (select to_jsonb(e) - 'k' from etats e where e.k = t.id),
         -- même numéro dans la même agence sur un autre lot ou d'autres clés : trousseau commun à l'immeuble, ou erreur à corriger
         'aussi_sur', (select jsonb_agg(distinct coalesce('lot ' || coalesce(nullif(l2.reference, ''), l2.id), t2.libelle))
                       from pilotage.cles_trousseaux t2 left join pilotage.v_lots l2 on l2.id = t2.asset_id
                       where t2.supprime_le is null and t2.id <> t.id and (t2.asset_id is distinct from t.asset_id or t.asset_id is null)
                         and t2.numero = t.numero and t2.agence is not distinct from t.agence))
       order by t.id) from tr t left join pilotage.cles_agences a on a.code = t.agence), '[]'::jsonb),
    'etat_lot', (select to_jsonb(e) - 'k' from etats e where e.k = 0),
    'sorties', (select count(*) from etats e where e.type = 'prise' and (e.k = 0 or e.k in (select id from tr))),
    'dernier', (select jsonb_build_object('type', m.type_mouvement, 'date', m.date_mouvement, 'detenteur', m.detenteur, 'motif', m.motif) from mv m order by m.date_mouvement desc, m.id desc limit 1),
    'mouvements', case when p_histo then coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'type', m.type_mouvement, 'date', m.date_mouvement, 'qui', m.qui,
         'detenteur', m.detenteur, 'motif', m.motif, 'commentaire', m.commentaire, 'trousseau', (select t.numero from pilotage.cles_trousseaux t where t.id = m.trousseau_id),
         'source', m.source, 'saisi_par', m.saisi_par, 'saisi_le', m.le, 'par_id', m.par) order by m.date_mouvement desc, m.id desc) from mv m), '[]'::jsonb) end)
  from (select 1) x left join pilotage.v_lots l on l.id = p_asset
  where (p_asset is not null and l.id is not null) or (p_asset is null and exists (select 1 from tr))
$$;

select (pilotage.cles_json(t.asset_id, null, false) ?& array['bailleur', 'etage', 'porte']) as champs_ajoutes from pilotage.cles_trousseaux t where t.asset_id is not null limit 1;
