-- 149 : adresses secondaires des membres (décision de Nicolas du 12/11/2026)
--  Dans Gmail, Google présente une personne au module « Pilotage UDI » sous l'adresse PRINCIPALE de son compte Google.
--  Un membre du pilotage peut être inscrit sous une autre adresse du même compte : votrecomptable@ est une adresse secondaire
--  du compte d'Audrey Guillon, dont l'adresse principale est gestionnaire@. Sans correspondance, le panneau lui affiche
--  « pas d'accès au pilotage ».
--  Ici : table des correspondances (adresse vue par Google → adresse du membre dans le pilotage), utilisée partout où le module
--  identifie la personne : droits, classement à la main, choix du dossier à la rédaction, « Ajouter au pilotage » (sa boîte).
--  Aucune adresse n'est reconnue sans y être déclarée.

begin;

create table if not exists pilotage.membres_alias (
  alias text primary key check (alias = lower(trim(alias)) and alias ~ '@udi-immo\.com$'),
  adresse text not null check (adresse = lower(trim(adresse))),
  note text,
  cree_le timestamptz not null default now()
);
alter table pilotage.membres_alias enable row level security;
revoke all on pilotage.membres_alias from public, anon, authenticated;

insert into pilotage.membres_alias (alias, adresse, note) values
  ('gestionnaire@udi-immo.com', 'votrecomptable@udi-immo.com', 'Audrey Guillon : adresse principale du compte Google')
on conflict (alias) do update set adresse = excluded.adresse, note = excluded.note;

-- Adresse du membre dans le pilotage pour une adresse vue par Google
create or replace function pilotage.addon_adresse(p_email text) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select coalesce((select a.adresse from pilotage.membres_alias a where a.alias = lower(trim(p_email))), lower(trim(p_email)))
$$;
revoke all on function pilotage.addon_adresse(text) from public, anon, authenticated;

create or replace function pilotage.addon_role(p_email text) returns text
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select m.role from pilotage.membres m join auth.users u on u.id = m.user_id
   where lower(u.email) = pilotage.addon_adresse(p_email) and m.actif limit 1
$$;
revoke all on function pilotage.addon_role(text) from public, anon, authenticated;

create or replace function public.pilotage_addon_classer(p_email text, p_mail bigint, p_lot text, p_ticket text) returns jsonb
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare r text := pilotage.addon_role(p_email); m pilotage.mails; uid uuid;
begin
  if r is null or r not in ('direction', 'superviseur', 'gestionnaire', 'comptable') then raise exception 'Classement réservé à la gestion'; end if;
  select * into m from pilotage.mails where id = p_mail;
  if m.id is null then raise exception 'Mail introuvable dans le pilotage'; end if;
  if not exists (select 1 from pilotage.v_lots where id = p_lot) then raise exception 'Lot introuvable'; end if;
  if p_ticket is not null and not exists (select 1 from pilotage.objets where type = 'Incident' and id = p_ticket and data->>'asset_id' = p_lot) then raise exception 'Ticket introuvable sur ce lot'; end if;
  select u.id into uid from auth.users u where lower(u.email) = pilotage.addon_adresse(p_email);  -- 149
  update pilotage.mails set statut = 'classe', methode = 'manuel', confiance = 1, lot_id = p_lot, ticket_id = p_ticket,
         bail_id = pilotage.mails_bail_a(p_lot, le::date), mandat_id = (select mandat_id from pilotage.v_lots where id = p_lot),
         classe_par = uid, classe_le = now() where id = p_mail;
  insert into pilotage.mails_memoire (email, lot_id) select p->>'email', p_lot from jsonb_array_elements(m.parties) p on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.pilotage_addon_choisir(p_email text, p_ref text, p_dest text[], p_objet text) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.addon_role(p_email) is null then raise exception 'Adresse % : pas d''accès au pilotage', p_email; end if;
  insert into pilotage.mails_choix (boite, ref, destinataires, objet)
  values (pilotage.addon_adresse(p_email), p_ref,  -- 149 : la boîte relevée est celle du membre
          coalesce((select array_agg(distinct lower(trim(x))) from unnest(coalesce(p_dest, '{}')) x where x ~ '@' and lower(x) !~ '@udi-immo\.com$'), '{}'),
          nullif(trim(coalesce(p_objet, '')), ''));
  delete from pilotage.mails_choix where cree_le < now() - interval '30 days';
end $$;

-- « Ajouter au pilotage » : la fonction pilotage-gmail vérifie la boîte avec l'adresse vue par Google
create or replace function public.pilotage_mails_boite_active(p_boite text) returns boolean
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select exists (select 1 from pilotage.mails_boites where adresse in (lower(trim(p_boite)), pilotage.addon_adresse(p_boite)) and actif)
$$;
-- et la fonction pilotage-mails lit la boîte avec l'adresse qu'elle reçoit (gestionnaire@ ou votrecomptable@ : même boîte Gmail)

revoke all on function public.pilotage_addon_classer(text, bigint, text, text), public.pilotage_addon_choisir(text, text, text[], text),
  public.pilotage_mails_boite_active(text) from public, anon, authenticated;
grant execute on function public.pilotage_addon_classer(text, bigint, text, text), public.pilotage_addon_choisir(text, text, text[], text),
  public.pilotage_mails_boite_active(text) to service_role;

commit;
