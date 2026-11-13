-- 162 : impayés à déclarer à Zelok sans les loyers du mois encore en attente de prélèvement (décision de Nicolas du 13/11/2026)
--  Constat du 13/11 : 48 baux « à déclarer », dont 31 avec une dette d'un mois de loyer ou moins, tous ouverts depuis le 4/11 :
--  les loyers de novembre pas encore encaissés (prélèvements le 5 et le 10), pas des impayés à déclarer.
--  Règle : avant le 16 du mois (ouverture des déclarations Zelok), l'échéance du mois en cours (loyer + charges du bail) est
--  considérée en attente et retirée de la dette ; un bail n'est « à déclarer » que s'il reste une dette au-delà. À partir du 16,
--  l'échéance du mois compte : un loyer prélevé le 5 ou le 10 et toujours impayé le 16 est un impayé.
--  - pilotage.dette_hors_mois(p_bail) : dette retenue (euros), selon cette règle.
--  - pilotage.impayes_a_declarer() : même signature, filtre sur la dette retenue.
--  - public.pilotage_impayes_mois() : ajoute « en_attente » (baux Zelok dont toute la dette est l'échéance du mois, avant le 16)
--    pour l'afficher en une ligne au lieu de les compter comme à déclarer.
--  Bloc unique.

begin;

create or replace function pilotage.dette_hors_mois(p_bail text) returns numeric
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select round(coalesce((b.data->>'unpaid_amount')::numeric, 0) / 100, 2)
         - case when pilotage.jour_paris() < 16 then coalesce(v.loyer_hc, 0) + coalesce(v.charges, 0) else 0 end
    from pilotage.objets b left join pilotage.v_baux v on v.id = b.id
   where b.type = 'LeasingContract' and b.id = p_bail
$$;

create or replace function pilotage.impayes_a_declarer()
 returns table(bail_id text, dossier_id bigint, dette numeric, ouvert_le timestamp with time zone)
language sql stable security definer set search_path to 'pilotage', 'public' as $$
  select b.id, (select d.id from pilotage.impayes d where d.bail_id = b.id and d.groupe <> 'Clôturé' order by d.cree_le desc limit 1),
         round(coalesce((b.data->>'unpaid_amount')::numeric, 0) / 100, 2), (pilotage.cycle_impaye(b.id)->>'ouvert_le')::timestamptz
  from pilotage.objets b
  where b.type = 'LeasingContract' and b.supprime_le is null and pilotage.organisme_bail(b.id) = 'zelok'
    and (coalesce((pilotage.cycle_impaye(b.id)->>'ouvert')::boolean, false)
         or coalesce((b.data->>'unpaid_amount')::numeric, 0) > greatest(coalesce((b.data->>'unpaid_threshold_amount_in_cents')::numeric, 0), 0))
    and pilotage.dette_hors_mois(b.id) > 1   -- 162 : échéance du mois en attente retirée avant le 16 (1 € de tolérance d'arrondi)
    and coalesce(pilotage.cycle_impaye(b.id)->>'statut', '') not in ('gli_reported', 'long_contentious')
    and not exists (select 1 from pilotage.impayes d where d.bail_id = b.id and d.groupe <> 'Clôturé' and d.declaration_le is not null
                    and d.declaration_le >= coalesce((pilotage.cycle_impaye(b.id)->>'ouvert_le')::date, d.declaration_le))
$$;

do $bloc$
declare d text; a text;
begin
  d := replace(pg_get_functiondef('public.pilotage_impayes_mois()'::regprocedure), E'\r\n', E'\n');
  if position('en_attente' in d) = 0 then
    a := $t$    'sans_organisme', (select count(*) from pilotage.impayes where groupe <> 'Clôturé' and organisme is null));$t$;
    if position(a in d) = 0 then raise exception '162 : fin de pilotage_impayes_mois introuvable, rien n''est modifié'; end if;
    d := replace(d, a, $t$    'sans_organisme', (select count(*) from pilotage.impayes where groupe <> 'Clôturé' and organisme is null),
    -- 162 : baux Zelok dont toute la dette est l'échéance du mois, avant le 16 (prélèvements du 5 et du 10)
    'en_attente', case when pilotage.jour_paris() < 16 then coalesce((select jsonb_agg(jsonb_build_object('bail_id', b.id, 'locataires', v.locataires,
                     'dette', round(coalesce((b.data->>'unpaid_amount')::numeric, 0) / 100, 2)) order by v.locataires)
                   from pilotage.objets b join pilotage.v_baux v on v.id = b.id
                  where b.type = 'LeasingContract' and b.supprime_le is null and pilotage.organisme_bail(b.id) = 'zelok'
                    and coalesce((b.data->>'unpaid_amount')::numeric, 0) > 0 and pilotage.dette_hors_mois(b.id) <= 1
                    and coalesce(pilotage.cycle_impaye(b.id)->>'statut', '') not in ('gli_reported', 'long_contentious')), '[]'::jsonb) else '[]'::jsonb end);$t$);
    execute d;
  end if;
end $bloc$;

commit;
