-- Suivi des baux : contrôle d'entrée (questionnaire), échéances et congés, paliers et franchises, actes,
-- obligations récurrentes (assurance, entretien, compteurs, garanties, taxes...) avec calendrier de relances,
-- lecture des baux par l'IA. Décisions de Nicolas (16/10/2026) :
--   calendrier d'information du bailleur avant échéance : habitation vide et professionnel 9/8/7/6 mois,
--   meublé 5/4,5/4/3 mois, commercial 12/10/8/6 mois, dérogatoire 3/2/1/0 mois ;
--   sans réponse du bailleur à la date de décision : LRAR pour acter son silence (tous types) ;
--   avant tout congé d'habitation : vérification de l'âge du locataire (plus de 65 ans) et de ses ressources ;
--   contrôle d'entrée bloquant, GO possible par la direction, le superviseur ou la gestionnaire ;
--   lecture IA systématique des baux commerciaux, par mots-clés pour l'habitation ;
--   paliers et franchises de loyer suivis dans le back-office.
-- Rien n'est envoyé automatiquement : le pilotage prépare les mails (Gmail de chaque utilisateur), l'utilisateur valide et envoie.

create table if not exists pilotage.parametres (cle text primary key, valeur text not null);
insert into pilotage.parametres values ('controle_entree_depuis', '2026-10-16') on conflict do nothing;

-- Fiche du bail : ce que Rivage ne porte pas
create table if not exists pilotage.baux_fiche (
  bail_id text primary key,
  type_bail text check (type_bail in ('vide','meuble','etudiant','mobilite','mixte','commercial','derogatoire','professionnel','autre')),
  date_origine date, date_signature date, date_acquisition date,
  situation text check (situation in ('en_cours','tacite_prolongation','renouvele')),
  destination text,
  terme text check (terme in ('avance','echu')),
  garantie_type text, garantie_montant numeric(12,2), garantie_fin date,
  locataire_65 boolean, ressources_sous_plafond boolean,
  exec_substitutive_jours integer, resolutoire text, anomalies text,
  go_le timestamptz, go_par uuid,
  maj_par uuid, maj_le timestamptz not null default now()
);

-- Questionnaire du contrôle d'entrée
create table if not exists pilotage.controle_questions (
  cle text primary key,
  portee text not null check (portee in ('commercial','habitation')),
  bloc text not null check (bloc in ('pieces','rivage','clauses')),
  ordre integer not null,
  libelle text not null,
  aide text,
  mode text not null check (mode in ('document','rivage','fiche','question')),
  ref text,            -- nature du document Rivage, clé de contrôle Rivage ou colonne de la fiche
  genere text          -- nature du suivi récurrent proposé (baux_obligations)
);

create table if not exists pilotage.baux_reponses (
  bail_id text not null, cle text not null references pilotage.controle_questions(cle),
  statut text not null check (statut in ('ok','anomalie','sans_objet')),
  suivi text check (suivi in ('rivage','backoffice')),
  valeur text, commentaire text,
  par uuid, le timestamptz not null default now(),
  primary key (bail_id, cle)
);

-- Lecture des documents par l'IA (proposition, jamais validée seule)
create table if not exists pilotage.baux_lectures (
  id bigserial primary key, bail_id text not null, source text not null, modele text,
  resultat jsonb not null, par uuid, le timestamptz not null default now()
);
create index if not exists baux_lectures_bail on pilotage.baux_lectures (bail_id, le desc);

-- Paliers et franchises de loyer (montant attendu dans Rivage, même unité que le champ loyer de Rivage)
create table if not exists pilotage.baux_paliers (
  id bigserial primary key, bail_id text not null,
  nature text not null check (nature in ('palier','franchise')),
  debut date not null, fin date, loyer_rivage numeric(12,2), commentaire text,
  par uuid, le timestamptz not null default now()
);

-- Actes et notifications (demande de renouvellement, congé, refus, avenant, commandement...)
create table if not exists pilotage.baux_actes (
  id bigserial primary key, bail_id text not null,
  nature text not null check (nature in ('demande_renouvellement','conge','refus_renouvellement','reponse','avenant','commandement','autre')),
  auteur text not null check (auteur in ('preneur','bailleur')),
  signifie_le date not null, forme text check (forme in ('acte','lrar','remise','autre')),
  reference text, effet_le date, reponse_le date, commentaire text,
  par uuid, le timestamptz not null default now()
);

-- Calendriers de relance des obligations récurrentes (jours par rapport à l'échéance de l'obligation)
create table if not exists pilotage.calendriers (
  nature text not null, ordre integer not null, jours integer not null,
  libelle text not null,
  canal text not null check (canal in ('mail_locataire','mail_bailleur','sms_rivage','lrar','tache')),
  modele text,
  primary key (nature, ordre)
);

create table if not exists pilotage.baux_obligations (
  id bigserial primary key, bail_id text not null,
  nature text not null, libelle text not null,
  periodicite_mois integer, prochaine date not null, derniere_le date,
  actif boolean not null default true,
  par uuid, cree_le timestamptz not null default now()
);
create index if not exists baux_obligations_bail on pilotage.baux_obligations (bail_id) where actif;

-- Échéance du bail : décision du bailleur pour un cycle (une échéance)
create table if not exists pilotage.baux_echeance (
  bail_id text not null, cycle date not null,
  decision text, decision_le timestamptz, decision_par uuid,
  proposition_le date, conge_le date, conge_mode text,
  primary key (bail_id, cycle)
);

-- Étapes faites (mail envoyé, relance, LRAR...) : clé e:<bail>:<cycle> ou o:<obligation>:<échéance>
create table if not exists pilotage.suivis_etapes (
  id bigserial primary key, cle text not null, etape text not null,
  fait_le timestamptz not null default now(), par uuid, detail text,
  unique (cle, etape)
);

alter table pilotage.parametres enable row level security;
alter table pilotage.baux_fiche enable row level security;
alter table pilotage.controle_questions enable row level security;
alter table pilotage.baux_reponses enable row level security;
alter table pilotage.baux_lectures enable row level security;
alter table pilotage.baux_paliers enable row level security;
alter table pilotage.baux_actes enable row level security;
alter table pilotage.calendriers enable row level security;
alter table pilotage.baux_obligations enable row level security;
alter table pilotage.baux_echeance enable row level security;
alter table pilotage.suivis_etapes enable row level security;
revoke all on pilotage.parametres, pilotage.baux_fiche, pilotage.controle_questions, pilotage.baux_reponses, pilotage.baux_lectures,
  pilotage.baux_paliers, pilotage.baux_actes, pilotage.calendriers, pilotage.baux_obligations, pilotage.baux_echeance, pilotage.suivis_etapes
  from public, anon, authenticated;

