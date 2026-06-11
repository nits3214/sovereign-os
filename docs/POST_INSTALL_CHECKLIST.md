# Sovereign OS — Post-Install Checklist
**Run after install.sh completes and all five services are confirmed active.**  
These steps configure the stack for first use. Required on every fresh install.

---

## STEP 1 — Create Admin Account

Open a browser and navigate to:
```
https://<machine-ip>
```

Accept the self-signed certificate warning (click Advanced → Proceed).

On first visit Open WebUI will prompt you to create an admin account.
- Use a strong password — this controls access to the entire stack
- This account is local only — no cloud registration, no email verification

> ⚠ The first account created automatically becomes admin.
> Create it immediately after install before anyone else accesses the machine.

---

## STEP 2 — Verify Web Search Config (Admin Panel)

Go to: **Profile icon → Admin Panel → Settings → Web Search**

Check the following:

| Setting | Required value |
|---------|----------------|
| Web Search toggle | ON |
| Web Search Engine | searxng |
| SearXNG Query URL | `http://localhost:8888/search?q=<query>&format=json` |

If the URL shows only `http://localhost:8888` — update it to the full URL above.

Save changes.

---

## STEP 3 — Run DB Config Patch (if web search still shows "No sources found")

If web search returns "No sources found" after Step 2, the install.sh config
patch timed out during install. Run it manually:

```bash
sudo apt install -y sqlite3

python3 << 'PYEOF'
import sqlite3, json, sys

db_path = "/var/lib/sovereign/openwebui/webui.db"
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("SELECT id, data FROM config WHERE id = 1")
row = cur.fetchone()
if not row:
    print("ERROR: config table empty -- Open WebUI has not initialised yet")
    sys.exit(1)

config_id, data_json = row
data = json.loads(data_json)

# Fix embedding model
data['RAG_EMBEDDING_MODEL'] = 'nomic-embed-text'

# Fix SearXNG URL
data['rag']['web']['search']['searxng_query_url'] = 'http://localhost:8888/search'

# Fix for CPU-only hardware -- bypass embedding race condition
data['rag']['web']['search']['bypass_embedding_and_retrieval'] = True
data['rag']['web']['search']['bypass_web_loader'] = True

# Performance tuning for CPU-only
data['rag']['enable_async_embedding'] = True
data['rag']['web']['search']['result_count'] = 3
data['rag']['chunk_size'] = 4000
data['rag']['chunk_overlap'] = 200
data['rag']['enable_markdown_header_text_splitter'] = False

# Embedding engine
data['rag']['embedding_engine'] = 'ollama'
data['rag']['embedding_model'] = 'nomic-embed-text'

cur.execute(
    "UPDATE config SET data = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
    (json.dumps(data), config_id)
)
conn.commit()
conn.close()
print("Config patched successfully")
PYEOF
```

Then restart Open WebUI:
```bash
sudo systemctl restart open-webui
sleep 15
```

Then retest web search in the browser.

---

## STEP 4 — Enable Web Search Per Chat

Web search is a per-conversation toggle in Open WebUI — it is not on by default
for every chat. To use it:

1. Start a new chat
2. Look for the search/globe icon near the message input bar
3. Click it to enable web search for that conversation
4. The model will retrieve live sources and cite them in its response

> Note: Web search requires internet connectivity on the machine.
> In fully airgapped deployments, disable the web search toggle and
> use the local knowledge base (RAG with uploaded documents) instead.

---

## STEP 5 — Test Inference End to End

Send a test message to each model to confirm inference is working:

**Offline test** (no web search):
```
What are the six founding principles of Sovereign OS?
```
The model won't know the answer — that's fine. You're testing that it responds
at all, not that it knows your project.

**Online test** (web search enabled):
```
What are the top two AI news stories today?
```
Should return: "Retrieved X sources" followed by real cited results.
If it returns "No sources found" — go back to Step 3.

---

## STEP 6 — Sovereignty Re-verification

Always re-run the sovereignty test after first use to confirm rules are intact:

```bash
sudo -u ollama curl -s --max-time 5 https://ollama.com && echo "BREACH" || echo "BLOCKED"
```

Must return `BLOCKED`.

---

## STEP 7 — Demo Access Setup (Optional)

If you need to expose the stack to a remote demo audience:

```bash
chmod +x /opt/sovereign/demo_access.sh
/opt/sovereign/demo_access.sh tailscale
```

See `demo_access.sh` for full usage. Always run:
```bash
/opt/sovereign/demo_access.sh stop
```
after the demo to tear down all tunnels.

---

## Quick Reference — What Each Service Does

| Service | URL | Purpose |
|---------|-----|---------|
| Open WebUI | https://\<ip\> | Main AI chat interface |
| Ollama API | http://\<ip\>:11434 | Model inference engine |
| SearXNG | http://\<ip\>:8888 | Local web search |
| n8n | http://\<ip\>:5678 | Workflow automation |
| ChromaDB | localhost:8000 (internal) | Vector database for RAG |

---

## Known First-Boot Behaviours (Not Errors)

| What you see | Why | Action needed |
|--------------|-----|---------------|
| Certificate warning in browser | Self-signed cert — expected | Click Advanced → Proceed |
| Ollama `model_recommendations refresh failed` in logs | Sovereignty rules blocking Ollama phone-home | None — this is correct behaviour |
| SearXNG `sqlite3 no such table: properties` in logs | Non-critical startup quirk | None — SearXNG works fine regardless |
| Open WebUI takes 30–60s to load on first boot | Python venv cold start | Wait — it will load |

---

*Sovereign AI — thedxjournal.com*  
*Intelligence stays on the machine. Always.*
