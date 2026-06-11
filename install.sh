#!/usr/bin/env bash
# =============================================================================
# Sovereign OS -- install.sh v2.2
# Installs the full AI stack from USB assets onto a fresh Ubuntu 22.04 machine.
#
# USAGE:
#   sudo bash install.sh
#
# WHAT IT DOES:
#   Stage 0a : Auto-detect USB by CIDATA label, mount it, copy assets to SSD
#   Stages 0-9  : Core stack (always runs)
#   Stage 10    : n8n workflow automation (if INSTALL_N8N=true)
#   Stage 11    : SearXNG local web search (if INSTALL_SEARXNG=true)
#   Stage 12    : nginx HTTPS (if INSTALL_HTTPS=true)
#
# AIRGAP BEHAVIOUR:
#   If packages/venv.tar.gz exists on USB: fully offline install
#   If not: internet required for first machine only, then USB is updated
#
# CHANGELOG v2.2 (June 2026):
#   + Stage 0a: fallback check for assets at /opt/sovereign (copied by
#               user-data v2.1 and earlier -- handles both path layouts)
#   + Stage 1:  sqlite3 and unzip added to base packages
#   + Stage 4:  iptables sovereignty rules inserted at OUTPUT position 1
#               (must fire BEFORE UFW chains -- critical fix from live testing)
#   + Stage 4:  Sovereignty verification test runs post-install
#   + Stage 5:  nomic-embed-text registered from USB blobs + manifest
#   + Stage 5:  All model num_ctx values set explicitly (no silent defaults)
#               7B: 16384, 3B: 8192
#   + Stage 6:  ExecStart uses --port CLI flag (ENV PORT ignored in v0.9.6)
#   + Stage 6:  Open WebUI config patched post-start via sqlite3 Python script
#               (fixes RAG embedding model, SearXNG URL, bypass flags)
#   + All v2.1 fixes retained
#
# COMPANION FILES (update together):
#   user-data v2.2  -- late-commands path + LVM extend + snap removal
#   populate.ps1 v2.1 -- nomic blob verification
#   verify_usb.ps1 v2.1 -- nomic blob checks
# =============================================================================

# =============================================================================
# CONFIG -- EDIT THIS SECTION TO CUSTOMISE YOUR DEPLOYMENT
# =============================================================================

SOVEREIGN_USER="sovereign"
OLLAMA_HOST="0.0.0.0"
OLLAMA_PORT="11434"
WEBUI_PORT="8080"
N8N_PORT="5678"
SEARXNG_PORT="8888"
LAN_SUBNET="192.168.1.0/24"

MODEL_PRIMARY="mistral-7b-instruct-q4_k_m.gguf"
MODEL_SECONDARY="Qwen2.5-7B-Instruct-Q4_K_M.gguf"
MODEL_SMALL="Qwen2.5-3B-Instruct-Q4_K_M.gguf"

INSTALL_N8N=true
INSTALL_SEARXNG=true
INSTALL_HTTPS=true

MODELS_DIR="/opt/sovereign/models"
DATA_DIR="/var/lib/sovereign"
VENV_DIR="/opt/sovereign/venv"
ASSETS_DIR="/opt/sovereign/usb-assets"   # USB contents copied here at Stage 0a

LOG_FILE="/var/log/sovereign-install.log"

# USB_SOURCE is set dynamically in stage_usb_copy -- do not edit here
USB_SOURCE=""

# =============================================================================
# DO NOT EDIT BELOW THIS LINE
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; }
log_section() { echo -e "\n${BOLD}${CYAN}======  $*  ======${RESET}\n" | tee -a "$LOG_FILE"; }

STATE_FILE="/var/lib/sovereign/.install_state"
mark_done() { mkdir -p "$(dirname $STATE_FILE)"; echo "$1" >> "$STATE_FILE"; }
is_done()   { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }

# =============================================================================
# STAGE 0a -- USB DETECTION AND ASSET COPY TO SSD
# Finds USB by CIDATA label, mounts it, copies sovereign folder to SSD.
# All subsequent stages read from SSD -- fast and reliable.
# =============================================================================
stage_usb_copy() {
    log_section "Stage 0a -- USB Detection and Asset Copy"

    # Check 1: assets already at canonical ASSETS_DIR (re-run scenario)
    if [[ -d "$ASSETS_DIR/binaries" ]] && [[ -d "$ASSETS_DIR/models" ]]; then
        log_ok "Assets already on SSD at $ASSETS_DIR -- skipping copy"
        USB_SOURCE="$ASSETS_DIR"
        return
    fi

    # Check 2: autoinstall late-commands copied assets to /opt/sovereign directly
    # (user-data v2.1 and earlier used this path before v2.2 fixed it)
    # Safe fallback -- use in place without copying again
    if [[ -d "/opt/sovereign/binaries" ]] && [[ -d "/opt/sovereign/models" ]]; then
        log_ok "Assets found at /opt/sovereign (copied by autoinstall) -- using in place"
        USB_SOURCE="/opt/sovereign"
        ASSETS_DIR="/opt/sovereign"
        return
    fi

    # Find the CIDATA partition by label
    local usb_dev=""
    log_info "Searching for CIDATA partition..."

    # Method 1: blkid by label
    usb_dev=$(blkid -L CIDATA 2>/dev/null || true)

    # Method 2: scan all block devices if method 1 fails
    if [[ -z "$usb_dev" ]]; then
        log_info "blkid label search failed -- scanning block devices..."
        for dev in /dev/sd?[0-9]*; do
            label=$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)
            if [[ "$label" == "CIDATA" ]]; then
                usb_dev="$dev"
                break
            fi
        done
    fi

    if [[ -z "$usb_dev" ]]; then
        log_error "Could not find CIDATA partition. Is the USB drive plugged in?"
        log_error "Plug in the USB drive and run again."
        exit 1
    fi

    log_ok "Found CIDATA partition: $usb_dev"

    # Mount it
    local usb_mount="/mnt/sovereign-usb"
    mkdir -p "$usb_mount"

    if mountpoint -q "$usb_mount"; then
        log_info "Already mounted at $usb_mount"
    else
        # Check if already mounted elsewhere and bind if so
        existing=$(findmnt -n -o TARGET --source "$usb_dev" 2>/dev/null | head -1)
        if [[ -n "$existing" ]]; then
            mount --bind "$existing" "$usb_mount" 2>&1 | tee -a "$LOG_FILE" || {
                log_error "Failed to bind mount $usb_dev from $existing"
                exit 1
            }
            log_ok "Bind mounted from $existing to $usb_mount"
        else
            mount -o ro "$usb_dev" "$usb_mount" 2>&1 | tee -a "$LOG_FILE" || {
                log_error "Failed to mount $usb_dev at $usb_mount"
                exit 1
            }
            log_ok "Mounted $usb_dev at $usb_mount (read-only)"
        fi
    fi

    # Verify sovereign folder exists on USB
    if [[ ! -d "$usb_mount/sovereign" ]]; then
        log_error "No 'sovereign' folder found on USB at $usb_mount"
        log_error "Expected: $usb_mount/sovereign/"
        exit 1
    fi

    # Copy sovereign folder to SSD
    log_info "Copying USB assets to SSD ($ASSETS_DIR)..."
    log_info "This may take 5-15 minutes for ~22GB of assets..."
    mkdir -p "$ASSETS_DIR"

    # Use rsync if available for progress; fall back to cp
    if command -v rsync &>/dev/null; then
        rsync -a --info=progress2 "$usb_mount/sovereign/" "$ASSETS_DIR/" \
            2>&1 | tee -a "$LOG_FILE"
    else
        cp -r "$usb_mount/sovereign/." "$ASSETS_DIR/" 2>&1 | tee -a "$LOG_FILE"
    fi

    log_ok "Assets copied to $ASSETS_DIR"

    # Unmount USB -- no longer needed
    umount "$usb_mount" 2>/dev/null || true
    log_ok "USB unmounted -- install continues from SSD"

    # Deploy demo_access.sh to /opt/sovereign for easy access
    cp "$ASSETS_DIR/demo_access.sh" /opt/sovereign/demo_access.sh 2>/dev/null || true
    chmod +x /opt/sovereign/demo_access.sh 2>/dev/null || true

    USB_SOURCE="$ASSETS_DIR"
    log_ok "USB_SOURCE set to: $USB_SOURCE"
}

