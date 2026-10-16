-- 025 : l'acte de caution / garantie déposé dans Rivage arrive avec la catégorie « guarantee_act » et sans libellé
-- (constaté le 16/10/2026 sur le bail du lot 31, Corbeil) : la pièce est désormais reconnue par cette catégorie.
update pilotage.controle_questions set ref = 'guarantee_act' where cle in ('c_doc_garantie', 'h_doc_caution');
