-- 078 — Onglet Mandats : un mandat dont un lot a un bail en cours est « Loué », même si ce bail est antérieur au mandat.
-- Constat du 26/10 (Fleurs de Blé Noir n° 388 et 391) : le statut « Loué » ne reconnaissait que le bail de mise en location
-- signé APRÈS le début du mandat (celui qui sert aux commissions). Les biens arrivés déjà loués restaient dans
-- « Dossier complet validé » : 25 mandats de 2026 concernés.
-- Seul l'affichage du statut change ; le calcul des commissions (bail de mise en location) n'est pas modifié.

begin;

create or replace function pilotage.mandat_loue(p_mandat text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select exists (select 1 from pilotage.v_baux b join pilotage.v_lots l on l.id = b.lot_id
                 where l.mandat_id = p_mandat and b.statut in ('created', 'move_in', 'in_progress')
                   and (b.fin is null or b.fin > current_date))
$$;

do $$
declare def text; ancien text := $a$when b.id is not null then 'Loué'$a$; n int;
begin
  select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace s on s.oid = p.pronamespace
  where s.nspname = 'pilotage' and p.proname = 'dossier_mandat';
  n := (length(def) - length(replace(def, ancien, ''))) / length(ancien);
  if n <> 1 then raise exception 'Critère attendu trouvé % fois (1 attendu) : rien n''est modifié', n; end if;
  execute replace(def, ancien, $a$when b.id is not null or pilotage.mandat_loue(p_mandat) then 'Loué'$a$);
end $$;

commit;

select d->>'statut' statut, count(*) from pilotage.v_mandats m, lateral (select pilotage.dossier_mandat(m.id) d) x
where m.debut >= date '2026-01-01' group by 1 order by 1;