# =============================================================================
# STAGE 0 -- PREFLIGHT
# =============================================================================
stage_preflight() {
    is_done "preflight" && { log_info "Preflight already done, skipping"; return; }
    log_section "Stage 0 -- Preflight"

    [[ $EUID -ne 0 ]] && { log_error "Must run as root"; exit 1; }

    [[ -z "$USB_SOURCE" ]] && { log_error "USB_SOURCE not set -- stage_usb_copy must run first"; exit 1; }

    if [[ ! -d "$USB_SOURCE" ]]; then
        log_error "USB source not found: $USB_SOURCE"
        exit 1
    fi
    log_ok "Asset source confirmed: $USB_SOURCE"

    # Detect RAM and assign tier
    RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    log_info "RAM detected: ${RAM_GB}GB"

    if   [[ $RAM_GB -ge 32 ]]; then TIER="A"
    elif [[ $RAM_GB -ge 12 ]]; then TIER="B"
    elif [[ $RAM_GB -ge 6  ]]; then TIER="C"
    elif [[ $RAM_GB -ge 4  ]]; then TIER="D"
    else
        log_error "Less than 4GB RAM detected. Minimum 4GB required."
        exit 1
    fi
    log_ok "Hardware tier: $TIER (${RAM_GB}GB RAM)"

    CPU_CORES=$(nproc)
    AVX2=$(grep -c avx2 /proc/cpuinfo || true)
    log_info "CPU: $CPU_CORES cores, AVX2: $([[ $AVX2 -gt 0 ]] && echo yes || echo no)"

    GPU_VENDOR="none"
    if lspci 2>/dev/null | grep -qi "nvidia"; then GPU_VENDOR="nvidia"; fi
    if lspci 2>/dev/null | grep -qi "amd\|radeon"; then GPU_VENDOR="amd"; fi
    log_info "GPU: $GPU_VENDOR"

    mkdir -p /etc/sovereign
    cat > /etc/sovereign/hw.conf << EOF
HW_TIER=$TIER
RAM_GB=$RAM_GB
CPU_CORES=$CPU_CORES
AVX2=$([[ $AVX2 -gt 0 ]] && echo true || echo false)
GPU_VENDOR=$GPU_VENDOR
MODELS_DIR=$MODELS_DIR
DATA_DIR=$DATA_DIR
INSTALL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

    mkdir -p "$MODELS_DIR/gguf" "$MODELS_DIR/sdxl" \
             "$MODELS_DIR/whisper" "$MODELS_DIR/piper"
    mkdir -p "$DATA_DIR/chromadb" "$DATA_DIR/logs" \
             "$DATA_DIR/openwebui" "$DATA_DIR/n8n"
    mkdir -p /etc/sovereign

    mark_done "preflight"
    log_ok "Preflight complete -- Tier $TIER, ${RAM_GB}GB RAM, GPU: $GPU_VENDOR"
}

# =============================================================================
# STAGE 1 -- BASE PACKAGES
# =============================================================================
stage_packages() {
    is_done "packages" && { log_info "Packages already installed, skipping"; return; }
    log_section "Stage 1 -- Base Packages"

    apt-get update -qq 2>&1 | tee -a "$LOG_FILE" || true

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl wget git \
        python3 python3-pip python3-venv \
        python3.11 python3.11-venv python3.11-dev \
        python3-dev python3-babel \
        libxml2-dev libxslt-dev zlib1g-dev \
        build-essential \
        ffmpeg \
        avahi-daemon \
        ufw \
        iptables-persistent \
        sqlite3 \
        unzip \
        htop \
        zstd \
        openssl \
        rsync \
        2>&1 | tee -a "$LOG_FILE"

    log_ok "Base packages installed"
    mark_done "packages"
}

# =============================================================================
# STAGE 2 -- SECURITY & FIREWALL
# =============================================================================
stage_security() {
    is_done "security" && { log_info "Security already configured, skipping"; return; }
    log_section "Stage 2 -- Security & Firewall"

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    ufw allow 22/tcp comment "SSH"
    ufw allow 443/tcp comment "Sovereign HTTPS"

    ufw allow from "$LAN_SUBNET" to any port "$WEBUI_PORT" comment "Open WebUI LAN"
    ufw allow from "$LAN_SUBNET" to any port "$OLLAMA_PORT" comment "Ollama LAN"
    ufw allow from "$LAN_SUBNET" to any port "$N8N_PORT" comment "n8n LAN"
    ufw allow from "$LAN_SUBNET" to any port "$SEARXNG_PORT" comment "SearXNG LAN"
    ufw allow in on tailscale0 to any port "$WEBUI_PORT" comment "Open WebUI Tailscale"
    ufw allow in on tailscale0 to any port "$SEARXNG_PORT" comment "SearXNG Tailscale"
    ufw allow in on tailscale0 to any port "$N8N_PORT" comment "n8n Tailscale"

    ufw --force enable
    log_ok "UFW configured"

    cat > /etc/sysctl.d/99-sovereign.conf << 'EOF'
vm.swappiness = 10
net.ipv4.tcp_syncookies = 1
EOF
    sysctl -p /etc/sysctl.d/99-sovereign.conf 2>/dev/null || true

    for svc in apport whoopsie snapd; do
        systemctl disable "$svc" 2>/dev/null || true
        systemctl stop "$svc" 2>/dev/null || true
    done

    mark_done "security"
    log_ok "Security stage complete"
}

