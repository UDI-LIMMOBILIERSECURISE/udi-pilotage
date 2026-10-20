-- 067 : SMS personnalisés (Nicolas, 20/10/2026) : chaque SMS du pilotage nomme la personne à qui il est adressé.
--   Dans le texte, « {nom} » est remplacé, pour chaque locataire, par son prénom et son nom repris de Rivage,
--   sans la civilité (« mrs Kellia PIERS » → « Kellia PIERS »). Le texte envoyé et tracé est le texte personnalisé.

create or replace function pilotage.nom_sms(p_nom text) returns text
language sql immutable as $$
  select trim(regexp_replace(coalesce(p_nom, ''), '^\s*(mr|mrs|ms|miss|m\.|mme|mlle|monsieur|madame|mademoiselle)\s+', '', 'i'))
$$;

create or replace function public.pilotage_sms_preparer(p_bail text, p_texte text, p_cle text, p_etape text) returns jsonb
language plpgsql security definer set search_path = pilotage, public as $$
declare loc jsonb; res jsonb := '[]'::jsonb; nid bigint; tel text; nom text; txt text;
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() = 'comptable') then raise exception 'Accès refusé'; end if;
  if nullif(trim(coalesce(p_texte, '')), '') is null then raise exception 'SMS vide'; end if;
  for loc in select x from jsonb_array_elements(coalesce(pilotage.contacts_bail(p_bail)->'locataires', '[]'::jsonb)) x loop
    tel := regexp_replace(coalesce(loc->>'telephone', ''), '[^0-9+]', '', 'g');
    if tel ~ '^0[67]\d{8}$' then tel := '+33' || substr(tel, 2); end if;
    continue when tel !~ '^\+\d{8,15}$';
    nom := pilotage.nom_sms(loc->>'nom');
    txt := trim(replace(p_texte, '{nom}', nom));
    if length(txt) > 640 then raise exception 'SMS trop long (640 caractères au plus)'; end if;
    insert into pilotage.sms_envois (bail_id, destinataire, telephone, texte, cle, etape, par)
    values (p_bail, nom, tel, txt, p_cle, p_etape, auth.uid()) returning id into nid;
    res := res || jsonb_build_object('id', nid, 'telephone', tel, 'nom', nom, 'texte', txt);
  end loop;
  if jsonb_array_length(res) = 0 then raise exception 'Aucun numéro de portable du locataire dans Rivage'; end if;
  return res;
end $$;
revoke all on function public.pilotage_sms_preparer(text, text, text, text) from public, anon;
grant execute on function public.pilotage_sms_preparer(text, text, text, text) to authenticated;

-- Contrôle
select pilotage.nom_sms('mrs Kellia PIERS') exemple_1, pilotage.nom_sms('M. Jean DUPONT') exemple_2, pilotage.nom_sms('SARL TECHSTAR') exemple_3;
