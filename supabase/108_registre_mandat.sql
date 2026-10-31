-- 108 — Contrôle d'entrée du mandat : plus d'écart entre le n° du mandat et le n° de registre Rivage (Nicolas, 31/10/2026).
-- Constat sur le mandat 378 : « Rivage : N° 378 · le mandat indique : n° 425 ». Le numéro d'inscription de Rivage est son
-- numéro interne ; le numéro porté sur le mandat est celui du registre UDI tenu dans MyNotary (ici 425, repris dans le nom du
-- mandat Rivage). Les deux n'ont pas à concorder : l'écart n'est plus signalé. Le point affiche les deux numéros et reste
-- conforme d'office ; il ne signale plus qu'un numéro Rivage absent.
-- Fonction modifiée : controle_mandat (remplacement ciblé, contrôlé). Un seul bloc.

begin;

do $do$
declare d text; a2 text; e2 text;
  avant constant text := $r$detail := 'N° ' || coalesce(o->>'register_number', '—');
          vide := o->>'register_number' is null;$r$;
  ecart constant text := $r$if valeur_ia is not null and nullif(valeur_ia->>'numero', '') is not null and valeur_ia->>'numero' <> coalesce(o->>'register_number', '') then
            ia_diff := 'n° ' || (valeur_ia->>'numero'); end if;
          ia_ok := ia_diff is null and nullif(valeur_ia->>'numero', '') is not null;$r$;
begin
  -- Fins de ligne ramenées à \n des deux côtés (l'éditeur Supabase peut envoyer des \r\n)
  d := replace(pg_get_functiondef('pilotage.controle_mandat(text)'::regprocedure), E'\r\n', E'\n');
  a2 := replace(avant, E'\r\n', E'\n'); e2 := replace(ecart, E'\r\n', E'\n');
  if position('registre UDI' in d) = 0 then
    if position(a2 in d) = 0 or position(e2 in d) = 0 then raise exception 'controle_mandat : point « registre » introuvable'; end if;
    d := replace(d, a2, $r$detail := 'N° Rivage ' || coalesce(o->>'register_number', '—')
                 || coalesce(' · n° du registre UDI (MyNotary) porté sur le mandat : ' || nullif(valeur_ia->>'numero', ''), '');
          vide := o->>'register_number' is null;$r$);
    -- 108 : numéro du registre UDI et numéro interne Rivage distincts par construction : pas de comparaison
    d := replace(d, e2, $r$ia_ok := not vide;$r$);
    execute d;
  end if;
end $do$;

commit;

-- Vérification : mandat 378, point « registre » conforme
-- select i->>'statut', i->>'detail' from jsonb_array_elements(pilotage.controle_mandat('mc_b86a143e924cad5677bbc811')->'items') i where i->>'cle' = 'm_rv_registre';
