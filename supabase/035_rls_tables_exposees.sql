-- 035 : sécurité (17/10/2026). Le RLS est activé sur les 19 tables qui n'en avaient pas.
--   Aucune policy n'est ajoutée : ces tables ne sont lues que par les fonctions du pilotage (security definer) et par
--   les fonctions serveur (clé de service), qui ne sont pas soumises au RLS. Rien ne change à l'écran.
--   Le RLS ferme la porte si un droit était un jour ouvert par erreur à la clé publique (anon ou authenticated).

alter table public.wipimo_import_lots            enable row level security;
alter table public.wipimo_import_baux            enable row level security;
alter table public.wipimo_import_baux_full       enable row level security;
alter table public.wipimo_import_etat_locatif    enable row level security;
alter table public._wipimo_dedup_backup_biens    enable row level security;
alter table public._wipimo_dedup_backup_mandats  enable row level security;
alter table public._wipimo_dedup_backup_baux     enable row level security;
alter table public._wipimo_dedup_backup_baux_loc enable row level security;
alter table public._wipimo_dedup_backup_diag     enable row level security;
alter table public._wipimo_taux_backup_20260811  enable row level security;
alter table public._wipimo_loyer_revert_20260811 enable row level security;
alter table pilotage.resumes                     enable row level security;
alter table pilotage.impayes                     enable row level security;
alter table pilotage.impayes_actions             enable row level security;
alter table pilotage.impayes_notes               enable row level security;
alter table pilotage.syncs                       enable row level security;
alter table pilotage.mandats_suivi               enable row level security;
alter table pilotage.baux_suivi                  enable row level security;
alter table pilotage.commissions_factures        enable row level security;
