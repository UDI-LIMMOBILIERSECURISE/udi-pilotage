-- 169 : rattachement d'un mail à une société bailleresse (profil Rivage), écran « Mails à vérifier » en trois questions
-- Décision de Nicolas du 14/11/2026 : pour une demande globale comme « tous les CRG de RB2M », le mail se range sur la société
-- (RB2M seule), pas sur l'adresse mail entière (qui couvre aussi BEYLERBEY 2). Le niveau « bailleur = adresse mail » du 168 reste
-- (références [UDI B<n°>] du module Gmail, classement automatique) ; le niveau société s'ajoute à côté.
-- Niveaux d'un mail classé, du plus fin au plus large : lot, immeuble (151), mandat (168), société (169), bailleur = adresse (168).
--   société : bailleur_profil renseigné (identifiant du profil Rivage) ; mandat_id rempli aussi si la société n'a qu'un mandat.
--   Le mail apparaît dans les échanges de chaque lot des mandats de la société, et sur la fiche bailleur de son adresse.
-- « Mails à vérifier » : sociétés du correspondant proposées, lots candidats rattachés à leur(s) société(s) pour les regrouper,
-- compteur des mails triés dans la journée.
-- Aucune suppression de données. À passer en 2 blocs (chaque bloc commence par « 169 — bloc N sur 2 »).

-- 169 — bloc 1 sur 2
begin;

alter table pilotage.mails add column if not exists bailleur_profil text;
create index if not exists mails_bailleur_profil on pilotage.mails (bailleur_profil) where bailleur_profil is not null;

-- Mandats (non supprimés) d'un profil propriétaire
create or replace function pilotage.profil_mandats(p_profil text) returns setof text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select distinct m.id
    from pilotage.objets m cross join jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
   where m.type = 'ManagementContract' and m.supprime_le is null and p->>'profile_id' = p_profil and nullif(trim(p_profil), '') is not null
$$;

-- Profils propriétaires d'un mandat
create or replace function pilotage.mandat_profils(p_mandat text) returns text[]
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce(array_agg(distinct p->>'profile_id'), '{}')
    from pilotage.objets m cross join jsonb_array_elements(coalesce(m.data->'profile_contracts_attributes', '[]'::jsonb)) p
   where m.type = 'ManagementContract' and m.id = p_mandat
$$;

create or replace function pilotage.societe_info(p_profil text) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('niveau', 'societe', 'profil_id', pr.id, 'nom', pilotage.nom_profil(pr.id), 'email', lower(trim(pr.data->>'email')),
           'mandats', (select count(*) from pilotage.profil_mandats(pr.id)),
           'lots', (select count(*) from pilotage.v_lots l where l.mandat_id in (select pilotage.profil_mandats(pr.id))))
    from pilotage.objets pr where pr.type = 'Profile' and pr.id = p_profil
$$;

-- Sociétés (profils propriétaires ayant au moins un mandat) des correspondants d'un mail
create or replace function pilotage.mails_societes(p_emails text[]) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  with e as (select distinct lower(trim(x)) x from unnest(coalesce(p_emails, '{}')) x where x ~ '@' and lower(x) !~ '@udi-immo\.com$'),
  s as (select pilotage.societe_info(pr.id) i from pilotage.objets pr
         where pr.type = 'Profile' and lower(trim(pr.data->>'email')) in (select x from e)
           and exists (select 1 from pilotage.profil_mandats(pr.id)))
  select coalesce(jsonb_agg(i order by (i->>'lots')::int desc, i->>'nom'), '[]'::jsonb) from s
$$;

revoke all on function pilotage.profil_mandats(text), pilotage.mandat_profils(text), pilotage.societe_info(text), pilotage.mails_societes(text[])
  from public, anon, authenticated;

-- Cohérence : un classement plus fin (lot, immeuble) ou un mail non classé efface les niveaux société et bailleur ;
-- un classement au niveau de l'adresse efface le niveau société.
create or replace function pilotage.mails_niveau_coherent() returns trigger
language plpgsql as $$
begin
  if new.lot_id is not null or new.immeuble_id is not null or new.statut <> 'classe' then
    new.bailleur_email := null; new.bailleur_profil := null;
  end if;
  if new.bailleur_email is not null then new.bailleur_profil := null; end if;
  return new;
end $$;

