-- 131 : liste « À louer » mise à jour avec la liste des biens à mettre en pub donnée par Nicolas le 06/11/2026 (bloc 1 sur 1)
--  Lots retrouvés dans Rivage (bailleur du mandat et locataire du bail en cours de sortie) :
--   320 CHATELAIN, bail 381 FERET / GERARD (1er étage, fin 03/12/2026)   322 CHATELAIN, bail 370 ABSALON / LAURENT (fin 30/06/2026)
--   342 PICOU ET GRIMBERT, bail 414 PETIT (fin 03/12/2026)               406 SCI BENGRIPIC (M. Grimbert), bail 481 PENA (fin 29/09/2026)
--   272 et 279 TAUSSAC, les deux appartements rue Saint-Spire              140 SPLICHIN ET SLEPAC, bail 158 MAMBIKI (fin 30/08/2026)
--   303 NEFYP IMMO, bail 356 (fin 02/11/2026)                              100 CHAUVIN, bail 104 (fin 05/09/2026)
--  Déjà dans la liste, inchangés : SYLVANIS 437 et 438, SOUMER 399 et 400.
--  Écartés sur réponse de Nicolas : SCHIBER (erreur dans la liste), BENGRIPIC 381. LÉOGANE : absent de Rivage, à ajouter une fois créé.
--  Même effet que le bouton « Mettre en location » (pilotage_a_louer_maj, action ajouter), y compris le rappel « permis de louer à
--  demander » dans les communes à autorisation préalable. Date de disponibilité : la fin du bail, ou aujourd'hui si elle est passée.
--  Un lot sort tout seul de la liste à la création de son nouveau bail dans Rivage. Rejouable.

do $$
declare r record; n integer := 0;
begin
  for r in
    select l.id, coalesce(nullif(l.reference, ''), l.id) as lot, o.data->>'management_contract_id' as mandat,
           (select max(pilotage.sortie_prevue(b.id)) from pilotage.v_baux b where b.lot_id = l.id and b.statut = 'move_out') as sortie
      from pilotage.v_lots l join pilotage.objets o on o.type = 'Asset' and o.id = l.id
     where l.reference in ('320', '322', '342', '406', '272', '279', '140', '303', '100')
       and o.data->>'management_contract_id' is not null
       and not exists (select 1 from pilotage.lots_a_louer a where a.asset_id = l.id and a.sorti_le is null)
  loop
    insert into pilotage.lots_a_louer (asset_id, disponible_le, motif)
    values (r.id, greatest(r.sortie, current_date), 'Liste des biens à mettre en pub du 06/11/2026')
    on conflict (asset_id) do update set depuis = current_date, disponible_le = excluded.disponible_le, motif = excluded.motif,
      loyer_prevu = null, note = null, par = null, sorti_le = null, sorti_motif = null;
    if pilotage.permis_lot(r.id)->>'regime' in ('autorisation', 'a_verifier')
       and not exists (select 1 from pilotage.permis_demandes d where d.asset_id = r.id and d.close_le is null
                       and (d.reponse is null or (d.reponse in ('accord', 'tacite') and d.reponse_le > current_date - interval '2 years'))) then
      perform pilotage.permis_suivi(r.mandat, r.id, 'permis_a_demander', 'Permis de louer à demander (lot ' || r.lot || ')', current_date, null);
    end if;
    n := n + 1;
  end loop;
  raise notice '% lot(s) mis en location', n;
end $$;

select l.reference as lot, pilotage.bailleurs_mandat(l.mandat_id) as bailleur, l.adresse, a.disponible_le, a.motif
  from pilotage.lots_a_louer a join pilotage.v_lots l on l.id = a.asset_id
 where a.sorti_le is null order by bailleur, lot;
