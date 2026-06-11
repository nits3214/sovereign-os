# Sovereign AI — Pre-Install Checklist
**Run every step below before launching install.sh**  
Learned from live deployments. Every item here has broken an install at least once.

---

## STAGE 0 — Ubuntu Autoinstall

The autoinstall (user-data on the USB) handles base OS setup, but it is
**not fully hands-free yet**. Expect to manually:

- Select language (English)
- Select keyboard layout
- Confirm username: `sovereign` / password as set
- Confirm disk to install to (select the SSD, not the USB)

> ⚠ Do not select the USB drive as the install target.  
> The SSD is typically `sda`. The USB will be `sdb`.

Once Ubuntu finishes installing, remove the USB, reboot, and log in via SSH:

```
ssh sovereign@<machine-ip>
```

If SSH gives a WARNING about host key changed — this is expected on a fresh
install. On your Windows machine run:

```
ssh-keygen -R <machine-ip>
```

Then reconnect and type `yes` to accept the new fingerprint.

---

## STAGE 1 — Fix LVM Disk Allocation

Ubuntu autoinstall does not use the full SSD by default.  
**Always run this before copying any files.**

### Check current allocation:
```bash
df -h /
```

If available space is less than 100GB on a 120GB SSD, run the fix:

### Fix:
```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

### Verify:
```bash
df -h /
```

Expected: ~103GB available on a 120GB SSD.  
**Do not proceed until this shows full disk.**

---

## STAGE 2 — Mount the USB Drive

The USB will not auto-mount on Ubuntu Server. Mount it manually.

### Find the USB:
```bash
lsblk
```

Look for a ~57GB disk — this is the USB (typically `sdb`).  
It has four partitions:

| Partition | Size    | Contents                        |
|-----------|---------|----------------------------------|
| sdb1      | 2GB     | Ubuntu ISO (bootable)           |
| sdb2      | ~5MB    | GPT metadata                    |
| sdb3      | ~300KB  | autoinstall config (user-data)  |
| sdb4      | ~55GB   | **Sovereign OS data** ← this one|

### Identify which partition has the data:
```bash
sudo blkid /dev/sdb1 /dev/sdb2 /dev/sdb3 /dev/sdb4
```

Look for the exFAT partition labelled `CIDATA` or the one showing ~55GB.

### Mount it:
```bash
sudo mkdir -p /mnt/usb
sudo mount /dev/sdb4 /mnt/usb
```

> If sdb4 doesn't work, try sdb1. The label and partition number can vary
> depending on how the USB was populated.

### Verify contents:
```bash
ls /mnt/usb
```

You should see:
```
install.sh
models/
venv.tar.gz
ollama-linux-amd64
n8n/
searxng/
nginx/
docs/
INSTALL_NOTES.md
```

**If models/ is missing or the listing looks wrong — stop.**  
The USB was not populated correctly. Re-run populate.ps1 on Windows first.

---

## STAGE 3 — Pre-flight Checks

Run these before executing install.sh:

### Check internet connectivity (needed for n8n NodeSource key):
```bash
curl -s --max-time 5 https://google.com > /dev/null && echo "ONLINE" || echo "OFFLINE"
```

> ⚠ Known limitation: n8n requires internet to fetch the NodeSource apt
> signing key. This is the one non-airgappable component. Document this
> for institutional deployments. All AI inference remains offline.

### Check available RAM:
```bash
free -h
```

Expected: ~14-15GB available on a 16GB machine.  
install.sh uses this to select the correct model tier automatically.

### Check available disk again:
```bash
df -h /
```

Must show at least 80GB free before models are copied (~21GB needed).

### Confirm unzip is available (needed by install.sh):
```bash
which unzip || sudo apt-get install -y unzip
```

---

## STAGE 4 — Run install.sh

Only proceed if all stages above are green.

```bash
cd /mnt/usb
sudo bash install.sh
```

Do not run with `sh install.sh` — must be `bash`.  
Expected runtime: 15–25 minutes depending on hardware.

---

## STAGE 5 — Post-Install Sovereignty Verification

**Always run this. Never assume.**

```bash
sudo -u ollama curl -s --max-time 5 https://ollama.com && echo "BREACH" || echo "BLOCKED"
```

Must return `BLOCKED`.

If it returns `BREACH`:
```bash
sudo iptables -I OUTPUT 1 -m owner --uid-owner $(id -u ollama) -j DROP
sudo iptables -I OUTPUT 2 -m owner --uid-owner $(id -u ollama) -j DROP
sudo netfilter-persistent save
```

Then re-run the test. Must return `BLOCKED` before the machine is considered sovereign.

### Verify iptables rule positions:
```bash
sudo iptables -L OUTPUT --line-numbers -n
```

The ollama DROP rules must appear at positions 1 and 2 — before the UFW
chains. If they are lower in the list, they will not fire.

---

## STAGE 6 — Service Health Check

```bash
sudo systemctl status ollama
sudo systemctl status open-webui
sudo systemctl status searxng
sudo systemctl status nginx
sudo systemctl status chromadb
```

All five must show `active (running)`.

Then confirm Open WebUI is accessible:
```bash
curl -s http://localhost:8080 | head -5
```

---

## STAGE 7 — Reboot Test

```bash
sudo reboot
```

SSH back in after ~60 seconds and re-run Stage 6.  
All five services must survive reboot without manual intervention.

---

## Known Limitations (document for institutional deployments)

| Issue | Status | Workaround |
|-------|--------|------------|
| LVM underallocation on autoinstall | Known | Stage 1 fix — baked into checklist |
| n8n NodeSource key needs internet | Known | Run install.sh while connected; AI stack works offline after |
| Open WebUI port set via CLI flag only | Known | `--port 8080 --host 0.0.0.0` in ExecStart (ENV var ignored in v0.9.6) |
| venv.tar.gz must use system Python | Known | Built with `/usr/bin/python3.11` not uv-embedded Python |
| USB may not mount to expected path | Known | Use `lsblk` + `blkid` to identify correct partition |
| Autoinstall not fully hands-free | Known | Language/keyboard/user prompts still require manual input |

---

## Quick Reference — Key Paths

| Resource | Path |
|----------|------|
| USB mount point | `/mnt/usb` |
| Ollama models | `/usr/share/ollama/.ollama/models/` |
| Open WebUI data | `/root/.open-webui/` |
| SearXNG config | `/etc/searxng/` |
| nginx config | `/etc/nginx/sites-available/sovereign` |
| n8n data | `/root/.n8n/` |
| ChromaDB data | `/var/lib/chromadb/` |
| Install log | `/var/log/sovereign_install.log` |
| Demo access log | `/var/log/demo_access.log` |

---

*Sovereign AI — thedxjournal.com*  
*Intelligence stays on the machine. Always.*
