-- 148 : choix du dossier fait dans le module Gmail à la rédaction, gardé côté pilotage (sécurité si la ligne « Réf. dossier » est effacée)
--  Quand la personne clique sur un lot ou un ticket dans le panneau Gmail, le module ajoute la référence en bas du mail ET enregistre ce choix ici
--  (boîte, référence, destinataires et objet du brouillon à ce moment-là).
--  À la lecture d'un mail ENVOYÉ depuis cette boîte, la fonction pilotage-mails prend le choix en attente qui lui correspond :
--   - envoyé au plus 24 h après le clic ;
--   - au moins un destinataire en commun avec ceux du brouillon, ou, si le brouillon n'avait pas encore de destinataire, le même objet ;
--   - un choix ne sert qu'une fois (le plus ancien d'abord).
--  La référence trouvée dans l'objet ou le texte du mail reste prioritaire ; le choix ne sert que si elle a disparu.
--  Inchangé : un mail n'est gardé que s'il a un correspondant extérieur connu de Rivage et lié à un lot ou à un bail.

create table if not exists pilotage.mails_choix (
  id bigserial primary key,
  boite text not null,
  ref text not null check (ref ~ '^\[UDI L[A-Za-z0-9-]+( T\d+)?\]$'),
  destinataires text[] not null default '{}',
  objet text,
  cree_le timestamptz not null default now(),
  utilise_le timestamptz,
  message_id text
);
create index if not exists mails_choix_attente on pilotage.mails_choix (boite, cree_le) where utilise_le is null;
alter table pilotage.mails_choix enable row level security;
revoke all on pilotage.mails_choix from public, anon, authenticated;

-- Objet ramené à l'essentiel pour la comparaison (sans Re:/TR:, sans référence, espaces et casse ignorés)
create or replace function pilotage.mails_objet_norm(p text) returns text language sql immutable as $$
  select nullif(lower(regexp_replace(regexp_replace(regexp_replace(coalesce(p, ''), '\[UDI [^\]]*\]', '', 'g'),
    '^\s*((re|tr|fw|fwd)\s*:\s*)+', '', 'i'), '\s+', ' ', 'g')), '')
$$;

