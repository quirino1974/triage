# Lab Triage AI

PostgreSQL + Ollama + n8n + Telegram con un principio solo: **l'AI propone, l'umano firma, il database registra.**

Ogni 5 minuti il flusso cerca i lock su PostgreSQL. Se ne trova uno, recupera il criterio di severità dal
vector DB, lo fa valutare a un modello locale e manda la proposta su Telegram: una persona approva o rifiuta.

| Componente | Ruolo |
|---|---|
| `ai_monitor` | **La sonda**: vede sessioni e lock, legge la base di conoscenza, non modifica nulla |
| `ai_action` | **L'automazione AI**: può solo chiamare la funzione approvata, e solo con una firma |
| `audit_log` | **La verifica**: registro in sola aggiunta, non si modifica e non si cancella |

I controlli non stanno nel flusso di n8n ma nel database: anche un flusso sbagliato non può fare più di
quanto i ruoli consentono.

La spiegazione passo passo è in `index.html`.

## Struttura

```
triage/
├── docker-compose.yml               # PG 5432 · Ollama 11434 · n8n 5678 (porte standard)
├── .env.example                     # modello per .env: password e chiave n8n
├── init/01-schema-ruoli.sh          # schema ops, ruoli, audit_log, funzione approvata (gira al primo avvio)
├── init/02-vector-kb.sh             # pgvector e schema kb (gira al primo avvio)
├── kb/severita.txt                  # criteri di severità P1-P4 con le soglie
├── kb/carica-kb.sh                  # carica il documento nel vector DB
├── query/sessioni_bloccanti.sql     # query di rilevazione dei lock
├── query/criterio_severita.sql      # ricerca del criterio nel vector DB
├── test/genera-lock.sh              # crea un lock di prova per 5 minuti
├── workflow/triage-sessioni-bloccanti.json   # flusso n8n da importare
├── index.html                       # presentazione: cosa fa il lab e come rifarlo
└── data/                            # dati di postgres, ollama e n8n (creata all'avvio, non versionata)
```

## Avvio

```bash
cd triage
cp .env.example .env
KEY=$(openssl rand -hex 24)
sed -i "s/cambia_con_openssl_rand/$KEY/" .env
nano .env                                   # cambia le tre password (senza il carattere $)

mkdir -p data/postgres data/ollama data/n8n # cartelle dati, di proprietà del tuo utente
docker compose up -d
docker compose ps                           # tutti e tre "running", lab-pg "healthy"
docker logs lab-pg 2>&1 | grep "Lab triage" # conferma che i due script di init sono andati

docker exec lab-ollama ollama pull llama3.2:3b
docker exec lab-ollama ollama pull nomic-embed-text

bash kb/carica-kb.sh                        # carica i criteri di severità nel vector DB
```

Le password vanno scelte prima del primo avvio: gli script di `init/` creano i ruoli una volta sola.

n8n: <http://localhost:5678>

## Verifica dei guardrail

```bash
# 1. ai_monitor vede ma non tocca
docker exec lab-pg psql -U ai_monitor -d labdb -c "SELECT count(*) FROM pg_stat_activity;"
docker exec lab-pg psql -U ai_monitor -d labdb -c "UPDATE ordini SET stato='x' WHERE id=2;"          # deve fallire
docker exec lab-pg psql -U ai_monitor -d labdb -c "SELECT ops.terminate_session(1,'io','test');"     # deve fallire

# 2. Genera un lock e trovalo
bash test/genera-lock.sh
docker exec -i lab-pg psql -U ai_monitor -d labdb < query/sessioni_bloccanti.sql

# 3. Senza firma umana: rifiutato
docker exec lab-pg psql -U ai_action -d labdb -c "SELECT ops.terminate_session(<PID_BLOCCANTE>, '', 'test');"

# 4. Con firma: eseguito
docker exec lab-pg psql -U ai_action -d labdb -c "SELECT ops.terminate_session(<PID_BLOCCANTE>, 'DbAdmin', 'lock su ordini id=1');"

# 5. Il registro
docker exec lab-pg psql -U postgres -d labdb -c "SELECT id, ts, actor, action, target, approved_by, outcome FROM ops.audit_log;"
docker exec lab-pg psql -U postgres -d labdb -c "DELETE FROM ops.audit_log;"                          # deve fallire, anche da superuser
```

