-- 063 : IBAN du compte de l'agence pour les mails de demande de reversement du dépôt de garantie (Nicolas, 20/10/2026).
-- À exécuter après 062, à la main. L'IBAN est rangé dans les paramètres du pilotage (pas dans le code, le dépôt GitHub
-- étant public) et lu par les membres de l'équipe connectés. Rien n'est écrit dans Rivage.

insert into pilotage.parametres (cle, valeur) values ('iban_agence', 'FR76 1027 8060 5500 0208 4010 306')
on conflict (cle) do update set valeur = excluded.valeur;

create or replace function public.pilotage_iban_agence() returns text
language sql stable security definer set search_path = pilotage, public as $$
  select case when pilotage.mon_role() is not null then (select valeur from pilotage.parametres where cle = 'iban_agence') end
$$;
revoke all on function public.pilotage_iban_agence() from public, anon;
grant execute on function public.pilotage_iban_agence() to authenticated;

-- Contrôle
select cle, valeur from pilotage.parametres where cle = 'iban_agence';
