-- 045 : clauses du mandat simplifiées (décision de Nicolas du 18/10, barème UDI Gestion du 01/09/2026)
-- Retirées du contrôle du mandat (ni question au commercial, ni point bloquant) :
--   - Travaux sans accord préalable : aucun plafond, tout travaux doit être validé par le bailleur (règle fixe du cabinet).
--   - Reddition des comptes et reversement : géré automatiquement par Rivage, aucun contrôle à faire.
--   - Résiliation du mandat : géré automatiquement par Rivage, aucun contrôle à faire.
--   - Anomalies de rédaction : relevées par la lecture IA du mandat signé (côté gestion), plus de question au commercial.
-- La garantie des loyers impayés devient une option du barème (2,8 % des sommes quittancées) : souscrite ou non, en un clic.
-- Les questions retirées sont gardées avec la portée « retire » (réponses déjà saisies conservées, retour en arrière possible).

alter table pilotage.controle_questions drop constraint if exists controle_questions_portee_check;
alter table pilotage.controle_questions add constraint controle_questions_portee_check
  check (portee = any (array['commercial', 'habitation', 'mandat', 'retire']));

update pilotage.controle_questions set portee = 'retire',
  aide = case cle
    when 'm_cl_travaux' then 'Retiré le 18/10/2026 : aucun plafond, tout travaux est validé par le bailleur.'
    when 'm_cl_reddition' then 'Retiré le 18/10/2026 : géré automatiquement par Rivage.'
    when 'm_cl_resiliation' then 'Retiré le 18/10/2026 : géré automatiquement par Rivage.'
    when 'm_cl_anomalies' then 'Retiré le 18/10/2026 : anomalies relevées par la lecture IA du mandat signé.' end
where cle in ('m_cl_travaux', 'm_cl_reddition', 'm_cl_resiliation', 'm_cl_anomalies');

update pilotage.controle_questions
set libelle = 'Garantie des loyers impayés (option du barème : 2,8 % des sommes quittancées)',
    aide = 'Souscrite ou non par le mandant.'
where cle = 'm_cl_gli';

-- Le cache des mandats est recalculé avec le nouveau questionnaire
select pilotage.rafraichir_audit();

-- Contrôle : questions de clauses encore posées pour un mandat (doit renvoyer équipements, compteurs, garantie des loyers impayés)
select cle, libelle from pilotage.controle_questions where portee = 'mandat' and bloc = 'clauses' order by ordre;
