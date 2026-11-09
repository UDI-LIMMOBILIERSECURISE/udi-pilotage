-- 133 : lenteur du cache des baux (« pilotage-cache-baux ») (bloc 1 sur 1)
--  Mesure du 09/11/2026 (24 h de tâches planifiées) : la mise à jour du cache des baux prend 28,5 s toutes les 30 minutes, le calcul
--  des alertes 15 s. Le coût est dans pilotage.controle_bail (93 ms sur 97 ms par bail, 301 baux en cours) : les pièces Rivage du bail
--  et du lot (quittances et avis d'échéance compris, souvent plusieurs centaines) étaient relues dans la table des objets une fois
--  pour l'inventaire, puis une fois par question « pièce » (9 en habitation).
--  Correction : les pièces sont lues une seule fois au début du contrôle, puis cherchées en mémoire pour chaque question.
--  Mêmes critères, même ordre (nature reconnue d'abord, puis date d'émission, puis date de mise à jour) : résultat identique, vérifié sur
--  tous les baux avant de livrer. L'inventaire « docs », calculé mais jamais utilisé, n'est plus calculé.
--  Pas d'index ajouté : l'index sur les rattachements des pièces existe déjà ; c'est le nombre de relectures qui coûtait.

do $p$
declare f text := pg_get_functiondef('pilotage.controle_bail(text)'::regprocedure);
  a0 text := $a$piece jsonb;
begin$a$;
  b0 text := $a$piece jsonb; ups jsonb;
begin$a$;
  a1 text := $a$  select array_agg(distinct u.data->>'nature') into docs from pilotage.objets u
   where u.type = 'Upload' and u.supprime_le is null$a$;
  b1 text := $a$  -- 133 : pièces du bail et du lot lues une seule fois, cherchées ensuite en mémoire pour chaque question
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'label', u.data->>'label', 'nature', u.data->>'nature', 'issued_on', u.data->>'issued_on', 'maj_le', u.maj_le)), '[]'::jsonb)
    into ups from pilotage.objets u
   where u.type = 'Upload' and u.supprime_le is null$a$;
  a2 text := $a$      select u.id, u.data->>'label' as label, u.data->>'nature' as nature, coalesce(u.data->>'nature' = any(coalesce(q.natures, array[q.ref])), false) as par_nature into up
        from pilotage.objets u
       where u.type = 'Upload' and u.supprime_le is null
         and (u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', p_bail)) or u.data->'resourceables' @> jsonb_build_array(jsonb_build_object('id', o->>'asset_id')))
         and ((coalesce(q.natures, array[q.ref]) is not null and u.data->>'nature' = any(coalesce(q.natures, array[q.ref])))
           or (q.mots is not null and pilotage.sans_accents(u.data->>'label') ~ ('\m(' || array_to_string(q.mots, '|') || ')')))
       order by coalesce(u.data->>'nature' = any(coalesce(q.natures, array[q.ref])), false) desc, nullif(u.data->>'issued_on', '')::date desc nulls last, u.maj_le desc limit 1;$a$;
  b2 text := $a$      select u.id, u.label, u.nature, coalesce(u.nature = any(coalesce(q.natures, array[q.ref])), false) as par_nature into up
        from jsonb_to_recordset(ups) as u(id text, label text, nature text, issued_on text, maj_le timestamptz)
       where ((coalesce(q.natures, array[q.ref]) is not null and u.nature = any(coalesce(q.natures, array[q.ref])))
           or (q.mots is not null and pilotage.sans_accents(u.label) ~ ('\m(' || array_to_string(q.mots, '|') || ')')))
       order by coalesce(u.nature = any(coalesce(q.natures, array[q.ref])), false) desc, nullif(u.issued_on, '')::date desc nulls last, u.maj_le desc limit 1;$a$;
begin
  if position('133 : pièces du bail et du lot lues une seule fois' in f) > 0 then raise notice 'controle_bail déjà modifiée'; return; end if;
  f := replace(f, chr(13), '');
  if (length(f) - length(replace(f, a0, ''))) / length(a0) <> 1 then raise exception 'Ancre 0 introuvable ou multiple'; end if;
  if (length(f) - length(replace(f, a1, ''))) / length(a1) <> 1 then raise exception 'Ancre 1 introuvable ou multiple'; end if;
  if (length(f) - length(replace(f, a2, ''))) / length(a2) <> 1 then raise exception 'Ancre 2 introuvable ou multiple'; end if;
  execute replace(replace(replace(f, a0, b0), a1, b1), a2, b2);
end $p$;

select pilotage.controle_bail(id) is not null as controle_ok from pilotage.v_baux where statut = 'in_progress' limit 1;