# =============================================================================
# STAGE 3 -- SECOND DISK (if present)
# =============================================================================
stage_disk() {
    is_done "disk" && { log_info "Disk already configured, skipping"; return; }
    log_section "Stage 3 -- Storage"

    # Find second disk that is not USB and not the boot disk
    local second_disk=""
    for dev in /dev/sdb /dev/sdc /dev/sdd; do
        [[ ! -b "$dev" ]] && continue
        local tran
        tran=$(lsblk -no TRAN "$dev" 2>/dev/null || echo "")
        [[ "$tran" == "usb" ]] && continue
        # Skip if it has the CIDATA label (it's the USB we copied from)
        if blkid "$dev"* 2>/dev/null | grep -q "CIDATA"; then continue; fi
        second_disk="$dev"
        break
    done

    if [[ -n "$second_disk" ]]; then
        log_info "Second disk found: $second_disk"

        if ! blkid "${second_disk}1" &>/dev/null; then
            log_info "Partitioning and formatting ${second_disk}..."
            echo -e "o\nn\np\n1\n\n\nw" | fdisk "$second_disk" 2>&1 | tee -a "$LOG_FILE" || true
            sleep 2
            mkfs.ext4 -F "${second_disk}1" 2>&1 | tee -a "$LOG_FILE"
            log_ok "${second_disk}1 formatted as ext4"
        else
            log_info "${second_disk}1 already formatted, skipping"
        fi

        mkdir -p /mnt/hdd
        # Only add to fstab if not already there
        if ! grep -q "${second_disk}1" /etc/fstab; then
            echo "${second_disk}1  /mnt/hdd  ext4  defaults  0  2" >> /etc/fstab
        fi
        mount /mnt/hdd 2>/dev/null || true
        log_ok "Second disk mounted at /mnt/hdd"

        MODELS_DIR="/mnt/hdd/models"
        DATA_DIR="/mnt/hdd/sovereign"
        mkdir -p "$MODELS_DIR/gguf" "$MODELS_DIR/sdxl" \
                 "$MODELS_DIR/whisper" "$MODELS_DIR/piper" \
                 "$DATA_DIR/chromadb" "$DATA_DIR/logs" \
                 "$DATA_DIR/openwebui"

        sed -i "s|MODELS_DIR=.*|MODELS_DIR=$MODELS_DIR|" /etc/sovereign/hw.conf
        sed -i "s|DATA_DIR=.*|DATA_DIR=$DATA_DIR|" /etc/sovereign/hw.conf
        log_ok "Storage redirected to /mnt/hdd"
    else
        log_info "No second disk -- using primary SSD"
    fi

    mark_done "disk"
    log_ok "Storage stage complete"
}

# =============================================================================
# STAGE 4 -- OLLAMA
# CRITICAL: iptables sovereignty rules MUST be inserted at OUTPUT position 1
# to fire BEFORE UFW chains. Appending with -A puts them after UFW and they
# never fire. Verified on i5-4570 Ubuntu 22.04 in live testing June 2026.
# Sovereignty test must be run after every install.
# =============================================================================
stage_ollama() {
    is_done "ollama" && { log_info "Ollama already installed, skipping"; return; }
    log_section "Stage 4 -- Ollama"

    source /etc/sovereign/hw.conf

    # Fix hostname if incorrect
    current_hostname=$(hostname)
    if [[ "$current_hostname" != "sovereign-server" ]]; then
        hostnamectl set-hostname sovereign-server
        sed -i "s/${current_hostname}/sovereign-server/g" /etc/hosts 2>/dev/null || true
        log_ok "Hostname set to sovereign-server"
    fi

    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        OLLAMA_BIN="$USB_SOURCE/binaries/ollama-linux-amd64.tar.zst"
    else
        OLLAMA_BIN="$USB_SOURCE/binaries/ollama-linux-arm64.tar.zst"
    fi

    if [[ -f "$OLLAMA_BIN" ]]; then
        log_info "Installing Ollama from USB assets..."
        tar --use-compress-program=zstd -xf "$OLLAMA_BIN" -C /usr 2>&1 | tee -a "$LOG_FILE"
        log_ok "Ollama installed"
    else
        log_warn "Ollama binary not found in assets -- downloading..."
        curl -fsSL https://ollama.com/install.sh | sh 2>&1 | tee -a "$LOG_FILE"
    fi

    id ollama &>/dev/null || useradd -r -s /bin/false -m -d /usr/share/ollama ollama

    # ------------------------------------------------------------------
    # SOVEREIGNTY BLOCK -- iptables rules MUST be at OUTPUT position 1
    # Inserting with -I OUTPUT 1 puts them before UFW's ufw-before-output
    # chain. If you use -A they go after UFW and never fire. This was
    # identified as a critical sovereignty breach in live testing.
    # ------------------------------------------------------------------
    log_info "Applying sovereignty iptables rules (OUTPUT position 1)..."
    OLLAMA_UID=$(id -u ollama)

    # Flush any existing ollama rules first to avoid duplicates on re-run
    iptables -D OUTPUT -m owner --uid-owner "$OLLAMA_UID" -p tcp --dport 443 -j DROP \
        2>/dev/null || true
    iptables -D OUTPUT -m owner --uid-owner "$OLLAMA_UID" -p tcp --dport 80 -j DROP \
        2>/dev/null || true

    # Insert at position 1 -- fires before UFW chains
    iptables -I OUTPUT 1 -m owner --uid-owner "$OLLAMA_UID" -p tcp --dport 443 -j DROP
    iptables -I OUTPUT 1 -m owner --uid-owner "$OLLAMA_UID" -p tcp --dport 80 -j DROP

    # Persist rules
    netfilter-persistent save 2>&1 | tee -a "$LOG_FILE" || \
        iptables-save > /etc/iptables/rules.v4

    log_ok "Sovereignty rules applied at OUTPUT positions 1 and 2"

    # Verify rules are in correct position
    log_info "Verifying sovereignty rule positions..."
	RULE_POS_443=$(sudo iptables -L OUTPUT --line-numbers 2>/dev/null | \
	    grep "uid-owner $OLLAMA_UID" | grep "dpt:443" | awk '{print $1}' | head -1) || true
	RULE_POS_80=$(sudo iptables -L OUTPUT --line-numbers 2>/dev/null | \
	    grep "uid-owner $OLLAMA_UID" | grep "dpt:80" | awk '{print $1}' | head -1) || true

    if [[ -n "$RULE_POS_443" ]] && [[ -n "$RULE_POS_80" ]] && [[ "$RULE_POS_443" -le 2 ]] && [[ "$RULE_POS_80" -le 2 ]]; then
        log_ok "Sovereignty rules confirmed at positions $RULE_POS_80 and $RULE_POS_443"
    else
        log_warn "Sovereignty rules may not be in correct position -- verify manually"
        log_warn "Run: sudo sudo iptables -L OUTPUT --line-numbers"
    fi

    # Fix permissions before starting service
    mkdir -p "$MODELS_DIR"
    chown -R ollama:ollama "$MODELS_DIR"

    cat > /etc/systemd/system/ollama.service << EOF
[Unit]
Description=Ollama AI Server
After=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=${OLLAMA_HOST}:${OLLAMA_PORT}"
Environment="OLLAMA_MODELS=${MODELS_DIR}"
Environment="OLLAMA_NOPRUNE=1"
Environment="HOME=/usr/share/ollama"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ollama
    systemctl start ollama

    log_info "Waiting for Ollama to start..."
    for i in $(seq 1 30); do
        curl -s "http://localhost:${OLLAMA_PORT}/api/version" &>/dev/null && break
        sleep 2
    done
    log_ok "Ollama running"

    # ------------------------------------------------------------------
    # SOVEREIGNTY VERIFICATION TEST
    # This MUST pass. A passing result means "BLOCKED" not "BREACH".
    # If it prints BREACH the iptables rules are not in the right position.
    # ------------------------------------------------------------------
    log_info "Running sovereignty verification test..."
    sudo -u ollama curl -s --max-time 5 https://ollama.com > /dev/null 2>&1 \
    	&& SOVEREIGNTY_RESULT="BREACH" || SOVEREIGNTY_RESULT="BLOCKED"


    if [[ "$SOVEREIGNTY_RESULT" == "BLOCKED" ]]; then
        log_ok "SOVEREIGNTY VERIFIED -- Ollama cannot reach internet"
    else
        log_error "SOVEREIGNTY BREACH -- Ollama CAN reach internet"
        log_error "Check iptables rule positions: sudo sudo iptables -L OUTPUT --line-numbers"
        log_error "Rules must be at positions 1 and 2, before UFW chains"
        # Do not exit -- log the breach and continue so install completes
        # Operator must fix manually
        echo "SOVEREIGNTY_BREACH=true" >> /etc/sovereign/hw.conf
    fi

    mark_done "ollama"
    log_ok "Ollama stage complete"
}

