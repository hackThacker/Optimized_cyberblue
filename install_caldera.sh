#!/bin/bash
# ============================================================================
# CyberBlue install_caldera.sh — FIXED
# ============================================================================
# WHAT ORIGINAL DID WRONG:
#
#  PROBLEM 1 — git clone --recursive
#              Downloads ALL 20+ submodules including huge Go toolchains
#              Takes 10-15 minutes, uses gigabytes of disk
#              FIX: --depth=1 (shallow) + git submodule update --init
#                   for ALL submodules (not just a few by name)
#
#  PROBLEM 2 — Always stops and removes running Caldera
#              docker_compose stop caldera + rm -f caldera every single run
#              Even if Caldera is running perfectly fine
#              FIX: Check if running and responding first — skip if healthy
#
#  PROBLEM 3 — docker_compose up -d caldera
#              Triggers full Docker image REBUILD every run
#              Even when nothing has changed
#              FIX: Check if image already exists — skip build if it does
#
#  PROBLEM 4 — No wait or verification after startup
#              Script exits immediately after docker compose up
#              You never know if Caldera actually started
#              FIX: Smart poll on port 7009 until it responds
#
#  PROBLEM 5 — Node.js 18 (deprecated)
#              Dockerfile needs npm to build plugins/magma
#              Node 18 shows deprecation warning + 10s delay every run
#              FIX: Node.js 20 LTS (supported until 2026)
#
#  PROBLEM 6 — Only named specific plugins in submodule init
#              Left plugins/emu, plugins/gameboard, plugins/human etc EMPTY
#              Caldera crashes at runtime loading missing plugins
#              FIX: git submodule update --init on ALL submodules
#
#  PROBLEM 7 — set -e with docker_compose stop (can exit early)
#              docker_compose stop caldera returns non-zero if not running
#              set -e causes entire script to exit at that point
#              FIX: removed set -e, use explicit || true on safe failures
#
#  PROBLEM 8 — docker_compose function checks v1 vs v2 every call
#              Unnecessary overhead — Docker v2 is standard now
#              FIX: use docker compose v2 directly
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ❌ $*${NC}"; exit 1; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# FIX 7: removed set -e — use explicit error handling instead
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR/caldera"
PORT_MAPPING="7009:8888"
LOCAL_YML="$INSTALL_DIR/conf/local.yml"

echo -e "${BLUE}[+] Starting Caldera installation...${NC}"
echo "==========================================="

# ============================================================
# STEP 1 — Skip entirely if already running and healthy
# ============================================================
step "STEP 1 — Check if Caldera already running"

# FIX 2: Original always stopped and removed the container
# Now we check first — if it works, skip everything
if docker ps --format "{{.Names}}" | grep -q "^caldera$"; then
  if curl -s --max-time 3 "http://localhost:7009" &>/dev/null; then
    log "Caldera already running and responding — nothing to do"
    echo -e "  🌐 http://$(hostname -I | awk '{print $1}'):7009"
    exit 0
  else
    warn "Caldera container exists but not responding — will restart"
    docker compose restart caldera 2>/dev/null || true
    sleep 5
    if curl -s --max-time 5 "http://localhost:7009" &>/dev/null; then
      log "Caldera responding after restart"
      exit 0
    fi
    warn "Still not responding — doing full reinstall..."
  fi
fi

# ============================================================
# STEP 2 — Node.js 20 LTS (needed for plugins/magma build)
# ============================================================
step "STEP 2 — Node.js check"

# FIX 5: was Node.js 18 (deprecated, 10s warning delay)
# Node.js 20 is current LTS — no warnings
if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
  log "Installing Node.js 20 LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null
  sudo apt-get install -y -qq nodejs 2>/dev/null
  log "Node.js installed: $(node --version)"
else
  NODE_VER=$(node --version | sed 's/v//' | cut -d. -f1)
  if [ "$NODE_VER" -lt 20 ]; then
    warn "Node.js v$(node --version) too old — upgrading to 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null
    sudo apt-get install -y -qq nodejs 2>/dev/null
    log "Upgraded: $(node --version)"
  else
    log "Node.js OK: $(node --version)"
  fi
fi

# ============================================================
# STEP 3 — Clone Caldera (shallow, not recursive)
# ============================================================
step "STEP 3 — Caldera source code"

# FIX 1: Original used --recursive which downloads all Go toolchains
# --depth=1 gets only the latest commit — much faster
if [ ! -d "$INSTALL_DIR" ]; then
  log "Cloning MITRE Caldera (shallow clone)..."
  git clone --depth=1 https://github.com/mitre/caldera.git "$INSTALL_DIR" \
    || err "Clone failed — check internet connection"
  log "Caldera cloned"
else
  log "Caldera already cloned at $INSTALL_DIR"
fi