-- ===== Questionnaire =====
delete from pilotage.controle_questions;
insert into pilotage.controle_questions (cle, portee, bloc, ordre, libelle, aide, mode, ref, genere) values
-- Commercial (aussi professionnel, dérogatoire et autres baux hors habitation) : pièces
('c_doc_bail','commercial','pieces',10,'Bail signé','Dans Rivage : document « bail ».','document','lease_contract',null),
('c_doc_actes','commercial','pieces',20,'Avenants, renouvellements et actes (congés, demandes de renouvellement)','Les déposer dans Rivage et les saisir dans « Actes » ci-dessous.','question',null,null),
('c_doc_edl','commercial','pieces',30,'État des lieux d''entrée','Obligatoire depuis la loi Pinel (2014).','document','move_in_inventory',null),
('c_doc_dpe','commercial','pieces',40,'DPE','','document','energy_performance_diagnosis',null),
('c_doc_amiante','commercial','pieces',50,'Dossier technique amiante (DTA)','Immeubles dont le permis de construire est antérieur au 1er juillet 1997.','document','asbestos_diagnosis_private_parts',null),
('c_doc_erp','commercial','pieces',60,'État des risques (ERP)','','question',null,null),
('c_doc_inventaire','commercial','pieces',70,'Inventaire des charges, impôts, taxes et redevances','Annexe obligatoire du bail commercial (loi Pinel).','question',null,null),
('c_doc_travaux','commercial','pieces',80,'État des travaux des 3 dernières années et prévisionnel des 3 prochaines','Article L145-40-2 du Code de commerce.','question',null,null),
('c_doc_assurance','commercial','pieces',90,'Attestation d''assurance du preneur','','document','home_insurance_certificate',null),
('c_doc_garantie','commercial','pieces',100,'Garantie (caution, garantie bancaire)','Sans objet si le bail n''en prévoit pas.','question',null,null),
('c_doc_annexe_env','commercial','pieces',110,'Annexe environnementale','Seulement pour les locaux de bureaux ou de commerce de plus de 2 000 m².','question',null,null),
-- Commercial : croisement avec Rivage
('c_rv_parties','commercial','rivage',10,'Bailleur et preneur conformes au bail','','rivage','parties',null),
('c_rv_dates','commercial','rivage',20,'Prise d''effet et durée du bail en cours','Pour un bail renouvelé : date d''effet du renouvellement, la date d''origine va dans la fiche.','rivage','dates',null),
('c_rv_loyer','commercial','rivage',30,'Loyer et périodicité','Vérifier si Rivage attend un montant par mois ou par période.','rivage','loyer',null),
('c_rv_terme','commercial','rivage',40,'Paiement à terme échu ou d''avance','À reporter aussi dans la fiche.','fiche','terme',null),
('c_rv_tva','commercial','rivage',50,'TVA sur le loyer','','rivage','tva',null),
('c_rv_indice','commercial','rivage',60,'Indice de révision (ILC ou ILAT), trimestre et valeur de base','','rivage','indice',null),
('c_rv_revision','commercial','rivage',70,'Périodicité de la révision (annuelle ou triennale)','','rivage','revision',null),
('c_rv_dg','commercial','rivage',80,'Dépôt de garantie','','rivage','dg',null),
('c_rv_charges','commercial','rivage',90,'Provisions sur charges','','rivage','charges',null),
('c_rv_tf','commercial','rivage',100,'Taxe foncière refacturable paramétrée dans Rivage','La campagne annuelle part de Rivage.','question',null,null),
-- Commercial : clauses et suivis
('c_cl_type','commercial','clauses',10,'Type de bail','Commercial, dérogatoire, professionnel...','fiche','type_bail',null),
('c_cl_origine','commercial','clauses',20,'Date d''origine du bail (premier bail)','Sert au suivi des renouvellements successifs.','fiche','date_origine',null),
('c_cl_situation','commercial','clauses',30,'Situation : en cours, tacite prolongation ou renouvelé','','fiche','situation',null),
('c_cl_actes','commercial','clauses',40,'Actes en cours saisis (demande de renouvellement, congé)','Une demande de renouvellement du preneur appelle une réponse sous 3 mois.','question',null,null),
('c_cl_paliers','commercial','clauses',50,'Paliers ou franchise de loyer','Les saisir dans « Paliers et franchises » : le pilotage rappelle chaque changement de loyer.','question',null,null),
('c_cl_dg_ajust','commercial','clauses',60,'Ajustement du dépôt de garantie à chaque révision','Si prévu : complément à appeler avec le premier terme révisé.','question',null,null),
('c_cl_garantie','commercial','clauses',70,'Garantie à durée limitée : date d''expiration','Garantie bancaire ou caution : relances avant expiration.','fiche','garantie_fin','garantie'),
('c_cl_regul','commercial','clauses',80,'Régularisation annuelle des charges et état récapitulatif','','question',null,'charges_regul'),
('c_cl_etat_travaux','commercial','clauses',90,'État prévisionnel des travaux tous les 3 ans','Article L145-40-2.','question',null,'etat_travaux'),
('c_cl_tsb','commercial','clauses',100,'Taxe sur les bureaux : lot concerné et refacturation prévue au bail','Île-de-France : déclaration et paiement par le propriétaire avant le 1er mars.','question',null,'tsb'),
('c_cl_surprime','commercial','clauses',110,'Surprime d''assurance due à l''activité, refacturable','','question',null,'surprime'),
('c_cl_frais','commercial','clauses',120,'Frais refacturables (poursuites, honoraires, architecte)','À refacturer au fil des factures sur le lot.','question',null,null),
('c_cl_assurance','commercial','clauses',130,'Assurance du preneur : justification annuelle','Indiquer la date d''échéance de l''attestation.','question',null,'assurance'),
('c_cl_entretien','commercial','clauses',140,'Entretien des équipements à la charge du preneur','Un suivi par équipement (chaudière, climatisation, extincteurs...).','question',null,'entretien'),
('c_cl_exec','commercial','clauses',150,'Exécution substitutive : délai de mise en demeure (jours)','','fiche','exec_substitutive_jours',null),
('c_cl_resolutoire','commercial','clauses',160,'Clause résolutoire : manquements visés et délai','','fiche','resolutoire',null),
('c_cl_destination','commercial','clauses',170,'Destination des lieux et maintien de l''exploitation','Contrôle annuel.','fiche','destination','destination'),
('c_cl_cession','commercial','clauses',180,'Cession et sous-location : conditions','','question',null,null),
('c_cl_tertiaire','commercial','clauses',190,'Décret tertiaire (1 000 m² ou plus de surfaces tertiaires)','Déclaration annuelle sur la plateforme OPERAT.','question',null,'tertiaire'),
('c_cl_dpe','commercial','clauses',200,'Validité du DPE et des diagnostics','Indiquer la date de fin de validité.','question',null,'dpe'),
('c_cl_anomalies','commercial','clauses',210,'Anomalies de rédaction à signaler','Par exemple un montant laissé en blanc.','fiche','anomalies',null),
-- Habitation : pièces
('h_doc_bail','habitation','pieces',10,'Bail signé et notice d''information','','document','lease_contract',null),
('h_doc_edl','habitation','pieces',20,'État des lieux d''entrée','','document','move_in_inventory',null),
('h_doc_dpe','habitation','pieces',30,'DPE','','document','energy_performance_diagnosis',null),
('h_doc_erp','habitation','pieces',40,'État des risques (ERP)','','question',null,null),
('h_doc_plomb','habitation','pieces',50,'Constat de risque d''exposition au plomb','Immeubles construits avant 1949.','question',null,null),
('h_doc_elec_gaz','habitation','pieces',60,'Diagnostics électricité et gaz','Installations de plus de 15 ans.','question',null,null),
('h_doc_surface','habitation','pieces',70,'Surface habitable','','question',null,null),
('h_doc_assurance','habitation','pieces',80,'Attestation d''assurance du locataire','','document','home_insurance_certificate',null),
('h_doc_caution','habitation','pieces',90,'Acte de caution','Sans objet s''il n''y a pas de caution.','question',null,null),
-- Habitation : croisement avec Rivage
('h_rv_parties','habitation','rivage',10,'Bailleur et locataires conformes au bail','','rivage','parties',null),
('h_rv_dates','habitation','rivage',20,'Prise d''effet et durée','','rivage','dates',null),
('h_rv_loyer','habitation','rivage',30,'Loyer et complément de loyer','','rivage','loyer',null),
('h_rv_charges','habitation','rivage',40,'Charges : provisions ou forfait','','rivage','charges',null),
('h_rv_dg','habitation','rivage',50,'Dépôt de garantie (1 mois en vide, 2 mois en meublé au plus)','','rivage','dg',null),
('h_rv_indice','habitation','rivage',60,'IRL et trimestre de référence','','rivage','indice',null),
-- Habitation : clauses (attendues dans les modèles UDI) et suivis
('h_cl_type','habitation','clauses',10,'Type de bail','Vide, meublé, étudiant, mobilité.','fiche','type_bail',null),
('h_cl_resolutoire','habitation','clauses',20,'Clause résolutoire (loyer, dépôt, assurance, troubles)','','question',null,null),
('h_cl_entretien','habitation','clauses',30,'Entretien des équipements à la charge du locataire, avec justificatif','Un suivi par équipement (chaudière, pompe à chaleur, ballon thermodynamique, cheminée, fosse septique, citerne gaz).','question',null,'entretien'),
('h_cl_compteurs','habitation','clauses',40,'Compteurs divisionnaires et refacturation des relevés','Si divisionnaires : relevé tous les 6 mois.','question',null,'compteur'),
('h_cl_exec','habitation','clauses',50,'Exécution substitutive','','question',null,null),
('h_cl_assurance','habitation','clauses',60,'Assurance : justification annuelle','Indiquer la date d''échéance de l''attestation.','question',null,'assurance'),
('h_cl_caution','habitation','clauses',70,'Caution : durée d''engagement','Indiquer la date de fin d''engagement si elle est limitée.','question',null,'caution'),
('h_cl_dpe','habitation','clauses',80,'DPE : classe et validité','Classe F ou G : loyer gelé à la révision.','question',null,'dpe'),
('h_cl_65','habitation','clauses',90,'Locataire de plus de 65 ans','À vérifier avant tout congé du bailleur.','fiche','locataire_65',null);

