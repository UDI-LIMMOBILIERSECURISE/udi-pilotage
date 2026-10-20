-- 066 : envoi des SMS depuis le pilotage par Zapier et Twilio, expéditeur UDI GESTION (Nicolas, 20/10/2026)
--   Le bouton « Envoyer le SMS » d'une étape de relance appelle la fonction serveur pilotage-sms, qui transmet le SMS
--   au Zap (webhook Zapier → Twilio « Send SMS », expéditeur UDI GESTION). Le numéro est toujours celui du locataire
--   dans Rivage, jamais un numéro saisi à la main. Chaque envoi est tracé ici et coche l'étape du suivi.
--   L'adresse du webhook est un secret de la fonction (ZAPIER_SMS_WEBHOOK), jamais dans le code ni dans la base.

create table if not exists pilotage.sms_envois (
  id bigserial primary key,
  bail_id text not null,
  destinataire text,
  telephone text not null,
  texte text not null,
  cle text,
  etape text,
  statut text not null default 'a_envoyer' check (statut in ('a_envoyer', 'transmis', 'erreur')),
  erreur text,
  par uuid,
  cree_le timestamptz not null default now(),
  transmis_le timestamptz
);
alter table pilotage.sms_envois enable row level security;
create index if not exists sms_envois_bail on pilotage.sms_envois (bail_id, cree_le desc);

-- Préparer l'envoi (appelé par la fonction serveur avec la session de l'utilisateur) : droits, numéros du locataire, trace
create or replace function public.pilotage_sms_preparer(p_bail text, p_texte text, p_cle text, p_etape text) returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
declare loc jsonb; res jsonb := '[]'::jsonb; nid bigint; tel text;
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() = 'comptable') then raise exception 'Accès refusé'; end if;
  if nullif(trim(coalesce(p_texte, '')), '') is null then raise exception 'SMS vide'; end if;
  if length(p_texte) > 640 then raise exception 'SMS trop long (640 caractères au plus)'; end if;
  for loc in select x from jsonb_array_elements(coalesce(pilotage.contacts_bail(p_bail)->'locataires', '[]'::jsonb)) x loop
    tel := regexp_replace(coalesce(loc->>'telephone', ''), '[^0-9+]', '', 'g');
    if tel ~ '^0[67]\d{8}$' then tel := '+33' || substr(tel, 2); end if;
    continue when tel !~ '^\+\d{8,15}$';
    insert into pilotage.sms_envois (bail_id, destinataire, telephone, texte, cle, etape, par)
    values (p_bail, loc->>'nom', tel, trim(p_texte), p_cle, p_etape, auth.uid()) returning id into nid;
    res := res || jsonb_build_object('id', nid, 'telephone', tel, 'nom', loc->>'nom');
  end loop;
  if jsonb_array_length(res) = 0 then raise exception 'Aucun numéro de portable du locataire dans Rivage'; end if;
  return res;
end $$;
revoke all on function public.pilotage_sms_preparer(text, text, text, text) from public, anon;
grant execute on function public.pilotage_sms_preparer(text, text, text, text) to authenticated;

-- Résultat de la transmission à Zapier (fonction serveur uniquement) : statut de l'envoi, étape du suivi cochée si transmis
create or replace function public.pilotage_sms_resultat(p_id bigint, p_ok boolean, p_erreur text, p_detail text) returns void
language plpgsql security definer set search_path = pilotage, public as $$
declare e pilotage.sms_envois;
begin
  update pilotage.sms_envois set statut = case when p_ok then 'transmis' else 'erreur' end, erreur = p_erreur,
         transmis_le = case when p_ok then now() end
   where id = p_id returning * into e;
  if p_ok and e.cle is not null and e.etape is not null then
    insert into pilotage.suivis_etapes (cle, etape, par, detail)
    values (e.cle, e.etape, e.par, coalesce(p_detail, 'SMS envoyé') || ' (UDI GESTION, au ' || e.telephone || ')')
    on conflict (cle, etape) do update set fait_le = now(), par = excluded.par, detail = excluded.detail;
  end if;
end $$;
revoke all on function public.pilotage_sms_resultat(bigint, boolean, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_sms_resultat(bigint, boolean, text, text) to service_role;

-- SMS envoyés sur un bail (affichés dans la fiche)
create or replace function public.pilotage_sms_bail(p_bail text) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('le', s.cree_le, 'telephone', s.telephone, 'nom', s.destinataire, 'texte', s.texte,
           'statut', s.statut, 'erreur', s.erreur, 'par', pilotage.prenom_membre(s.par)) order by s.cree_le desc), '[]'::jsonb)
  from pilotage.sms_envois s where s.bail_id = p_bail and (pilotage.peut_traiter_dossier('bail', p_bail) or pilotage.mon_role() = 'comptable')
$$;
revoke all on function public.pilotage_sms_bail(text) from public, anon;
grant execute on function public.pilotage_sms_bail(text) to authenticated;

-- Contrôle
select count(*) sms_envois from pilotage.sms_envois;
