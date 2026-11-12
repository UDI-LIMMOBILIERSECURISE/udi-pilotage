-- 156 : demande de reversement du dépôt reconnue sur le mail réellement envoyé au bailleur (constat de Nicolas du 12/11/2026, bail 279)
--  Le mail « Dépôt de garantie à reverser » envoyé au bailleur depuis Gmail a bien été rangé sur le lot et le bail, mais l'alerte
--  « Reversement du dépôt à demander au bailleur » restait : la demande n'est notée (dg_suivi.demande_le) que par le bouton du pilotage.
--  Désormais, un mail ENVOYÉ, rangé sur un bail en sortie (ou clos), adressé à un bailleur du dossier (destinataire ou copie), dont
--  l'objet ou le texte parle du dépôt de garantie et de son reversement, note la demande à la date du mail (ou une relance si la
--  demande était déjà notée plus tôt). Si le même mail annonce le départ du locataire (« quitte », « congé », « départ »), il compte aussi
--  comme le mail au bailleur de l'étape « Congé reçu » (journal des messages, moyen « gmail »).
--  Rattrapage des mails déjà rangés. Bloc unique.

begin;

create or replace function pilotage.mails_dg_demande() returns trigger
language plpgsql security definer set search_path to 'pilotage', 'public' as $$
declare txt text; b record;
begin
  if new.statut <> 'classe' or new.sens <> 'envoye' or new.bail_id is null then return new; end if;
  select id, statut into b from pilotage.v_baux where id = new.bail_id;
  if b.id is null or b.statut not in ('move_out', 'closed') then return new; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(new.parties, '[]'::jsonb)) p
                  where p->>'role' = 'bailleur' and lower(p->>'email') = any(select lower(x) from unnest(coalesce(new.a, '{}') || coalesce(new.cc, '{}')) x)) then
    return new;
  end if;
  txt := lower(coalesce(new.objet, '') || ' ' || coalesce(new.corps, new.extrait, ''));
  if txt ~ 'd[ée]p[ôo]t de garantie' and txt ~ 'revers' then
    insert into pilotage.dg_suivi (bail_id, demande_le, maj_le) values (new.bail_id, new.le::date, now())
    on conflict (bail_id) do update set
      demande_le = coalesce(pilotage.dg_suivi.demande_le, excluded.demande_le),
      relance_le = case when pilotage.dg_suivi.demande_le is not null and excluded.demande_le > pilotage.dg_suivi.demande_le
                        then greatest(coalesce(pilotage.dg_suivi.relance_le, excluded.demande_le), excluded.demande_le) else pilotage.dg_suivi.relance_le end,
      maj_le = now();
    if txt ~ '(quitte|cong[ée]|d[ée]part)' and b.statut = 'move_out'
       and not exists (select 1 from pilotage.messages_journal j where j.objet = 'bail' and j.objet_id = new.bail_id and j.code = 'cg_bailleur_email') then
      insert into pilotage.messages_journal (objet, objet_id, code, canal, a, objet_mail, texte, moyen, par, le)
      values ('bail', new.bail_id, 'cg_bailleur_email', 'email', array_to_string(new.a, ', '), new.objet, left(coalesce(new.extrait, ''), 500), 'gmail', null, new.le);
    end if;
  end if;
  return new;
end $$;
revoke all on function pilotage.mails_dg_demande() from public, anon, authenticated;

drop trigger if exists mails_dg_demande on pilotage.mails;
create trigger mails_dg_demande after insert or update of statut, bail_id on pilotage.mails
  for each row execute function pilotage.mails_dg_demande();

-- Rattrapage : mails déjà rangés (repasse par le déclencheur)
update pilotage.mails set bail_id = bail_id where statut = 'classe' and sens = 'envoye' and bail_id is not null
  and lower(coalesce(objet, '') || ' ' || coalesce(corps, extrait, '')) ~ 'd[ée]p[ôo]t de garantie';

select pilotage.executer_controles();

commit;

-- Vérification : select * from pilotage.dg_suivi where bail_id = (select id from pilotage.v_baux where reference = '279');
