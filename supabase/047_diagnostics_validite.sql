-- 047 : validité des diagnostics (DPE, ERP, amiante, plomb, électricité, gaz)
-- Constat du 19/10 : dans Rivage, un diagnostic est une pièce (Upload) de nature dédiée qui porte sa date de réalisation (issued_on)
-- et sa date de fin de validité (expiration_date) ; le détail du lot en reprend la plus récente par nature (liste « diagnostics »).
-- Les pièces étaient déjà reconnues par leur nature ; ce script ajoute leur validité :
--   - mandat : un diagnostic expiré (DPE, amiante, plomb…) devient une anomalie ; l'ERP n'est pas bloquant au mandat (il se refait
--     avant chaque bail) mais sa validité est affichée ;
--   - bail : le diagnostic doit être valable à la date de signature du bail (ERP de moins de 6 mois, DPE en cours de validité…) ;
--   - « prêt à louer » (liste À louer) : DPE et ERP jugés sur leur date de fin de validité et non plus sur la date de dépôt.
-- Pour chaque nature, la pièce retenue est la plus récente par date de réalisation (et non plus la dernière déposée).

create or replace function pilotage.validite_diag(p_upload text, p_ref date) returns jsonb
language sql stable security definer set search_path = pilotage, public as $$
  select case when nullif(u.data->>'issued_on', '') is null and nullif(u.data->>'expiration_date', '') is null then null else
    jsonb_build_object('realise', nullif(u.data->>'issued_on', '')::date, 'fin', nullif(u.data->>'expiration_date', '')::date,
      'expire', coalesce(nullif(u.data->>'expiration_date', '')::date < coalesce(p_ref, current_date), false),
      'apres', coalesce(nullif(u.data->>'issued_on', '')::date > coalesce(p_ref, current_date), false)) end
  from pilotage.objets u where u.type = 'Upload' and u.id = p_upload
$$;

create or replace function pilotage.texte_validite(v jsonb, p_au text) returns text
language sql immutable as $$
  select case when v is null then ''
    else coalesce(' · réalisé le ' || to_char((v->>'realise')::date, 'DD/MM/YYYY'), '')
      || case when (v->>'apres')::boolean then ' (après la signature du bail : pièce remplacée depuis)' else '' end
      || case when (v->>'fin') is null then ' · sans date de fin de validité'
              when (v->>'expire')::boolean then ' · expiré le ' || to_char((v->>'fin')::date, 'DD/MM/YYYY') || coalesce(' (' || p_au || ')', '')
              else ' · valable jusqu''au ' || to_char((v->>'fin')::date, 'DD/MM/YYYY') end end
$$;

-- ========== Contrôle du mandat et du bail : validité ajoutée à la pièce trouvée ==========
do $$
declare d text; n text; cible text := 'piece := jsonb_build_object(''id'', up.id, ''libelle'', up.label, ''par_nom'', not up.par_nature);';
  tri_avant text := 'order by coalesce(u.data->>''nature'' = any(coalesce(q.natures, array[q.ref])), false) desc, u.maj_le desc limit 1;';
  tri_apres text := 'order by coalesce(u.data->>''nature'' = any(coalesce(q.natures, array[q.ref])), false) desc, nullif(u.data->>''issued_on'', '''')::date desc nulls last, u.maj_le desc limit 1;';
begin
  -- Mandat : validité au jour du contrôle ; l'ERP n'est pas bloquant au mandat
  d := pg_get_functiondef('pilotage.controle_mandat(text)'::regprocedure);
  if position('validite_diag' in d) = 0 then
    n := replace(d, cible, cible || '
        if pilotage.validite_diag(up.id, current_date) is not null then
          detail := detail || pilotage.texte_validite(pilotage.validite_diag(up.id, current_date), case when up.nature = ''natural_risks_and_pollution_state'' then ''à refaire avant chaque nouveau bail'' end);
          if (pilotage.validite_diag(up.id, current_date)->>''expire'')::boolean and up.nature <> ''natural_risks_and_pollution_state'' then auto := ''anomalie''; end if;
        end if;');
    n := replace(n, tri_avant, tri_apres);
    if n = d or position('validite_diag' in n) = 0 then raise exception '047 : emplacement introuvable dans controle_mandat'; end if;
    execute n;
  end if;
  -- Bail : validité à la date de signature du bail (à défaut sa date de début, puis aujourd'hui)
  d := pg_get_functiondef('pilotage.controle_bail(text)'::regprocedure);
  if position('validite_diag' in d) = 0 then
    n := replace(d, cible, cible || '
        if pilotage.validite_diag(up.id, coalesce(nullif(o->>''signed_at'', '''')::date, nullif(o->>''start_date'', '''')::date, current_date)) is not null then
          detail := detail || pilotage.texte_validite(pilotage.validite_diag(up.id, coalesce(nullif(o->>''signed_at'', '''')::date, nullif(o->>''start_date'', '''')::date, current_date)), ''avant la signature du bail'');
          if (pilotage.validite_diag(up.id, coalesce(nullif(o->>''signed_at'', '''')::date, nullif(o->>''start_date'', '''')::date, current_date))->>''expire'')::boolean then auto := ''anomalie''; end if;
        end if;');
    n := replace(n, tri_avant, tri_apres);
    if n = d or position('validite_diag' in n) = 0 then raise exception '047 : emplacement introuvable dans controle_bail'; end if;
    execute n;
  end if;
end $$;

-- ========== Prêt à louer : DPE et ERP selon leur date de fin de validité ==========
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.pilotage_a_louer()'::regprocedure);
  if position('expiration_date' in d) = 0 then
    n := replace(d, 'and u.maj_le > now() - interval ''10 years'')',
                    'and coalesce(nullif(u.data->>''expiration_date'', '''')::date >= current_date, u.maj_le > now() - interval ''10 years''))');
    n := replace(n, 'and u.maj_le > now() - interval ''6 months'')',
                    'and coalesce(nullif(u.data->>''expiration_date'', '''')::date >= current_date, nullif(u.data->>''issued_on'', '''')::date > current_date - interval ''6 months'', u.maj_le > now() - interval ''6 months''))');
    if n = d then raise exception '047 : critères DPE / ERP introuvables dans pilotage_a_louer'; end if;
    execute n;
  end if;
end $$;

revoke all on function pilotage.validite_diag(text, date), pilotage.texte_validite(jsonb, text) from public, anon, authenticated;

-- Les caches sont recalculés avec la validité des diagnostics
select pilotage.rafraichir_audit();
select pilotage.rafraichir_baux();

-- Contrôle : pièces du mandat DREZET (diagnostics déposés le 19/10 ; l'ERP de 2022 doit apparaître expiré, sans bloquer le mandat)
select i->>'libelle' piece, i->>'detail' detail, coalesce(i->>'auto', '') auto
from jsonb_array_elements(pilotage.controle_mandat('mc_940f0f67b439e70f734a6be8')->'items') i where i->>'bloc' = 'pieces';