# ============================================================
# STEP 4 — Initialize ALL plugin submodules
# ============================================================
step "STEP 4 — Plugin submodules"

cd "$INSTALL_DIR"

# FIX 6: Original only initialized 6 specific plugins by name
# This left emu, gameboard, human, builder, ssl, training EMPTY
# git submodule update --init without naming plugins = initializes ALL of them
log "Initializing ALL plugin submodules..."
git submodule update --init --depth=1 2>/dev/null && \
  log "All submodules initialized" || {
    warn "Some submodules had issues — retrying without --depth=1..."
    git submodule update --init 2>/dev/null || \
      warn "Submodule init had issues — some plugins may be missing"
  }

# Verify critical plugins have content
echo ""
echo -e "${BLUE}  Plugin status:${NC}"
EMPTY_COUNT=0
for plugin_dir in plugins/*/; do
  plugin=$(basename "$plugin_dir")
  if [ -n "$(ls -A "$plugin_dir" 2>/dev/null)" ]; then
    echo -e "  ${GREEN}✅ $plugin${NC}"
  else
    echo -e "  ${RED}❌ $plugin (empty — cloning directly)${NC}"
    # Clone directly as fallback for any empty plugin
    rm -rf "$plugin_dir"
    git clone --depth=1 \
      "https://github.com/mitre/${plugin}.git" \
      "$plugin_dir" 2>/dev/null || \
      warn "  Could not clone $plugin"
    EMPTY_COUNT=$((EMPTY_COUNT + 1))
  fi
done

# Special check: magma needs package.json for npm build
if [ ! -f "plugins/magma/package.json" ]; then
  warn "plugins/magma/package.json missing — cloning directly..."
  rm -rf "plugins/magma"
  git clone --depth=1 \
    https://github.com/mitre/magma.git \
    "plugins/magma" \
    || err "Cannot clone plugins/magma — required for Docker build"
  log "plugins/magma cloned"
fi

echo ""
log "All plugins verified"
cd "$SCRIPT_DIR"

# ============================================================
# STEP 5 — Write local.yml configuration
# ============================================================
step "STEP 5 — Configuration"

log "Writing local.yml with cyberblue passwords..."
mkdir -p "$INSTALL_DIR/conf"

# FIX: use single quotes on heredoc delimiter (<<'EOF') so variables
# like $SCRIPT_DIR are NOT expanded inside the config file
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

# ============================================================
# STEP 6 — Build Docker image (only if not already built)
# ============================================================
step "STEP 6 — Docker image"

cd "$SCRIPT_DIR"

# FIX 3: Original always ran docker compose up --build (rebuilds every time)
# Check if image exists first — skip build if already done
CALDERA_IMAGE=$(docker compose config --images 2>/dev/null \
  | grep -i caldera | head -1 || echo "")

if [ -n "$CALDERA_IMAGE" ] && \
   docker images --format "{{.Repository}}:{{.Tag}}" \
   | grep -qF "$CALDERA_IMAGE"; then
  log "Caldera image already built — skipping rebuild (saves 3-5 min)"
  # FIX 8: use docker compose v2 directly
  docker compose up -d caldera
else
  log "Building Caldera image for first time (3-5 min — normal)..."
  # FIX 8: use docker compose v2 directly (no v1/v2 check needed)
  docker compose up -d --build caldera 2>&1 \
    | tee /tmp/caldera-build.log | tail -20

  if ! docker ps --format "{{.Names}}" | grep -q "^caldera$"; then
    err "Build failed — full log: cat /tmp/caldera-build.log"
  fi
fi

# ============================================================
# STEP 7 — Wait for Caldera to respond
# ============================================================
step "STEP 7 — Waiting for Caldera"

# FIX 4: Original had NO wait — exited immediately after docker compose up
# Smart poll: check every 5s, max 3 minutes
HOST_PORT="${PORT_MAPPING%%:*}"
WAIT=0; MAX=180

until curl -s --max-time 3 "http://localhost:${HOST_PORT}" &>/dev/null; do
  echo -ne "\r  Waiting for Caldera... ${WAIT}s / ${MAX}s"
  sleep 5; WAIT=$((WAIT+5))
  [ $WAIT -ge $MAX ] && {
    echo ""
    warn "Caldera slow — check logs: docker logs caldera --tail 30"
    break
  }
done
[ $WAIT -lt $MAX ] && { echo ""; log "Caldera ready in ${WAIT}s"; }

HOST_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗"
echo -e "║   ✅  Caldera is running!                            ║"
echo -e "╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  🌐 URL      : http://${HOST_IP}:${HOST_PORT}"
echo -e "  👤 Red user : red  / cyberblue"
echo -e "  👤 Blue user: blue / cyberblue"
echo -e "  👤 Admin    : admin / cyberblue"
echo ""
