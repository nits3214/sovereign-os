# Sovereign OS — INSTALL_NOTES.md
# Documented fixes from live deployment sessions
# Dell OptiPlex 3020 SFF | Ubuntu 22.04 | June 2026
# install.sh v2.0 incorporates all fixes below

---

## DEPLOYMENT PREREQUISITES

Before running install.sh, confirm:
- Ubuntu Server 22.04.5 LTS installed (via USB autoinstall)
- Machine is connected via ethernet (not WiFi)
- SSH access working: `ssh sovereign@[machine-ip]`
- USB drive mounted at /mnt/usb or /dev/sdb4

---

## FIX 1 — USB label must be CIDATA not SOVEREIGN
**Problem:** Cloud-init looks for a volume named CIDATA specifically.
**Symptom:** Autoinstall doesn't trigger, Ubuntu asks for manual setup.
**Fix:** Label the exFAT partition CIDATA in PowerShell before use:
```powershell
label S: CIDATA
```
user-data and meta-data must be in the ROOT of S:\ not in a subfolder.

---

## FIX 2 — meta-data file must exist alongside user-data
**Problem:** Cloud-init requires both user-data AND meta-data to be present.
**Symptom:** Autoinstall triggers partially or not at all.
**Fix:** Create an empty meta-data file at S:\meta-data
```powershell
New-Item -ItemType File -Path "S:\meta-data" -Force
```

---

## FIX 3 — USB detected as second disk during install
**Problem:** On machines with one SSD, the USB was seen as /dev/sda pushing
the SSD to /dev/sdb, causing storage layout mismatch.
**Symptom:** Install fails at storage configuration stage.
**Fix:** user-data storage layout uses `name: lvm` with `match: path: /dev/sda`.
Verify your disk path by booting a live USB and running `lsblk` first.

---

## FIX 4 — LVM only allocates ~50% of disk
**Problem:** Ubuntu autoinstall with LVM layout leaves half the disk unallocated.
**Symptom:** Disk fills up during asset copy (22GB models + 3.3GB venv).
**Fix:** Run immediately after install:
```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```
Now baked into user-data late-commands and install.sh Stage 0.

---

## FIX 5 — Ollama permission denied on models directory
**Problem:** Models directory created as root, Ollama service runs as ollama user.
**Symptom:** `permission denied` when Ollama tries to read GGUF files.
**Fix:**
```bash
sudo chown -R ollama:ollama /opt/sovereign/models
sudo chmod -R 755 /opt/sovereign/models
```

---

## FIX 6 — uv tarball extraction path mismatch
**Problem:** uv extracts to `uv-x86_64-unknown-linux-gnu/uv` not `uv/uv`.
**Symptom:** `uv: command not found` after extraction.
**Fix:** Use find to locate the binary after extraction:
```bash
UV_BIN=$(find /tmp/uv-extract -name "uv" -type f | head -1)
sudo cp "$UV_BIN" /usr/local/bin/uv
```

---

## FIX 7 — Open WebUI requires Python 3.11 not system Python 3.10
**Problem:** Ubuntu 22.04 ships Python 3.10. Open WebUI 0.9.6 requires 3.11.
**Symptom:** Import errors, missing tomllib module.
**Fix:** Install Python 3.11 explicitly:
```bash
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt install python3.11 python3.11-dev python3.11-venv -y
```
Then use uv to create venv with 3.11:
```bash
uv venv --python 3.11 /opt/sovereign/venv
```

---

## FIX 8 — venv.tar.gz non-portable due to uv embedded Python path
**Problem:** venv built with uv embeds Python at a machine-specific path
`/opt/uv-python/cpython-3.11-linux-x86_64-gnu/bin/python3.11`
which doesn't exist on any other machine.
**Symptom:** Open WebUI deadlocks on startup on second machine.
**Fix:** Build venv using system Python via uv:
```bash
uv venv --python /usr/bin/python3.11 /opt/sovereign/venv
source /opt/sovereign/venv/bin/activate
uv pip install open-webui==0.9.6
```
Then repack from the WORKING live machine:
```bash
cd /opt/sovereign
sudo tar -czf /tmp/venv.tar.gz venv/
# Copy to USB and replace old venv.tar.gz
```

---

## FIX 9 — venv ownership causes systemd 203/EXEC errors
**Problem:** venv directory owned by root, service runs as sovereign user.
**Symptom:** `open-webui.service` fails with code=exited, status=203/EXEC
**Fix:** Fix ownership before starting service:
```bash
sudo chown -R sovereign:sovereign /opt/sovereign/venv
sudo chown -R sovereign:sovereign /opt/sovereign
```
Now baked into install.sh before systemctl start open-webui.

---

