-- Tous les membres actifs voient tous les tableaux de suivi (agence, sinistres, sorties et DG, comptabilité), sur tous les mandats.
-- Restent réservés : Mandats et commissions (direction, superviseur), Obligations, Règles, Équipe (direction).
create or replace function pilotage.voit_tableau(p_tableau text, p_mandat text) returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select pilotage.mon_role() is not null
$$;

create or replace function public.pilotage_tableaux_visibles() returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when pilotage.mon_role() is not null then '["agence","sinistres","dg","compta"]'::jsonb else '[]'::jsonb end
$$;
-- pilotage_agence : contrôle d'accès ramené à « membre actif » (voir migration pilotage_tableaux_pour_tous)
