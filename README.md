# Pilotage UDI Gestion

Appli web React/Vite branchée sur le schéma `pilotage` du projet Supabase d'UDIGESTION.
Connexion avec les comptes UDIGESTION existants. Les droits sont vérifiés dans la base
(fonctions `pilotage_*`), pas seulement à l'écran.

## Lancer en local
    npm install
    cp .env.example .env
    npm run dev

## Mettre en ligne (Vercel ou Netlify)
- Commande de build : `npm run build` — dossier publié : `dist`
- Variables d'environnement : `VITE_SUPABASE_URL` et `VITE_SUPABASE_PUBLISHABLE_KEY` (voir `.env.example`)
- Dans Supabase > Authentication > URL Configuration, ajouter l'adresse du site.

## Rôles
- direction : tout, y compris obligations, règles et équipe
- superviseur : journées de toute l'équipe + mandats et commissions
- gestionnaire, comptable, négociateur : sa propre journée uniquement