## FIX 10 — Open WebUI binds to port 8080 not 3000
**Problem:** Open WebUI v0.9.6 ignores `Environment="PORT=3000"` in service file
and always binds to port 8080.
**Symptom:** Open WebUI unreachable at port 3000, nginx returns 502.
**Fix:** nginx proxy_pass must point to 8080:
```nginx
proxy_pass http://127.0.0.1:8080;
```
And ExecStart must use CLI flag:
```
ExecStart=/opt/sovereign/venv/bin/open-webui serve --port 8080 --host 0.0.0.0
```

---

## FIX 11 — Models must be registered with Ollama via Modelfile
**Problem:** Copying GGUF files to /opt/sovereign/models is not enough.
Ollama does not auto-detect them — they must be explicitly registered.
**Symptom:** `ollama list` shows no models despite files being present.
**Fix:** Register each model:
```bash
echo "FROM /opt/sovereign/models/gguf/mistral-7b-instruct-q4_k_m.gguf" | \
  ollama create mistral-7b -f -
echo "FROM /opt/sovereign/models/gguf/qwen2.5-7b-instruct-q4_k_m.gguf" | \
  ollama create qwen2.5-7b -f -
echo "FROM /opt/sovereign/models/gguf/qwen2.5-3b-instruct-q4_k_m.gguf" | \
  ollama create qwen2.5-3b -f -
```

---

## FIX 12 — Copy ALL models regardless of RAM tier for server deployment
**Problem:** install.sh originally skipped larger models on low-RAM machines.
**Symptom:** Only 3B model available on 8GB machine even when used as server.
**Fix:** Always copy all models. Tier detection only affects which model is
set as default in Open WebUI, not which models are available.

---

## FIX 13 — GRUB timeout set to 30 seconds by default
**Problem:** Ubuntu sets GRUB timeout to 30 seconds, slowing every boot.
**Symptom:** Machine waits 30 seconds at GRUB before booting.
**Fix:**
```bash
sudo sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
sudo update-grub
```

---

## FIX 14 — Hostname typo sovereign -> soverreign
**Problem:** Typo in user-data or identity block duplicated in /etc/hosts.
**Symptom:** SSH banner shows `soverreign`, hostname mismatch warnings.
**Fix:**
```bash
sudo hostnamectl set-hostname sovereign-server
sudo sed -i 's/soverreign/sovereign/g' /etc/hosts
```

---

## FIX 15 — Stale fstab entries cause boot hangs
**Problem:** Old USB or disk entries in /etc/fstab cause systemd to wait on
missing devices at boot.
**Symptom:** Boot hangs for 90 seconds with "A start job is running for..."
**Fix:**
```bash
sudo nano /etc/fstab
# Remove any lines referencing /dev/sdb or old USB paths
# Keep only /dev/ubuntu-vg/ubuntu-lv and /boot/efi entries
```

---

## FIX 16 — nginx self-signed cert required for microphone access
**Problem:** Chrome blocks microphone (getUserMedia) on HTTP origins.
**Symptom:** Whisper STT button does nothing in Open WebUI over HTTP.
**Fix:** Generate self-signed cert and configure nginx HTTPS on port 443:
```bash
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/ssl/private/sovereign.key \
  -out /etc/ssl/certs/sovereign.crt \
  -subj "/CN=sovereign-server"
```
Users must click "Advanced → Proceed" on first visit.
Access URL: https://[machine-ip]

---

## FIX 17 — PM2 startup crashes under set -euo pipefail
**Problem:** `pm2 startup systemd` outputs text that grep treats as a command,
crashing install.sh under strict error mode.
**Symptom:** install.sh exits at Stage 10 with grep error.
**Fix:** Capture pm2 startup output separately, run the generated command
independently, and suppress grep exit codes:
```bash
PM2_STARTUP=$(pm2 startup systemd 2>&1 | grep "sudo env" || true)
if [ -n "$PM2_STARTUP" ]; then eval "$PM2_STARTUP"; fi
pm2 save --force
```

---

## FIX 18 — n8n reinstalls on every install.sh run
**Problem:** install.sh checked for npm package not n8n binary.
**Symptom:** n8n npm install runs every time, taking 2+ minutes.
**Fix:** Check for n8n binary before installing:
```bash
if ! command -v n8n &>/dev/null; then
  npm install -g n8n
fi
```

---

## FIX 19 — SearXNG git clone fails on existing directory
**Problem:** `git clone` errors if /opt/searxng/searxng-src already exists.
**Symptom:** install.sh exits at Stage 11.
**Fix:**
```bash
if [ ! -d "/opt/searxng/searxng-src/.git" ]; then
  git clone https://github.com/searxng/searxng /opt/searxng/searxng-src
else
  cd /opt/searxng/searxng-src && git pull
fi
```

---

## FIX 20 — SearXNG venv rebuilds unnecessarily
**Problem:** venv check was too broad, triggering full rebuild on every run.
**Symptom:** SearXNG stage takes 5+ minutes every install.sh run.
**Fix:** Check for searxng package specifically:
```bash
if ! /opt/searxng/venv/bin/python -c "import searx" 2>/dev/null; then
  # rebuild venv
fi
```

