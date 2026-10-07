-- Lab Triage AI
-- Copyright (c) 2026 Quirino Scaramastra
-- SPDX-License-Identifier: MIT

-- Recupero dalla base vettoriale kb.documenti (eseguita dal workflow come ai_monitor).
-- $1 = embedding della situazione (nomic-embed-text), $2 = attesa massima in secondi, $3 = sessioni bloccate.
-- criterio: tra le severità le cui soglie sono soddisfatte, la più grave (filtro sui metadati).
-- contesto: i frammenti senza soglie più vicini alla situazione (ricerca per similarità).
WITH q AS (SELECT $1::vector AS v, $2::int AS attesa, $3::int AS n),
criterio AS (
    SELECT d.sezione, d.contenuto
    FROM kb.documenti d, q
    WHERE d.documento = 'severita' AND d.meta ? 'gravita'
      AND (q.attesa >= (d.meta->>'attesa_min')::int OR q.n >= (d.meta->>'sessioni_min')::int)
    ORDER BY (d.meta->>'gravita')::int
    LIMIT 1),
contesto AS (
    SELECT d.sezione, d.contenuto
    FROM kb.documenti d, q
    WHERE NOT d.meta ? 'gravita'
    ORDER BY d.embedding <=> q.v
    LIMIT 2)
SELECT (SELECT sezione   FROM criterio) AS severita_kb,
       (SELECT contenuto FROM criterio) AS criterio_kb,
       (SELECT string_agg('[' || sezione || '] ' || contenuto, E'\n\n') FROM contesto) AS contesto_kb;
