#!/bin/bash
# =============================================================
# demo_access.sh — Sovereign AI Demo Access
# Part of: Sovereign OS / AI in a Box project
# Author: thedxjournal.com
#
# PURPOSE: Temporarily expose Open WebUI to a remote demo
#          audience via Tailscale (preferred) or Cloudflare
#          Tunnel (fallback). This is DEMO SCAFFOLDING only.
#          Intelligence runs locally. No data leaves the device.
#
# USAGE:
#   ./demo_access.sh tailscale     — install + start Tailscale
#   ./demo_access.sh status        — show current access info
#   ./demo_access.sh cloudflare    — start Cloudflare tunnel
#   ./demo_access.sh stop          — tear down all tunnels
#   ./demo_access.sh verify        — confirm sovereignty intact
#
# SOVEREIGNTY NOTE:
#   Tailscale relay servers are US-based. Cloudflare infra
#   is US-based. Both are DEMO-ONLY exceptions. The AI models,
#   data, and inference remain entirely on this machine.
#   Never use these tunnels in production deployments.
# =============================================================

set -e

WEBUI_PORT=8080
SEARXNG_PORT=8888
LOG_FILE="/var/log/demo_access.log"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CLOUDFLARE_PID_FILE="/tmp/cloudflared_demo.pid"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

banner() {
    echo ""
    echo -e "${BLUE}${BOLD}================================================${NC}"
    echo -e "${BLUE}${BOLD}  Sovereign AI — Demo Access Manager${NC}"
    echo -e "${BLUE}${BOLD}================================================${NC}"
    echo -e "${YELLOW}  ⚠  DEMO MODE: Tunnels are temporary scaffolding${NC}"
    echo -e "${YELLOW}  ✓  AI inference stays on this machine${NC}"
    echo ""
}

check_webui_running() {
    if ! ss -tlnp | grep -q ":${WEBUI_PORT}"; then
        echo -e "${RED}✗ Open WebUI not detected on port ${WEBUI_PORT}${NC}"
        echo "  Start it first: sudo systemctl start open-webui"
        exit 1
    fi
    echo -e "${GREEN}✓ Open WebUI running on port ${WEBUI_PORT}${NC}"
}

# -------------------------------------------------------
# TAILSCALE — preferred demo method
# -------------------------------------------------------
install_tailscale() {
    banner
    echo -e "${BOLD}Setting up Tailscale...${NC}"
    echo ""

    # Check if already installed
    if command -v tailscale &>/dev/null; then
        echo -e "${GREEN}✓ Tailscale already installed${NC}"
    else
        echo "Installing Tailscale (requires internet for this step only)..."
        curl -fsSL https://tailscale.com/install.sh | sh
        log "Tailscale installed"
    fi

    # Check if already connected
    TS_STATUS=$(tailscale status 2>/dev/null | head -1 || echo "not connected")
    if echo "$TS_STATUS" | grep -q "^[0-9]"; then
        echo -e "${GREEN}✓ Tailscale already connected${NC}"
    else
        echo ""
        echo "Connecting to Tailscale network..."
        echo -e "${YELLOW}→ A browser URL will appear below. Open it to authenticate.${NC}"
        echo ""
        sudo tailscale up
        log "Tailscale connected"
    fi

    echo ""
    echo -e "${BOLD}Your Tailscale IP:${NC}"
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unavailable")
    echo -e "${GREEN}  ${TS_IP}${NC}"
    echo ""
    echo -e "${BOLD}Share these links with your demo audience:${NC}"
    echo -e "  Open WebUI:  ${GREEN}http://${TS_IP}:${WEBUI_PORT}${NC}"
    echo -e "  SearXNG:     ${GREEN}http://${TS_IP}:${SEARXNG_PORT}${NC}"
    echo ""
    echo -e "${YELLOW}Audience must have Tailscale installed and be added to your network.${NC}"
    echo -e "Manage access at: https://login.tailscale.com/admin/machines"
    echo ""
    log "Tailscale demo access started. IP: ${TS_IP}"
}

