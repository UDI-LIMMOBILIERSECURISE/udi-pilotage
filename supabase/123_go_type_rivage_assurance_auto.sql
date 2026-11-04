-- 123 : GO sans ressaisie du type de bail, assurance du locataire reprise de Rivage (Nicolas, 04/11/2026, bail 530 SARAGA)
--  1. « Valider le dossier » refusait le GO (« Confirmez d'abord le type de bail ») quand aucun type n'était saisi dans la fiche,
--     règle d'avant 099. Désormais le type de Rivage suffit quand le point « Type de bail » du contrôle est conforme
--     (même famille que le bail lu par l'IA, ou bail pas encore lu : règles 099 et 119). Écart avec le bail lu : refus maintenu.
--  2. Attestation d'assurance déposée dans Rivage avec une date de fin de validité (Upload home_insurance_certificate,
--     expiration_date) : sur un nouveau bail en cours, le suivi « Attestation d'assurance » (12 mois) est créé à cette date
--     et la question « Assurance : justification annuelle » est répondue (« valable jusqu'au … (Rivage) »), sans saisie.
--     Bail 530 : attestation déposée le 04/11 à 07 h 54, valable jusqu'au 06/11/2027, suivi ressaisi à la main à 10 h.
--  3. Renouvellement : quand une nouvelle attestation est reconnue comme justificatif, l'échéance suivante est sa date de fin
--     de validité dans Rivage (avant : ancienne échéance + 12 mois).
--  Rien n'est écrit dans Rivage. Un suivi ou une réponse existants ne sont jamais modifiés par le point 2.

-- 1. GO : type de Rivage accepté quand le point du contrôle est conforme
do $$
declare def text := pg_get_functiondef('public.pilotage_bail_go'::regproc);
        a text := $a$    if not exists (select 1 from pilotage.baux_fiche where bail_id = p_bail and type_bail is not null) then raise exception 'Confirmez d''abord le type de bail'; end if;$a$;
begin
  if position('123 :' in def) = 0 then
    if position(a in def) = 0 then raise exception '123 : ancre introuvable dans pilotage_bail_go'; end if;
    execute replace(def, a, $b$    -- 123 : type de Rivage suffisant quand le point « Type de bail » est conforme (concorde avec le bail lu, ou bail pas encore lu)
    if not exists (select 1 from pilotage.baux_fiche where bail_id = p_bail and type_bail is not null)
       and not (pilotage.type_bail_rivage(p_bail) is not null
                and exists (select 1 from jsonb_array_elements(c->'items') i where i->>'ref' = 'type_bail' and i->>'statut' = 'ok')) then
      raise exception 'Confirmez d''abord le type de bail (Rivage ne le donne pas ou il diffère du bail lu)';
    end if;$b$);
  end if;
end $$;

-- 2. Assurance du locataire reprise de Rivage
create or replace function pilotage.assurance_rivage_auto()
returns integer language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare n integer := 0; x record; cle text; nid bigint;
begin
  for x in
    select b.id bail_id, b.lot_id, u.id upload_id, u.maj_le::date depose_le, (u.data->>'expiration_date')::date fin
      from pilotage.v_baux b
      cross join lateral (
        select u.* from pilotage.objets u
         where u.type = 'Upload' and u.supprime_le is null and u.data->>'nature' = 'home_insurance_certificate'
           and nullif(u.data->>'expiration_date', '')::date > current_date
           and exists (select 1 from jsonb_array_elements(coalesce(u.data->'resourceables', '[]'::jsonb)) rr where rr->>'id' in (b.id, b.lot_id))
         order by nullif(u.data->>'expiration_date', '')::date desc limit 1) u
     where b.statut in ('created', 'move_in', 'in_progress') and (b.fin is null or b.fin > current_date)
       and pilotage.dossier_nouveau('LeasingContract', b.id)
  loop
    cle := case when pilotage.portee_bail_id(x.bail_id) = 'commercial' then 'c_cl_assurance' else 'h_cl_assurance' end;
    -- suivi créé seulement s'il n'y en a aucun d'actif
    if not exists (select 1 from pilotage.baux_obligations o where o.bail_id = x.bail_id and o.nature = 'assurance' and o.actif) then
      insert into pilotage.baux_obligations (bail_id, nature, libelle, periodicite_mois, prochaine, derniere_le)
      values (x.bail_id, 'assurance', 'Attestation d’assurance', 12, x.fin, x.depose_le) returning id into nid;
      insert into pilotage.obligations_justificatifs (upload_id, obligation_id) values (x.upload_id, nid) on conflict do nothing;
      n := n + 1;
    end if;
    -- question répondue seulement si personne n'y a répondu
    insert into pilotage.baux_reponses (bail_id, cle, statut, suivi, valeur)
    values (x.bail_id, cle, 'ok', 'backoffice', 'Attestation valable jusqu’au ' || to_char(x.fin, 'DD/MM/YYYY') || ' (Rivage)')
    on conflict (bail_id, cle) do nothing;
  end loop;
  return n;
end $$;

-- 3. Renouvellement : échéance = fin de validité de la nouvelle attestation
do $$
declare def text := pg_get_functiondef('pilotage.appliquer_justificatifs'::regproc);
        a1 text := 'u.maj_le::date as le into up';
        a2 text := 'suivante := case';
begin
  if position('123 :' in def) = 0 then
    if position(a1 in def) = 0 or position(a2 in def) = 0 then raise exception '123 : ancre introuvable dans appliquer_justificatifs'; end if;
    def := replace(def, a1, $b$u.maj_le::date as le, nullif(u.data->>'expiration_date', '')::date as fin into up$b$);
    def := replace(def, a2, $b$suivante := case
      -- 123 : attestation d'assurance, échéance = sa date de fin de validité dans Rivage
      when ob.nature = 'assurance' and up.fin > current_date then up.fin$b$);
    execute def;
  end if;
end $$;

-- Passage avant chaque contrôle (toutes les 30 minutes)
do $$
declare def text := pg_get_functiondef('pilotage.executer_controles'::regproc);
        a text := 'create temp table _det on commit drop as';
begin
  if position('assurance_rivage_auto' in def) = 0 then
    if position(a in def) = 0 then raise exception '123 : ancre introuvable dans executer_controles'; end if;
    execute replace(def, a, 'perform pilotage.assurance_rivage_auto();
  ' || a);
  end if;
end $$;

select pilotage.executer_controles();
-- Vérification : suivis d'assurance créés par Rivage (sans auteur) et réponses automatiques
select b.reference, o.prochaine, o.cree_le from pilotage.baux_obligations o join pilotage.v_baux b on b.id = o.bail_id
 where o.nature = 'assurance' and o.par is null and o.cree_le > now() - interval '5 minutes';