-- ===== Calendriers de relance =====
delete from pilotage.calendriers;
insert into pilotage.calendriers (nature, ordre, jours, libelle, canal, modele) values
('assurance',1,-45,'1er mail au locataire : attestation d''assurance à transmettre','mail_locataire','assurance_1'),
('assurance',2,-30,'SMS de relance depuis Rivage','sms_rivage','assurance_sms'),
('assurance',3,-15,'2e mail de relance au locataire','mail_locataire','assurance_2'),
('assurance',4,1,'Mise en demeure en recommandé (délai d''un mois)','lrar','assurance_md'),
('assurance',5,1,'Prévenir le bailleur (vérifier son assurance PNO)','mail_bailleur','assurance_bailleur'),
('assurance',6,32,'Décider la suite au cas par cas (souscription pour le compte du locataire ou commandement)','tache',null),
('entretien',1,-45,'1er mail au locataire : justificatif d''entretien','mail_locataire','entretien_1'),
('entretien',2,-30,'2e mail au locataire','mail_locataire','entretien_2'),
('entretien',3,-15,'Mise en demeure en recommandé (15 jours)','lrar','entretien_md'),
('entretien',4,1,'Informer le bailleur','mail_bailleur','entretien_bailleur'),
('entretien',5,11,'Relancer le bailleur','mail_bailleur','entretien_bailleur_relance'),
('entretien',6,21,'Demander au bailleur s''il souhaite invoquer la clause résolutoire','mail_bailleur','entretien_resolutoire'),
('compteur',1,0,'Mail au locataire : relevé des compteurs','mail_locataire','compteur_1'),
('compteur',2,5,'SMS de relance depuis Rivage','sms_rivage','compteur_sms'),
('compteur',3,10,'2e mail au locataire','mail_locataire','compteur_2'),
('compteur',4,15,'Organiser une visite sur place pour le relevé','tache',null),
('garantie',1,-90,'Mail au preneur : renouvellement de la garantie','mail_locataire','garantie_1'),
('garantie',2,-60,'Relance du preneur','mail_locataire','garantie_2'),
('garantie',3,-30,'Décider : mise en demeure ou mise en jeu de la garantie avant son expiration','tache',null),
('caution',1,-60,'Fin d''engagement de la caution : vérifier le compte du locataire','tache',null),
('dpe',1,-90,'Informer le bailleur de la fin de validité du DPE','mail_bailleur','dpe_bailleur'),
('tsb',1,-60,'Rappeler au bailleur la déclaration de la taxe sur les bureaux (avant le 1er mars)','mail_bailleur','tsb_rappel'),
('tsb',2,15,'Demander au bailleur sa déclaration et la preuve de paiement','mail_bailleur','tsb_justif'),
('tsb',3,30,'Appeler la taxe sur les bureaux au preneur (appel ponctuel dans Rivage)','tache',null),
('surprime',1,-30,'Vérifier la surprime d''assurance liée à l''activité et la refacturer','tache',null),
('charges_regul',1,-60,'Préparer la régularisation des charges et l''état récapitulatif annuel','tache',null),
('charges_regul',2,0,'Adresser la régularisation et l''état récapitulatif au preneur','tache',null),
('etat_travaux',1,-60,'Préparer l''état prévisionnel des travaux (3 ans) et le récapitulatif des 3 dernières années','tache',null),
('tertiaire',1,-60,'Rappeler la déclaration annuelle OPERAT (décret tertiaire)','mail_bailleur','tertiaire'),
('destination',1,0,'Contrôler l''exploitation des locaux conforme à la destination du bail','tache',null);

-- ===== Fonctions de calcul =====

create or replace function pilotage.type_bail_suggere(p_nature text, p_duree integer) returns text
language sql immutable as $$
  select case
    when p_nature in ('commercial','office') then
      case when p_duree between 1 and 36 then 'derogatoire' when p_duree = 72 then 'professionnel' else 'commercial' end
    when p_nature in ('parking','box','basement') then 'autre'
    when p_nature in ('flat','house','room') then
      case when p_duree = 9 then 'etudiant' when p_duree between 1 and 10 then 'mobilite' when p_duree = 12 then 'meuble' when p_duree >= 36 then 'vide' end
  end
$$;

create or replace function pilotage.portee_bail(p_type text) returns text
language sql immutable as $$
  select case when p_type in ('vide','meuble','etudiant','mobilite','mixte') then 'habitation' when p_type is null then null else 'commercial' end
$$;

create or replace function pilotage.ajouter_mois(p_date date, p_mois integer) returns date
language sql immutable as $$ select (p_date + make_interval(months => p_mois))::date $$;