## Cosa garantisce lo schema

| Guardrail | Come |
|---|---|
| Il monitor non scrive | `ai_monitor` ha solo `pg_monitor` + `SELECT` su `audit_log` e `kb.documenti`; l'unica scrittura è `ops.log_event()` |
| L'azione è circoscritta | `ai_action` non ha accesso alle tabelle, solo `EXECUTE` su `ops.terminate_session()` |
| Serve la firma umana | `terminate_session` rifiuta se `approved_by` è vuoto |
| Sessioni protette | non termina superuser, i ruoli AI né se stessa |
| Tracciabilità | ogni esecuzione, anche fallita, scrive su `audit_log` |
| Registro inalterabile | trigger che blocca `UPDATE`, `DELETE`, `TRUNCATE` su `audit_log` |
| Niente query infinite | `statement_timeout` 5 s (monitor) e 10 s (action) |

## Base di conoscenza (vector DB)

I criteri di severità stanno in `kb/severita.txt`. `kb/carica-kb.sh` divide il documento in sezioni, calcola
gli embedding con `nomic-embed-text` e li salva in `kb.documenti` (pgvector, 768 dimensioni).

Ogni sezione di severità ha una riga `soglie`, salvata come metadati: il database filtra su quelle e
restituisce la severità più grave tra quelle applicabili; la similarità vettoriale sceglie il contesto generale.

| Severità | Attesa massima | | Sessioni bloccate | Azione |
|---|---|---|---|---|
| P1 | oltre 300 s | oppure | più di 5 | TERMINA |
| P2 | da 60 a 300 s | oppure | da 2 a 5 | TERMINA |
| P3 | da 10 a 60 s | e | una sola | ATTENDI |
| P4 | sotto 10 s | e | una sola | ATTENDI |

Dopo ogni modifica al documento va rilanciato `bash kb/carica-kb.sh`. Se cambi una soglia nel testo, cambia
anche la riga `soglie` della stessa sezione.

## Flusso n8n

1. In n8n crea tre credenziali: due Postgres (host `postgres`, database `labdb`, utenti `ai_monitor` e
   `ai_action`) e una Telegram con il token del bot creato con @BotFather.
2. Importa `workflow/triage-sessioni-bloccanti.json` e assegna le credenziali ai nodi: `ai_action` solo su
   «Termina sessione», `ai_monitor` sugli altri nodi Postgres.
3. Nel nodo Config imposta il `chatId` Telegram e il nome dell'approvatore.
4. In `docker-compose.yml` imposta `WEBHOOK_URL` con l'IP di rete del PC, poi `docker compose up -d n8n`:
   è l'indirizzo usato dai pulsanti Approva / Rifiuta.
5. Prova con `bash test/genera-lock.sh` e «Execute workflow»; con «Publish» il flusso parte ogni 5 minuti.

Il flusso: rilevazione dei lock → embedding della situazione → ricerca del criterio nel vector DB → prompt →
Ollama → controllo della risposta → `PROPOSED` nel registro → messaggio Telegram → se approvata
`ops.terminate_session()` ed esito su Telegram, altrimenti `REJECTED` nel registro.

## Limiti da conoscere

- Nel registro finisce il nome scritto nel nodo Config, non l'identità di chi ha premuto il pulsante.
- «Approva» termina sempre la sessione bloccante, anche quando la proposta dell'AI è ATTENDI.
- La severità è quella del vector DB; la frase di motivazione è scritta dal modello e può contenere numeri imprecisi.

## Reset

```bash
docker compose down
sudo rm -rf data/postgres    # il database riparte da zero: registro e vector DB
docker compose up -d
bash kb/carica-kb.sh
                             # data/ollama = modelli scaricati, data/n8n = flussi e credenziali
```

## Autore

**Quirino Scaramastra** — 
[LinkedIn](https://www.linkedin.com/in/qscaramastra/) · [prodigeit.io](https://prodigeit.io)

## Licenza

Distribuito con licenza [MIT](LICENSE): libero da usare, modificare e ridistribuire, mantenendo l'indicazione dell'autore.
