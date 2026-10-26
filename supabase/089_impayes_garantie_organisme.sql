-- 089 — Impayés : « Garantie » et « Organisme » ne font plus qu'un (remarque de Nicolas du 27/10).
-- Constat : la fiche demandait l'organisme (« À renseigner ») alors que la garantie était déjà saisie (reprise Monday) ;
-- 19 dossiers avaient l'organisme vide, dont les 6 nouveaux dossiers du 086.
-- Désormais la garantie et l'organisme restent synchronisés dans la base, dans les deux sens :
--   GLI ZELOK = Zelok, TRANSFERT MILA = Mila, CAUTION SMARTGARANT = Smart Garant, CAUTION GARANTME = Garantme,
--   VISALE = Visale, PAS DE GARANTIE = Sans garantie.
-- « CDT VIA HUISSIER » et « AVOCAT » ne désignent pas d'organisme : l'organisme reste vide (décision à prendre par Nicolas).
begin;

create or replace function pilotage.organisme_de_garantie(p_garantie text) returns text
language sql immutable as $$
  select case upper(trim(coalesce(p_garantie, '')))
    when 'GLI ZELOK' then 'zelok' when 'TRANSFERT MILA' then 'mila' when 'CAUTION SMARTGARANT' then 'smartgarant'
    when 'CAUTION GARANTME' then 'garantme' when 'VISALE' then 'visale' when 'PAS DE GARANTIE' then 'aucun' end
$$;

create or replace function pilotage.garantie_d_organisme(p_organisme text) returns text
language sql immutable as $$
  select case p_organisme when 'zelok' then 'GLI ZELOK' when 'mila' then 'TRANSFERT MILA' when 'smartgarant' then 'CAUTION SMARTGARANT'
    when 'garantme' then 'CAUTION GARANTME' when 'visale' then 'VISALE' when 'aucun' then 'PAS DE GARANTIE' end
$$;

create or replace function pilotage.impayes_synchro_garantie() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.garantie is distinct from old.garantie then
    -- la garantie saisie (ou reprise de Monday) donne l'organisme
    if pilotage.organisme_de_garantie(new.garantie) is not null then new.organisme := pilotage.organisme_de_garantie(new.garantie); end if;
  elsif new.organisme is distinct from old.organisme and new.organisme is not null then
    -- l'organisme choisi (déclaration Zelok du mois, ancien sélecteur) met la garantie à jour
    new.garantie := pilotage.garantie_d_organisme(new.organisme);
  end if;
  if new.organisme is null and new.garantie is null and new.bail_id is not null then
    new.organisme := pilotage.organisme_bail(new.bail_id);
    new.garantie := pilotage.garantie_d_organisme(new.organisme);
  end if;
  return new;
end $$;

drop trigger if exists impayes_synchro_garantie on pilotage.impayes;
create trigger impayes_synchro_garantie before insert or update of garantie, organisme, bail_id on pilotage.impayes
for each row execute function pilotage.impayes_synchro_garantie();

-- Rattrapage des dossiers existants
update pilotage.impayes set organisme = pilotage.organisme_de_garantie(garantie)
where organisme is null and pilotage.organisme_de_garantie(garantie) is not null;

commit;

-- Contrôle (attendu : seuls restent sans organisme les dossiers « CDT VIA HUISSIER », « AVOCAT » et 1 « Fait »)
select coalesce(garantie, '(vide)') garantie, count(*) sans_organisme, count(*) filter (where groupe <> 'Clôturé') dont_en_cours
from pilotage.impayes where organisme is null group by 1 order by 2 desc;
