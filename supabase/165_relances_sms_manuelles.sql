-- 165 : SMS de relance envoyés à la main depuis l'onglet Impayés (demande de Nicolas du 13/11/2026, 19 h 28)
--  « Active les relances SMS, comme ça on peut tout sélectionner ou juste un et envoyer les SMS, le message est éditable. »
--  Les relances automatiques (163) restent désactivées : elles ne rattrapent pas les impayés déjà ouverts. Ce lot ajoute un envoi
--  manuel, dans le bloc « Relances automatiques » de « À faire ce mois-ci » : cocher un, plusieurs ou tous les baux, modifier le
--  texte, envoyer. Envoi par la fonction pilotage-sms existante (Twilio, expéditeur UDI GESTION), numéros de Rivage seulement.
--  - public.pilotage_relances_sms_textes(p_baux, p_texte) : texte rempli bail par bail ({dette}, {adresse}, {constat_sms},
--    {reference}, {libelle_virement}, {iban} ; {nom} est remplacé ensuite pour chaque locataire) et nombre de portables connus.
--  - Un SMS envoyé est noté dans le dossier d'impayé (« Relance SMS envoyée à la main »), ce qui fait avancer la frise.
--  Aussi : « Signalé à l'organisme » ne propose plus un règlement de 0,00 € (date de paiement Rivage sans montant).
--  Bloc unique.

begin;

create or replace function public.pilotage_relances_sms_textes(p_baux text[], p_texte text)
returns jsonb language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare b text; ctx jsonb; orig jsonb; res jsonb := '[]'::jsonb; t text; n int;
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() = 'comptable') then raise exception 'Accès refusé'; end if;
  if nullif(trim(coalesce(p_texte, '')), '') is null then raise exception 'SMS vide'; end if;
  if cardinality(p_baux) > 200 then raise exception 'Trop de baux d''un coup (200 au plus)'; end if;
  select coalesce(jsonb_object_agg(x.bail_id, x.origine), '{}'::jsonb) into orig
    from pilotage.relances_impayes_candidats((now() at time zone 'Europe/Paris')::date) x where x.bail_id = any(p_baux);
  foreach b in array p_baux loop
    ctx := pilotage.messages_contexte('bail', b);
    ctx := ctx || jsonb_build_object(
      'dette', pilotage.euros((select round(coalesce((o.data->>'unpaid_amount')::numeric, 0) / 100, 2) from pilotage.objets o where o.type = 'LeasingContract' and o.id = b)),
      'constat_sms', case orig->>b when 'rejet' then 'votre prélèvement de loyer a été rejeté par votre banque'
                                    when 'prelevement' then 'votre loyer n''a pas pu être prélevé'
                                    else 'sauf erreur, votre loyer n''est pas réglé' end);
    t := pilotage.message_remplir(p_texte, ctx);
    select count(*) into n from jsonb_array_elements(coalesce(ctx->'_contacts'->'locataires', '[]'::jsonb)) x where pilotage.tel_portable(x->>'telephone') is not null;
    res := res || jsonb_build_object('bail_id', b, 'texte', t, 'portables', n,
      'manquants', (select coalesce(jsonb_agg(distinct m[1]), '[]'::jsonb) from regexp_matches(t, '\{([a-z_]+)\}', 'g') m where m[1] <> 'nom'));
  end loop;
  return res;
end $$;
revoke all on function public.pilotage_relances_sms_textes(text[], text) from public, anon;
grant execute on function public.pilotage_relances_sms_textes(text[], text) to authenticated;

-- SMS envoyé à la main (clé rim:<bail>:<jour>) : noté dans le dossier d'impayé, comme les relances automatiques (clé ri:<cycle>)
create or replace function pilotage.relance_impaye_vers_dossier() returns trigger
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_bail text; v_dossier bigint; lib text;
begin
  if new.cle like 'rim:%' then
    v_bail := split_part(new.cle, ':', 2);
    lib := 'Relance SMS envoyée à la main';
  elsif new.cle like 'ri:%' and coalesce(new.detail, '') not like 'Non envoyé%' then
    select bail_id into v_bail from pilotage.relances_impayes where id = nullif(split_part(new.cle, ':', 2), '')::bigint;
    lib := case new.etape when 'j0_sms' then 'Relance automatique : premier SMS' when 'j0_mail' then 'Relance automatique : premier mail'
                          when 'j2_sms' then 'Relance automatique : deuxième SMS' when 'j5_mail' then 'Relance automatique : mail ferme'
                          when 'med' then 'Mise en demeure envoyée' end;
  else
    return new;
  end if;
  select id into v_dossier from pilotage.impayes where bail_id = v_bail and groupe <> 'Clôturé' order by cree_le desc limit 1;
  if v_dossier is null or lib is null then return new; end if;
  if not exists (select 1 from pilotage.impayes_actions a where a.impaye_id = v_dossier and a.libelle = lib and a.le = current_date) then
    insert into pilotage.impayes_actions (impaye_id, libelle, statut, le, par) values (v_dossier, lib, 'Fait', current_date, new.par);
  end if;
  return new;
end $$;

-- Règlements à signaler : plus de ligne pour un paiement de 0,00 €
create or replace function pilotage.impayes_reglements()
returns table(dossier_id bigint, bail_id text, organisme text, recu_le date, montant numeric, indemnisation_compte numeric)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select d.id, d.bail_id, d.organisme, (b.data->>'received_rent_date')::date, round(coalesce((b.data->>'received_rent_amount')::numeric, 0) / 100, 2),
         (select round(sum(coalesce((c.data->>'credit_in_cents')::numeric, 0) - coalesce((c.data->>'debit_in_cents')::numeric, 0)) / 100, 2)
          from pilotage.objets c where c.type = 'AccountingAccount' and c.data->>'leasing_contract_id' = d.bail_id and c.data->>'holder_type' = 'gli_provider')
  from pilotage.impayes d join pilotage.objets b on b.type = 'LeasingContract' and b.id = d.bail_id
  where d.groupe <> 'Clôturé' and d.declaration_le is not null and d.organisme is not null and d.organisme <> 'aucun'
    and nullif(b.data->>'received_rent_date', '') is not null
    and coalesce((b.data->>'received_rent_amount')::numeric, 0) > 0   -- 165
    and (b.data->>'received_rent_date')::date > greatest(d.declaration_le, coalesce(d.reglement_signale_le, d.declaration_le))
$$;

commit;
