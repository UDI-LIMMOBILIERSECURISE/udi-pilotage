-- 104 — Impayés : la section et la garantie restent d'accord (signalement d'Audrey du 30/10/2026, 17 h 39).
-- Constat : dossier n° 9 (bail 282, KALALA Isaac). Audrey a passé la section de « GLI ZELOK » à « TRANSFERT MILA » à 17 h 27.
-- La page Impayés (classée par section) le montre bien en Transfert Mila, mais l'organisme est resté Zelok : la garantie
-- n'avait pas changé, et c'est la garantie qui donne l'organisme (089-090). Le dossier restait donc dans l'actualisation
-- mensuelle « Zelok » de Ma journée et dans la fiche des dossiers Zelok à actualiser. Seul dossier dans ce cas au 31/10.
-- Correction :
--   1. Section GLI ZELOK, TRANSFERT MILA, SMARTGARANT ou VISALE choisie : la garantie et l'organisme suivent.
--   2. Garantie changée sur un dossier rangé dans l'une de ces sections : la section suit.
--   Les sections de procédure (Huissier, Avocat, Liquidation) et « Clôturé » ne touchent pas à la garantie, et inversement.
--   3. Dossier n° 9 remis d'accord : garantie TRANSFERT MILA, organisme Mila.
-- Un seul bloc.

begin;

create or replace function pilotage.organisme_de_section(p_groupe text) returns text
language sql immutable as $$
  select case upper(trim(coalesce(p_groupe, '')))
    when 'GLI ZELOK' then 'zelok' when 'TRANSFERT MILA' then 'mila' when 'SMARTGARANT' then 'smartgarant' when 'VISALE' then 'visale' end
$$;

create or replace function pilotage.section_d_organisme(p_organisme text) returns text
language sql immutable as $$
  select case p_organisme when 'zelok' then 'GLI ZELOK' when 'mila' then 'TRANSFERT MILA' when 'smartgarant' then 'SMARTGARANT' when 'visale' then 'VISALE' end
$$;

create or replace function pilotage.impayes_synchro_garantie() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.groupe is distinct from old.groupe and pilotage.organisme_de_section(new.groupe) is not null
     and new.garantie is not distinct from old.garantie then
    -- 104 : la section choisie (garantie) donne la garantie et l'organisme
    new.organisme := pilotage.organisme_de_section(new.groupe);
    new.garantie := pilotage.garantie_d_organisme(new.organisme);
  elsif tg_op = 'INSERT' or new.garantie is distinct from old.garantie then
    if pilotage.organisme_de_garantie(new.garantie) is not null then new.organisme := pilotage.organisme_de_garantie(new.garantie); end if;
  elsif new.organisme is distinct from old.organisme and new.organisme is not null
        and pilotage.organisme_de_garantie(new.garantie) is distinct from new.organisme then
    new.garantie := pilotage.garantie_d_organisme(new.organisme);
  end if;
  if new.organisme is null and new.garantie is null and new.bail_id is not null then
    new.organisme := pilotage.organisme_bail(new.bail_id);
    new.garantie := pilotage.garantie_d_organisme(new.organisme);
  end if;
  -- 104 : garantie ou organisme changé sur un dossier rangé dans une section de garantie : la section suit
  if tg_op = 'UPDATE' and new.groupe is not distinct from old.groupe and pilotage.organisme_de_section(new.groupe) is not null
     and pilotage.section_d_organisme(new.organisme) is not null and pilotage.organisme_de_section(new.groupe) <> new.organisme then
    new.groupe := pilotage.section_d_organisme(new.organisme);
  end if;
  return new;
end $$;

update pilotage.impayes set garantie = 'TRANSFERT MILA' where id = 9 and groupe = 'TRANSFERT MILA' and organisme = 'zelok';

select pilotage.executer_controles();

commit;

-- Vérification : aucun dossier dont la section de garantie et l'organisme divergent (doit renvoyer 0)
-- select count(*) from pilotage.impayes where pilotage.organisme_de_section(groupe) is not null and organisme is distinct from pilotage.organisme_de_section(groupe);
