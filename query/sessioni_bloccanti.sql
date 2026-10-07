-- Lab Triage AI
-- Copyright (c) 2026 Quirino Scaramastra
-- SPDX-License-Identifier: MIT

-- Query di rilevazione eseguita dal flusso n8n con l'utente ai_monitor.
-- Restituisce le sessioni bloccate, chi le blocca e da quanto.
SELECT
    bloccata.pid                                      AS pid_bloccato,
    bloccata.usename                                  AS utente_bloccato,
    host(bloccata.client_addr)                        AS ip_bloccato,       -- NULL = connessione locale (socket)
    left(bloccata.query, 120)                         AS query_bloccata,
    round(extract(epoch FROM now() - bloccata.query_start))::int AS attesa_sec,
    bloccante.pid                                     AS pid_bloccante,
    bloccante.usename                                 AS utente_bloccante,
    host(bloccante.client_addr)                       AS ip_bloccante,      -- NULL = connessione locale (socket)
    bloccante.application_name                        AS applicazione_bloccante,
    bloccante.state                                   AS stato_bloccante,
    left(bloccante.query, 120)                        AS query_bloccante,
    round(extract(epoch FROM now() - bloccante.xact_start))::int AS durata_tx_bloccante_sec
FROM pg_stat_activity bloccata
JOIN LATERAL unnest(pg_blocking_pids(bloccata.pid)) AS b(pid) ON true
JOIN pg_stat_activity bloccante ON bloccante.pid = b.pid
WHERE bloccata.datname = current_database()
ORDER BY attesa_sec DESC;
