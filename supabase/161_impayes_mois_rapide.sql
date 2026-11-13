-- 161 : page Impayés, « canceling statement due to statement timeout » (constat de Nicolas du 13/11/2026)
--  Le bloc du mois (public.pilotage_impayes_mois) prenait environ 7,7 s, à la limite des 8 s accordées à une requête de
--  l'application : la page tombait en erreur une fois sur deux (12 expirations dans les journaux entre 11 h et 13 h 35).
--  Cause : pour chacun des 48 baux à déclarer, pilotage.pieces_declaration cherchait deux fois la source du mandat et deux fois
--  la source du bail, et public.pilotage_lecture_source (fonction SQL « en ligne ») relançait la recherche des documents du bail
--  plusieurs fois par appel.
--  Correctif, sans changement de résultat (contrôlé sur les 48 baux : 0 différence) :
--   - public.pilotage_lecture_source : la liste des documents est calculée une seule fois ;
--   - pilotage.pieces_declaration : sources du mandat et du bail calculées une seule fois par bail.
--  Mesuré avant le script : 7,4 s pour les pièces ; avec le correctif : 2,7 s.
--  Bloc unique.

begin;

create or replace function public.pilotage_lecture_source(p_bail text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare d jsonb := pilotage.lecture_documents(p_bail);
begin
  return case when jsonb_array_length(d) > 0
              then jsonb_build_object('upload_id', d->0->>'upload_id', 'libelle', d->0->>'libelle', 'url', d->0->>'url') end;
end $$;

create or replace function pilotage.pieces_declaration(p_bail text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare v_lot text; v_mandat text; ms jsonb; bs jsonb;
begin
  select l.id, l.mandat_id into v_lot, v_mandat from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id where b.id = p_bail;
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