# =============================================================================
# STAGE 5 -- MODELS
# Registers GGUF models with Ollama via Modelfile.
# nomic-embed-text registered via blob+manifest copy (no Modelfile needed).
# num_ctx values set explicitly -- never rely on model defaults.
#
# num_ctx rationale (tested on i5-4570 16GB RAM):
#   7B models: 16384 -- required for web search context injection
#   3B models: 8192  -- safe maximum for 16GB RAM
#   nomic-embed-text: 8192 -- default from upstream, retained
# =============================================================================
stage_models() {
    is_done "models" && { log_info "Models already installed, skipping"; return; }
    log_section "Stage 5 -- Models"

    source /etc/sovereign/hw.conf

    case "$HW_TIER" in
        A|B)   MODELS_TO_INSTALL=("$MODEL_PRIMARY" "$MODEL_SECONDARY") ;;
        C)     MODELS_TO_INSTALL=("$MODEL_PRIMARY" "$MODEL_SMALL") ;;
        D)     MODELS_TO_INSTALL=("$MODEL_SMALL") ;;
    esac

    chown -R ollama:ollama "$MODELS_DIR"
    chmod -R 755 "$MODELS_DIR"

for model in "${MODELS_TO_INSTALL[@]}"; do
        src="$USB_SOURCE/models/gguf/$model"
        dst="$MODELS_DIR/gguf/$model"
        if [[ -f "$dst" ]]; then
            log_info "Already on disk: $model"
        elif [[ -f "$src" ]]; then
            log_info "Copying $model..."
            cp "$src" "$dst"
            chown ollama:ollama "$dst"
            log_ok "Copied: $model"
        else
            log_warn "Not found in assets: $model"
        fi
    done

    for wm in ggml-base.bin ggml-medium.bin; do
        src="$USB_SOURCE/models/whisper/$wm"
        dst="$MODELS_DIR/whisper/$wm"
        [[ -f "$src" ]] && [[ ! -f "$dst" ]] && cp "$src" "$dst" && log_ok "Whisper: $wm"
    done

    for pf in en_US-lessac-medium.onnx en_US-lessac-medium.onnx.json; do
        src="$USB_SOURCE/models/piper/$pf"
        dst="$MODELS_DIR/piper/$pf"
        [[ -f "$src" ]] && [[ ! -f "$dst" ]] && cp "$src" "$dst" && log_ok "Piper: $pf"
    done

    chown -R ollama:ollama "$MODELS_DIR"

    # Register GGUF models with Ollama via Modelfile
    # num_ctx 16384 for 7B models, 8192 for 3B -- never use silent defaults
    for model in "${MODELS_TO_INSTALL[@]}"; do
        model_path="$MODELS_DIR/gguf/$model"
        model_name="${model%.*}"
        model_name="${model_name,,}"

        # Set num_ctx based on model size
        if echo "$model_name" | grep -qi "3b\|3B"; then
            NUM_CTX=8192
        else
            NUM_CTX=16384
        fi

        if [[ -f "$model_path" ]]; then
            log_info "Registering with Ollama: $model_name (num_ctx $NUM_CTX)"
            cat > /tmp/Modelfile << EOF
FROM $model_path
PARAMETER temperature 0.7
PARAMETER num_ctx $NUM_CTX
SYSTEM "You are a helpful AI assistant. Your responses are private and never leave this machine."
EOF
            ollama create "$model_name" -f /tmp/Modelfile 2>&1 | \
                tee -a "$LOG_FILE" || log_warn "Could not register $model_name"
            log_ok "Registered: $model_name (num_ctx $NUM_CTX)"
        fi
    done

    # ------------------------------------------------------------------
    # REGISTER nomic-embed-text via blob + manifest copy
    # This is the embedding model required for RAG and web search.
    # Do NOT use 'ollama pull' -- this is an airgap install.
    # Do NOT use a Modelfile -- the manifest already encodes all metadata.
    # Blob SHAs are fixed for nomic-embed-text:latest as of June 2026.
    # ------------------------------------------------------------------
    log_info "Registering nomic-embed-text embedding model..."

    NOMIC_BLOB_DIR="$USB_SOURCE/models/blobs"
    NOMIC_MANIFEST_SRC="$USB_SOURCE/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest"
    NOMIC_MANIFEST_DST="$MODELS_DIR/manifests/registry.ollama.ai/library/nomic-embed-text"

    NOMIC_BLOBS=(
        "sha256-970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6"
        "sha256-31df23ea7daa448f9ccdbbcecce6c14689c8552222b80defd3830707c0139d4f"
        "sha256-c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4"
        "sha256-ce4a164fc04605703b485251fe9f1a181688ba0eb6badb80cc6335c0de17ca0d"
    )

    # Check all source blobs are present before copying anything
    local nomic_ok=true
    for blob in "${NOMIC_BLOBS[@]}"; do
        if [[ ! -f "$NOMIC_BLOB_DIR/$blob" ]]; then
            log_warn "nomic blob missing from USB: $blob"
            nomic_ok=false
        fi
    done

    if [[ ! -f "$NOMIC_MANIFEST_SRC" ]]; then
        log_warn "nomic manifest missing from USB: $NOMIC_MANIFEST_SRC"
        nomic_ok=false
    fi

    if [[ "$nomic_ok" == "true" ]]; then
        # Copy blobs
        for blob in "${NOMIC_BLOBS[@]}"; do
            cp "$NOMIC_BLOB_DIR/$blob" "$MODELS_DIR/blobs/"
            chown ollama:ollama "$MODELS_DIR/blobs/$blob"
            log_ok "nomic blob: $blob"
        done

        # Copy manifest
        mkdir -p "$NOMIC_MANIFEST_DST"
        cp "$NOMIC_MANIFEST_SRC" "$NOMIC_MANIFEST_DST/latest"
        chown -R ollama:ollama "$NOMIC_MANIFEST_DST"
        log_ok "nomic manifest installed"

        # Verify Ollama can see it
        sleep 2
        if ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
            log_ok "nomic-embed-text registered and visible to Ollama"
        else
            log_warn "nomic-embed-text not visible in ollama list -- verify manually"
        fi
    else
        log_warn "nomic-embed-text skipped -- missing blobs or manifest on USB"
        log_warn "Web search embedding will not work without nomic-embed-text"
        log_warn "Add blobs to USB: sovereign/models/blobs/ and manifest to"
        log_warn "sovereign/models/manifests/registry.ollama.ai/library/nomic-embed-text/"
    fi

    mark_done "models"
    log_ok "Models stage complete"
}

