#!/bin/bash
# Lab Triage AI
# Copyright (c) 2026 Quirino Scaramastra
# SPDX-License-Identifier: MIT
# Carica (o ricarica) un documento nella base vettoriale kb.documenti.
# Ogni sezione "## Titolo" diventa un frammento con il suo embedding (Ollama, nomic-embed-text).
# Uso: bash kb/carica-kb.sh [file.txt]   (default: kb/severita.txt)
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:-kb/severita.txt}"
python3 - "$FILE" <<'PY'
import json, re, subprocess, sys, pathlib

path = pathlib.Path(sys.argv[1])
documento = path.stem
testo = path.read_text(encoding='utf-8')
sezioni = re.split(r'^## +', testo, flags=re.M)[1:]

def embed(testo):
    out = subprocess.run(
        ['docker', 'exec', '-i', 'lab-ollama', 'ollama', 'run', 'nomic-embed-text'],
        input=testo, capture_output=True, text=True, check=True).stdout
    return json.loads(out)

sql = ["BEGIN;", f"DELETE FROM kb.documenti WHERE documento = $d${documento}$d$;"]
for s in sezioni:
    titolo, _, corpo = s.partition('\n')
    meta = {}
    m = re.search(r'<!--\s*soglie:(.*?)-->', corpo)
    if m:
        meta = {k: int(v) for k, v in (c.split('=') for c in m.group(1).split())}
    contenuto = re.sub(r'<!--.*?-->', '', corpo, flags=re.S).strip()
    v = embed(f"search_document: {titolo.strip()}. {contenuto}")
    sql.append("INSERT INTO kb.documenti(documento, sezione, contenuto, meta, embedding) VALUES "
               f"($d${documento}$d$, $t${titolo.strip()}$t$, $c${contenuto}$c$, '{json.dumps(meta)}', '{json.dumps(v)}');")
    print(f"  {documento} / {titolo.strip()}: {len(v)} dimensioni, soglie {meta or '-'}")
sql.append("COMMIT;")
subprocess.run(['docker', 'exec', '-i', 'lab-pg', 'psql', '-q', '-v', 'ON_ERROR_STOP=1',
                '-U', 'postgres', '-d', 'labdb'], input='\n'.join(sql), text=True, check=True)
print(f">>> {len(sezioni)} frammenti caricati da {path}")
PY
