-- 143 : une relance envoyée fait disparaître tout de suite l'alerte « suivi du bail » (retour de Nicolas du 11/11/2026)
--  Constat : après l'envoi groupé (142), l'étape est bien marquée faite, mais l'alerte bail_suivi restait ouverte dans Ma journée
--  jusqu'au passage suivant des contrôles (toutes les 30 min) ; la recocher ouvrait une fenêtre vide, bouton grisé.
--  Règle : dès qu'une étape de suivi est faite (mail auto, SMS, ou « fait » à la main), si plus aucune obligation active du bail
--  n'a d'étape à faire aujourd'hui, ses alertes bail_suivi / bail_suivi_retard passent « résolues ».
--  Sans risque : si quelque chose reste dû, le contrôle suivant la rouvre (une alerte résolue redétectée repasse « ouverte »).

create or replace function pilotage.resoudre_suivi_bail(p_cle text)
returns void language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare v_bail text;
begin
  v_bail := case when p_cle like 'e:%' then split_part(p_cle, ':', 2)
                 when p_cle like 'o:%' then (select o.bail_id from pilotage.baux_obligations o
                                              where o.id::text = split_part(p_cle, ':', 2)) end;
  if v_bail is null then return; end if;
  if exists (select 1 from pilotage.baux_obligations o, lateral pilotage.obligation_etat(o.id) e
              where o.bail_id = v_bail and (e->>'actif')::boolean is not false
                and jsonb_typeof(e->'a_faire') = 'object') then return; end if;
  update pilotage.alertes set statut = 'resolue', resolue_le = now()
   where regle in ('bail_suivi', 'bail_suivi_retard') and objet_type = 'LeasingContract'
     and objet_id = v_bail and statut = 'ouverte';
end $$;
revoke all on function pilotage.resoudre_suivi_bail(text) from public, anon, authenticated;

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
    perform pilotage.resoudre_suivi_bail(e.cle);
  end if;
end $$;

create or replace function public.pilotage_sms_resultat(p_id bigint, p_ok boolean, p_erreur text, p_detail text)
returns void language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare e pilotage.sms_envois;
begin
  update pilotage.sms_envois set statut = case when p_ok then 'transmis' else 'erreur' end, erreur = p_erreur,
         transmis_le = case when p_ok then now() end
   where id = p_id returning * into e;
  if p_ok and e.cle is not null and e.etape is not null then
    insert into pilotage.suivis_etapes (cle, etape, par, detail)
    values (e.cle, e.etape, e.par, coalesce(p_detail, 'SMS envoyé') || ' (UDI GESTION, au ' || e.telephone || ')')
    on conflict (cle, etape) do update set fait_le = now(), par = excluded.par, detail = excluded.detail;
    perform pilotage.resoudre_suivi_bail(e.cle);
  end if;
end $$;

create or replace function public.pilotage_suivi_etape(p_cle text, p_etape text, p_detail text, p_annuler boolean)
returns void language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if not pilotage.peut_suivre_baux() then raise exception 'Accès refusé'; end if;
  if p_cle !~ '^(e|o|m):' then raise exception 'Clé de suivi invalide'; end if;
  if p_annuler then delete from pilotage.suivis_etapes where cle = p_cle and etape = p_etape; return; end if;
  insert into pilotage.suivis_etapes (cle, etape, par, detail) values (p_cle, p_etape, auth.uid(), p_detail)
  on conflict (cle, etape) do update set fait_le = now(), par = auth.uid(), detail = excluded.detail;
  perform pilotage.resoudre_suivi_bail(p_cle);
end $$;

-- Rattrapage : alertes de suivi déjà envoyées aujourd'hui mais restées ouvertes
select pilotage.resoudre_suivi_bail('o:' || o.id || ':x')
  from pilotage.baux_obligations o
 where o.bail_id in (select objet_id from pilotage.alertes where regle in ('bail_suivi', 'bail_suivi_retard') and statut = 'ouverte');
