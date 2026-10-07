#!/bin/bash
# Lab Triage AI
# Copyright (c) 2026 Quirino Scaramastra
# SPDX-License-Identifier: MIT
# Eseguito una sola volta da PostgreSQL al primo avvio (volume vuoto).
# Crea: schema ops, audit_log append-only, ruoli ai_monitor / ai_action,
# funzione approvata ops.terminate_session, tabella demo per i test di lock.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v mon_pwd="$AI_MONITOR_PASSWORD" -v act_pwd="$AI_ACTION_PASSWORD" <<'SQL'

-- ============================================================
-- 1. Schema operativo
-- ============================================================
CREATE SCHEMA ops;
REVOKE ALL ON SCHEMA ops FROM PUBLIC;

-- ============================================================
-- 2. audit_log: la verifica del flusso
--    Append-only: nessuno può modificare o cancellare righe.
-- ============================================================
CREATE TABLE ops.audit_log (
    id           bigserial PRIMARY KEY,
    ts           timestamptz NOT NULL DEFAULT now(),
    actor        text        NOT NULL,              -- chi agisce (ruolo DB / workflow)
    action       text        NOT NULL,              -- es. PROPOSED, APPROVED, REJECTED, EXECUTED, FAILED
    target       text,                              -- es. pid=1234
    severity     text CHECK (severity IN ('P1','P2','P3','P4')),
    detail       jsonb       NOT NULL DEFAULT '{}', -- proposta LLM, query, motivazione
    approved_by  text,                              -- chi ha firmato (utente Telegram)
    outcome      text
);

CREATE FUNCTION ops.audit_log_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log è append-only: % non consentito', TG_OP;
END $$;

CREATE TRIGGER audit_log_no_update_delete
    BEFORE UPDATE OR DELETE ON ops.audit_log
    FOR EACH ROW EXECUTE FUNCTION ops.audit_log_immutable();

CREATE TRIGGER audit_log_no_truncate
    BEFORE TRUNCATE ON ops.audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION ops.audit_log_immutable();

-- ============================================================
-- 3. Ruolo ai_monitor: vede tutto, non tocca niente
-- ============================================================
CREATE ROLE ai_monitor LOGIN PASSWORD :'mon_pwd'
    CONNECTION LIMIT 5;
GRANT pg_monitor TO ai_monitor;                    -- lettura su pg_stat_*, pg_locks
GRANT CONNECT ON DATABASE labdb TO ai_monitor;
GRANT USAGE ON SCHEMA ops TO ai_monitor;
GRANT SELECT ON ops.audit_log TO ai_monitor;
ALTER ROLE ai_monitor SET statement_timeout = '5s';

-- Nessun INSERT diretto: l'unica scrittura consentita è registrare un evento
-- tramite questa funzione (proposte, approvazioni, rifiuti).
CREATE FUNCTION ops.log_event(
    p_action text, p_target text, p_severity text,
    p_detail jsonb, p_approved_by text DEFAULT NULL, p_outcome text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $$
DECLARE v_id bigint;
BEGIN
    INSERT INTO ops.audit_log(actor, action, target, severity, detail, approved_by, outcome)
    VALUES (session_user, p_action, p_target, p_severity, coalesce(p_detail,'{}'), p_approved_by, p_outcome)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- ============================================================
-- 4. Ruolo ai_action: può fare SOLO ciò che è in una funzione approvata
-- ============================================================
CREATE ROLE ai_action LOGIN PASSWORD :'act_pwd'
    CONNECTION LIMIT 2;
GRANT CONNECT ON DATABASE labdb TO ai_action;
GRANT USAGE ON SCHEMA ops TO ai_action;
ALTER ROLE ai_action SET statement_timeout = '10s';

-- Azione approvata n.1: terminare una sessione bloccante.
-- Guardrail: serve un approvatore, non tocca superuser né sessioni di sistema,
-- non tocca se stessa, e scrive sempre su audit_log (anche se fallisce).
CREATE FUNCTION ops.terminate_session(p_pid int, p_approved_by text, p_reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $$
DECLARE
    v_user text;
    v_ok   boolean := false;
BEGIN
    IF p_approved_by IS NULL OR length(trim(p_approved_by)) = 0 THEN
        RAISE EXCEPTION 'Azione rifiutata: manca la firma umana (approved_by)';
    END IF;

    SELECT usename INTO v_user FROM pg_stat_activity WHERE pid = p_pid;

    IF v_user IS NULL THEN
        INSERT INTO ops.audit_log(actor, action, target, detail, approved_by, outcome)
        VALUES (session_user, 'FAILED', 'pid=' || p_pid,
                jsonb_build_object('reason', p_reason), p_approved_by, 'pid non trovato');
        RETURN false;
    END IF;

    IF p_pid = pg_backend_pid()
       OR v_user IN (SELECT rolname FROM pg_roles WHERE rolsuper)
       OR v_user IN ('ai_monitor', 'ai_action') THEN
        INSERT INTO ops.audit_log(actor, action, target, detail, approved_by, outcome)
        VALUES (session_user, 'FAILED', 'pid=' || p_pid,
                jsonb_build_object('reason', p_reason, 'user', v_user), p_approved_by,
                'bloccato dal guardrail: sessione protetta');
        RETURN false;
    END IF;

    v_ok := pg_terminate_backend(p_pid);

    INSERT INTO ops.audit_log(actor, action, target, detail, approved_by, outcome)
    VALUES (session_user, 'EXECUTED', 'pid=' || p_pid,
            jsonb_build_object('reason', p_reason, 'user', v_user), p_approved_by,
            CASE WHEN v_ok THEN 'terminata' ELSE 'non terminata' END);
    RETURN v_ok;
END $$;

-- Nessuno esegue le funzioni salvo chi è autorizzato esplicitamente
REVOKE ALL ON FUNCTION ops.log_event(text,text,text,jsonb,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.terminate_session(int,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.log_event(text,text,text,jsonb,text,text) TO ai_monitor, ai_action;
GRANT EXECUTE ON FUNCTION ops.terminate_session(int,text,text) TO ai_action;

-- ============================================================
-- 5. Utente applicativo + tabella demo per generare lock
-- ============================================================
CREATE ROLE app_user LOGIN PASSWORD 'app_lab_only';
CREATE TABLE public.ordini (id int PRIMARY KEY, stato text, aggiornato timestamptz DEFAULT now());
INSERT INTO public.ordini(id, stato) SELECT g, 'nuovo' FROM generate_series(1, 100) g;
GRANT SELECT, UPDATE ON public.ordini TO app_user;

SQL

echo ">>> Lab triage: schema ops, ruoli ai_monitor / ai_action e audit_log creati."
