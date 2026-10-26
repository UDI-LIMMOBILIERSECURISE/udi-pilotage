-- 074 — Rémunérations du stock classées à la reprise (décision de Nicolas du 26/10 :
-- « classe-les toutes, laisse uniquement les rémunérations des mandats ou baux signés ce mois-ci »).
-- Restent ouvertes : les versements des mandats signés depuis le 01/10/2026 (rentrée v1, v2, v3), le 3e versement d'un
-- mandat plus ancien quand son bail de mise en location a été signé depuis le 01/10/2026, et la commission de location
-- des baux signés (ou commencés) depuis le 01/10/2026.
-- Tout le reste est marqué « Classé à la reprise » avec un montant de 0 € : la ligne ne compte plus ni dans « À facturer »
-- ni dans « Déjà facturé ». Une ligne classée se rouvre en effaçant son n° de facture dans l'écran des commissions.

begin;

insert into pilotage.commissions_factures (mandat_id, versement, facture, montant, par)
select x->>'objet', x->>'regle', 'Classé à la reprise (26/10/2026)', 0,
       (select user_id from pilotage.membres where prenom = 'Nicolas' and role = 'direction' limit 1)
from jsonb_array_elements(pilotage.lignes_commissions()) x
where (x->'facture' is null or jsonb_typeof(x->'facture') = 'null')
  and not coalesce(
    case when x->>'type' = 'mandat' then
           (select m.signe_le from pilotage.v_mandats m where m.id = x->>'objet') >= date '2026-10-01'
           or (x->>'regle' = 'v3' and (select coalesce(b.signe_le, b.debut) from pilotage.v_baux b
                                       where b.id = pilotage.bail_location(x->>'objet')) >= date '2026-10-01')
         else (select coalesce(b.signe_le, b.debut) from pilotage.v_baux b where b.id = x->>'objet') >= date '2026-10-01'
    end, false)
on conflict (mandat_id, versement) do nothing;

commit;

-- Lignes restées ouvertes (attendu : 14, mandats 418, 420, 421, 423, 424 et bail 526)
select x->>'regle' versement, coalesce(x->>'bail_ref', x->>'mandat_ref') dossier, x->>'prenom' beneficiaire,
       x->>'montant' montant, x->>'condition' condition
from jsonb_array_elements(pilotage.lignes_commissions()) x
where (x->'facture' is null or jsonb_typeof(x->'facture') = 'null')
order by 2, 1;
