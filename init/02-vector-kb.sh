#!/bin/bash
# Lab Triage AI
# Copyright (c) 2026 Quirino Scaramastra
# SPDX-License-Identifier: MIT
# Eseguito una sola volta al primo avvio (volume vuoto), dopo 01-schema-ruoli.sh.
# Crea la base di conoscenza vettoriale (pgvector) letta dal workflow di triage.
# I documenti si caricano dopo l'avvio con: bash kb/carica-kb.sh
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;

CREATE SCHEMA IF NOT EXISTS kb;
REVOKE ALL ON SCHEMA kb FROM PUBLIC;

-- Un frammento di documento per riga; embedding di nomic-embed-text (768 dimensioni).
CREATE TABLE IF NOT EXISTS kb.documenti (
    id         bigserial PRIMARY KEY,
    documento  text        NOT NULL,              -- es. severita
    sezione    text        NOT NULL,              -- es. P1
    contenuto  text        NOT NULL,
    meta       jsonb       NOT NULL DEFAULT '{}', -- soglie numeriche (gravita, attesa_min, sessioni_min)
    embedding  vector(768) NOT NULL,
    caricato   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (documento, sezione)
);
CREATE INDEX IF NOT EXISTS documenti_embedding_idx
    ON kb.documenti USING hnsw (embedding vector_cosine_ops);

-- Il monitor legge la base di conoscenza, non la modifica.
GRANT USAGE ON SCHEMA kb TO ai_monitor;
GRANT SELECT ON kb.documenti TO ai_monitor;
SQL

echo ">>> Lab triage: schema kb (pgvector) creato."
