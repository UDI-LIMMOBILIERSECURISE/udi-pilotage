-- 079 — Cartes des mandats et des baux : type de bien, adresse et coordonnées des parties (demande de Nicolas du 26/10).
-- Une seule lecture pour toutes les cartes : pour chaque bail en cours, le type et l'adresse du lot, les locataires et
-- les bailleurs (nom, téléphone, e-mail, repris de Rivage) ; pour chaque mandat, le type et l'adresse de chaque lot et
-- les bailleurs. Lecture réservée aux membres de l'équipe (même accès que les onglets Baux et Mandats).

begin;

create or replace function public.pilotage_infos_cartes() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'baux', coalesce((select jsonb_object_agg(b.id, jsonb_build_object(
        'nature', l.nature, 'adresse', l.adresse, 'surface', l.surface,
        'parties', pilotage.contacts_bail(b.id)))
      from pilotage.v_baux b join pilotage.baux_cache c on c.bail_id = b.id left join pilotage.v_lots l on l.id = b.lot_id), '{}'::jsonb),
    'mandats', coalesce((select jsonb_object_agg(m.id, jsonb_build_object(
        'lots', coalesce((select jsonb_agg(jsonb_build_object('nature', l.nature, 'adresse', l.adresse, 'surface', l.surface) order by l.reference)
                          from pilotage.v_lots l where l.mandat_id = m.id), '[]'::jsonb),
        'parties', pilotage.contacts_mandat(m.id)))
      from pilotage.v_mandats m), '{}'::jsonb));
end $$;

revoke all on function public.pilotage_infos_cartes() from public, anon;
grant execute on function public.pilotage_infos_cartes() to authenticated;

commit;

select (select count(*) from jsonb_object_keys(r->'baux')) baux, (select count(*) from jsonb_object_keys(r->'mandats')) mandats
from (select jsonb_build_object(
  'baux', (select jsonb_object_agg(b.id, 1) from pilotage.v_baux b join pilotage.baux_cache c on c.bail_id = b.id),
  'mandats', (select jsonb_object_agg(m.id, 1) from pilotage.v_mandats m)) r) x;