-- Classement mandat / adresse (168) : efface aussi le niveau société
create or replace function pilotage.mail_classer_niveau(p_id bigint, p_mandat text, p_bailleur text, p_par uuid) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_m text := nullif(trim(coalesce(p_mandat, '')), ''); v_b text := nullif(lower(trim(coalesce(p_bailleur, ''))), '');
begin
  if not exists (select 1 from pilotage.mails where id = p_id) then raise exception 'Mail introuvable'; end if;
  if (v_m is null) = (v_b is null) then raise exception 'Choisir un mandat ou un bailleur'; end if;
  if v_m is not null and not exists (select 1 from pilotage.v_mandats where id = v_m) then raise exception 'Mandat introuvable'; end if;
  if v_b is not null and not exists (select 1 from pilotage.bailleur_mandats(v_b)) then raise exception 'Aucun mandat Rivage pour l''adresse %', v_b; end if;
  perform pilotage.bailleurs_maj();
  update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = null, bail_id = null, ticket_id = null, immeuble_id = null,
         mandat_id = v_m, bailleur_email = v_b, bailleur_profil = null, classe_par = p_par, classe_le = now() where id = p_id;
end $$;
revoke all on function pilotage.mail_classer_niveau(bigint, text, text, uuid) from public, anon, authenticated;

-- Classement au niveau d'une société
create or replace function public.pilotage_mail_classer_societe(p_id bigint, p_profil text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare md text[];
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  if not exists (select 1 from pilotage.mails where id = p_id) then raise exception 'Mail introuvable'; end if;
  select array_agg(x) into md from pilotage.profil_mandats(p_profil) x;
  if md is null then raise exception 'Aucun mandat Rivage pour cette société'; end if;
  update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = null, bail_id = null, ticket_id = null, immeuble_id = null,
         mandat_id = case when cardinality(md) = 1 then md[1] end, bailleur_email = null, bailleur_profil = p_profil,
         classe_par = auth.uid(), classe_le = now() where id = p_id;
  return jsonb_build_object('ignore', false);
end $$;
revoke all on function public.pilotage_mail_classer_societe(bigint, text) from public, anon;
grant execute on function public.pilotage_mail_classer_societe(bigint, text) to authenticated;

commit;

-- 169 — bloc 2 sur 2
begin;

-- Ligne d'un mail : niveau société en plus (repris du 168)
create or replace function pilotage.mails_ligne(m pilotage.mails) returns jsonb
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select jsonb_build_object('id', m.id, 'thread_id', m.thread_id, 'sens', m.sens, 'de', m.de, 'a', m.a, 'cc', m.cc, 'objet', m.objet, 'le', m.le,
    'resume', m.resume, 'extrait', m.extrait, 'pj', (select coalesce(jsonb_agg(jsonb_build_object('nom', x->>'nom', 'taille', x->>'taille', 'cle', x->>'cle')), '[]'::jsonb) from jsonb_array_elements(m.pj) x),
    'parties', m.parties, 'statut', m.statut, 'methode', m.methode, 'lot_id', m.lot_id, 'bail_id', m.bail_id, 'ticket_id', m.ticket_id,
    'lot', (select reference from pilotage.v_lots where id = m.lot_id), 'adresse', (select adresse from pilotage.v_lots where id = m.lot_id),
    'bail', (select reference from pilotage.v_baux where id = m.bail_id),
    'ticket', (select jsonb_build_object('numero', i.data->>'number', 'titre', i.data->>'title') from pilotage.objets i where i.type = 'Incident' and i.id = m.ticket_id),
    'immeuble_id', m.immeuble_id, 'immeuble', case when m.immeuble_id is not null then pilotage.immeuble_libelle(m.immeuble_id) end,
    'boites', (select array_agg(k) from jsonb_object_keys(m.boites) k),
    'mandat_id', m.mandat_id, 'bailleur_email', m.bailleur_email, 'bailleur_profil', m.bailleur_profil,
    'niveau', case when m.statut <> 'classe' then null when m.lot_id is not null then 'lot' when m.immeuble_id is not null then 'immeuble'
                   when m.bailleur_profil is not null then 'societe' when m.bailleur_email is not null then 'bailleur'
                   when m.mandat_id is not null then 'mandat' end,
    'mandat', case when m.lot_id is null and m.immeuble_id is null and m.bailleur_profil is null and m.mandat_id is not null then pilotage.mandat_info(m.mandat_id) end,
    'societe', case when m.bailleur_profil is not null then pilotage.societe_info(m.bailleur_profil) end,
    'bailleur', case when m.bailleur_email is not null then pilotage.bailleur_info(m.bailleur_email) end)
$$;

-- Mails à vérifier : sociétés du correspondant, lots candidats avec leur(s) société(s)
create or replace function public.pilotage_mails_a_verifier() returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(pilotage.mails_ligne(m) || jsonb_build_object(
                     'candidats', (select jsonb_agg(c || jsonb_build_object('societes', to_jsonb(pilotage.mandat_profils(c->>'mandat_id'))))
                                     from jsonb_array_elements(coalesce(m.candidats, '[]'::jsonb)) c),
                     'confiance', m.confiance,
                     'niveaux', pilotage.mails_niveaux(array[m.de] || m.a || m.cc),
                     'societes', pilotage.mails_societes(array[m.de] || m.a || m.cc)) order by m.le desc)
                     from pilotage.mails m where m.statut = 'a_verifier'), '[]'::jsonb);
