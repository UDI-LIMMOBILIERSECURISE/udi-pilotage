-- 142 : envoi automatique des mails depuis le pilotage (bloc unique), pour les relances groupées de Ma journée
--  Décisions de Nicolas du 11/11/2026 : dans Ma journée, sélectionner d'un coup toutes les alertes (et en décocher), puis lancer
--  l'action proposée (mail ou SMS) ; les mails partent automatiquement, depuis votregestionnaire@udi-immo.com.
--  Même principe que les SMS (066-067) : la fonction pilotage-mail vérifie les droits et les adresses ici, avec la session de
--  l'utilisateur, puis transmet le mail à un Zap (webhook Zapier → Gmail « Send Email » depuis votregestionnaire@udi-immo.com).
--  Adresse du webhook : secret ZAPIER_MAIL_WEBHOOK de la fonction (jamais dans le code ni dans le chat).
--  Seules les adresses du bail dans Rivage sont acceptées (locataires et bailleurs) : pas d'envoi à une adresse saisie à la main.
--  Une fois le mail transmis, l'étape de relance est marquée faite (comme pour un SMS) et le mail est tracé.

create table if not exists pilotage.mails_envois (
  id bigint generated always as identity primary key,
  bail_id text not null,
  destinataires text[] not null,
  objet text not null,
  corps text not null,
  cle text,
  etape text,
  par uuid,
  cree_le timestamptz not null default now(),
  statut text not null default 'prepare' check (statut in ('prepare', 'transmis', 'erreur')),
  transmis_le timestamptz,
  erreur text
);
alter table pilotage.mails_envois enable row level security;
revoke all on pilotage.mails_envois from public, anon, authenticated;

create or replace function public.pilotage_mail_preparer(p_bail text, p_to text[], p_objet text, p_corps text, p_cle text, p_etape text)
returns jsonb language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare c jsonb := pilotage.contacts_bail(p_bail); connues text[]; a text; nid bigint;
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() = 'comptable') then raise exception 'Accès refusé'; end if;
  if nullif(trim(coalesce(p_objet, '')), '') is null or nullif(trim(coalesce(p_corps, '')), '') is null then raise exception 'Mail vide'; end if;
  if coalesce(cardinality(p_to), 0) = 0 then raise exception 'Aucun destinataire'; end if;
  if cardinality(p_to) > 10 then raise exception 'Trop de destinataires'; end if;
  select coalesce(array_agg(distinct lower(trim(x->>'email'))), '{}') into connues
    from jsonb_array_elements(coalesce(c->'locataires', '[]'::jsonb) || coalesce(c->'bailleurs', '[]'::jsonb)) x
   where nullif(trim(x->>'email'), '') is not null;
  foreach a in array p_to loop
    if not lower(trim(a)) = any(connues) then raise exception 'Adresse % absente des contacts du bail dans Rivage', a; end if;
  end loop;
  insert into pilotage.mails_envois (bail_id, destinataires, objet, corps, cle, etape, par)
  values (p_bail, (select array_agg(lower(trim(x))) from unnest(p_to) x), trim(p_objet), p_corps, p_cle, p_etape, auth.uid())
  returning id into nid;
  return jsonb_build_object('id', nid, 'to', (select array_agg(lower(trim(x))) from unnest(p_to) x));
end $$;
revoke all on function public.pilotage_mail_preparer(text, text[], text, text, text, text) from public, anon;
grant execute on function public.pilotage_mail_preparer(text, text[], text, text, text, text) to authenticated;

create or replace function public.pilotage_mail_resultat(p_id bigint, p_ok boolean, p_erreur text, p_detail text)
returns void language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare e pilotage.mails_envois;
begin
  update pilotage.mails_envois set statut = case when p_ok then 'transmis' else 'erreur' end, erreur = p_erreur,
         transmis_le = case when p_ok then now() end
   where id = p_id returning * into e;
  if p_ok and e.cle is not null and e.etape is not null then
    insert into pilotage.suivis_etapes (cle, etape, par, detail)
    values (e.cle, e.etape, e.par, coalesce(p_detail, 'Mail envoyé') || ' (votregestionnaire@udi-immo.com, à ' || array_to_string(e.destinataires, ', ') || ')')
    on conflict (cle, etape) do update set fait_le = now(), par = excluded.par, detail = excluded.detail;
  end if;
end $$;
revoke all on function public.pilotage_mail_resultat(bigint, boolean, text, text) from public, anon, authenticated;
grant execute on function public.pilotage_mail_resultat(bigint, boolean, text, text) to service_role;