# =============================================================================
# STAGE 6 -- OPEN WEBUI
# Path 1: venv.tar.gz on USB assets (true airgap -- machine 2+)
# Path 2: uv from USB + internet (first machine only)
#
# IMPORTANT: After Open WebUI starts, this stage patches the SQLite config DB
# to apply correct settings for CPU-only hardware. These settings cannot be
# set via environment variables in v0.9.6 and must be written to the DB.
# See patch_openwebui_config() for full rationale.
# =============================================================================
stage_openwebui() {
    is_done "openwebui" && { log_info "Open WebUI already installed, skipping"; return; }
    log_section "Stage 6 -- Open WebUI"

    source /etc/sovereign/hw.conf

    local venv_tarball="$USB_SOURCE/packages/venv.tar.gz"
    local uv_tarball="$USB_SOURCE/binaries/uv-x86_64-unknown-linux-gnu.tar.gz"
    local owui_wheel="$USB_SOURCE/packages/pip/open_webui-0.9.6-py3-none-any.whl"
    local uv_bin="/usr/local/bin/uv"

    # PATH 1 -- pre-built venv tarball (fully offline)
    if [[ -f "$venv_tarball" ]]; then
        log_info "venv.tar.gz found -- extracting (fully offline)"
        mkdir -p /opt/sovereign
        tar -xzf "$venv_tarball" -C /opt/sovereign 2>&1 | tee -a "$LOG_FILE"
        chown -R "$SOVEREIGN_USER:$SOVEREIGN_USER" /opt/sovereign
        log_ok "Venv extracted -- includes Open WebUI and ChromaDB"

    # PATH 2 -- internet required (first machine only)
    else
        log_warn "No venv.tar.gz found -- internet required for this install"

        log_info "Waiting for internet..."
        local waited=0
        until curl -s --max-time 5 https://pypi.org > /dev/null 2>&1; do
            [[ $waited -eq 0 ]] && echo "  Plug in ethernet cable -- checking every 30s..."
            waited=1
            sleep 30
        done
        log_ok "Internet connected"

        if [[ ! -f "$uv_bin" ]]; then
            if [[ -f "$uv_tarball" ]]; then
                log_info "Installing uv from USB assets..."
                mkdir -p /tmp/uv_extract
                tar -xzf "$uv_tarball" -C /tmp/uv_extract
                find /tmp/uv_extract -name "uv" -type f -exec install -m 755 {} "$uv_bin" \;
                log_ok "uv installed"
            else
                curl -LsSf https://astral.sh/uv/install.sh | \
                    env UV_INSTALL_DIR=/usr/local/bin sh 2>&1 | tee -a "$LOG_FILE"
            fi
        fi

        $uv_bin venv /opt/sovereign/venv --python 3.11 2>&1 | tee -a "$LOG_FILE"

        if [[ -f "$owui_wheel" ]]; then
            $uv_bin pip install --python /opt/sovereign/venv/bin/python \
                "$owui_wheel" 2>&1 | tee -a "$LOG_FILE"
        else
            $uv_bin pip install --python /opt/sovereign/venv/bin/python \
                open-webui 2>&1 | tee -a "$LOG_FILE"
        fi
        log_ok "Open WebUI installed"

        chown -R "$SOVEREIGN_USER:$SOVEREIGN_USER" /opt/sovereign

        # Save venv to USB assets for future machines
        log_info "Saving venv.tar.gz to USB assets for future offline installs..."
        if tar -czf /tmp/venv.tar.gz -C /opt/sovereign venv 2>&1 | tee -a "$LOG_FILE"; then
            cp /tmp/venv.tar.gz "$venv_tarball" 2>/dev/null && \
                log_ok "venv.tar.gz saved -- future installs will be fully offline" || \
                log_warn "Could not write venv.tar.gz back -- copy manually from /tmp/venv.tar.gz"
        fi
    fi

    WEBUI_SECRET=$(openssl rand -hex 32)

    # NOTE: ExecStart uses --port and --host CLI flags, NOT Environment PORT=
    # Open WebUI v0.9.6 ignores the PORT environment variable in systemd.
    # CLI flags are the only reliable way to set port and host. Verified in
    # live testing June 2026.
    cat > /etc/systemd/system/open-webui.service << EOF
[Unit]
Description=Sovereign Open WebUI
After=network-online.target ollama.service
Requires=ollama.service

[Service]
Type=simple
User=$SOVEREIGN_USER
WorkingDirectory=$DATA_DIR
ExecStart=/opt/sovereign/venv/bin/open-webui serve --port ${WEBUI_PORT} --host 0.0.0.0
Restart=always
RestartSec=5
Environment="HOST=0.0.0.0"
Environment="PORT=${WEBUI_PORT}"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:${OLLAMA_PORT}"
Environment="WEBUI_SECRET_KEY=${WEBUI_SECRET}"
Environment="WEBUI_NAME=Sovereign AI"
Environment="DATA_DIR=${DATA_DIR}/openwebui"
Environment="ENABLE_TELEMETRY=false"
Environment="ENABLE_UPDATE_CHECK=false"
Environment="DO_NOT_TRACK=true"
Environment="ENABLE_IMAGE_GENERATION=false"
Environment="ENABLE_COMMUNITY_SHARING=false"
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    chown -R "$SOVEREIGN_USER:$SOVEREIGN_USER" "$DATA_DIR"
    systemctl daemon-reload
    systemctl enable open-webui
    chown -R ${SOVEREIGN_USER}:${SOVEREIGN_USER} /opt/sovereign
    systemctl start open-webui


    log_info "Waiting for Open WebUI to start and initialise DB..."
    local webui_ready=false
    local db_path="${DATA_DIR}/openwebui/webui.db"
    for i in $(seq 1 90); do
        if curl -s "http://localhost:${WEBUI_PORT}" &>/dev/null && \
           [[ -f "$db_path" ]]; then
            webui_ready=true
            break
        fi
        sleep 3
    done
    if [[ "$webui_ready" == "true" ]]; then
        log_ok "Open WebUI running and DB initialised"
        # Extra 10s for DB to finish writing initial config rows
        sleep 10
        patch_openwebui_config
    else
        log_warn "Open WebUI did not respond or DB not found -- skipping config patch"
        log_warn "Run manually: python3 /opt/sovereign/usb-assets/config/patch_openwebui.py"
    fi


    mark_done "openwebui"
    log_ok "Open WebUI stage complete"
}

