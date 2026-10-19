-- 050 : rafraîchissement des écrans à la réception d'un webhook Rivage (remplace toute relecture périodique)
-- À chaque webhook enregistré, un signal est diffusé sur le canal Realtime privé « pilotage ». Il ne contient que
-- le type d'objet Rivage modifié (Incident, LeasingContract…) : aucune donnée de gestion ne transite par le canal.
-- Seuls les membres actifs du pilotage peuvent écouter ce canal (politique sur realtime.messages).
-- Le signal ne peut jamais bloquer l'enregistrement du webhook (erreur avalée).
-- À passer après le 049. Aucun appel à l'API Rivage.

create or replace function public.pilotage_peut_ecouter() returns boolean
language sql stable security definer set search_path = pilotage, public as $$
  select pilotage.mon_role() is not null
$$;
revoke all on function public.pilotage_peut_ecouter() from public, anon;
grant execute on function public.pilotage_peut_ecouter() to authenticated;

drop policy if exists pilotage_ecoute on realtime.messages;
create policy pilotage_ecoute on realtime.messages for select to authenticated
  using (realtime.topic() = 'pilotage' and public.pilotage_peut_ecouter());

create or replace function pilotage.trg_webhook_signal() returns trigger
language plpgsql security definer set search_path = pilotage, public as $$
begin
  begin
    perform realtime.send(jsonb_build_object('type', new.model_name), 'rivage', 'pilotage', true);
  exception when others then
    raise warning 'signal pilotage non envoyé : %', sqlerrm;
  end;
  return null;
end $$;

-- Après le déclencheur « pilotage_reflet » (ordre alphabétique) : l'objet est déjà à jour quand l'écran relit
drop trigger if exists pilotage_signal on public.rivage_webhook_events;
create trigger pilotage_signal after insert on public.rivage_webhook_events
  for each row execute function pilotage.trg_webhook_signal();

-- Contrôle : doit renvoyer true, true
select exists (select 1 from pg_trigger where tgname = 'pilotage_signal') declencheur,
       exists (select 1 from pg_policies where schemaname = 'realtime' and policyname = 'pilotage_ecoute') politique;
