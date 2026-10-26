-- 090 — Impayés : « CDT VIA HUISSIER » et « AVOCAT » valent « Sans garantie » (décision de Nicolas du 27/10).
-- La garantie garde son libellé (huissier, avocat) ; l'organisme passe à « aucun ».
-- La synchronisation du 089 ne réécrit plus une garantie déjà compatible avec l'organisme choisi.
begin;

create or replace function pilotage.organisme_de_garantie(p_garantie text) returns text
language sql immutable as $$
  select case upper(trim(coalesce(p_garantie, '')))
    when 'GLI ZELOK' then 'zelok' when 'TRANSFERT MILA' then 'mila' when 'CAUTION SMARTGARANT' then 'smartgarant'
    when 'CAUTION GARANTME' then 'garantme' when 'VISALE' then 'visale'
    when 'PAS DE GARANTIE' then 'aucun' when 'CDT VIA HUISSIER' then 'aucun' when 'AVOCAT' then 'aucun' end
$$;

create or replace function pilotage.impayes_synchro_garantie() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.garantie is distinct from old.garantie then
    if pilotage.organisme_de_garantie(new.garantie) is not null then new.organisme := pilotage.organisme_de_garantie(new.garantie); end if;
  elsif new.organisme is distinct from old.organisme and new.organisme is not null
        and pilotage.organisme_de_garantie(new.garantie) is distinct from new.organisme then
    new.garantie := pilotage.garantie_d_organisme(new.organisme);
  end if;
  if new.organisme is null and new.garantie is null and new.bail_id is not null then
    new.organisme := pilotage.organisme_bail(new.bail_id);
    new.garantie := pilotage.garantie_d_organisme(new.organisme);
  end if;
  return new;
end $$;

update pilotage.impayes set organisme = 'aucun' where organisme is null and upper(trim(garantie)) in ('CDT VIA HUISSIER', 'AVOCAT');

commit;

-- Contrôle (attendu : 12 dossiers « aucun » avec leur garantie d'origine ; reste sans organisme : 1 « Fait »)
select garantie, organisme, count(*) from pilotage.impayes where upper(trim(garantie)) in ('CDT VIA HUISSIER', 'AVOCAT') or organisme is null group by 1, 2 order by 1;