-- Échéance du bail et procédure d'information du bailleur
create or replace function pilotage.echeance_bail(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  o jsonb; lot record; f pilotage.baux_fiche; e pilotage.baux_echeance;
  typ text; sugg text; s date; d integer; r integer; k integer := 0; t date; t_manque date; mode text := 'terme';
  cal interval[]; info date; rel date; dec date; lim date; j date := current_date;
  v_cle text; informe date; relance date; lrar date; vu date;
  act text; act_lib text; grav text := 'normale'; etat text; blocages jsonb := '[]'::jsonb; options jsonb; douze date; alerte_derog text;
begin
  select data into o from pilotage.objets where type = 'LeasingContract' and id = p_bail and supprime_le is null;
  if o is null then return null; end if;
  select * into lot from pilotage.v_lots where id = o->>'asset_id';
  select * into f from pilotage.baux_fiche where bail_id = p_bail;
  s := (o->>'start_date')::date; d := nullif(o->>'duration_in_months', '')::integer;
  sugg := pilotage.type_bail_suggere(lot.nature, d);
  typ := coalesce(f.type_bail, sugg);
  if typ is null or s is null or coalesce(d, 0) = 0 then
    return jsonb_build_object('type', typ, 'type_confirme', f.type_bail is not null, 'type_suggere', sugg, 'etat', 'incomplet',
      'raison', case when typ is null then 'Type de bail inconnu : à renseigner dans la fiche.' else 'Date de début ou durée absente dans Rivage.' end);
  end if;

  cal := case
    when typ = 'commercial' then array['12 months','10 months','8 months','6 months']::interval[]
    when typ = 'meuble' then array['5 months','4 months 15 days','4 months','3 months']::interval[]
    when typ = 'derogatoire' then array['3 months','2 months','1 month','0 days']::interval[]
    when typ in ('etudiant','mobilite') then array['2 months','2 months','2 months','0 days']::interval[]
    when typ = 'autre' then array['3 months','3 months','3 months','1 month']::interval[]
    else array['9 months','8 months','7 months','6 months']::interval[] end;

  if typ = 'commercial' then
    t := pilotage.ajouter_mois(s, d) - 1;
    douze := (s + interval '12 years')::date;
    if t <= j then mode := 'prolongation'; end if;
    lim := case when mode = 'terme' then (t - cal[4])::date end;
  elsif typ in ('derogatoire','etudiant','mobilite') then
    t := pilotage.ajouter_mois(s, d) - 1;
    lim := (t - cal[4])::date;
    if typ <> 'derogatoire' then mode := 'fin_auto'; end if;
  else
    r := coalesce(nullif(o->>'tacit_renewal_duration_years', '')::integer * 12, case when typ = 'meuble' then 12 else d end);
    t := pilotage.ajouter_mois(s, d) - 1;
    while t <= j loop k := k + 1; t := pilotage.ajouter_mois(s, d + k * r) - 1; end loop;
    lim := (t - cal[4])::date;
    if lim < j then t_manque := t; k := k + 1; t := pilotage.ajouter_mois(s, d + k * r) - 1; lim := (t - cal[4])::date; end if;
    if typ = 'autre' then mode := 'info'; t_manque := null; end if;
  end if;
  info := (t - cal[1])::date; rel := (t - cal[2])::date; dec := (t - cal[3])::date;

  v_cle := 'e:' || p_bail || ':' || t;
  select max(fait_le::date) filter (where etape = 'informe'), max(fait_le::date) filter (where etape = 'relance'),
         max(fait_le::date) filter (where etape = 'lrar'), max(fait_le::date) filter (where etape = 'vu')
    into informe, relance, lrar, vu from pilotage.suivis_etapes where suivis_etapes.cle = v_cle;
  select * into e from pilotage.baux_echeance where bail_id = p_bail and cycle = t;

  options := case
    when typ = 'vide' or typ = 'mixte' then '["reconduire","renouveler_loyer","conge_reprise","conge_vente","conge_motif"]'
    when typ = 'meuble' then '["reconduire","conge_reprise","conge_vente","conge_motif"]'
    when typ = 'commercial' then '["ne_rien_faire","conge_offre","refus_indemnite","refus_motif_grave"]'
    when typ = 'derogatoire' then '["opposition","laisser_commercial"]'
    when typ in ('etudiant','mobilite','autre') then '[]'
    else '["reconduire","conge"]' end::jsonb;

  if typ = 'derogatoire' and j > pilotage.ajouter_mois(t, 1) and coalesce(e.decision, '') <> 'opposition' then
    alerte_derog := 'Le preneur est dans les lieux plus d''un mois après la fin du bail dérogatoire sans opposition enregistrée : un bail commercial a pu naître (article L145-5).';
  end if;

  if mode in ('fin_auto','info') then
    if j >= info and vu is null then act := case when mode = 'info' then 'verifier_contrat' else 'fin_auto' end; etat := mode;
      act_lib := case when mode = 'info' then 'Échéance du contrat le ' || to_char(t, 'DD/MM/YYYY') || ' : vérifier le préavis prévu au contrat et informer le bailleur si besoin'
                      else 'Préparer la sortie : le bail prend fin le ' || to_char(t, 'DD/MM/YYYY') || ' sans congé' end;
    else etat := case when vu is null then 'a_venir' else mode end; end if;
  elsif typ = 'derogatoire' and e.decision is null and j > lim then
    if j <= pilotage.ajouter_mois(t, 1) then act := 'opposition_urgente'; grav := 'critique'; etat := 'derogatoire_terme';
      act_lib := 'Bail dérogatoire terminé le ' || to_char(t, 'DD/MM/YYYY') || ' : manifester l''opposition du bailleur au maintien du preneur avant le ' || to_char(pilotage.ajouter_mois(t, 1), 'DD/MM/YYYY');
    else etat := 'derogatoire_depasse'; end if;
  elsif e.decision is null then
    if j < info then etat := 'a_venir';
    elsif informe is null then act := 'informer'; act_lib := 'Informer le bailleur de l''échéance et de ses options'; etat := 'a_informer';
      if j >= rel then grav := 'haute'; end if;
    elsif relance is null and j >= greatest(rel, informe + 15) then act := 'relancer'; act_lib := 'Relancer le bailleur'; grav := 'haute'; etat := 'attente_bailleur';
    elsif lrar is null and j >= greatest(dec, coalesce(relance, informe) + 15) then act := 'lrar_silence'; act_lib := 'Envoyer une LRAR au bailleur pour acter son silence'; grav := 'haute'; etat := 'attente_bailleur';
    elsif mode = 'terme' and lim is not null and j > lim then etat := 'reconduit';
    else etat := 'attente_bailleur'; end if;
    if mode = 'terme' and lim is not null and j <= lim and lim - j <= 30 and etat in ('a_informer','attente_bailleur') then grav := 'critique';
      if act is null then act := 'decision_attendue'; act_lib := 'Décision du bailleur toujours attendue : date limite du congé le ' || to_char(lim, 'DD/MM/YYYY'); end if;
    end if;
  elsif e.decision in ('reconduire','ne_rien_faire','laisser_commercial') then etat := 'decide';
  elsif e.decision = 'renouveler_loyer' then
    if e.proposition_le is null and j <= lim then act := 'proposer_loyer'; act_lib := 'Adresser la proposition de nouveau loyer (au plus tard le ' || to_char(lim, 'DD/MM/YYYY') || ')';
      grav := case when lim - j <= 30 then 'critique' else 'haute' end; etat := 'decide';
    else etat := 'decide'; end if;
  else
    if typ in ('vide','meuble','mixte') and e.decision in ('conge_reprise','conge_vente','conge_motif') then
      if f.locataire_65 is null then blocages := blocages || '"Vérifier l''âge du locataire (plus de 65 ans à l''échéance ?) avant le congé."'::jsonb;
      elsif f.locataire_65 and f.ressources_sous_plafond is null then blocages := blocages || '"Locataire de plus de 65 ans : vérifier ses ressources (plafond logement conventionné)."'::jsonb;
      elsif f.locataire_65 and f.ressources_sous_plafond then blocages := blocages || '"Locataire protégé : une offre de relogement est obligatoire, sauf si le bailleur remplit lui-même les conditions d''âge ou de ressources."'::jsonb; end if;
    end if;
    if e.conge_le is null then
      if lim is null or j <= lim then act := 'delivrer_conge';
        act_lib := case when typ in ('commercial','derogatoire') then 'Faire délivrer l''acte par commissaire de justice' else 'Délivrer le congé (LRAR, commissaire de justice ou remise contre émargement)' end
          || case when lim is not null then ' au plus tard le ' || to_char(lim, 'DD/MM/YYYY') else '' end;
        grav := case when lim is not null and lim - j <= 30 then 'critique' else 'haute' end; etat := 'conge_a_delivrer';
      else act := 'hors_delai'; act_lib := 'Délai du congé dépassé pour cette échéance : à revoir avec le bailleur'; grav := 'critique'; etat := 'hors_delai'; end if;
    else etat := 'conge_delivre'; end if;
  end if;

  return jsonb_build_object(
    'type', typ, 'type_confirme', f.type_bail is not null, 'type_suggere', sugg, 'mode', mode,
    'echeance', t, 'cycle', t, 'cle', v_cle, 'manquee', t_manque,
    'info', info, 'relance', rel, 'decision', dec, 'limite', lim,
    'informe_le', informe, 'relance_le', relance, 'lrar_le', lrar,
    'choix', e.decision, 'choix_le', e.decision_le, 'proposition_le', e.proposition_le, 'conge_le', e.conge_le, 'conge_mode', e.conge_mode,
    'etat', etat, 'action', act, 'action_libelle', act_lib, 'gravite', grav, 'blocages', blocages, 'options', options,
    'douze_ans', douze, 'alerte_derogatoire', alerte_derog,
    'effet_conge_au_plus_tot', case when mode = 'prolongation' then (date_trunc('quarter', j + interval '6 months') + interval '3 months' - interval '1 day')::date end,
    'triennale', case when typ = 'commercial' then (select min(pilotage.ajouter_mois(s, 36 * n) - 1) from generate_series(1, 30) n where pilotage.ajouter_mois(s, 36 * n) - 1 > j) end
  );
end $$;

-- État d'une obligation récurrente : étape du calendrier à faire
create or replace function pilotage.obligation_etat(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare ob pilotage.baux_obligations; v_cle text; etapes jsonb; afaire jsonb; suivante jsonb; j date := current_date;
begin
  select * into ob from pilotage.baux_obligations where id = p_id;
  if not found then return null; end if;
  v_cle := 'o:' || ob.id || ':' || ob.prochaine;
  select coalesce(jsonb_agg(jsonb_build_object('ordre', c.ordre, 'date', ob.prochaine + c.jours, 'libelle', c.libelle, 'canal', c.canal, 'modele', c.modele,
           'fait_le', se.fait_le, 'du', (ob.prochaine + c.jours) <= j) order by c.jours, c.ordre), '[]'::jsonb)
    into etapes
  from pilotage.calendriers c left join pilotage.suivis_etapes se on se.cle = v_cle and se.etape = c.ordre::text
  where c.nature = ob.nature;
  select x into afaire from jsonb_array_elements(etapes) x where (x->>'du')::boolean and x->>'fait_le' is null order by (x->>'date')::date limit 1;
  select x into suivante from jsonb_array_elements(etapes) x where not (x->>'du')::boolean order by (x->>'date')::date limit 1;
  return jsonb_build_object('id', ob.id, 'nature', ob.nature, 'libelle', ob.libelle, 'periodicite_mois', ob.periodicite_mois,
    'prochaine', ob.prochaine, 'derniere_le', ob.derniere_le, 'actif', ob.actif, 'cle', v_cle,
    'etapes', etapes, 'a_faire', afaire, 'suivante', suivante,
    'en_retard', ob.actif and j > ob.prochaine + 30,
    'gravite', case when not ob.actif then 'normale' when j > ob.prochaine + 30 then 'critique' when afaire is not null and (afaire->>'canal') = 'lrar' then 'haute'
                    when afaire is not null then 'normale' else 'normale' end);
end $$;

-- Contrôle d'entrée : questions, réponses, contrôles automatiques et proposition de l'IA
create or replace function pilotage.controle_bail(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare
  o jsonb; lot record; f pilotage.baux_fiche; typ text; v_portee text; items jsonb := '[]'::jsonb; q record; rep pilotage.baux_reponses;
  auto text; detail text; valeur_ia jsonb; lecture jsonb; docs text[]; loyer numeric; dg numeric; idx jsonb; restant integer := 0; anomalies integer := 0;
begin
  select data into o from pilotage.objets where type = 'LeasingContract' and id = p_bail;
  if o is null then return null; end if;
  select * into lot from pilotage.v_lots where id = o->>'asset_id';
  select * into f from pilotage.baux_fiche where bail_id = p_bail;
  typ := coalesce(f.type_bail, pilotage.type_bail_suggere(lot.nature, nullif(o->>'duration_in_months','')::integer));
  v_portee := coalesce(pilotage.portee_bail(typ), 'habitation');
  select resultat into lecture from pilotage.baux_lectures where bail_id = p_bail order by le desc limit 1;
  select array_agg(distinct u.data->>'nature') into docs from pilotage.objets u
   where u.type = 'Upload' and u.supprime_le is null
     and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr where rr->>'id' in (p_bail, o->>'asset_id'));
  loyer := round((o->>'rent_in_cents')::numeric / 100, 2); dg := round((o->>'deposit_in_cents')::numeric / 100, 2); idx := o->'signing_quarter_revision_index';

  for q in select * from pilotage.controle_questions where controle_questions.portee = v_portee order by case bloc when 'pieces' then 1 when 'rivage' then 2 else 3 end, ordre loop
    select * into rep from pilotage.baux_reponses where bail_id = p_bail and cle = q.cle;
    auto := null; detail := null; valeur_ia := lecture->q.cle;
    if q.mode = 'document' then
      if q.ref = any(coalesce(docs, '{}')) then auto := 'ok'; detail := 'Déposé dans Rivage.'; else detail := 'Absent dans Rivage.'; end if;
    elsif q.mode = 'fiche' then
      detail := case q.ref
        when 'type_bail' then coalesce(f.type_bail, 'Suggestion : ' || coalesce(pilotage.type_bail_suggere(lot.nature, nullif(o->>'duration_in_months','')::integer), 'aucune'))
        when 'date_origine' then to_char(f.date_origine, 'DD/MM/YYYY') when 'situation' then f.situation when 'terme' then f.terme
        when 'garantie_fin' then to_char(f.garantie_fin, 'DD/MM/YYYY') when 'exec_substitutive_jours' then f.exec_substitutive_jours || ' jours'
        when 'resolutoire' then f.resolutoire when 'destination' then f.destination when 'anomalies' then f.anomalies
        when 'locataire_65' then case f.locataire_65 when true then 'Oui' when false then 'Non' end end;
      if detail is not null and not (q.ref = 'type_bail' and f.type_bail is null) then auto := 'ok'; end if;
    elsif q.mode = 'rivage' then
      case q.ref
        when 'parties' then
          detail := 'Preneur : ' || coalesce((select string_agg(coalesce(nullif(t->>'company_name',''), concat_ws(' ', t->>'last_name', t->>'first_name')), ', ') from jsonb_array_elements(o->'tenants') t), '—')
                 || ' · Bailleur : ' || coalesce(pilotage.bailleurs_mandat(lot.mandat_id), '—');
          if jsonb_array_length(coalesce(o->'tenants','[]'::jsonb)) = 0 then auto := 'anomalie'; end if;
        when 'dates' then
          detail := 'Début ' || coalesce(to_char((o->>'start_date')::date, 'DD/MM/YYYY'), '—') || ', durée ' || coalesce(o->>'duration_in_months', '—') || ' mois';
          if o->>'start_date' is null or coalesce(nullif(o->>'duration_in_months','')::integer, 0) = 0 then auto := 'anomalie'; end if;
          if valeur_ia is not null and valeur_ia->>'debut' = o->>'start_date' and (valeur_ia->>'duree_mois')::text = o->>'duration_in_months' then auto := 'ok'; end if;
        when 'loyer' then
          detail := 'Loyer ' || coalesce(replace(to_char(loyer, 'FM999G999G990D00'), ',', ' '), '—') || ' € HC, appelé tous les ' || coalesce(o->>'frequency_in_months', '1') || ' mois'
                 || case when (o->>'rent_supplement_in_cents') is not null then ', complément ' || round((o->>'rent_supplement_in_cents')::numeric / 100, 2) || ' €' else '' end;
          if coalesce(loyer, 0) = 0 then auto := 'anomalie'; end if;
        when 'tva' then detail := case when (o->>'vat_applicable')::boolean then 'TVA oui, taux ' || coalesce(o->>'vat_rate', '?') else 'Pas de TVA' end;
        when 'indice' then
          detail := coalesce(upper(idx->>'nature'), 'aucun') || coalesce(' ' || upper(idx->>'quarter') || ' ' || (idx->>'year') || ' = ' || (idx->>'value'), '')
                 || case when (o->>'indexation_enabled')::boolean then '' else ' (indexation désactivée)' end;
          if v_portee = 'commercial' and coalesce(idx->>'nature', '') not in ('ilc','ilat','icc') and (o->>'indexation_enabled')::boolean then auto := 'anomalie'; detail := detail || ' : indice d''habitation sur un bail commercial'; end if;
          if v_portee = 'habitation' and coalesce(idx->>'nature', '') not in ('irl','irl_outre_mer') and (o->>'indexation_enabled')::boolean then auto := 'anomalie'; end if;
        when 'revision' then detail := 'Tous les ' || coalesce(o->>'revision_frequency_in_years', '?') || ' an(s), prochaine le ' || coalesce(to_char((o->>'next_revision_date')::date, 'DD/MM/YYYY'), '—');
        when 'dg' then
          detail := coalesce(dg::text, '—') || ' €' || case when loyer > 0 and dg is not null then ' (' || round(dg / loyer, 1) || ' fois le loyer appelé)' else '' end;
          if v_portee = 'habitation' and loyer > 0 and dg > loyer * (case when typ = 'meuble' then 2 else 1 end) then auto := 'anomalie'; detail := detail || ' : au-delà du plafond légal'; end if;
          if valeur_ia is not null and (valeur_ia->>'montant')::numeric = dg and auto is null then auto := 'ok'; end if;
        when 'charges' then detail := coalesce(round((o->>'charges_in_cents')::numeric / 100, 2)::text, '0') || ' € par appel';
        else null;
      end case;
    end if;
    if rep.statut is null then
      if coalesce(auto, '') <> 'ok' then restant := restant + 1; end if;
    end if;
    if coalesce(rep.statut, auto) = 'anomalie' then anomalies := anomalies + 1; end if;
    items := items || jsonb_build_object('cle', q.cle, 'bloc', q.bloc, 'libelle', q.libelle, 'aide', q.aide, 'mode', q.mode, 'ref', q.ref, 'genere', q.genere,
      'auto', auto, 'detail', detail, 'ia', valeur_ia,
      'statut', coalesce(rep.statut, case when auto = 'ok' then 'ok' end), 'repondu', rep.statut is not null,
      'suivi', rep.suivi, 'valeur', rep.valeur, 'commentaire', rep.commentaire, 'par', pilotage.prenom_membre(rep.par), 'le', rep.le,
      'a_traiter', rep.statut is null and coalesce(auto, '') <> 'ok');
  end loop;
  return jsonb_build_object('portee', v_portee, 'items', items, 'restant', restant, 'anomalies', anomalies,
    'go_le', f.go_le, 'go_par', pilotage.prenom_membre(f.go_par), 'lecture_le', (select max(le) from pilotage.baux_lectures where bail_id = p_bail));
end $$;

create or replace function pilotage.prenom_membre(p_user uuid) returns text
language sql stable security definer set search_path = pilotage, public as $$ select prenom from pilotage.membres where user_id = p_user $$;

-- Contacts pour les mails (locataires et bailleurs du mandat)
create or replace function pilotage.contacts_bail(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object(
    'locataires', coalesce((select jsonb_agg(jsonb_build_object('nom', coalesce(nullif(t->>'company_name',''), concat_ws(' ', t->>'civility', t->>'first_name', t->>'last_name')),
        'email', t->>'email', 'telephone', t->>'phone_number')) from jsonb_array_elements(b.data->'tenants') t), '[]'::jsonb),
    'bailleurs', coalesce((select jsonb_agg(jsonb_build_object('nom', pilotage.nom_profil(p->>'profile_id'), 'email', pr.data->>'email', 'telephone', pr.data->>'phone_number'))
        from pilotage.objets m, jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes','[]'::jsonb)) p
        left join pilotage.objets pr on pr.type = 'Profile' and pr.id = p->>'profile_id'
        where m.type = 'ManagementContract' and m.id = a.data->>'management_contract_id'), '[]'::jsonb))
  from pilotage.objets b left join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id'
  where b.type = 'LeasingContract' and b.id = p_bail
$$;

-- Détections pour la file d'alertes (une ligne par bail et par règle)
create or replace function pilotage.suivi_detections() returns table (regle text, objet_type text, objet_id text, titre text, detail text, lien text)
language sql stable security definer set search_path = pilotage, public as $$
  with baux as (
    select b.id, b.reference, b.locataires, b.debut, pilotage.echeance_bail(b.id) ech
    from pilotage.v_baux b where b.statut in ('created','move_in','in_progress') and (b.fin is null or b.fin > current_date)
  ), lien as (select 'https://rivage.immo/leasing_contracts?leasing_contract_id=' l)
  select 'bail_controle_entree', 'LeasingContract', b.id, 'Bail ' || coalesce(b.reference,'') || ' : contrôle d''entrée à valider',
         coalesce((pilotage.controle_bail(b.id)->>'restant'), '?') || ' point(s) à traiter · ' || coalesce(b.locataires, ''), (select l from lien) || b.id
  from baux b left join pilotage.baux_fiche f on f.bail_id = b.id
  where f.go_le is null and ((b.ech->>'type') in ('commercial','derogatoire','professionnel') or b.debut >= (select valeur::date from pilotage.parametres where cle = 'controle_entree_depuis'))
  union all
  select case when b.ech->>'gravite' = 'critique' then 'bail_echeance_urgente' else 'bail_echeance' end, 'LeasingContract', b.id,
         'Bail ' || coalesce(b.reference,'') || ' : ' || (b.ech->>'action_libelle'),
         'Échéance le ' || to_char((b.ech->>'echeance')::date, 'DD/MM/YYYY') || coalesce(', date limite du congé le ' || to_char((b.ech->>'limite')::date, 'DD/MM/YYYY'), '') || ' · ' || coalesce(b.locataires, ''),
         (select l from lien) || b.id
  from baux b where b.ech->>'action' is not null
  union all
  select 'bail_derogatoire', 'LeasingContract', b.id, 'Bail ' || coalesce(b.reference,'') || ' : bail dérogatoire dépassé', b.ech->>'alerte_derogatoire', (select l from lien) || b.id
  from baux b where b.ech->>'alerte_derogatoire' is not null
  union all
  select 'bail_douze_ans', 'LeasingContract', b.id, 'Bail ' || coalesce(b.reference,'') || ' : 12 ans de durée le ' || to_char((b.ech->>'douze_ans')::date, 'DD/MM/YYYY'),
         'Au-delà, le loyer du bail renouvelé peut être déplafonné (L145-34) : à examiner avec le bailleur.', (select l from lien) || b.id
  from baux b where (b.ech->>'douze_ans')::date between current_date and current_date + 365 and b.ech->>'mode' = 'prolongation'
  union all
  select case when bool_or(e->>'gravite' = 'critique') then 'bail_suivi_retard' else 'bail_suivi' end, 'LeasingContract', o.bail_id,
         'Bail ' || coalesce(max(b.reference),'') || ' : ' || string_agg(coalesce(e->'a_faire'->>'libelle', 'en retard') || ' (' || (e->>'libelle') || ')', ' ; '),
         string_agg((e->>'libelle') || ' : échéance le ' || to_char((e->>'prochaine')::date, 'DD/MM/YYYY'), ' ; '), (select l from lien) || o.bail_id
  from pilotage.baux_obligations o join baux b on b.id = o.bail_id, lateral (select pilotage.obligation_etat(o.id) e) x
  where o.actif and (jsonb_typeof(e->'a_faire') = 'object' or (e->>'en_retard')::boolean)
  group by o.bail_id
  union all
  select 'bail_palier', 'LeasingContract', p.bail_id,
         'Bail ' || coalesce(b.reference,'') || ' : ' || case when p.debut > current_date then (case p.nature when 'franchise' then 'franchise' else 'palier' end) || ' de loyer le ' || to_char(p.debut, 'DD/MM/YYYY') || ', mettre à jour Rivage'
                                                   else 'loyer Rivage différent du palier en cours' end,
         'Loyer attendu dans Rivage : ' || coalesce(p.loyer_rivage::text, '—') || ' € ; loyer actuel dans Rivage : ' || coalesce(vb.loyer_hc::text, '—') || ' €', (select l from lien) || p.bail_id
  from pilotage.baux_paliers p join baux b on b.id = p.bail_id join pilotage.v_baux vb on vb.id = p.bail_id
  where (p.debut between current_date and current_date + 30)
     or (p.debut <= current_date and (p.fin is null or p.fin >= current_date) and p.loyer_rivage is not null and vb.loyer_hc is distinct from p.loyer_rivage
         and not exists (select 1 from pilotage.baux_paliers p2 where p2.bail_id = p.bail_id and p2.debut > p.debut and p2.debut <= current_date))
  union all
  select 'bail_acte_delai', 'LeasingContract', a.bail_id,
         'Bail ' || coalesce(b.reference,'') || ' : demande de renouvellement du ' || to_char(a.signifie_le, 'DD/MM/YYYY') || ' sans réponse enregistrée',
         'Le bailleur doit répondre avant le ' || to_char(pilotage.ajouter_mois(a.signifie_le, 3), 'DD/MM/YYYY') || ', sinon il est réputé accepter le principe du renouvellement (L145-10).',
         (select l from lien) || a.bail_id
  from pilotage.baux_actes a join baux b on b.id = a.bail_id
  where a.nature = 'demande_renouvellement' and a.auteur = 'preneur' and a.reponse_le is null and current_date <= pilotage.ajouter_mois(a.signifie_le, 3) + 15
$$;

insert into pilotage.regles (cle, libelle, domaine, gravite, categorie, actif, explication) values
 ('bail_controle_entree','Contrôle d''entrée du bail à valider','baux','haute','tache',true,'Chaque bail commercial et chaque nouveau bail passe par le contrôle d''entrée (pièces, croisement avec Rivage, clauses) avant le GO.'),
 ('bail_echeance','Échéance du bail : étape à faire','baux','haute','courrier',true,'Information du bailleur avant l''échéance (12 mois en commercial, 9 en habitation vide, 5 en meublé), relance, LRAR si pas de réponse, puis congé ou reconduction.'),
 ('bail_echeance_urgente','Échéance du bail : date limite proche','baux','critique','courrier',true,'Moins de 30 jours avant la date limite du congé sans décision ou sans congé délivré.'),
 ('bail_derogatoire','Bail dérogatoire dépassé','baux','critique','oblig',true,'Le preneur resté plus d''un mois après la fin d''un bail dérogatoire sans opposition bénéficie du statut des baux commerciaux (L145-5).'),
 ('bail_douze_ans','Bail commercial proche de 12 ans','baux','haute','oblig',true,'Au-delà de 12 ans par tacite prolongation, le loyer de renouvellement peut être déplafonné (L145-34).'),
 ('bail_suivi','Suivi du bail : relance à faire','baux','haute','courrier',true,'Obligations suivies (assurance, entretien, compteurs, garanties, taxes...) selon leur calendrier de relances.'),
 ('bail_suivi_retard','Suivi du bail : obligation en retard','baux','critique','oblig',true,'Obligation non justifiée plus de 30 jours après son échéance.'),
 ('bail_palier','Palier ou franchise de loyer','baux','haute','tache',true,'Le loyer de Rivage doit suivre les paliers et franchises du bail.'),
 ('bail_acte_delai','Demande de renouvellement sans réponse','baux','critique','oblig',true,'Le bailleur a 3 mois pour refuser le renouvellement par acte extrajudiciaire, sinon il est réputé l''accepter (L145-10).')
on conflict (cle) do update set libelle = excluded.libelle, gravite = excluded.gravite, categorie = excluded.categorie, explication = excluded.explication;

-- ===== Fonctions exposées à l'appli =====

create or replace function pilotage.peut_suivre_baux() returns boolean
language sql stable security definer set search_path = pilotage, public as $$ select pilotage.mon_role() in ('direction','superviseur','gestionnaire') $$;

create or replace function public.pilotage_baux() returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  return jsonb_build_object('peut', pilotage.peut_suivre_baux(), 'baux', coalesce((
    select jsonb_agg(x order by (x->'echeance'->>'echeance') nulls last) from (
      select jsonb_build_object(
        'bail_id', b.id, 'reference', b.reference, 'statut', b.statut, 'locataires', b.locataires, 'debut', b.debut, 'loyer_hc', b.loyer_hc,
        'lot', l.reference, 'adresse', l.adresse, 'nature_lot', l.nature, 'mandat_id', l.mandat_id,
        'mandat', (select coalesce(nullif(m.nom,''), 'Mandat n°' || m.reference) from pilotage.v_mandats m where m.id = l.mandat_id),
        'bailleur', pilotage.bailleurs_mandat(l.mandat_id),
        'echeance', pilotage.echeance_bail(b.id),
        'controle', (select jsonb_build_object('restant', (c->>'restant')::int, 'anomalies', (c->>'anomalies')::int, 'go_le', c->'go_le', 'go_par', c->'go_par', 'portee', c->'portee')
                     from pilotage.controle_bail(b.id) c),
        'obligations', coalesce((select jsonb_agg(pilotage.obligation_etat(o.id) order by o.prochaine) from pilotage.baux_obligations o where o.bail_id = b.id and o.actif), '[]'::jsonb),
        'lien', 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || b.id) x
      from pilotage.v_baux b left join pilotage.v_lots l on l.id = b.lot_id
      where b.statut in ('created','move_in','in_progress') and (b.fin is null or b.fin > current_date)
    ) t), '[]'::jsonb));
end $$;

create or replace function public.pilotage_bail_dossier(p_bail text) returns jsonb
language plpgsql stable security definer set search_path = pilotage, public as $$
declare f pilotage.baux_fiche;
begin
  if pilotage.mon_role() is null then raise exception 'Accès refusé'; end if;
  select * into f from pilotage.baux_fiche where bail_id = p_bail;
  return jsonb_build_object(
    'fiche', to_jsonb(f) - 'go_par' - 'maj_par',
    'controle', pilotage.controle_bail(p_bail),
    'echeance', pilotage.echeance_bail(p_bail),
    'contacts', pilotage.contacts_bail(p_bail),
    -- Équipements déclarés dans Rivage (lot) et dernier entretien de chaudière (bail), pour pré-remplir les questions de suivi
    'rivage', (select jsonb_build_object('nature_lot', a.data->>'nature',
                 'chauffage', a.data->'equipment'->>'heating_method', 'type_chauffage', a.data->'equipment'->>'heating_type',
                 'eau_chaude', a.data->'equipment'->>'hot_water_method', 'type_eau_chaude', a.data->'equipment'->>'hot_water_type',
                 'entretien_chaudiere', b.data->>'last_boiler_maintenance_date')
               from pilotage.objets b left join pilotage.objets a on a.type = 'Asset' and a.id = b.data->>'asset_id'
               where b.type = 'LeasingContract' and b.id = p_bail),
    'paliers', coalesce((select jsonb_agg(to_jsonb(p) - 'par' order by p.debut) from pilotage.baux_paliers p where p.bail_id = p_bail), '[]'::jsonb),
    'actes', coalesce((select jsonb_agg(to_jsonb(a) - 'par' order by a.signifie_le desc) from pilotage.baux_actes a where a.bail_id = p_bail), '[]'::jsonb),
    'obligations', coalesce((select jsonb_agg(pilotage.obligation_etat(o.id) order by o.actif desc, o.prochaine) from pilotage.baux_obligations o where o.bail_id = p_bail), '[]'::jsonb),
    'journal', coalesce((select jsonb_agg(jsonb_build_object('le', se.fait_le, 'cle', se.cle, 'etape', se.etape, 'detail', se.detail, 'par', pilotage.prenom_membre(se.par)) order by se.fait_le desc)
                         from pilotage.suivis_etapes se where se.cle like 'e:' || p_bail || ':%'
                           or se.cle like any (array(select 'o:' || o.id || ':%' from pilotage.baux_obligations o where o.bail_id = p_bail))), '[]'::jsonb),
    'lecture', (select jsonb_build_object('le', le, 'source', source, 'modele', modele, 'resultat', resultat) from pilotage.baux_lectures where bail_id = p_bail order by le desc limit 1),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'nature', u.data->>'nature', 'libelle', u.data->>'label')) from pilotage.objets u
                   where u.type = 'Upload' and u.supprime_le is null and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables','[]'::jsonb)) rr
                     where rr->>'id' in (p_bail, (select data->>'asset_id' from pilotage.objets where type = 'LeasingContract' and id = p_bail)))), '[]'::jsonb));
