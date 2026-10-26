-- 088 — Rattachement de 8 dossiers WeRoof en cours aux incidents créés dans Rivage le 26/10 (incidents n° 24 à 31), comme le 087.
-- Ces dossiers n'avaient pas de bail dans la reprise 086 (pas de locataire dans WeRoof) ; le lot a été retrouvé à la main
-- (adresse à un seul lot, mandat à un seul lot, nom de la locataire pour BIYAKA, lot 235 confirmé par Nicolas pour Athis-Mons).
-- Le lot est aussi reporté sur le dossier repris. Rien n'est supprimé ; vider incident_id suffit pour revenir en arrière.
begin;
update pilotage.travaux_monday t set incident_id = x.incident_id, lot_id = coalesce(t.lot_id, i.data->>'asset_id'),
       rattachement = coalesce(t.rattachement, '') || ' ; lot de l''incident Rivage (088)'
from (values
  (-28, 'inc_8d3f12fc2f8819d56e10a9d8'),
  (-31, 'inc_09eca16168b0ed6ed41f397e'),
  (-64, 'inc_03e51b71898709a5f9401cb0'),
  (-45, 'inc_67f944b0bbabf28fd6d7d4bf'),
  (-51, 'inc_9a38b88803cdccf07674c584'),
  (-53, 'inc_c0636bfe0bffd94763f0ae1c'),
  (-54, 'inc_122170f19429b552b1acbb93'),
  (-57, 'inc_ec8ed102abbb04751fdda2d4')
) as x(monday_id, incident_id)
join pilotage.objets i on i.type = 'Incident' and i.id = x.incident_id and i.supprime_le is null
where t.monday_id = x.monday_id and t.incident_id is null and (i.data->>'declared_at')::date = t.cree_le::date;
commit;
-- Contrôle (attendu : 29 rattachés au total, 21 du 087 + 8)
select count(*) filter (where incident_id is not null) rattaches from pilotage.travaux_monday;