end $$;

-- Mails triés à la main aujourd'hui (heure de Paris) : par moi et par l'équipe
create or replace function public.pilotage_mails_tri_jour() returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare d timestamptz := (date_trunc('day', now() at time zone 'Europe/Paris')) at time zone 'Europe/Paris';
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  return jsonb_build_object(
    'equipe', (select count(*) from pilotage.mails where methode = 'manuel' and classe_le >= d and statut in ('classe', 'ignore')),
    'moi', (select count(*) from pilotage.mails where methode = 'manuel' and classe_le >= d and statut in ('classe', 'ignore') and classe_par = auth.uid()));
end $$;
revoke all on function public.pilotage_mails_tri_jour() from public, anon;
grant execute on function public.pilotage_mails_tri_jour() to authenticated;

-- Échanges d'un lot : plus les mails rangés au niveau d'une société propriétaire de son mandat
create or replace function public.pilotage_mails_lot(p_asset text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare v_m text := (select mandat_id from pilotage.v_lots where id = p_asset);
begin
  if pilotage.mon_role() is null or not pilotage.voit_tableau('sinistres', v_m) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(pilotage.mails_ligne(m) order by m.le desc) from pilotage.mails m
     where m.statut = 'classe' and (m.lot_id = p_asset
        or (m.lot_id is null and m.immeuble_id is null and m.bailleur_email is null and m.mandat_id = v_m)
        or (m.lot_id is null and m.immeuble_id is null and m.bailleur_email is not null
            and v_m in (select pilotage.bailleur_mandats(m.bailleur_email)))
        or (m.lot_id is null and m.immeuble_id is null and m.bailleur_profil is not null
            and v_m in (select pilotage.profil_mandats(m.bailleur_profil))))), '[]'::jsonb);
end $$;

-- Fiche bailleur (168) : mails rangés sur une société de cette adresse en plus
create or replace function public.pilotage_bailleur(p_email text) returns jsonb
language plpgsql stable security definer set search_path to 'pilotage', 'public' as $$
declare e text := lower(trim(coalesce(p_email, ''))); md text[]; pf text[];
begin
  if not (pilotage.peut_suivre_baux() or pilotage.mon_role() in ('direction', 'comptable')) then raise exception 'Accès refusé'; end if;
  select array_agg(x) into md from pilotage.bailleur_mandats(e) x;
  if md is null then raise exception 'Aucun mandat Rivage pour l''adresse %', e; end if;
  select coalesce(array_agg(pr.id), '{}') into pf from pilotage.objets pr where pr.type = 'Profile' and lower(trim(pr.data->>'email')) = e;
  return pilotage.bailleur_info(e) || jsonb_build_object(
    'mandats', (select jsonb_agg(pilotage.mandat_info(vm.id) || jsonb_build_object('lots_detail',
                   (select coalesce(jsonb_agg(jsonb_build_object('lot_id', l.id, 'lot', l.reference, 'adresse', l.adresse,
                            'bail', vb.reference, 'locataires', vb.locataires, 'impaye', vb.impaye) order by l.reference), '[]'::jsonb)
                      from pilotage.v_lots l left join pilotage.v_baux vb on vb.id = pilotage.mails_bail_a(l.id, current_date)
                     where l.mandat_id = vm.id)) order by trim(vm.reference))
                  from pilotage.v_mandats vm where vm.id = any(md)),
    'tickets', (select coalesce(jsonb_agg(jsonb_build_object('ticket_id', i.id, 'numero', i.data->>'number', 'titre', i.data->>'title',
                   'lot', l.reference, 'declare_le', (i.data->>'declared_at')::date) order by i.data->>'declared_at' desc), '[]'::jsonb)
                  from pilotage.objets i join pilotage.v_lots l on l.id = i.data->>'asset_id'
                 where i.type = 'Incident' and i.supprime_le is null and l.mandat_id = any(md)
                   and coalesce(i.data->>'status', '') not in ('closed', 'resolved', 'cancelled') and i.data->>'archived_at' is null),
    'mails', (select coalesce(jsonb_agg(pilotage.mails_ligne(m) order by m.le desc), '[]'::jsonb) from (
                select * from pilotage.mails m where m.statut = 'classe'
                   and (m.bailleur_email = e or m.mandat_id = any(md) or m.bailleur_profil = any(pf))
                 order by m.le desc limit 300) m));
end $$;
revoke all on function public.pilotage_bailleur(text) from public, anon;
grant execute on function public.pilotage_bailleur(text) to authenticated;

commit;

-- Vérification (à lancer après les 2 blocs) : la colonne existe, les sociétés de mechety@outlook.fr sont proposées (BEYLERBEY 2 et RB2M)
-- select pilotage.mails_societes(array['mechety@outlook.fr']);
