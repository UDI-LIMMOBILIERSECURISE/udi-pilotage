-- 048 : liens « Corriger dans Rivage » / « Déposer dans Rivage » des mandats
-- L'adresse https://rivage.immo/landlords/profiles/p_… ne renvoie qu'un fragment de page (sans mise en forme).
-- La page complète de la fiche propriétaire est https://rivage.immo/landlords/profiles?profile_id=p_…
-- (vérifié dans Rivage le 19/10). Le mandat lui-même n'a pas de page propre : il s'ouvre en fenêtre depuis l'onglet « Mandats »
-- de cette fiche (/creation_flow/management_contracts/mc_…/edit n'est qu'un fragment).
-- Le script réécrit l'adresse dans toutes les fonctions qui la construisent, puis corrige les alertes déjà enregistrées.
-- À passer après le 047. Rien n'est écrit dans Rivage.

do $$
declare f record; def text; n int := 0;
begin
  for f in
    select p.oid, n.nspname, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('pilotage', 'public') and p.prokind = 'f'
      and pg_get_functiondef(p.oid) like '%https://rivage.immo/landlords/profiles/''%'
  loop
    def := replace(pg_get_functiondef(f.oid), 'https://rivage.immo/landlords/profiles/''', 'https://rivage.immo/landlords/profiles?profile_id=''');
    execute def;
    n := n + 1;
    raise notice 'lien corrigé : %.%', f.nspname, f.proname;
  end loop;
  raise notice '% fonction(s) corrigée(s)', n;
end $$;

update pilotage.alertes
   set lien_rivage = replace(lien_rivage, 'https://rivage.immo/landlords/profiles/', 'https://rivage.immo/landlords/profiles?profile_id=')
 where lien_rivage like 'https://rivage.immo/landlords/profiles/p\_%';

-- Contrôle : les deux colonnes doivent valoir 0
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname in ('pilotage', 'public') and p.prokind = 'f'
           and pg_get_functiondef(p.oid) like '%https://rivage.immo/landlords/profiles/''%') fonctions_restantes,
       (select count(*) from pilotage.alertes where lien_rivage like 'https://rivage.immo/landlords/profiles/p\_%') alertes_restantes;
