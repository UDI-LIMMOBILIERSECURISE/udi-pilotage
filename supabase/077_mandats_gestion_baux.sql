-- 077 — Onglet Mandats chez la gestionnaire et la comptable : « Accès refusé » corrigé.
-- La page charge aussi la liste des baux de mise en location (pilotage_baux_a_valider), restée réservée à la direction
-- par le 076. Ouverte en lecture à la gestion et à la comptabilité (aucun montant de commission dans cette liste ;
-- la validation des baux pour les commissions reste à la direction).

begin;

do $$
declare def text; ancien text := $a$if pilotage.mon_role() not in ('direction', 'superviseur') then raise exception 'Accès refusé'; end if;$a$; n int;
begin
  select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace s on s.oid = p.pronamespace
  where s.nspname = 'public' and p.proname = 'pilotage_baux_a_valider';
  n := (length(def) - length(replace(def, ancien, ''))) / length(ancien);
  if n <> 1 then raise exception 'Critère attendu trouvé % fois (1 attendu) : rien n''est modifié', n; end if;
  execute replace(def, ancien,
    $a$if pilotage.mon_role() not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Accès refusé'; end if;$a$);
end $$;

commit;

select prosrc like '%''gestionnaire'', ''comptable''%' ouvert_a_la_gestion from pg_proc where proname = 'pilotage_baux_a_valider';
