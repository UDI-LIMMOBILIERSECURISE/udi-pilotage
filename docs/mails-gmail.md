# Historique des mails Gmail dans le pilotage (script 145) — mise en service

Préparé le 12/11/2026. À dérouler dans Chrome quand Nicolas donne le feu vert. Nicolas est administrateur Google Workspace (udi-immo.com).

## Ce qui est livré (PR « mails-echanges »)
- `supabase/145_mails_echanges.sql` : tables `pilotage.mails`, `mails_boites`, `mails_memoire`, annuaire des contacts Rivage par e-mail,
  rattachement (référence, conversation, mémoire, contact unique, IA), écrans (lot, ticket, à vérifier), tâche planifiée toutes les 5 min.
- Fonction `pilotage-mails` : lecture Gmail (compte de service, délégation sur le domaine), pièces jointes sur R2 (`mails/AAAA-MM/…`),
  résumé et choix par l'IA (Haiku), libellés Gmail « Pilotage/Classé », « Pilotage/À vérifier », « Privé ».
- Écrans : fiche du bien → « Échanges par mail » ; ticket → « Mails du ticket » ; page « Mails à vérifier » ; bandeau dans Ma journée.
- Boîtes prévues : votrecomptable@, votregestionnaire@, nvedrines@, mgatti@, nsleman@ — toutes INACTIVES au départ.

## Étapes (dans l'ordre)
1. Google Cloud (console.cloud.google.com), organisation udi-immo.com : créer le projet « udi-pilotage-mails ».
2. Activer l'API Gmail sur ce projet.
3. IAM → Comptes de service → créer « pilotage-mails » (aucun rôle à donner). Noter son « ID unique » (numérique).
4. Clés du compte de service → Ajouter une clé → JSON (fichier téléchargé sur le poste de Nicolas).
   Si la création est bloquée par la règle d'organisation « iam.disableServiceAccountKeyCreation » (active par défaut sur les
   organisations récentes) : Règles d'administration → cette règle → personnaliser pour le projet « udi-pilotage-mails » seulement
   (il faut le rôle Administrateur des règles d'administration au niveau de l'organisation).
5. Console d'administration (admin.google.com) → Sécurité → Accès et contrôle des données → Contrôles des API →
   Gérer la délégation au niveau du domaine → Ajouter : ID unique de l'étape 3, champ d'application
   `https://www.googleapis.com/auth/gmail.modify` (lecture des mails et pose des libellés ; pas d'envoi, pas de suppression).
6. Supabase → Edge Functions → Secrets → `GOOGLE_SA_JSON` = contenu complet du fichier JSON. Nicolas colle lui-même le contenu
   (la clé ne passe jamais par la conversation), puis supprime le fichier de son poste.
7. Passer le script 145, déployer `pilotage-mails`, fusionner les PR (99 puis mails-echanges).
8. Ouvrir les deux boîtes de service :
   `update pilotage.mails_boites set actif = true where adresse in ('votregestionnaire@udi-immo.com', 'votrecomptable@udi-immo.com');`
   (`import_jours = 0` : à partir de maintenant ; mettre par ex. 90 pour reprendre 3 mois d'historique.)
9. Test : un mail d'un contact Rivage connu vers votregestionnaire@ → dans les 5 min, libellé « Pilotage/Classé » dans Gmail,
   mail visible dans la fiche du lot. Contrôle : `select adresse, derniere_synchro, erreur from pilotage.mails_boites;`
10. Boîtes nominatives (nvedrines@, mgatti@, nsleman@) : seulement après remise de la note d'information aux personnes concernées.

## Règles
- Seuls les mails avec un correspondant extérieur (hors @udi-immo.com) connu de Rivage sont gardés ; le reste n'est ni lu par l'IA ni stocké.
- Libellé « Privé » posé dans Gmail = mail jamais repris.
- Pas de rattachement au hasard : sous 0,8 de confiance, le mail va dans « Mails à vérifier ». Un choix manuel est mémorisé pour ce correspondant.
- « Pas un dossier » : le mail est vidé de son contenu et ne revient plus.
- Mails envoyés depuis le pilotage : prochaine étape, ajouter la référence `[UDI L<lot> T<ticket>]` dans l'objet (rattachement certain des réponses).
- Phase 2 : module complémentaire Gmail (panneau latéral, recherche du lot / ticket à l'écriture).
