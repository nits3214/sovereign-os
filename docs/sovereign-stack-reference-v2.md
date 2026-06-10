# Sovereign OS — Stack Reference Card v2
# Dell OptiPlex 3020 SFF | June 2026

---

## Machine

| Item        | Value                          |
|-------------|-------------------------------|
| Hostname    | sovereign-server               |
| IP          | 192.168.1.100                  |
| SSH         | `ssh sovereign@192.168.1.100`  |
| OS          | Ubuntu Server 22.04.5 LTS      |
| CPU         | Intel i5-4570 (4 core, 3.2GHz) |
| RAM         | 16GB DDR3 1600MHz dual-channel |
| Storage     | 120GB SSD                      |
| GPU         | None (CPU inference only)      |
| Performance | 4.2 tokens/sec (7B Q4 model)   |

---

## Access URLs

| Service    | URL                              | Notes                          |
|------------|----------------------------------|-------------------------------|
| Open WebUI | https://192.168.1.100            | Accept cert warning on first visit |
| n8n        | http://192.168.1.100:5678        | Workflow automation            |
| Ollama API | http://192.168.1.100:11434       | LAN only, blocked from internet |
| SearXNG    | http://127.0.0.1:8888            | Localhost only                 |
| ChromaDB   | http://127.0.0.1:8000            | Localhost only                 |

---

## Services

| Service      | Manager  | Status command                          |
|--------------|----------|-----------------------------------------|
| ollama       | systemd  | `sudo systemctl status ollama`          |
| open-webui   | systemd  | `sudo systemctl status open-webui`      |
| searxng      | systemd  | `sudo systemctl status searxng`         |
| chromadb     | systemd  | `sudo systemctl status chromadb`        |
| nginx        | systemd  | `sudo systemctl status nginx`           |
| n8n          | PM2      | `pm2 status`                            |

Restart all: `sudo systemctl restart ollama open-webui searxng chromadb nginx && pm2 restart n8n`

---

## Models

| Model           | Size   | Use case                    | Ollama name    |
|-----------------|--------|-----------------------------|----------------|
| Mistral 7B Q4   | 4.1GB  | General chat, coding        | mistral-7b     |
| Qwen 2.5 7B Q4  | 4.4GB  | Multilingual, documents     | qwen2.5-7b     |
| Qwen 2.5 3B Q4  | 1.8GB  | Fast responses, low RAM     | qwen2.5-3b     |

List models: `ollama list`
Run a model: `ollama run mistral-7b`
Add a model: `ollama pull [model-name]`

---

## Key Paths

| Path                              | Contents                        |
|-----------------------------------|---------------------------------|
| `/opt/sovereign/`                 | Main deployment directory        |
| `/opt/sovereign/models/gguf/`     | GGUF model files                 |
| `/opt/sovereign/venv/`            | Open WebUI Python venv           |
| `/var/lib/sovereign/chromadb/`    | ChromaDB vector database         |
| `/etc/nginx/sites-enabled/`       | nginx config                     |
| `/home/sovereign/ecosystem.config.js` | n8n PM2 config              |
| `/etc/systemd/system/`            | All service unit files           |

---

## Ports

| Port  | Service    | Access      |
|-------|------------|-------------|
| 443   | nginx/HTTPS | LAN         |
| 5678  | n8n        | LAN         |
| 8080  | Open WebUI (via nginx) | localhost |
| 8888  | SearXNG    | localhost   |
| 8000  | ChromaDB   | localhost   |
| 11434 | Ollama API | LAN         |
| 22    | SSH        | Anywhere    |

---

## Firewall (UFW + iptables)

```bash
sudo ufw status verbose          # Show all UFW rules
sudo iptables -L OUTPUT --line-numbers  # Verify sovereignty rules at lines 1+2
```

Sovereignty test (Ollama cannot reach internet):
```bash
sudo -u ollama curl -s --max-time 5 https://api.openai.com 2>&1 | \
  grep -q "Connection refused\|timed out\|Network unreachable" && \
  echo "SOVEREIGN ✅" || echo "BREACH ❌"
```

---

## USB Drive Structure

```
S:\ (labelled CIDATA — exFAT)
├── user-data              # Ubuntu autoinstall config
├── meta-data              # Required empty file for cloud-init
└── sovereign/
    ├── install.sh         # Main deployment script v2.0
    ├── models/
    │   └── gguf/          # GGUF model files (~10GB)
    ├── binaries/          # Ollama binaries (amd64 + arm64)
    ├── packages/          # npm tarballs (n8n, PM2)
    ├── venv.tar.gz        # Open WebUI Python venv (3.3GB)
    ├── searxng.zip        # SearXNG source
    ├── open-webui-*.whl   # Open WebUI wheel
    └── docs/              # This documentation
```

---

## Common Commands

```bash
# Check all services at once
for svc in ollama open-webui searxng chromadb nginx; do
  echo "$svc: $(systemctl is-active $svc)"
done
pm2 status

# View logs
sudo journalctl -u open-webui -f
sudo journalctl -u ollama -f
pm2 logs n8n

# Disk usage
df -h /
du -sh /opt/sovereign/models/

# RAM usage
free -h
```

---

## Troubleshooting Quick Reference

| Symptom | Fix |
|---------|-----|
| Open WebUI blank/502 | `sudo systemctl restart open-webui nginx` |
| Models not showing | `ollama list` — re-register if empty |
| n8n not accessible | `pm2 restart n8n` |
| Search not working | `sudo systemctl restart searxng` |
| Disk full | `df -h` — remove /opt/sovereign/usb-assets if post-install |
| Slow inference | Normal — 4.2 tok/s on CPU. GPU upgrade improves this |
| Cert warning in browser | Click Advanced → Proceed (self-signed cert, expected) |
| SSH refuses connection | `sudo systemctl restart ssh` from console |
