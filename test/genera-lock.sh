#!/bin/bash
# Lab Triage AI
# Copyright (c) 2026 Quirino Scaramastra
# SPDX-License-Identifier: MIT
# Genera un lock di prova: la sessione A apre una transazione e la lascia "idle",
# la sessione B prova ad aggiornare la stessa riga e resta in attesa.
# Durata: 5 minuti, poi si sblocca da solo.
set -euo pipefail

echo ">>> Sessione A: blocca la riga 1 e resta in idle in transaction (300 s)"
docker exec -d lab-pg psql -U app_user -d labdb -c \
  "BEGIN; UPDATE ordini SET stato='in_lavorazione' WHERE id=1; SELECT pg_sleep(300); COMMIT;"

sleep 2

echo ">>> Sessione B: prova ad aggiornare la stessa riga (resterà bloccata)"
docker exec -d lab-pg psql -U app_user -d labdb -c \
  "UPDATE ordini SET stato='spedito' WHERE id=1;"

sleep 2
echo ">>> Fatto. Verifica con:"
echo "    docker exec -i lab-pg psql -U ai_monitor -d labdb < query/sessioni_bloccanti.sql"
