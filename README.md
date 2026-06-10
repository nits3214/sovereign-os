# Sovereign OS

**A bootable, offline-capable sovereign AI stack for institutional deployment in developing economies.**

Run local large language models privately and permanently on second-hand hardware.  
No cloud. No subscriptions. No data leaving the building. Ever.

---

## What This Is

Sovereign OS is a scripted deployment stack that turns a standard x86 desktop — a Dell OptiPlex, a Lenovo ThinkCentre, any i5/i7 machine from 2014 onwards — into a fully functional private AI server. Students and staff access it from any browser on the local network. No accounts. No internet required after installation.

**Proven on:** Dell OptiPlex 3020 SFF, Intel i5-4570, 16GB DDR3, 120GB SSD, no GPU  
**Purchase cost:** Under £50 / ₹5,000 second-hand  
**Payback vs cloud subscription:** ~8 weeks  
**Marginal cost per query after that:** £0

Read the full white paper: [Sovereign AI — thedxjournal.com](https://thedxjournal.com/sovereign-ai/)

---

## What's Included

| File | Purpose |
|---|---|
| `install.sh` | Main deployment script — 12 idempotent stages, runs from USB |
| `populate.ps1` | Windows PowerShell script to load assets onto USB drive |
| `verify_usb.ps1` | Verifies USB contents before deployment |
| `user-data` | Ubuntu Server 22.04 autoinstall configuration |
| `docs/INSTALL_NOTES.md` | 28+ documented fixes from live deployment |
| `docs/sovereign-stack-reference-v2.md` | Full stack reference card |
| `docs/sovereign-os-setup-guide-v4.html` | Printable setup guide |

---

## The Stack

All components are MIT or Apache 2.0 licensed. No US-controlled proprietary dependencies.

- **OS:** Ubuntu Server 22.04.5 LTS
- **AI Runtime:** Ollama
- **Models:** Mistral 7B, Qwen 3 7B and 3B (Q4_K_M quantised)
- **Interface:** Open WebUI (browser-based, LAN accessible)
- **Speech to Text:** Whisper
- **Text to Speech:** Piper TTS
- **Search:** SearXNG (self-hosted)
- **Vector DB:** ChromaDB (RAG pipeline)
- **Automation:** n8n (self-hosted workflow engine)
- **Proxy:** nginx with HTTPS (self-signed cert)
- **Security:** UFW + iptables, all AI traffic LAN-only, outbound blocked

---

## Hardware Requirements

**Minimum (Retrofit tier):**
- Intel i5 or i7, 4th generation or later
- 16GB RAM (8GB works, 16GB recommended)
- 120GB SSD (minimum)
- No GPU required

**Recommended for institutions (Hub tier):**
- 32–64GB RAM
- AMD RX 6600 GPU or better
- Serves 20–30 Retrofit machines over LAN via Ollama network API

See the [white paper](https://thedxjournal.com/sovereign-ai/) for full hardware tier breakdown and Bill of Materials.

---

## Quick Start

**You will need:**
- A 64GB USB drive
- A Windows machine to run `populate.ps1`
- A target x86 machine (see hardware requirements above)
- A monitor and keyboard for the initial 15-minute install phase

**Steps:**
1. Run `populate.ps1` on Windows to download all assets to the USB (~21GB)
2. Boot the target machine from USB — Ubuntu Server installs automatically
3. SSH into the machine after install completes
4. Run `sudo bash /opt/sovereign/install.sh`
5. Access Open WebUI at `https://[machine-ip]` from any browser on your network

Full step-by-step instructions in `docs/sovereign-os-setup-guide-v4.html`

---

## Deployment Models

**Hub and Spoke:** One powerful machine runs the stack and serves 20–30 thin-client machines over LAN. End users connect via browser — no change to their existing Windows workflow.

**Fully Distributed:** Each machine runs its own full stack from USB. Completely airgapped. No network dependency.

---

## ⚠️ Disclaimer

This software is provided **as is**, without warranty of any kind, express or implied.

By using this software you acknowledge:

- You are responsible for your own deployment, configuration, and maintenance
- The authors accept no liability for data loss, system damage, hardware failure, security incidents, or any other consequences arising from use of these scripts
- This is not production enterprise software — it is an open-source deployment toolkit intended for technically capable users
- Always test on non-critical hardware before institutional deployment
- Review all scripts before running them — never run untrusted code as root without reading it first

For supported deployment with professional accountability, see the **Professional Services** section below.

---

## Professional Services

Self-deployment is free and fully documented here.

If you are an institution that wants hands-on support — hardware selection, 
deployment, staff training, and ongoing maintenance — that is available as 
a professional service:

- **AI Lab Audit** — assess your existing hardware and readiness:   from £350 / ₹25,000
- **Retrofit Kit + Deployment** — hardware sourced, configured, deployed: from £150 / ₹8,000 per machine
- **Full Lab Setup + Training** — complete institutional deployment: from £2,000 / ₹1,00,000
- **Annual Support Contract** — ongoing maintenance and model updates: from £1,000 / ₹50,000 per year

**Contact:** [thedxjournal.com/sovereign-ai](https://thedxjournal.com/sovereign-ai/)

---

## Licence

MIT Licence — Copyright 2026 Nitin Chandnani / thedxjournal.com

Free to use, modify, and distribute. Share freely with attribution.  
See `LICENSE` for full terms.

---

*Built by a practitioner who deployed it. Not a research project.*
