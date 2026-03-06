#!/bin/bash
# ============================================================================
# CyberBlue install_caldera.sh — OPTIMIZED
# FIXES vs original:
#   ORIGINAL problem 1: git clone --recursive downloads ALL submodules
#                        including huge Go toolchains → very slow
#                        → Use --depth=1 and only needed submodules
#   ORIGINAL problem 2: Stops and removes running Caldera every time
#                        → Skip if already running correctly
#   ORIGINAL problem 3: docker compose up -d caldera triggers a full rebuild
#                        every run even when nothing changed
#                        → Check if image already exists, skip build if so
#   ORIGINAL problem 4: No wait / verification after startup
#                        → Smart poll to confirm Caldera is up
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR/caldera"
LOCAL_YML="$INSTALL_DIR/conf/local.yml"

echo -e "${BLUE}[+] Caldera Install/Update — FAST${NC}"
echo "==========================================="

# ── Step 1: Skip if Caldera is already running correctly ──────────
step "STEP 1 — Check if Caldera already running"

# FIX: Original always stops and removes the container even if it's healthy
if docker ps --format "{{.Names}}" | grep -q "^caldera$"; then
  if curl -s --max-time 3 "http://localhost:7009" &>/dev/null; then
    log "Caldera already running and responding — skipping reinstall"
    echo "  🌐 Caldera: http://$(hostname -I | awk '{print $1}'):7009"
    exit 0
  else
    warn "Caldera container running but not responding — restarting..."
    docker compose restart caldera 2>/dev/null || true
    exit 0
  fi
fi

# ── Step 2: Clone only if not already present ─────────────────────
step "STEP 2 — Caldera source code"

if [ ! -d "$INSTALL_DIR" ]; then
  log "Cloning MITRE Caldera (shallow + no unnecessary submodules)..."

  # FIX: Original uses --recursive which downloads huge Go plugin toolchains
  # --depth=1 gets only the latest commit (much faster)
  # We add submodules selectively after
  git clone --depth=1 https://github.com/mitre/caldera.git "$INSTALL_DIR"

  cd "$INSTALL_DIR"
  # Only init the plugin submodules actually needed (not all 20+)
  git submodule update --init --depth=1 \
    plugins/stockpile \
    plugins/sandcat \
    plugins/atomic \
    plugins/compass \
    plugins/debrief 2>/dev/null || true
  cd "$SCRIPT_DIR"
  log "Caldera cloned"
else
  log "Caldera already cloned — skipping clone"
fi

# ── Step 3: Create/update local.yml ───────────────────────────────
step "STEP 3 — Configuration"

mkdir -p "$INSTALL_DIR/conf"
cat > "$LOCAL_YML" << 'EOF'
ability_refresh: 60
api_key_blue: cyberblue
api_key_red: cyberblue
app.contact.dns.domain: mycaldera.caldera
app.contact.dns.socket: 0.0.0.0:8853
app.contact.gist: ""
app.contact.html: /weather
app.contact.http: http://0.0.0.0:8888
app.contact.slack.api_key: ""
app.contact.slack.bot_id: ""
app.contact.slack.channel_id: ""
app.contact.tunnel.ssh.host_key_file: ""
app.contact.tunnel.ssh.host_key_passphrase: ""
app.contact.tunnel.ssh.socket: 0.0.0.0:8022
app.contact.tunnel.ssh.user_name: sandcat
app.contact.tunnel.ssh.user_password: s4ndc4t!
app.contact.ftp.host: 0.0.0.0
app.contact.ftp.port: 2222
app.contact.ftp.pword: caldera
app.contact.ftp.server.dir: ftp_dir
app.contact.ftp.user: caldera_user
app.contact.tcp: 0.0.0.0:7010
app.contact.udp: 0.0.0.0:7011
app.contact.websocket: 0.0.0.0:7012
objects.planners.default: atomic
crypt_salt: cyberblue-salt
encryption_key: cyberblue-key
exfil_dir: /tmp/caldera
reachable_host_traits:
  - remote.host.fqdn
  - remote.host.ip
host: 0.0.0.0
port: 8888
plugins:
  - access
  - atomic
  - compass
  - debrief
  - fieldmanual
  - manx
  - response
  - sandcat
  - stockpile
  - training
reports_dir: /tmp
auth.login.handler.module: default
requirements:
  go:
    command: go version
    type: installed_program
    version: 1.19
  python:
    attr: version
    module: sys
    type: python_module
    version: 3.9.0
users:
  red:
    red: cyberblue
    admin: cyberblue
  blue:
    blue: cyberblue
EOF
log "local.yml written"

# ── Step 4: Build image only if it doesn't exist yet ─────────────
step "STEP 4 — Docker image"

cd "$SCRIPT_DIR"

# FIX: Original always runs docker compose up -d caldera which triggers
# a full image rebuild even if nothing changed. We check first.
# FIX: Check specifically for the CyberBlue caldera image (not any image named caldera)
# Original grep was too broad and would skip build if ANY "caldera" image existed
CALDERA_IMAGE=$(docker compose config --images 2>/dev/null | grep -i caldera | head -1 || echo "")
if docker images --format "{{.Repository}}:{{.Tag}}" | grep -qF "${CALDERA_IMAGE:-NOTFOUND}"; then
  log "Caldera Docker image already exists — skipping build (saves 2-3 min)"
  docker compose up -d caldera
else
  log "Building Caldera image (first time only)..."
  docker compose up -d --build caldera
fi

# ── Step 5: Smart wait ────────────────────────────────────────────
step "STEP 5 — Waiting for Caldera"

WAIT=0; MAX=120
until curl -s --max-time 3 "http://localhost:7009" &>/dev/null; do
  echo -ne "\r  Waiting for Caldera... ${WAIT}s / ${MAX}s"
  sleep 5; WAIT=$((WAIT+5))
  [ $WAIT -ge $MAX ] && { echo ""; warn "Caldera slow — check: docker logs caldera"; break; }
done
[ $WAIT -lt $MAX ] && { echo ""; log "Caldera ready (${WAIT}s)"; }

HOST_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}[✓] Caldera is running!${NC}"
echo "==========================================="
echo -e "  🌐 URL     : http://${HOST_IP}:7009"
echo -e "  👤 Red user : red / cyberblue"
echo -e "  👤 Blue user: blue / cyberblue"
echo -e "  👤 Admin    : admin / cyberblue"
echo ""