# =============================================================================
# patch_openwebui_config
# Patches the Open WebUI SQLite config DB for CPU-only hardware.
#
# WHY THIS IS NEEDED:
#   Open WebUI v0.9.6 stores runtime config in a JSON blob in SQLite.
#   Several settings cannot be set via environment variables and must be
#   written directly to the DB. The defaults are wrong for CPU-only hardware.
#
# WHAT IT FIXES:
#   1. RAG_EMBEDDING_MODEL -- default is blank or wrong model; must be
#      nomic-embed-text (the dedicated embedding model, not a chat LLM)
#   2. searxng_query_url -- must include /search suffix; without it
#      SearXNG returns HTML not JSON and web search silently fails
#   3. bypass_embedding_and_retrieval (web search) -- must be True
#      CPU embedding takes 30-40s per query; chat fires before embeddings
#      complete, causing "No sources found". Bypass injects SearXNG
#      snippets directly into context instead. Trade-off: no semantic
#      ranking, but all snippets are relevant at 3-result count.
#   4. bypass_web_loader -- must be True alongside bypass_embedding.
#      Without this, full pages are fetched (thousands of tokens) and
#      injected into context, overflowing the model's context window.
#      With it, only the SearXNG snippet (~50 tokens) is used per result.
#   5. enable_async_embedding -- True improves server responsiveness
#      during background embedding operations
#   6. result_count -- reduced to 3 (default 5 creates too much context)
#   7. chunk_size / chunk_overlap -- 4000/200 reduces chunk count for
#      knowledge base documents (fewer embedding calls per document)
#   8. enable_markdown_header_text_splitter -- False reduces chunk count
#
# VERIFIED: These settings produce working web search on i5-4570 16GB RAM
# with Qwen 2.5 7B Q4_K_M at num_ctx 16384. June 2026.
# =============================================================================
patch_openwebui_config() {
    log_info "Patching Open WebUI config DB for CPU-only hardware..."

    local db_path="${DATA_DIR}/openwebui/webui.db"

    if [[ ! -f "$db_path" ]]; then
        log_warn "webui.db not found at $db_path -- skipping config patch"
        log_warn "Open WebUI may not have initialised yet"
        return
    fi

    python3 << PYEOF
import sqlite3, json, sys

db_path = "${db_path}"
try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("SELECT id, data FROM config WHERE id = 1")
    row = cur.fetchone()
    if not row:
        print("ERROR: config table empty -- Open WebUI has not initialised")
        sys.exit(1)

    config_id, data_json = row
    data = json.loads(data_json)

    # Fix 1: embedding model must be nomic-embed-text not a chat model
    data['RAG_EMBEDDING_MODEL'] = 'nomic-embed-text'

    # Fix 2: SearXNG URL must include /search suffix
    data['rag']['web']['search']['searxng_query_url'] = \
        'http://localhost:${SEARXNG_PORT}/search'

    # Fix 3 + 4: bypass embedding and web loader for CPU-only hardware
    data['rag']['web']['search']['bypass_embedding_and_retrieval'] = True
    data['rag']['web']['search']['bypass_web_loader'] = True

    # Fix 5: async embedding
    data['rag']['enable_async_embedding'] = True

    # Fix 6: fewer results = less context injection
    data['rag']['web']['search']['result_count'] = 3

    # Fix 7: larger chunks = fewer embedding calls for knowledge base docs
    data['rag']['chunk_size'] = 4000
    data['rag']['chunk_overlap'] = 200

    # Fix 8: fewer chunks from markdown documents
    data['rag']['enable_markdown_header_text_splitter'] = False

    # Fix 9: make sure embedding engine points to Ollama
    data['rag']['embedding_engine'] = 'ollama'
    data['rag']['embedding_model'] = 'nomic-embed-text'

    cur.execute(
        "UPDATE config SET data = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        (json.dumps(data), config_id)
    )
    conn.commit()
    conn.close()
    print("Config patched successfully")

except Exception as e:
    print(f"ERROR patching config: {e}")
    sys.exit(1)
PYEOF

    if [[ $? -eq 0 ]]; then
        log_ok "Open WebUI config patched"
        # Restart to pick up new config
        systemctl restart open-webui
        log_info "Open WebUI restarted with patched config"
    else
        log_warn "Config patch failed -- web search may not work correctly"
        log_warn "Run patch manually: see INSTALL_NOTES.md"
    fi
}

# =============================================================================
# STAGE 7 -- CHROMADB
# =============================================================================
stage_chromadb() {
    is_done "chromadb" && { log_info "ChromaDB already installed, skipping"; return; }
    log_section "Stage 7 -- ChromaDB"

    if /opt/sovereign/venv/bin/pip show chromadb &>/dev/null; then
        log_ok "ChromaDB already present in venv"
    else
        log_info "Installing ChromaDB..."
        /opt/sovereign/venv/bin/pip install chromadb 2>&1 | tee -a "$LOG_FILE" || \
            log_warn "ChromaDB install failed -- RAG unavailable"
    fi

    cat > /etc/systemd/system/chromadb.service << EOF
[Unit]
Description=Sovereign ChromaDB
After=network-online.target

[Service]
Type=simple
User=$SOVEREIGN_USER
ExecStart=/opt/sovereign/venv/bin/chroma run \
    --host 127.0.0.1 \
    --port 8000 \
    --path ${DATA_DIR}/chromadb
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable chromadb
    systemctl start chromadb
    sleep 5

    if curl -s http://localhost:8000/api/v2/heartbeat &>/dev/null; then
        log_ok "ChromaDB running on localhost:8000"
    else
        log_warn "ChromaDB did not respond -- check: journalctl -u chromadb"
    fi

    mark_done "chromadb"
    log_ok "ChromaDB stage complete"
}

# =============================================================================
# STAGE 8 -- LAN DISCOVERY
# =============================================================================
stage_lan() {
    is_done "lan" && { log_info "LAN already configured, skipping"; return; }
    log_section "Stage 8 -- LAN Discovery"

    systemctl enable avahi-daemon
    systemctl start avahi-daemon

    LAN_IP=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname)

    cat > /etc/sovereign/access_info.txt << EOF

============================================================
  SOVEREIGN AI -- ACCESS INFORMATION
============================================================

  Open WebUI (AI chat):
    https://${LAN_IP}              (accept certificate warning)
    http://${HOSTNAME}.local:${WEBUI_PORT}

  n8n (automation):
    http://${LAN_IP}:${N8N_PORT}

  SearXNG (search):
    http://${LAN_IP}:${SEARXNG_PORT}

  Ollama API:
    http://${LAN_IP}:${OLLAMA_PORT}

  Sovereignty check:
    sudo sudo iptables -L OUTPUT --line-numbers | head -10
    sudo -u ollama curl -s --max-time 5 https://ollama.com && echo BREACH || echo BLOCKED

  Install log:
    ${LOG_FILE}

============================================================
EOF

    cat > /etc/profile.d/sovereign.sh << 'EOF'
cat /etc/sovereign/access_info.txt 2>/dev/null || true
EOF
    chmod +x /etc/profile.d/sovereign.sh

    mark_done "lan"
    log_ok "LAN discovery configured"
}

