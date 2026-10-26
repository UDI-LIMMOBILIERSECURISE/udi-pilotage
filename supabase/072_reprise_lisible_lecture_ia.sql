-- 072 — Après la bascule : « Ma journée » lisible, lecture IA par dates métier, audit du stock lancé à 20 par jour.
-- Décisions de Nicolas du 26/10 :
--   date de référence (controle_entree_depuis) au 01/09/2026, date du barème en vigueur ;
--   un dossier est NOUVEAU s'il est signé (ou, pour un bail, commencé) depuis cette date, ou créé dans Rivage après
--   la reprise ; tout le reste est le STOCK, traité par l'audit (onglet Reprise), plus dans « Ma journée » ;
--   les 88 mandats de 2026 du stock passent par l'audit, plus en lecture IA d'office ;
--   audit du stock lancé, 20 lectures IA par jour.
-- Corrige aussi l'effet du 071 : le GO de reprise avait ouvert 88 suivis « pièces à obtenir du bailleur ».
--
-- Les fonctions existantes sont modifiées par remplacement d'un critère précis ; si le texte attendu n'est pas trouvé
-- exactement une fois, le script s'arrête sans rien changer.

begin;

-- 1. Date de référence
update pilotage.parametres set valeur = '2026-09-01' where cle = 'controle_entree_depuis';

create or replace function pilotage.date_reference() returns date
language sql stable as $$
  select coalesce((select valeur::date from pilotage.parametres where cle = 'controle_entree_depuis'), date '2026-09-01')
$$;

-- Dossier nouveau (mandat ou bail) : date métier depuis la date de référence, ou arrivé dans Rivage après la reprise
create or replace function pilotage.dossier_nouveau(p_type text, p_id text) returns boolean
language sql stable as $$
  select coalesce((
    select o.recu_le >= pilotage.date_reference()
        or nullif(o.data->>'signed_at', '')::date >= pilotage.date_reference()
        or (p_type = 'LeasingContract' and nullif(o.data->>'start_date', '')::date >= pilotage.date_reference())
    from pilotage.objets o where o.type = p_type and o.id = p_id), false)
$$;

-- 2. Remplacement des critères dans les fonctions existantes
do $$
declare
  t record; def text; n int;