-- Module Gmail : enregistrer le choix (appelé par la fonction pilotage-gmail avec l'adresse vérifiée de la personne)
create or replace function public.pilotage_addon_choisir(p_email text, p_ref text, p_dest text[], p_objet text) returns void
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
begin
  if pilotage.addon_role(p_email) is null then raise exception 'Adresse % : pas d''accès au pilotage', p_email; end if;
  insert into pilotage.mails_choix (boite, ref, destinataires, objet)
  values (lower(trim(p_email)), p_ref,
          coalesce((select array_agg(distinct lower(trim(x))) from unnest(coalesce(p_dest, '{}')) x where x ~ '@' and lower(x) !~ '@udi-immo\.com$'), '{}'),
          nullif(trim(coalesce(p_objet, '')), ''));
  delete from pilotage.mails_choix where cree_le < now() - interval '30 days';
end $$;

-- Fonction pilotage-mails : prendre le choix en attente correspondant à un mail envoyé (null s'il n'y en a pas)
create or replace function public.pilotage_mails_choix_prendre(p_boite text, p_le timestamptz, p_dest text[], p_objet text, p_message_id text) returns text
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare c record;
begin
  select * into c from pilotage.mails_choix ch
   where ch.boite = lower(trim(p_boite)) and ch.utilise_le is null
     and ch.cree_le between p_le - interval '24 hours' and p_le + interval '5 minutes'
     and (ch.destinataires && (select array_agg(lower(trim(x))) from unnest(coalesce(p_dest, '{}')) x)
          or (cardinality(ch.destinataires) = 0 and pilotage.mails_objet_norm(ch.objet) = pilotage.mails_objet_norm(p_objet)))
   order by ch.cree_le limit 1 for update skip locked;
  if c.id is null then return null; end if;
  update pilotage.mails_choix set utilise_le = now(), message_id = p_message_id where id = c.id;
  return c.ref;
end $$;

revoke all on function public.pilotage_addon_choisir(text, text, text[], text), public.pilotage_mails_choix_prendre(text, timestamptz, text[], text, text)
  from public, anon, authenticated;
grant execute on function public.pilotage_addon_choisir(text, text, text[], text), public.pilotage_mails_choix_prendre(text, timestamptz, text[], text, text)
  to service_role;

-- ===================== Ajout d'un ancien mail depuis le module Gmail, et reprise de 6 mois d'historique =====================
-- « Ajouter au pilotage » (module Gmail) : un mail arrivé avant le branchement de la boîte est lu et rangé à la demande
--  (même règles que les autres : correspondant connu de Rivage et lié à un lot ou un bail, sinon rien n'est gardé).
-- Reprise d'historique : la fonction pilotage-mails remonte chaque boîte du plus récent au plus ancien, jusqu'à la date « depuis »,
--  avec le temps qui reste après les nouveaux mails à chaque passage (toutes les 5 min). Un mail sans correspondant connu de Rivage
--  est écarté sur ses seuls en-têtes (expéditeur, destinataires) : son texte n'est ni téléchargé ni lu.

create table if not exists pilotage.mails_reprise (
  boite text primary key references pilotage.mails_boites(adresse) on delete cascade,
  depuis timestamptz not null,               -- date la plus ancienne reprise
  curseur timestamptz not null,              -- prochain lot : mails envoyés ou reçus avant cette date
  vus integer not null default 0,
  gardes integer not null default 0,
  fini_le timestamptz,
  maj_le timestamptz not null default now()
);
alter table pilotage.mails_reprise enable row level security;
revoke all on pilotage.mails_reprise from public, anon, authenticated;

-- Un correspondant au moins est-il connu de Rivage (toutes périodes) ?
create or replace function public.pilotage_mails_connus(p_emails text[]) returns boolean
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select exists (select 1 from pilotage.mails_annuaire(p_emails))
$$;

-- Reprise en cours (une boîte à la fois, boîtes actives seulement)
create or replace function public.pilotage_mails_reprise_suivante() returns setof pilotage.mails_reprise
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select r.* from pilotage.mails_reprise r join pilotage.mails_boites b on b.adresse = r.boite and b.actif
   where r.fini_le is null order by r.boite limit 1
$$;
create or replace function public.pilotage_mails_reprise_maj(p_boite text, p_curseur timestamptz, p_vus integer, p_gardes integer, p_fini boolean)
returns void language sql security definer set search_path to 'pilotage', 'public' as $$
  update pilotage.mails_reprise set curseur = least(curseur, p_curseur), vus = vus + p_vus, gardes = gardes + p_gardes,
         fini_le = case when p_fini then now() end, maj_le = now() where boite = p_boite
$$;

-- Une boîte peut-elle être lue (branchée et active) ?
create or replace function public.pilotage_mails_boite_active(p_boite text) returns boolean
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select exists (select 1 from pilotage.mails_boites where adresse = lower(trim(p_boite)) and actif)
$$;

revoke all on function public.pilotage_mails_connus(text[]), public.pilotage_mails_reprise_suivante(),
  public.pilotage_mails_reprise_maj(text, timestamptz, integer, integer, boolean), public.pilotage_mails_boite_active(text) from public, anon, authenticated;
grant execute on function public.pilotage_mails_connus(text[]), public.pilotage_mails_reprise_suivante(),
  public.pilotage_mails_reprise_maj(text, timestamptz, integer, integer, boolean), public.pilotage_mails_boite_active(text) to service_role;

-- Reprise de 6 mois demandée par Nicolas le 12/11/2026 : boîtes de service et boîte de Nicolas.
-- Boîtes de Marion Gatti et Nicolas Sleman : à ajouter de la même façon quand elles sont informées de la reprise d'historique.
insert into pilotage.mails_reprise (boite, depuis, curseur)
select adresse, now() - interval '6 months', now() from pilotage.mails_boites
 where adresse in ('votregestionnaire@udi-immo.com', 'votrecomptable@udi-immo.com', 'nvedrines@udi-immo.com')
on conflict (boite) do nothing;