# =============================================================================
# STAGE 9 -- VERIFY CORE STACK
# =============================================================================
stage_verify() {
    log_section "Stage 9 -- Verification"

    local all_ok=true

    for svc in ollama open-webui chromadb avahi-daemon; do
        if systemctl is-active --quiet "$svc"; then
            log_ok "Running: $svc"
        else
            log_warn "Not running: $svc"
            all_ok=false
        fi
    done

    log_info "Registered models:"
    ollama list 2>/dev/null | tee -a "$LOG_FILE" || true

    # Verify nomic-embed-text specifically
    if ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
        log_ok "nomic-embed-text present"
    else
        log_warn "nomic-embed-text not found -- web search embedding will fail"
    fi

    if curl -s --max-time 5 "http://localhost:${WEBUI_PORT}" &>/dev/null || \
       curl -sk --max-time 5 "https://localhost" &>/dev/null; then
        log_ok "Open WebUI responding"
    else
        log_warn "Open WebUI not responding -- check: journalctl -u open-webui -f"
    fi

    # Sovereignty check -- rules must be at positions 1 and 2
    log_info "Final sovereignty verification..."
    SOVEREIGNTY_RESULT=$(sudo -u ollama curl -s --max-time 5 \
        https://ollama.com && echo "BREACH" || echo "BLOCKED")

    if [[ "$SOVEREIGNTY_RESULT" == "BLOCKED" ]]; then
        log_ok "SOVEREIGNTY VERIFIED -- Ollama cannot reach internet"
    else
        log_error "SOVEREIGNTY BREACH DETECTED"
        log_error "Ollama CAN reach the internet -- iptables rules not working"
        log_error "Check: sudo sudo iptables -L OUTPUT --line-numbers"
        log_error "Rules for uid $(id -u ollama) must appear at positions 1 and 2"
        all_ok=false
    fi

    if [[ "$all_ok" == "true" ]]; then
        log_ok "All verification checks passed"
    else
        log_warn "Some checks failed -- review warnings above"
    fi

    echo "CORE_INSTALL_COMPLETE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /etc/sovereign/hw.conf
}

# =============================================================================
# STAGE 10 -- n8n WORKFLOW AUTOMATION (optional)
# NOTE: NodeSource apt signing key requires internet. n8n is NOT fully
# airgappable in this version. This is a known limitation.
# =============================================================================
stage_n8n() {
    [[ "$INSTALL_N8N" != "true" ]] && { log_info "n8n disabled -- skipping"; return; }
    is_done "n8n" && { log_info "n8n already installed, skipping"; return; }
    log_section "Stage 10 -- n8n Workflow Automation"

    local node_setup="$USB_SOURCE/packages/deb/nodesource_setup_22.x.sh"
    local n8n_tgz="$USB_SOURCE/packages/npm/n8n-2.23.4.tgz"
    local pm2_tgz="$USB_SOURCE/packages/npm/pm2-5.4.3.tgz"

    # Install Node.js 22
    if ! command -v node &>/dev/null || \
       [[ $(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v') -lt 20 ]]; then
        log_info "Installing Node.js 22 LTS..."
        if [[ -f "$node_setup" ]]; then
            if bash "$node_setup" 2>&1 | tee -a "$LOG_FILE"; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs \
                    2>&1 | tee -a "$LOG_FILE"
                log_ok "Node.js $(node -v) installed via NodeSource"
            else
                log_warn "NodeSource setup failed -- trying direct download..."
                local node_url="https://nodejs.org/dist/v22.15.0/node-v22.15.0-linux-x64.tar.xz"
                curl -fsSL "$node_url" | tar -xJ -C /usr/local --strip-components=1 \
                    2>&1 | tee -a "$LOG_FILE" && log_ok "Node.js installed from tarball"
            fi
        else
            log_info "No NodeSource script on USB -- downloading Node.js..."
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | tee -a "$LOG_FILE"
            DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs \
                2>&1 | tee -a "$LOG_FILE"
        fi
        log_ok "Node.js $(node -v) installed"
    else
        log_ok "Node.js $(node -v) already present"
    fi

    # Install n8n and PM2
    if command -v n8n &>/dev/null; then
        log_ok "n8n $(n8n --version) already installed"
    else
        log_info "Installing n8n and PM2..."
        if [[ -f "$n8n_tgz" ]] && [[ -f "$pm2_tgz" ]]; then
            npm install -g "$n8n_tgz" "$pm2_tgz" 2>&1 | tee -a "$LOG_FILE"
        else
            npm install -g n8n pm2 2>&1 | tee -a "$LOG_FILE"
        fi
        log_ok "n8n and PM2 installed"
    fi

    mkdir -p /opt/n8n
    chown "$SOVEREIGN_USER:$SOVEREIGN_USER" /opt/n8n

    cat > /opt/n8n/ecosystem.config.js << EOF
module.exports = {
  apps: [{
    name: 'n8n',
    script: 'n8n',
    interpreter: 'none',
    env: {
      N8N_USER_FOLDER: '/opt/n8n',
      N8N_PORT: '${N8N_PORT}',
      N8N_HOST: '0.0.0.0',
      N8N_SECURE_COOKIE: 'false',
      N8N_PROTOCOL: 'http',
      N8N_DIAGNOSTICS_ENABLED: 'false',
      N8N_VERSION_NOTIFICATIONS_ENABLED: 'false',
      N8N_TEMPLATES_ENABLED: 'false',
      N8N_HIDE_USAGE_PAGE: 'true',
      EXECUTIONS_DATA_PRUNE: 'true',
      EXECUTIONS_DATA_MAX_AGE: '336'
    }
  }]
}
EOF
    chown "$SOVEREIGN_USER:$SOVEREIGN_USER" /opt/n8n/ecosystem.config.js

    if sudo -u "$SOVEREIGN_USER" pm2 list 2>/dev/null | grep -q "n8n"; then
        sudo -u "$SOVEREIGN_USER" pm2 restart /opt/n8n/ecosystem.config.js \
            2>&1 | tee -a "$LOG_FILE" || true
    else
        sudo -u "$SOVEREIGN_USER" pm2 start /opt/n8n/ecosystem.config.js \
            2>&1 | tee -a "$LOG_FILE" || true
    fi
    sudo -u "$SOVEREIGN_USER" pm2 save 2>&1 | tee -a "$LOG_FILE" || true

    PM2_STARTUP=$(sudo -u "$SOVEREIGN_USER" pm2 startup systemd \
        -u "$SOVEREIGN_USER" --hp "/home/$SOVEREIGN_USER" 2>&1 | grep "sudo env" || true)
    if [[ -n "$PM2_STARTUP" ]]; then
        eval "$PM2_STARTUP" 2>&1 | tee -a "$LOG_FILE" || true
        log_ok "PM2 startup hook registered"
    else
        log_info "PM2 startup already registered"
    fi

    sleep 8
    if curl -s "http://localhost:${N8N_PORT}" &>/dev/null; then
        log_ok "n8n running on port $N8N_PORT"
    else
        log_warn "n8n did not respond -- check: pm2 logs n8n"
    fi

    mark_done "n8n"
    log_ok "n8n stage complete"
}

# =============================================================================
# STAGE 11 -- SEARXNG LOCAL WEB SEARCH (optional)
# =============================================================================
stage_searxng() {
    [[ "$INSTALL_SEARXNG" != "true" ]] && { log_info "SearXNG disabled -- skipping"; return; }
    is_done "searxng" && { log_info "SearXNG already installed, skipping"; return; }
    log_section "Stage 11 -- SearXNG Local Web Search"

    local searxng_zip="$USB_SOURCE/packages/searxng/searxng-master.zip"

    id searxng &>/dev/null || \
        useradd --shell /bin/bash --system \
            --home-dir "/usr/local/searxng" \
            --comment 'SearXNG metasearch engine' searxng

    mkdir -p /usr/local/searxng
    chown -R searxng:searxng /usr/local/searxng

    if [[ -d "/usr/local/searxng/searxng-src" ]]; then
        log_ok "SearXNG source already present"
    elif [[ -f "$searxng_zip" ]]; then
        log_info "Installing SearXNG from USB assets..."
        unzip -q "$searxng_zip" -d /tmp/searxng_src 2>&1 | tee -a "$LOG_FILE"
        mv /tmp/searxng_src/searxng-master /usr/local/searxng/searxng-src
        chown -R searxng:searxng /usr/local/searxng/searxng-src
        log_ok "SearXNG source installed"
    else
        log_info "Cloning SearXNG from GitHub..."
        sudo -u searxng git clone https://github.com/searxng/searxng \
            /usr/local/searxng/searxng-src 2>&1 | tee -a "$LOG_FILE"
    fi

    if [[ -f "/usr/local/searxng/searx-pyenv/bin/python" ]]; then
        log_ok "SearXNG venv already present"
    else
        log_info "Building Python 3.11 venv for SearXNG..."
        sudo -u searxng bash -c "
            python3.11 -m venv /usr/local/searxng/searx-pyenv
            source /usr/local/searxng/searx-pyenv/bin/activate
            pip install -U pip setuptools wheel pyyaml msgspec typing_extensions
            pip install --use-pep517 --no-build-isolation \
                -e /usr/local/searxng/searxng-src
        " 2>&1 | tee -a "$LOG_FILE"
        log_ok "SearXNG Python environment built"
    fi

    mkdir -p /etc/searxng
    cp /usr/local/searxng/searxng-src/utils/templates/etc/searxng/settings.yml \
        /etc/searxng/settings.yml

    SECRET=$(openssl rand -hex 32)
    sed -i "s/ultrasecretkey/$SECRET/g" /etc/searxng/settings.yml
    sed -i 's/instance_name: "SearXNG"/instance_name: "Sovereign Search"/g' \
        /etc/searxng/settings.yml
    sed -i 's/  formats:/  formats:\n    - json/' /etc/searxng/settings.yml
    sed -i 's/  limiter: true/  limiter: false/' /etc/searxng/settings.yml
    sed -i '/  image_proxy: true/a\  bind_address: "0.0.0.0"\n  port: '"$SEARXNG_PORT" \
        /etc/searxng/settings.yml
    sed -i 's|  url: valkey://localhost:6379/0|  url: ""|' /etc/searxng/settings.yml

    chown -R searxng:searxng /etc/searxng

    cat > /etc/systemd/system/searxng.service << EOF
[Unit]
Description=Sovereign SearXNG
After=network-online.target

[Service]
Type=simple
User=searxng
Group=searxng
WorkingDirectory=/usr/local/searxng/searxng-src
Environment=SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml
ExecStart=/usr/local/searxng/searx-pyenv/bin/python -m searx.webapp
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable searxng
    systemctl start searxng
    sleep 8

    if curl -s "http://localhost:${SEARXNG_PORT}/search?q=test&format=json" \
        &>/dev/null; then
        log_ok "SearXNG running on port $SEARXNG_PORT"
    else
        log_warn "SearXNG did not respond -- check: journalctl -u searxng"
    fi

    mark_done "searxng"
    log_ok "SearXNG stage complete"
}

# =============================================================================
# STAGE 12 -- NGINX HTTPS
# =============================================================================
stage_https() {
    [[ "$INSTALL_HTTPS" != "true" ]] && { log_info "HTTPS disabled -- skipping"; return; }
    is_done "https" && { log_info "HTTPS already configured, skipping"; return; }
    log_section "Stage 12 -- nginx HTTPS"

    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx 2>&1 | tee -a "$LOG_FILE"

    LAN_IP=$(hostname -I | awk '{print $1}')

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/ssl/private/sovereign.key \
        -out /etc/ssl/certs/sovereign.crt \
        -subj "/C=GB/ST=Local/L=Local/O=SovereignAI/CN=${LAN_IP}" \
        2>&1 | tee -a "$LOG_FILE"

    cat > /etc/nginx/sites-available/sovereign << EOF
server {
    listen 80;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    ssl_certificate     /etc/ssl/certs/sovereign.crt;
    ssl_certificate_key /etc/ssl/private/sovereign.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 100M;

    location / {
        proxy_pass         http://127.0.0.1:${WEBUI_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}
EOF

    ln -sf /etc/nginx/sites-available/sovereign /etc/nginx/sites-enabled/sovereign
    rm -f /etc/nginx/sites-enabled/default

    nginx -t 2>&1 | tee -a "$LOG_FILE"
    systemctl enable nginx
    systemctl restart nginx
    log_ok "nginx HTTPS configured -- access at https://${LAN_IP}"

    # Update access info with HTTPS URL
    sed -i "s|http://${LAN_IP}:${WEBUI_PORT}|https://${LAN_IP}|g" \
        /etc/sovereign/access_info.txt 2>/dev/null || true

    mark_done "https"
    log_ok "HTTPS stage complete"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    mkdir -p "$(dirname $LOG_FILE)"
    touch "$LOG_FILE"

    [[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash install.sh"; exit 1; }

    clear
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  +--------------------------------------------------+"
    echo "  |        SOVEREIGN OS v2.2 -- INSTALLING           |"
    echo "  |   Sovereign AI for Developing Economies          |"
    echo "  +--------------------------------------------------+"
    echo -e "${RESET}"
    echo ""
    echo -e "  n8n:     ${INSTALL_N8N}"
    echo -e "  SearXNG: ${INSTALL_SEARXNG}"
    echo -e "  HTTPS:   ${INSTALL_HTTPS}"
    echo ""
    log_info "Started: $(date)"
    log_info "Log: $LOG_FILE"
    echo ""

    # Stage 0a must run first -- sets USB_SOURCE for all subsequent stages
    stage_usb_copy

    stage_preflight
    stage_packages
    stage_security
    stage_disk
    stage_ollama
    stage_models
    stage_openwebui
    stage_chromadb
    stage_lan
    stage_verify

    stage_n8n
    stage_searxng
    stage_https

    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  +--------------------------------------------------+"
    echo "  |   SOVEREIGN OS v2.2 INSTALLED SUCCESSFULLY       |"
    echo "  +--------------------------------------------------+"
    echo -e "${RESET}"
    cat /etc/sovereign/access_info.txt
}

main "$@"