begin
  for t in select * from (values
    -- Contrôle d'entrée des baux : seulement les baux nouveaux (le stock, y compris commercial, va à l'audit)
    ('pilotage', 'suivi_detections',
     $a$(b.ech->>'type') in ('commercial','derogatoire','professionnel') or b.debut >= (select valeur::date from pilotage.parametres where cle = 'controle_entree_depuis') or (select o2.recu_le from pilotage.objets o2 where o2.type = 'LeasingContract' and o2.id = b.id) >= (select valeur::date from pilotage.parametres where cle = 'controle_entree_depuis'))$a$,
     $a$pilotage.dossier_nouveau('LeasingContract', b.id))$a$),
    -- DG au-dessus du plafond : seulement les baux nouveaux
    ('pilotage', 'executer_controles',
     $a$and loyer_hc > 0 and depot_garantie > loyer_hc$a$,
     $a$and loyer_hc > 0 and depot_garantie > loyer_hc and pilotage.dossier_nouveau('LeasingContract', id)$a$),
    -- Dépôts de garantie : sorties depuis la date de référence et baux en cours (les sorties anciennes sont de l'historique)
    ('pilotage', 'suivi_detections_dg',
     $a$select * from pilotage.dg_dossiers() where not remboursee$a$,
     $a$select * from pilotage.dg_dossiers() where not remboursee and (depart is null or depart >= pilotage.date_reference())$a$),
    -- Pièces à obtenir du bailleur : seulement les mandats nouveaux, jamais sur un GO de reprise
    ('pilotage', 'mandats_pieces_auto',
     $a$where coalesce(s.valide_le, s.go_le) >= now() - interval '60 days' and s.retire_le is null$a$,
     $a$where coalesce(s.valide_le, s.go_le) >= now() - interval '60 days' and s.retire_le is null
             and pilotage.dossier_nouveau('ManagementContract', s.mandat_id) and coalesce(s.note, '') not like '%GO de reprise%'$a$),
    -- Lecture IA des baux : la date du bail remplace la date d'arrivée de la pièce (chargement de la GED sans effet)
    ('public', 'pilotage_baux_a_lire',
     $a$or pilotage.upload_recent(public.pilotage_lecture_source(b.id)->>'upload_id'))$a$,
     $a$or pilotage.dossier_nouveau('LeasingContract', b.id))$a$),
    -- Lecture IA des mandats : la date de signature remplace le 01/01/2026 écrit en dur
    ('public', 'pilotage_mandats_a_lire',
     $a$and (m.debut >= date '2026-01-01' or pilotage.dossier_recu('ManagementContract', m.id))$a$,
     $a$and pilotage.dossier_nouveau('ManagementContract', m.id)$a$),
    -- Lecture IA des EDL d'entrée : seulement ceux d'un bail nouveau
    ('public', 'pilotage_edl_a_lire',
     $a$and not exists (select 1 from pilotage.edl_lectures l where l.upload_id = u.id)$a$,
     $a$and not exists (select 1 from pilotage.edl_lectures l where l.upload_id = u.id)
        and exists (select 1 from pilotage.objets b where b.type = 'LeasingContract' and b.supprime_le is null
                      and (b.id = rr.rid or b.data->>'asset_id' = a.id) and pilotage.dossier_nouveau('LeasingContract', b.id))$a$)
  ) v(schema, fonction, ancien, nouveau) loop
    select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = t.schema and p.proname = t.fonction;
    if def is null then raise exception 'Fonction %.% introuvable', t.schema, t.fonction; end if;
    n := (length(def) - length(replace(def, t.ancien, ''))) / length(t.ancien);
    if n <> 1 then raise exception 'Critère attendu trouvé % fois dans %.% (1 attendu) : rien n''est modifié', n, t.schema, t.fonction; end if;
    execute replace(def, t.ancien, t.nouveau);
  end loop;
end $$;

-- 3. Les 88 suivis de pièces ouverts à tort par le GO de reprise (aucune relance faite)
delete from pilotage.mandats_obligations o
where o.nature = 'mandat_pieces'
  and exists (select 1 from pilotage.mandats_suivi s where s.mandat_id = o.mandat_id and coalesce(s.note, '') like '%GO de reprise%');

-- 4. Alertes devenues sans objet : clôturées tout de suite (sinon au prochain passage des contrôles)
select pilotage.executer_controles();
select pilotage.rattacher_alertes();

-- 5. Lecture IA relancée et audit du stock lancé (20 lectures par jour)
select jobname, cron.alter_job(jobid, active := true) from cron.job
where jobname in ('pilotage-lecture-baux', 'pilotage-lecture-mandats', 'pilotage-lecture-edl', 'pilotage-lecture-justificatifs');
update pilotage.parametres set valeur = '20' where cle = 'audit_max_jour';
insert into pilotage.parametres (cle, valeur) values ('audit_stock', 'actif') on conflict (cle) do update set valeur = excluded.valeur;
insert into pilotage.parametres (cle, valeur) values ('audit_stock_lance_le', now()::text) on conflict (cle) do update set valeur = excluded.valeur;

commit;

-- Vérification
select a.regle, count(*) n from pilotage.alertes a where a.statut <> 'resolue' group by 1 order by 2 desc;

select (select count(*) from pilotage.mandats_obligations where nature = 'mandat_pieces') suivis_pieces,
       jsonb_array_length(public.pilotage_baux_a_lire(1000)) baux_lus_d_office,
       jsonb_array_length(public.pilotage_mandats_a_lire(1000)) mandats_lus_d_office,
       (select count(*) from cron.job where jobname like 'pilotage-%' and not active) taches_en_pause,
       pilotage.audit_actif() audit_actif;