# -------------------------------------------------------
# CLOUDFLARE TUNNEL — fallback, no audience install needed
# -------------------------------------------------------
start_cloudflare() {
    banner
    echo -e "${BOLD}Starting Cloudflare Tunnel (no-account mode)...${NC}"
    echo -e "${YELLOW}⚠  Traffic transits Cloudflare US infrastructure${NC}"
    echo -e "${YELLOW}   Use only for demos. Tear down immediately after.${NC}"
    echo ""

    check_webui_running

    # Install cloudflared if missing
    if [ ! -f "$CLOUDFLARED_BIN" ]; then
        echo "Downloading cloudflared..."
        ARCH=$(uname -m)
        if [ "$ARCH" = "x86_64" ]; then
            CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
        elif [ "$ARCH" = "aarch64" ]; then
            CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
        else
            echo -e "${RED}Unsupported architecture: ${ARCH}${NC}"
            exit 1
        fi
        sudo curl -fsSL "$CF_URL" -o "$CLOUDFLARED_BIN"
        sudo chmod +x "$CLOUDFLARED_BIN"
        log "cloudflared downloaded"
    fi

    # Kill any existing tunnel
    if [ -f "$CLOUDFLARE_PID_FILE" ]; then
        OLD_PID=$(cat "$CLOUDFLARE_PID_FILE")
        kill "$OLD_PID" 2>/dev/null && echo "Stopped previous tunnel (PID ${OLD_PID})"
        rm -f "$CLOUDFLARE_PID_FILE"
    fi

    echo "Starting tunnel to localhost:${WEBUI_PORT}..."
    echo -e "${YELLOW}Your public demo URL will appear below in ~5 seconds:${NC}"
    echo ""

    # Run in background, capture output to temp file
    TUNNEL_LOG=$(mktemp /tmp/cloudflare_tunnel.XXXXXX)
    nohup "$CLOUDFLARED_BIN" tunnel --url "http://localhost:${WEBUI_PORT}" \
        > "$TUNNEL_LOG" 2>&1 &
    CF_PID=$!
    echo "$CF_PID" > "$CLOUDFLARE_PID_FILE"

    # Wait for URL to appear
    ATTEMPTS=0
    while [ $ATTEMPTS -lt 20 ]; do
        CF_URL=$(grep -oP 'https://[a-z0-9\-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1)
        if [ -n "$CF_URL" ]; then
            break
        fi
        sleep 1
        ATTEMPTS=$((ATTEMPTS + 1))
    done

    if [ -z "$CF_URL" ]; then
        echo -e "${RED}Tunnel URL not detected after 20s. Check ${TUNNEL_LOG}${NC}"
        exit 1
    fi

    echo -e "${GREEN}${BOLD}Demo URL: ${CF_URL}${NC}"
    echo ""
    echo "Share this link with anyone — no install needed on their end."
    echo -e "${YELLOW}Tunnel runs until you call: ./demo_access.sh stop${NC}"
    echo ""
    log "Cloudflare tunnel started. URL: ${CF_URL} PID: ${CF_PID}"
}

# -------------------------------------------------------
# STATUS — show what's currently running
# -------------------------------------------------------
show_status() {
    banner
    echo -e "${BOLD}Current access status:${NC}"
    echo ""

    # WebUI
    if ss -tlnp | grep -q ":${WEBUI_PORT}"; then
        echo -e "  Open WebUI    ${GREEN}● running${NC} (port ${WEBUI_PORT})"
    else
        echo -e "  Open WebUI    ${RED}○ not running${NC}"
    fi

    # SearXNG
    if ss -tlnp | grep -q ":${SEARXNG_PORT}"; then
        echo -e "  SearXNG       ${GREEN}● running${NC} (port ${SEARXNG_PORT})"
    else
        echo -e "  SearXNG       ${RED}○ not running${NC}"
    fi

    # Ollama
    if ss -tlnp | grep -q ":11434"; then
        echo -e "  Ollama        ${GREEN}● running${NC} (port 11434)"
    else
        echo -e "  Ollama        ${RED}○ not running${NC}"
    fi

    echo ""

    # Tailscale
    if command -v tailscale &>/dev/null; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
        if echo "$TS_IP" | grep -q "^100\."; then
            echo -e "  Tailscale     ${GREEN}● connected${NC} — IP: ${TS_IP}"
            echo -e "  WebUI via TS  ${GREEN}http://${TS_IP}:${WEBUI_PORT}${NC}"
        else
            echo -e "  Tailscale     ${YELLOW}○ installed but not connected${NC}"
        fi
    else
        echo -e "  Tailscale     ${RED}○ not installed${NC}"
    fi

    # Cloudflare tunnel
    if [ -f "$CLOUDFLARE_PID_FILE" ]; then
        CF_PID=$(cat "$CLOUDFLARE_PID_FILE")
        if kill -0 "$CF_PID" 2>/dev/null; then
            echo -e "  CF Tunnel     ${GREEN}● running${NC} (PID ${CF_PID})"
        else
            echo -e "  CF Tunnel     ${RED}○ PID stale — tunnel stopped${NC}"
            rm -f "$CLOUDFLARE_PID_FILE"
        fi
    else
        echo -e "  CF Tunnel     ${YELLOW}○ not running${NC}"
    fi

    echo ""
}

# -------------------------------------------------------
# STOP — tear everything down
# -------------------------------------------------------
stop_all() {
    banner
    echo -e "${BOLD}Stopping all demo tunnels...${NC}"
    echo ""

    # Cloudflare
    if [ -f "$CLOUDFLARE_PID_FILE" ]; then
        CF_PID=$(cat "$CLOUDFLARE_PID_FILE")
        if kill "$CF_PID" 2>/dev/null; then
            echo -e "  ${GREEN}✓ Cloudflare tunnel stopped (PID ${CF_PID})${NC}"
            log "Cloudflare tunnel stopped"
        fi
        rm -f "$CLOUDFLARE_PID_FILE"
    else
        echo -e "  ${YELLOW}  No Cloudflare tunnel running${NC}"
    fi

    # Tailscale disconnect (optional — ask user)
    if command -v tailscale &>/dev/null; then
        echo ""
        read -rp "  Disconnect Tailscale too? (y/N): " TS_STOP
        if [[ "$TS_STOP" =~ ^[Yy]$ ]]; then
            sudo tailscale down
            echo -e "  ${GREEN}✓ Tailscale disconnected${NC}"
            log "Tailscale disconnected"
        else
            echo -e "  ${YELLOW}  Tailscale left running${NC}"
        fi
    fi

    echo ""
    echo -e "${GREEN}✓ Demo access closed.${NC}"
    echo ""
}

# -------------------------------------------------------
# VERIFY — confirm sovereignty is intact post-tunnel
# -------------------------------------------------------
verify_sovereignty() {
    banner
    echo -e "${BOLD}Running sovereignty verification...${NC}"
    echo ""

    # Test ollama UID block
    echo -n "  Ollama outbound block: "
    RESULT=$(sudo -u ollama curl -s --max-time 5 https://ollama.com 2>/dev/null && echo "BREACH" || echo "BLOCKED")
    if [ "$RESULT" = "BLOCKED" ]; then
        echo -e "${GREEN}✓ BLOCKED${NC}"
    else
        echo -e "${RED}✗ BREACH — iptables rules need fixing!${NC}"
        echo ""
        echo -e "${RED}  Run: sudo iptables -I OUTPUT 1 -m owner --uid-owner \$(id -u ollama) -j DROP${NC}"
        log "SOVEREIGNTY BREACH DETECTED"
        exit 1
    fi

    # Check iptables rule positions
    echo -n "  iptables rule order: "
    RULE_1=$(sudo iptables -L OUTPUT --line-numbers -n 2>/dev/null | grep "ollama\|$(id -u ollama 2>/dev/null)" | head -1 | awk '{print $1}')
    if [ "$RULE_1" = "1" ] || [ "$RULE_1" = "2" ]; then
        echo -e "${GREEN}✓ Rules at positions 1/2 (before UFW chains)${NC}"
    else
        echo -e "${YELLOW}⚠ Rule position unclear — verify manually${NC}"
        echo "    sudo iptables -L OUTPUT --line-numbers -n"
    fi

    # DNS check
    echo -n "  DNS resolution (expected): "
    if host google.com &>/dev/null; then
        echo -e "${GREEN}✓ Working (system has internet — expected)${NC}"
    else
        echo -e "${YELLOW}  No internet (fully air-gapped mode)${NC}"
    fi

    echo ""
    echo -e "${GREEN}✓ Sovereignty check complete.${NC}"
    echo -e "${YELLOW}  Reminder: tunnels are demo scaffolding only.${NC}"
    echo -e "${YELLOW}  Tear down after demo: ./demo_access.sh stop${NC}"
    echo ""
    log "Sovereignty verification passed"
}

# -------------------------------------------------------
# ENTRYPOINT
# -------------------------------------------------------
case "${1:-help}" in
    tailscale)
        install_tailscale
        ;;
    cloudflare)
        start_cloudflare
        ;;
    status)
        show_status
        ;;
    stop)
        stop_all
        ;;
    verify)
        verify_sovereignty
        ;;
    *)
        banner
        echo "Usage:"
        echo "  ./demo_access.sh tailscale    Install + connect Tailscale"
        echo "  ./demo_access.sh cloudflare   Start Cloudflare public tunnel"
        echo "  ./demo_access.sh status       Show what's running"
        echo "  ./demo_access.sh stop         Tear down all tunnels"
        echo "  ./demo_access.sh verify       Confirm sovereignty intact"
        echo ""
        echo "Recommended demo flow:"
        echo "  1. ./demo_access.sh tailscale"
        echo "  2. ./demo_access.sh verify"
        echo "  3. Share the Tailscale IP with your audience"
        echo "  4. ./demo_access.sh stop  (when done)"
        echo ""
        ;;
esac