---

## FIX 21 — SearXNG settings.yml bind_address and port as separate keys
**Problem:** SearXNG 2026 changed settings format — combined server.port
no longer works.
**Symptom:** SearXNG starts but listens on wrong address/port.
**Fix:** settings.yml must have:
```yaml
server:
  bind_address: "127.0.0.1"
  port: 8888
```

---

## FIX 22 — SearXNG valkey URL must be empty string not commented out
**Problem:** SearXNG errors on startup if valkey/redis URL is present but
the service isn't running.
**Symptom:** SearXNG fails to start with connection refused error.
**Fix:** Set explicitly to empty:
```yaml
redis:
  url: ""
```

---

## FIX 23 — n8n activation screen on first access
**Problem:** n8n shows activation/registration screen on first browser visit.
**Symptom:** Users prompted to create n8n account before using workflows.
**Fix:** Set in ecosystem.config.js:
```javascript
N8N_SKIP_WEBHOOK_DEREGISTRATION_SHUTDOWN: 'true',
N8N_PERSONALIZATION_ENABLED: 'false',
N8N_DIAGNOSTICS_ENABLED: 'false',
N8N_VERSION_NOTIFICATIONS_ENABLED: 'false',
```

---

## FIX 24 — n8n secure cookie requires HTTPS
**Problem:** n8n sets secure cookie flag which fails over HTTP.
**Symptom:** n8n login loop — logs in then immediately redirects to login.
**Fix:** Set in ecosystem.config.js:
```javascript
N8N_SECURE_COOKIE: 'false',
```

---

## FIX 25 — USB_SOURCE path must be /opt/sovereign not /mnt/usb/sovereign
**Problem:** user-data copies USB assets to /opt/sovereign during autoinstall.
install.sh was looking at /mnt/usb/sovereign.
**Symptom:** install.sh Stage 0 cannot find models or binaries.
**Fix:** USB_SOURCE="/opt/sovereign" in install.sh

---

## FIX 26 — USB mount detection must use findmnt before remounting
**Problem:** Stage 0a tried to remount USB already mounted at /mnt/usb,
causing mount conflict error.
**Symptom:** install.sh exits at Stage 0a with "already mounted" error.
**Fix:**
```bash
EXISTING=$(findmnt -rn -S LABEL=CIDATA -o TARGET 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  USB_MOUNT="$EXISTING"
else
  sudo mount LABEL=CIDATA /mnt/sovereign-usb
  USB_MOUNT="/mnt/sovereign-usb"
fi
```

---

## FIX 27 — CRITICAL: Sovereignty breach — iptables rules fired after UFW
**Problem:** iptables DROP rules for Ollama UID 998 were inserted after UFW
ACCEPT chains, so UFW accepted outbound traffic before DROP rules fired.
**Symptom:** Ollama could make outbound HTTP/HTTPS connections despite
appearing to be blocked. Sovereignty was NOT enforced.
**Fix:** Rules must be inserted at positions 1 and 2, before UFW chains:
```bash
sudo iptables -I OUTPUT 1 -m owner --uid-owner 998 -p tcp --dport 443 -j DROP
sudo iptables -I OUTPUT 2 -m owner --uid-owner 998 -p tcp --dport 80 -j DROP
sudo netfilter-persistent save
```
Verify sovereignty:
```bash
sudo iptables -L OUTPUT --line-numbers | grep -i "ollama\|uid-owner\|DROP"
# Rules must appear at lines 1 and 2, BEFORE any UFW rules
```

---

## FIX 28 — Sovereignty check grep didn't match iptables output
**Problem:** install.sh grepped for Ollama UID number in iptables output.
The output format uses "uid-owner" text not the numeric UID.
**Symptom:** Sovereignty check always showed WARN even when correctly configured.
**Fix:**
```bash
iptables -L OUTPUT | grep -q "ollama\|uid-owner"
```

---

## VERIFIED WORKING STATE (June 2026)

Stack confirmed fully operational on Dell OptiPlex 3020 SFF:
- Ollama — running, 3 models registered ✅
- Open WebUI — port 8080, accessible via nginx HTTPS ✅
- SearXNG — port 8888, wired into Open WebUI ✅
- ChromaDB — running, v2 API confirmed ✅
- n8n — port 5678, PM2 managed, boot persistent ✅
- nginx — HTTPS port 443, self-signed cert ✅
- UFW — hardened, AI services LAN-only ✅
- Sovereignty — iptables DROP rules at positions 1+2, verified ✅
- Performance — 4.2 tokens/sec on i5-4570, 16GB RAM ✅

Access: https://192.168.1.100 (accept self-signed cert warning)
SSH: ssh sovereign@192.168.1.100
