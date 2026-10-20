-- 058 : contrôle des mandats et des baux ajoutés dans Rivage, même anciens (Nicolas, 20/10/2026)
--   1. Date d'arrivée de chaque objet dans le pilotage (pilotage.objets.recu_le) : un mandat ou un bail saisi aujourd'hui
--      avec une date ancienne est reconnu comme nouveau.
--   2. Bail : contrôle d'entrée exigé s'il est arrivé après la date de départ du contrôle, même si son début est antérieur.
--   3. Mandat : nouvelle alerte « contrôle d'entrée du mandat à valider » tant que le GO n'est pas donné.
--   4. Échéance du mandat : quand la date de fin de Rivage est passée et que le mandat se reconduit tacitement,
--      le suivi part de la prochaine échéance réelle (date de fin + reconductions), et non de la date passée.

-- 1. Date d'arrivée : le portefeuille déjà présent est marqué ancien ; les arrivées suivantes prennent la date du jour.
--    Le mandat 11 et le bail 33, saisis le 20/10/2026 et arrivés avant ce script, sont marqués à leur date d'arrivée.
alter table pilotage.objets add column if not exists recu_le timestamptz;
update pilotage.objets set recu_le = '-infinity' where recu_le is null;
update pilotage.objets set recu_le = maj_le
 where (type = 'ManagementContract' and data->>'reference' in ('10', '11'))
    or (type = 'LeasingContract' and data->>'reference' = '33');
alter table pilotage.objets alter column recu_le set default now(), alter column recu_le set not null;

-- 4. Prochaine échéance réelle d'un mandat
create or replace function pilotage.mandat_echeance_effective(d jsonb) returns date
language plpgsql stable as $$
declare fin date := nullif(d->>'end_date', '')::date; an integer := nullif(d->>'renewal_duration_years', '')::integer; k integer := 0;
begin
  if fin is null or d->>'renewal_type' <> 'tacit' or coalesce(an, 0) <= 0 then return fin; end if;
  while pilotage.ajouter_mois(fin, k * an * 12) < current_date and k < 100 loop k := k + 1; end loop;
  return pilotage.ajouter_mois(fin, k * an * 12);
end $$;

-- 3. Règle d'alerte du contrôle d'entrée des mandats
insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication, parametres)
values ('mandat_controle_entree', 'Contrôle d''entrée du mandat à valider', 'Mandat, compta, agence', 'haute', 'tache', true,
        'Chaque mandat ajouté dans Rivage, même ancien, passe par le contrôle d''entrée (pièces, croisement avec Rivage) jusqu''au GO.', '[]'::jsonb)
on conflict (cle) do nothing;

do $$
declare
  rempl jsonb := '[
    ["pilotage.suivi_detections()", "or b.debut >= (select valeur::date from pilotage.parametres where cle = ''controle_entree_depuis''))", "or b.debut >= (select valeur::date from pilotage.parametres where cle = ''controle_entree_depuis'') or (select o2.recu_le from pilotage.objets o2 where o2.type = ''LeasingContract'' and o2.id = b.id) >= (select valeur::date from pilotage.parametres where cle = ''controle_entree_depuis''))", 1],
    ["pilotage.mandats_suivis_auto()", "(m.data->>''end_date'')::date", "pilotage.mandat_echeance_effective(m.data)", 3],
    ["pilotage.mandats_suivis_auto()", "  return n;", "  -- Mandat arrivé depuis le dernier calcul : son contrôle d''entrée est calculé tout de suite\r\n  insert into pilotage.mandats_cache (mandat_id, ligne, calcule_le)\r\n  select m.id, pilotage.ligne_audit(pilotage.controle_mandat(m.id)), now() from pilotage.objets m\r\n  where m.type = ''ManagementContract'' and m.supprime_le is null and m.data->>''status'' = ''active''\r\n    and not exists (select 1 from pilotage.mandats_cache c where c.mandat_id = m.id)\r\n  on conflict (mandat_id) do nothing;\r\n  return n;", 1],
    ["pilotage.suivi_detections_mandats()", "  group by o.mandat_id", "  group by o.mandat_id\r\n  union all\r\n  select ''mandat_controle_entree'', ''ManagementContract'', m.id,\r\n         ''Mandat '' || coalesce(m.data->>''reference'', '''') || '' : contrôle d''''entrée à valider'',\r\n         coalesce(c.ligne->>''restant'', ''?'') || '' point(s) à traiter avant le GO'',\r\n         ''https://rivage.immo/landlords/profiles?profile_id='' || coalesce(m.data->''profile_contracts_attributes''->0->>''profile_id'', '''')\r\n  from pilotage.objets m\r\n  left join pilotage.mandats_suivi s on s.mandat_id = m.id\r\n  left join pilotage.mandats_cache c on c.mandat_id = m.id\r\n  where m.type = ''ManagementContract'' and m.supprime_le is null and m.data->>''status'' = ''active''\r\n    and s.go_le is null and s.retire_le is null\r\n    and (m.recu_le >= (select valeur::date from pilotage.parametres where cle = ''controle_entree_depuis'')\r\n         or nullif(m.data->>''signed_at'', '''')::date >= (select valeur::date from pilotage.parametres where cle = ''controle_entree_depuis''))", 1]
  ]';
  fns text[]; f text; def text; x jsonb; n int;
begin
  select array_agg(distinct e->>0) into fns from jsonb_array_elements(rempl) e;
  foreach f in array fns loop
    def := pg_get_functiondef(f::regprocedure);
    for x in select e from jsonb_array_elements(rempl) e where e->>0 = f loop
      n := (length(def) - length(replace(def, x->>1, ''))) / length(x->>1);
      if n <> (x->>3)::int then raise exception 'Code inattendu dans % : « % » trouvé % fois au lieu de %', f, x->>1, n, x->>3; end if;
      def := replace(def, x->>1, x->>2);
    end loop;
    execute def;
  end loop;
end $$;

-- Application immédiate (sans attendre les tâches planifiées)
select pilotage.mandats_suivis_auto();
select pilotage.executer_controles();

-- Contrôle : échéance du mandat 11 et alertes de contrôle d'entrée
select m.data->>'reference' mandat, o.prochaine echeance_suivie from pilotage.mandats_obligations o join pilotage.objets m on m.id = o.mandat_id
 where o.nature = 'mandat_echeance' and m.data->>'reference' = '11';
select regle, titre from pilotage.alertes where statut = 'ouverte' and regle in ('mandat_controle_entree', 'bail_controle_entree', 'mandat_suivi', 'mandat_suivi_retard') order by regle;
