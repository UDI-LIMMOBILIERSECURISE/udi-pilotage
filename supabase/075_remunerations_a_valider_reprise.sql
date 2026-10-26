-- 075 — « Rémunérations à valider » de Ma journée (récap de la direction) : stock classé à la reprise.
-- Le 074 a classé les versements du stock dans le suivi des commissions, mais le récap « Rémunérations à valider »
-- lit une autre table (validations de la direction) : il affichait toujours 88 dossiers.
-- Même règle que le 074 (décision de Nicolas du 26/10) : restent à valider uniquement les rémunérations des mandats signés
-- depuis le 01/10/2026, du 3e versement d'un mandat dont le bail de mise en location est signé depuis le 01/10/2026,
-- et des baux signés depuis le 01/10/2026. Le reste est enregistré comme validé à 0 € avec la note « Classé à la reprise ».

begin;

insert into pilotage.commissions_validations (objet, regle, beneficiaire, montant, montant_calcule, note, valide_le, valide_par)
select x->>'objet', x->>'regle', (x->>'beneficiaire')::uuid, 0, (x->>'montant')::numeric,
       'Classé à la reprise (26/10/2026) : dossier antérieur au pilotage', now(),
       (select user_id from pilotage.membres where prenom = 'Nicolas' and role = 'direction' limit 1)
from jsonb_array_elements(pilotage.lignes_commissions()) x
where x->>'beneficiaire' is not null
  and not exists (select 1 from pilotage.commissions_validations v
                  where v.objet = x->>'objet' and v.regle = x->>'regle' and v.beneficiaire = (x->>'beneficiaire')::uuid)
  and not coalesce(
    case when x->>'type' = 'mandat' then
           (select m.signe_le from pilotage.v_mandats m where m.id = x->>'objet') >= date '2026-10-01'
           or (x->>'regle' = 'v3' and (select coalesce(b.signe_le, b.debut) from pilotage.v_baux b
                                       where b.id = pilotage.bail_location(x->>'objet')) >= date '2026-10-01')
         else (select coalesce(b.signe_le, b.debut) from pilotage.v_baux b where b.id = x->>'objet') >= date '2026-10-01'
    end, false);

commit;

-- Dossiers restant à valider par la direction (attendu : mandats 420, 421, 423, 424)
select x->>'objet' objet, coalesce(x->>'bail_ref', x->>'mandat_ref') dossier, string_agg(x->>'regle', ', ') versements
from jsonb_array_elements(pilotage.lignes_commissions()) x
where x->>'beneficiaire' is not null and (x->>'du')::boolean
  and not exists (select 1 from pilotage.commissions_validations v
                  where v.objet = x->>'objet' and v.regle = x->>'regle' and v.beneficiaire = (x->>'beneficiaire')::uuid)
group by 1, 2 order by 2;