end $$;

create or replace function public.pilotage_fiche_bail_maj(p_bail text, p_champ text, p_valeur text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_champ not in ('type_bail','date_origine','date_signature','date_acquisition','situation','destination','terme','garantie_type','garantie_montant','garantie_fin',
                     'locataire_65','ressources_sous_plafond','exec_substitutive_jours','resolutoire','anomalies') then raise exception 'Champ non prévu'; end if;
  insert into pilotage.baux_fiche (bail_id) values (p_bail) on conflict do nothing;
  execute format('update pilotage.baux_fiche set %I = $1::%s, maj_par = auth.uid(), maj_le = now() where bail_id = $2', p_champ,
    case when p_champ in ('date_origine','date_signature','date_acquisition','garantie_fin') then 'date'
         when p_champ in ('locataire_65','ressources_sous_plafond') then 'boolean'
         when p_champ = 'garantie_montant' then 'numeric' when p_champ = 'exec_substitutive_jours' then 'integer' else 'text' end)
  using nullif(p_valeur, ''), p_bail;
  -- Une garantie à durée limitée crée son suivi
  if p_champ = 'garantie_fin' and nullif(p_valeur, '') is not null then
    update pilotage.baux_obligations set prochaine = p_valeur::date, actif = true where bail_id = p_bail and nature = 'garantie';
    if not found then insert into pilotage.baux_obligations (bail_id, nature, libelle, prochaine, par) values (p_bail, 'garantie', 'Expiration de la garantie', p_valeur::date, auth.uid()); end if;
  end if;
end $$;

create or replace function public.pilotage_bail_repondre(p_bail text, p_cle text, p_statut text, p_suivi text, p_valeur text, p_commentaire text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_statut is null then delete from pilotage.baux_reponses where bail_id = p_bail and cle = p_cle; return; end if;
  if p_statut = 'anomalie' and nullif(trim(coalesce(p_commentaire, '')), '') is null then raise exception 'Décrivez l''anomalie en commentaire'; end if;
  insert into pilotage.baux_reponses (bail_id, cle, statut, suivi, valeur, commentaire, par) values (p_bail, p_cle, p_statut, p_suivi, p_valeur, p_commentaire, auth.uid())
  on conflict (bail_id, cle) do update set statut = excluded.statut, suivi = excluded.suivi, valeur = excluded.valeur, commentaire = excluded.commentaire, par = auth.uid(), le = now();
end $$;

-- GO du contrôle d'entrée : direction, superviseur ou gestionnaire, seulement quand tout est traité
create or replace function public.pilotage_bail_go(p_bail text, p_oui boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare c jsonb;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_oui then
    c := pilotage.controle_bail(p_bail);
    if (c->>'restant')::int > 0 then raise exception 'Il reste % point(s) à traiter avant le GO', c->>'restant'; end if;
    if not exists (select 1 from pilotage.baux_fiche where bail_id = p_bail and type_bail is not null) then raise exception 'Confirmez d''abord le type de bail'; end if;
  end if;
  insert into pilotage.baux_fiche (bail_id) values (p_bail) on conflict do nothing;
  update pilotage.baux_fiche set go_le = case when p_oui then now() end, go_par = case when p_oui then auth.uid() end where bail_id = p_bail;
end $$;

create or replace function public.pilotage_bail_palier(p_bail text, p_id bigint, p_nature text, p_debut date, p_fin date, p_loyer numeric, p_commentaire text, p_supprimer boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_supprimer then delete from pilotage.baux_paliers where id = p_id and bail_id = p_bail; return; end if;
  if p_debut is null then raise exception 'Date de début obligatoire'; end if;
  if p_id is null then insert into pilotage.baux_paliers (bail_id, nature, debut, fin, loyer_rivage, commentaire, par) values (p_bail, p_nature, p_debut, p_fin, p_loyer, p_commentaire, auth.uid());
  else update pilotage.baux_paliers set nature = p_nature, debut = p_debut, fin = p_fin, loyer_rivage = p_loyer, commentaire = p_commentaire, par = auth.uid(), le = now() where id = p_id and bail_id = p_bail; end if;
end $$;

create or replace function public.pilotage_bail_acte(p_bail text, p_id bigint, p_nature text, p_auteur text, p_signifie date, p_forme text, p_reference text, p_effet date, p_reponse date, p_commentaire text, p_supprimer boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_supprimer then delete from pilotage.baux_actes where id = p_id and bail_id = p_bail; return; end if;
  if p_signifie is null then raise exception 'Date de signification obligatoire'; end if;
  if p_id is null then insert into pilotage.baux_actes (bail_id, nature, auteur, signifie_le, forme, reference, effet_le, reponse_le, commentaire, par)
    values (p_bail, p_nature, p_auteur, p_signifie, p_forme, p_reference, p_effet, p_reponse, p_commentaire, auth.uid());
  else update pilotage.baux_actes set nature = p_nature, auteur = p_auteur, signifie_le = p_signifie, forme = p_forme, reference = p_reference, effet_le = p_effet,
    reponse_le = p_reponse, commentaire = p_commentaire, par = auth.uid(), le = now() where id = p_id and bail_id = p_bail; end if;
end $$;

create or replace function public.pilotage_bail_obligation(p_bail text, p_id bigint, p_nature text, p_libelle text, p_periodicite integer, p_prochaine date, p_actif boolean) returns bigint
language plpgsql security definer set search_path = pilotage, public as $$
declare nid bigint;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_nature not in (select distinct nature from pilotage.calendriers) then raise exception 'Nature de suivi inconnue'; end if;
  if p_id is null then
    if p_prochaine is null then raise exception 'Date d''échéance obligatoire'; end if;
    insert into pilotage.baux_obligations (bail_id, nature, libelle, periodicite_mois, prochaine, par) values (p_bail, p_nature, p_libelle, p_periodicite, p_prochaine, auth.uid()) returning id into nid;
  else
    update pilotage.baux_obligations set libelle = coalesce(p_libelle, libelle), periodicite_mois = p_periodicite, prochaine = coalesce(p_prochaine, prochaine), actif = coalesce(p_actif, actif)
     where id = p_id and bail_id = p_bail returning id into nid;
  end if;
  return nid;
end $$;

-- Obligation réalisée (justificatif reçu) : nouvelle échéance, les relances repartent de zéro
create or replace function public.pilotage_obligation_realisee(p_id bigint, p_le date, p_prochaine date) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare ob pilotage.baux_obligations;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  select * into ob from pilotage.baux_obligations where id = p_id;
  insert into pilotage.suivis_etapes (cle, etape, par, detail) values ('o:' || ob.id || ':' || ob.prochaine, 'realise', auth.uid(), 'Réalisé le ' || to_char(coalesce(p_le, current_date), 'DD/MM/YYYY'))
  on conflict (cle, etape) do nothing;
  update pilotage.baux_obligations set derniere_le = coalesce(p_le, current_date),
    prochaine = coalesce(p_prochaine, case when periodicite_mois is not null then pilotage.ajouter_mois(coalesce(p_le, current_date), periodicite_mois) end, prochaine),
    actif = (p_prochaine is not null or periodicite_mois is not null)
  where id = p_id;
end $$;

-- Étape faite (mail envoyé, SMS, LRAR, tâche) ou annulée
create or replace function public.pilotage_suivi_etape(p_cle text, p_etape text, p_detail text, p_annuler boolean) returns void
language plpgsql security definer set search_path = pilotage, public as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_cle !~ '^(e|o):' then raise exception 'Clé de suivi invalide'; end if;
  if p_annuler then delete from pilotage.suivis_etapes where cle = p_cle and etape = p_etape; return; end if;
  insert into pilotage.suivis_etapes (cle, etape, par, detail) values (p_cle, p_etape, auth.uid(), p_detail)
  on conflict (cle, etape) do update set fait_le = now(), par = auth.uid(), detail = excluded.detail;
end $$;

-- Décision du bailleur sur l'échéance, proposition de loyer, congé délivré
create or replace function public.pilotage_echeance_decision(p_bail text, p_decision text, p_proposition date, p_conge date, p_conge_mode text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare ech jsonb; t date;
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  ech := pilotage.echeance_bail(p_bail);
  t := (ech->>'cycle')::date;
  if t is null then raise exception 'Échéance non calculable : complétez la fiche du bail'; end if;
  if p_decision is not null and not (ech->'options') ? p_decision then raise exception 'Choix non prévu pour ce type de bail'; end if;
  if p_conge is not null and jsonb_array_length(ech->'blocages') > 0 and (ech->'blocages'->>0) like 'Vérifier%' then raise exception '%', ech->'blocages'->>0; end if;
  insert into pilotage.baux_echeance (bail_id, cycle) values (p_bail, t) on conflict do nothing;
  update pilotage.baux_echeance set
    decision = case when p_decision = '' then null else coalesce(p_decision, decision) end,
    decision_le = case when p_decision is not null then now() else decision_le end, decision_par = case when p_decision is not null then auth.uid() else decision_par end,
    proposition_le = coalesce(p_proposition, proposition_le), conge_le = coalesce(p_conge, conge_le), conge_mode = coalesce(p_conge_mode, conge_mode)
  where bail_id = p_bail and cycle = t;
end $$;

revoke all on function public.pilotage_baux(), public.pilotage_bail_dossier(text), public.pilotage_fiche_bail_maj(text, text, text),
  public.pilotage_bail_repondre(text, text, text, text, text, text), public.pilotage_bail_go(text, boolean),
  public.pilotage_bail_palier(text, bigint, text, date, date, numeric, text, boolean),
  public.pilotage_bail_acte(text, bigint, text, text, date, text, text, date, date, text, boolean),
  public.pilotage_bail_obligation(text, bigint, text, text, integer, date, boolean), public.pilotage_obligation_realisee(bigint, date, date),
  public.pilotage_suivi_etape(text, text, text, boolean), public.pilotage_echeance_decision(text, text, date, date, text) from public, anon;
grant execute on function public.pilotage_baux(), public.pilotage_bail_dossier(text), public.pilotage_fiche_bail_maj(text, text, text),
  public.pilotage_bail_repondre(text, text, text, text, text, text), public.pilotage_bail_go(text, boolean),
  public.pilotage_bail_palier(text, bigint, text, date, date, numeric, text, boolean),
  public.pilotage_bail_acte(text, bigint, text, text, date, text, text, date, date, text, boolean),
  public.pilotage_bail_obligation(text, bigint, text, text, integer, date, boolean), public.pilotage_obligation_realisee(bigint, date, date),
  public.pilotage_suivi_etape(text, text, text, boolean), public.pilotage_echeance_decision(text, text, date, date, text) to authenticated;

-- Écriture d'une lecture IA (fonction de bord pilotage-lecture-bail, clé de service)
create or replace function public.pilotage_lecture_ecrire(p_bail text, p_source text, p_modele text, p_resultat jsonb, p_user uuid) returns void
language sql security definer set search_path = pilotage, public as $$
  insert into pilotage.baux_lectures (bail_id, source, modele, resultat, par) values (p_bail, p_source, p_modele, p_resultat, p_user)
$$;
create or replace function public.pilotage_lecture_source(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select jsonb_build_object('upload_id', u.id, 'libelle', u.data->>'label', 'url', u.data->>'file_url')
  from pilotage.objets u where u.type = 'Upload' and u.supprime_le is null and u.data->>'nature' = 'lease_contract'
    and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables','[]'::jsonb)) rr
                where rr->>'id' in (p_bail, (select data->>'asset_id' from pilotage.objets where type = 'LeasingContract' and id = p_bail)))
  order by u.maj_le desc limit 1
$$;
create or replace function public.pilotage_questions_bail(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('cle', cle, 'libelle', libelle, 'aide', aide) order by bloc, ordre), '[]'::jsonb)
  from pilotage.controle_questions where portee = (pilotage.controle_bail(p_bail)->>'portee') and mode <> 'document'
$$;
revoke all on function public.pilotage_lecture_ecrire(text, text, text, jsonb, uuid), public.pilotage_lecture_source(text), public.pilotage_questions_bail(text) from public, anon, authenticated;
grant execute on function public.pilotage_lecture_ecrire(text, text, text, jsonb, uuid), public.pilotage_lecture_source(text), public.pilotage_questions_bail(text) to service_role;

-- Onglet visible par tous les membres
create or replace function public.pilotage_tableaux_visibles() returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when pilotage.mon_role() is not null then '["agence","sinistres","dg","compta","impayes","baux"]'::jsonb else '[]'::jsonb end
$$;

revoke all on all functions in schema pilotage from public, anon, authenticated;

-- ===== Branchement sur les contrôles existants (toutes les 30 minutes) : même corps qu'avant + détections du suivi des baux =====
create or replace function pilotage.executer_controles() returns integer
language plpgsql security definer set search_path = pilotage, public as $function$
declare n integer;
begin
  create temp table _det on commit drop as
  with lots as (select * from pilotage.v_lots),
       baux as (select b.*, l.nature lot_nature, l.code_postal, l.chauffage from pilotage.v_baux b left join lots l on l.id = b.lot_id)
  select 'surface_boutin'::text regle, 'Asset'::text objet_type, id objet_id,
    'Lot ' || coalesce(reference,'') || ' : surface Boutin ' || surface_boutin || ' m² pour ' || surface || ' m²' titre,
    adresse detail, 'https://rivage.immo/asset_list' lien
  from lots where surface_boutin > surface
  union all
  select 'irl_outremer_metropole', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : IRL outre-mer hors DOM', 'Lot en ' || coalesce(code_postal,'?') || ' — locataires : ' || coalesce(locataires,'?'),
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where indice = 'irl_outre_mer' and coalesce(code_postal,'') not like '97%' and statut <> 'closed'
  union all
  select 'irl_local_professionnel', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : IRL sur un local ' || lot_nature, 'Locataires : ' || coalesce(locataires,'?') || ' — ILC ou ILAT attendu',
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where indice in ('irl','irl_outre_mer') and lot_nature in ('commercial','office') and statut <> 'closed'
  union all
  select 'mandat_sans_signature', 'ManagementContract', id,
    'Mandat n°' || coalesce(reference,'') || ' ' || coalesce(nom,'') || ' : pas de date de signature', 'Début le ' || to_char(debut,'DD/MM/YYYY'),
    'https://rivage.immo/landlords/profiles/' || split_part(coalesce(proprietaires,''), ', ', 1)
  from pilotage.v_mandats where statut = 'active' and signe_le is null
  union all
  select 'dg_plafond', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : DG de ' || round(depot_garantie / nullif(loyer_hc,0), 1) || ' mois de loyer HC',
    'DG ' || depot_garantie || ' € pour un loyer HC de ' || loyer_hc || ' € — ' || coalesce(locataires,'?') ||
      case when depot_garantie > 2 * loyer_hc then ' (au-delà même du plafond meublé)' else ' (au-delà du plafond en location vide, normal seulement en meublé)' end,
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where lot_nature in ('flat','house','room') and statut in ('created','move_in','in_progress') and loyer_hc > 0 and depot_garantie > loyer_hc
  union all
  select 'chaudiere_gaz_entretien', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : chauffage au gaz, entretien de chaudière ' || coalesce('du ' || to_char(entretien_chaudiere,'DD/MM/YYYY'), 'non renseigné'),
    'Locataires : ' || coalesce(locataires,'?'), 'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where chauffage = 'gas' and statut in ('move_in','in_progress') and (entretien_chaudiere is null or entretien_chaudiere < current_date - 365)
  union all
  select 'bail_non_entre', 'LeasingContract', id,
    'Bail ' || coalesce(reference,'') || ' : début le ' || to_char(debut,'DD/MM/YYYY') || ', toujours au statut « Créé »',
    'Locataires : ' || coalesce(locataires,'?') || ' — vérifier la date d''entrée et l''EDL d''entrée',
    'https://rivage.immo/leasing_contracts?leasing_contract_id=' || id
  from baux where statut = 'created' and debut < current_date - 5
  union all
  select 'document_supprime', 'Upload', o.id,
    'Document supprimé : ' || coalesce(o.data->>'nature','type inconnu'),
    'Supprimé le ' || to_char(o.supprime_le at time zone 'Europe/Paris','DD/MM/YYYY HH24:MI') || coalesce(' — lot ' || (o.data->'resourceables'->0->>'reference'), ''),
    'https://rivage.immo/customer/uploads'
  from pilotage.objets o where o.type = 'Upload' and o.supprime_le > now() - interval '30 days'
    and o.data->>'nature' in ('lease_contract','move_in_inventory','move_out_inventory','home_insurance_certificate','property_insurance_contracts',
         'management_mandate','technical_diagnostic_reports','maintenance_contracts','guarantor_documents','security_deposit_proof',
         'energy_performance_diagnosis','asbestos_diagnosis_private_parts')
  union all
  select d.regle, d.objet_type, d.objet_id, d.titre, d.detail, d.lien from pilotage.suivi_detections() d;

  insert into pilotage.alertes(regle, objet_type, objet_id, gravite, titre, detail, lien_rivage)
  select d.regle, d.objet_type, d.objet_id, r.gravite, d.titre, d.detail, d.lien
  from _det d join pilotage.regles r on r.cle = d.regle and r.actif
  on conflict (regle, objet_type, objet_id) do update
    set titre = excluded.titre, detail = excluded.detail, lien_rivage = excluded.lien_rivage, derniere_detection = now(),
        statut = case when pilotage.alertes.statut = 'resolue' then 'ouverte' else pilotage.alertes.statut end,
        resolue_le = case when pilotage.alertes.statut = 'resolue' then null else pilotage.alertes.resolue_le end;

  update pilotage.alertes a set statut = 'resolue', resolue_le = now()
  where a.statut in ('ouverte','traitee')
    and not exists (select 1 from _det d where d.regle = a.regle and d.objet_type = a.objet_type and d.objet_id = a.objet_id);

  select count(*) into n from pilotage.alertes where statut = 'ouverte';
  return n;
end $function$;
revoke all on function pilotage.executer_controles() from public, anon, authenticated;

-- ===== Lecture IA systématique des baux commerciaux (chaque nuit, 3 baux au plus par passage) =====
create or replace function public.pilotage_baux_a_lire(p_max integer) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (
    select b.id from pilotage.v_baux b
    where b.statut in ('created','move_in','in_progress') and (b.fin is null or b.fin > current_date)
      and (pilotage.echeance_bail(b.id)->>'type') in ('commercial','derogatoire','professionnel')
      and not exists (select 1 from pilotage.baux_lectures l where l.bail_id = b.id)
      and public.pilotage_lecture_source(b.id) is not null
    order by b.debut limit p_max) t
$$;
revoke all on function public.pilotage_baux_a_lire(integer) from public, anon, authenticated;
grant execute on function public.pilotage_baux_a_lire(integer) to service_role;

select cron.unschedule('pilotage-lecture-baux') where exists (select 1 from cron.job where jobname = 'pilotage-lecture-baux');
select cron.schedule('pilotage-lecture-baux', '15 1 * * *', $$ select net.http_post(
  url := 'https://tanupqmphxadaxeksxjh.supabase.co/functions/v1/pilotage-lecture-bail',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-pilotage-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'pilotage_cron_secret')),
  body := '{}'::jsonb, timeout_milliseconds := 300000) $$);
