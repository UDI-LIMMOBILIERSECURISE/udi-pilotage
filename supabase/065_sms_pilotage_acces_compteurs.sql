-- 065 : SMS des relances envoyés par l'agence, pas par Rivage ; compteurs du bail lisibles par le commercial (Nicolas, 20/10/2026)
--   1. Rivage n'envoie pas les relances des compteurs ni de l'assurance : les étapes « SMS depuis Rivage » deviennent des SMS
--      préparés par le pilotage (texte prêt à copier, envoyé depuis le téléphone de l'agence), comme les mails.
--   2. « Accès refusé » sur la fiche d'un bail ouverte par un commercial (ou la comptable) : la lecture des compteurs et des
--      équipements du bail leur est ouverte. La saisie des relevés et le pilotage des relances restent à la gestion.

alter table pilotage.calendriers drop constraint if exists calendriers_canal_check;
alter table pilotage.calendriers add constraint calendriers_canal_check check (canal in ('mail_locataire', 'mail_bailleur', 'sms', 'sms_rivage', 'lrar', 'tache'));

update pilotage.calendriers set canal = 'sms', libelle = case
    when nature = 'assurance' then 'SMS au locataire : attestation d''assurance à transmettre (texte prêt, envoi depuis le téléphone de l''agence)'
    when nature = 'compteur' and modele = 'compteur_sms' then 'SMS de relance au locataire (texte prêt, envoi depuis le téléphone de l''agence)'
    when nature = 'compteur' and modele = 'compteur_sms3' then '3e relance : SMS au locataire (texte prêt, envoi depuis le téléphone de l''agence)'
    else replace(libelle, 'depuis Rivage', 'depuis le téléphone de l''agence') end
 where canal = 'sms_rivage';

do $$
declare
  f text; def text;
  ancien text := 'if not pilotage.peut_suivre_baux() then raise exception ''Accès refusé''; end if;';
  nouveau text := 'if not (pilotage.peut_suivre_baux() or pilotage.peut_traiter_dossier(''bail'', p_bail) or pilotage.mon_role() = ''comptable'') then raise exception ''Accès refusé''; end if;';
begin
  foreach f in array array['public.pilotage_bail_compteurs(text)', 'public.pilotage_bail_equipements(text)'] loop
    def := pg_get_functiondef(f::regprocedure);
    if (length(def) - length(replace(def, ancien, ''))) / length(ancien) <> 1 then raise exception 'Code inattendu dans %', f; end if;
    execute replace(def, ancien, nouveau);
  end loop;
end $$;

-- Contrôle
select nature, ordre, jours, canal, libelle from pilotage.calendriers where canal = 'sms' order by nature, ordre;
