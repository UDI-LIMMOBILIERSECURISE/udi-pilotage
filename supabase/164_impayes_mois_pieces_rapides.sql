-- 164 : onglet Impayés « À faire ce mois-ci » encore trop lent (constat de Nicolas du 13/11/2026 au soir : « les boutons ne marchent pas »)
--  Mesuré le 13/11 à 19 h : public.pilotage_impayes_mois prend 3,2 à 4,7 s, et 8,7 s (délai dépassé, erreur 500) à 19 h 04.
--  L'écran affichait alors « Rien à déclarer » au lieu de l'erreur, et chaque bouton relance ce calcul : d'où l'impression de boutons morts.
--  Cause : pilotage.pieces_declaration (3,5 s pour 47 baux) ; par bail, il relisait les vues v_baux / v_lots (≈ 40 ms) et cherchait le compte
--  des dépôts de garantie du lot sans index (≈ 9 ms).
--  Correctif, sans changement de résultat (lot et mandat identiques pour les 47 baux du 13/11) :
--   - lot et mandat lus directement (bail → lot → mandat), sans passer par les vues ;
--   - index sur les comptes Rivage (AccountingAccount) par bail et par lot.
--  Le 162 (loyer du mois en attente avant le 16) réduit aussi la liste : 47 baux le 13/11, dont une majorité de loyers de novembre
--  encore en cours de prélèvement. Passer le 162 avant celui-ci.
--  Bloc unique.

begin;

create index if not exists objets_compte_bail on pilotage.objets ((data->>'leasing_contract_id')) where type = 'AccountingAccount';
create index if not exists objets_compte_lot on pilotage.objets ((data->>'asset_id')) where type = 'AccountingAccount';

create or replace function pilotage.pieces_declaration(p_bail text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare v_lot text; v_mandat text; ms jsonb; bs jsonb;
begin
  select b.data->>'asset_id', a.data->>'management_contract_id' into v_lot, v_mandat
    from pilotage.objets b left join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id'
   where b.type = 'LeasingContract' and b.id = p_bail;
  if not found then return null; end if;
  ms := public.pilotage_mandat_source(v_mandat);
  bs := public.pilotage_lecture_source(p_bail);
  return jsonb_build_array(
    jsonb_build_object('piece', 'Mandat de gestion', 'ok', ms is not null, 'detail', coalesce(ms->>'libelle', 'Absent dans Rivage')),
    jsonb_build_object('piece', 'Bail', 'ok', bs is not null, 'detail', coalesce(bs->>'libelle', 'Absent dans Rivage')),
    jsonb_build_object('piece', 'Extrait de compte locataire', 'ok', exists (select 1 from pilotage.objets c where c.type = 'AccountingAccount' and c.data->>'leasing_contract_id' = p_bail and c.data->>'holder_type' = 'tenant'),
                       'detail', 'Généré à la date du jour (bouton « Extrait de compte »)'),
    jsonb_build_object('piece', 'Preuve d''encaissement du dépôt de garantie',
                       'ok', exists (select 1 from pilotage.objets c where c.type = 'AccountingAccount' and c.data->>'asset_id' = v_lot and c.data->>'general_number' = '1651'
                                     and coalesce((c.data->>'credit_in_cents')::numeric, 0) > 0),
                       'detail', 'Écriture au compte des dépôts de garantie du lot (avec l''extrait)'),
    jsonb_build_object('piece', 'RIB de l''agence', 'ok', true, 'detail', 'Toujours le même'));
end $$;

commit;
