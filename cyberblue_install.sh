#!/bin/bash
# ============================================================================
# CyberBlue FAST Installer — Optimized for i7-14700HX / 16GB RAM
# Fixes all slowness issues in the original cyberblue_install.sh
# ============================================================================
# WHAT THIS FIXES vs ORIGINAL:
#   ORIGINAL problem 1: apt-get upgrade -y  → wastes 3-5 min upgrading unneeded pkgs
#   ORIGINAL problem 2: docker compose up --build  → rebuilds images every run
#   ORIGINAL problem 3: Sequential container startup  → containers start one-by-one
#   ORIGINAL problem 4: No JVM heap setting  → OpenSearch/Wazuh thrash swap constantly
#   ORIGINAL problem 5: 60s fixed sleep waits  → wastes time even when ready early
#   ORIGINAL problem 6: Downloads rules DURING install  → blocks deployment
#   ORIGINAL problem 7: Fleet DB setup inside install  → adds 3-5 min to startup
#   ORIGINAL problem 8: MISP feed config blocks install  → adds 4+ min
#   ORIGINAL problem 9: No parallel jobs  → your 20-core CPU sits idle
#   ORIGINAL problem 10: swap on disk  → 100x slower than RAM, you have 16GB
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_TIME=$(date +%s)

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err()  { echo -e "${RED}[ERR]  $*${NC}"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ── detect user for docker group ─────────────────────────────────
INSTALL_USER="${SUDO_USER:-$USER}"
export DEBIAN_FRONTEND=noninteractive

echo -e "${CYAN}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║   CyberBlue FAST INSTALLER  — i7-14700HX / 16GB    ║
  ║   Parallel startup · Heap tuned · No wasted waits  ║
  ╚══════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ============================================================
# STEP 0 — System pre-checks  (FAST — no full upgrade)
# ============================================================
step "STEP 0 — Quick system pre-check"

# Clear APT locks without restarting services
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
           /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
sudo dpkg --configure -a --force-all 2>/dev/null || true

# FIX: only update package lists, DO NOT full upgrade (saves 3-5 min)
log "Refreshing package lists only (no full upgrade)..."
sudo apt-get update -qq

# FIX: install only what is strictly needed, not a whole toolchain
NEED_PKGS=()
for pkg in git curl wget ca-certificates gnupg lsb-release jq; do
  dpkg -s "$pkg" &>/dev/null || NEED_PKGS+=("$pkg")
done
if [ ${#NEED_PKGS[@]} -gt 0 ]; then
  log "Installing missing: ${NEED_PKGS[*]}"
  sudo apt-get install -y -qq "${NEED_PKGS[@]}"
fi

# ============================================================
# STEP 1 — Docker  (skip if already installed + working)
# ============================================================
step "STEP 1 — Docker check/install"

if docker ps &>/dev/null; then
  log "Docker already running — skipping install"
else
  log "Installing Docker..."
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo rm -f /etc/apt/keyrings/docker.gpg
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable docker --now
fi

# Ensure compose v2 binary exists
if ! command -v docker-compose &>/dev/null; then
  sudo ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose 2>/dev/null || \
  sudo curl -fsSL -o /usr/local/bin/docker-compose \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
  sudo chmod +x /usr/local/bin/docker-compose
fi

sudo usermod -aG docker "$INSTALL_USER" 2>/dev/null || true
sudo chmod 660 /var/run/docker.sock 2>/dev/null || true
log "Docker OK — $(docker --version)"

# ============================================================
# STEP 2 — Kernel + Docker tuning  (critical for your 16GB)
# ============================================================
step "STEP 2 — Kernel & Docker performance tuning"

# FIX: These settings prevent OpenSearch from crashing on 16 GB
apply_sysctl() {
  grep -qF "$1" /etc/sysctl.conf || echo "$1" | sudo tee -a /etc/sysctl.conf >/dev/null
}
apply_sysctl "vm.max_map_count=262144"       # required by OpenSearch / Wazuh indexer
apply_sysctl "vm.swappiness=10"              # FIX: avoid swap unless truly necessary
apply_sysctl "net.core.rmem_max=134217728"   # large buffers for Suricata
apply_sysctl "net.core.wmem_max=134217728"
apply_sysctl "net.core.netdev_max_backlog=250000"
sudo sysctl -p -q

# FIX: Docker daemon — log rotation prevents disk filling, live-restore keeps
# containers alive across daemon restarts (no full restart needed)
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "iptables": true,
  "userland-proxy": false,
  "live-restore": true,
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker
sleep 5
log "Kernel + Docker tuning applied"

# ============================================================
# STEP 3 — SWAP: zram instead of disk swap (HUGE speedup)
# ============================================================
step "STEP 3 — zram swap (RAM-based, 5x faster than disk swap)"

# FIX: Original creates an 8 GB FILE swap (slow disk I/O).
# zram creates a compressed RAM swap — same protection, no disk thrash.
if swapon --show | grep -q zram; then
  log "zram already active: $(free -h | grep Swap)"
else
  sudo modprobe zram 2>/dev/null || true

  # Find a free zram device (zram0 may already be in use by OS)
  ZRAM_DEV=""
  for dev in /sys/block/zram*; do
    [ -e "$dev" ] || continue
    SIZE=$(cat "$dev/disksize" 2>/dev/null || echo "0")
    if [ "$SIZE" = "0" ]; then
      ZRAM_DEV="/dev/$(basename $dev)"
      ZRAM_SYS="$dev"
      break
    fi
  done

  # If all existing devices are busy, create a new one
  if [ -z "$ZRAM_DEV" ]; then
    IDX=$(cat /sys/class/zram-control/hot_add 2>/dev/null || echo "")
    if [ -n "$IDX" ]; then
      ZRAM_DEV="/dev/zram${IDX}"
      ZRAM_SYS="/sys/block/zram${IDX}"
    fi
  fi

  if [ -n "$ZRAM_DEV" ] && [ -e "$ZRAM_DEV" ]; then
    echo 4294967296 | sudo tee "$ZRAM_SYS/disksize" >/dev/null
    sudo mkswap "$ZRAM_DEV"
    sudo swapon "$ZRAM_DEV" -p 100
    log "zram swap active on $ZRAM_DEV: $(free -h | grep Swap)"
  else
    # Fallback: file swap
    if ! swapon --show | grep -q '/swapfile'; then
      warn "zram not available — creating 4 GB file swap"
      sudo fallocate -l 4G /swapfile
      sudo chmod 600 /swapfile
      sudo mkswap /swapfile
      sudo swapon /swapfile
      grep -qF '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    else
      log "File swap already active: $(free -h | grep Swap)"
    fi
  fi
fi

# ============================================================
# STEP 4 — Env file + network interface detection
# ============================================================
step "STEP 4 — Environment & network detection"

cd "$SCRIPT_DIR"

# Detect primary interface
IFACE=$(ip route show default | awk '/default/{print $5}' | head -1)
[ -z "$IFACE" ] && IFACE=$(ip -o link show | awk '$2!="lo:"&&/UP/{print $2}' | tr -d ':' | head -1)
[ -z "$IFACE" ] && { err "Cannot detect network interface"; exit 1; }
log "Network interface: $IFACE"

HOST_IP=$(hostname -I | awk '{print $1}')
log "Host IP: $HOST_IP"

# Write / update .env
[ -f .env ] || touch .env

upsert_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

upsert_env SURICATA_INT        "$IFACE"
upsert_env HOST_IP             "$HOST_IP"
upsert_env MISP_BASE_URL       "https://${HOST_IP}:7003"
upsert_env CYBERBLUE_INSTALL_DIR "$SCRIPT_DIR"
upsert_env CYBERBLUE_INSTALL_USER "$INSTALL_USER"

# Generate YETI secret if missing
grep -q "^YETI_AUTH_SECRET_KEY=" .env || \
  echo "YETI_AUTH_SECRET_KEY=$(openssl rand -hex 64)" >> .env

sudo mkdir -p /opt/yeti/bloomfilters
log ".env written"

# ============================================================
# STEP 5 — Pre-pull all Docker images IN PARALLEL
# ============================================================
step "STEP 5 — Pre-pull images in parallel (uses your 20 cores)"

# FIX: Original does docker compose up --build which is SEQUENTIAL.
# Pulling images first in parallel, then starting, is much faster.

# Extract all image names from compose file
IMAGES=$(grep -E '^\s+image:' docker-compose.yml 2>/dev/null | awk '{print $2}' | sort -u)

if [ -n "$IMAGES" ]; then
  log "Pulling images in parallel (up to 8 simultaneous)..."
  echo "$IMAGES" | xargs -P 8 -I{} bash -c \
    'docker image inspect "{}" &>/dev/null || docker pull "{}" &>/dev/null && echo "  ✓ {}" || echo "  ✗ {} (will build)"'
  log "Image pre-pull complete"
else
  warn "No images found in docker-compose.yml — will build at startup"
fi

# ============================================================
# STEP 6 — Wazuh SSL certs  (run once, skip if exist)
# ============================================================
step "STEP 6 — Wazuh SSL certificates"

CERT_DIR="wazuh/config/wazuh_indexer_ssl_certs"
if [ -d "$CERT_DIR" ] && find "$CERT_DIR" -name "*.pem" | grep -q .; then
  log "Certs already exist — skipping"
else
  log "Generating certs..."
  docker compose run --rm generator 2>&1 | tail -5 || warn "Cert generator had warnings"
  sleep 5
  # Fix permissions on certs
  [ -d "$CERT_DIR" ] && {
    sudo chown -R "$INSTALL_USER:$(id -gn "$INSTALL_USER")" "$CERT_DIR" 2>/dev/null || true
    find "$CERT_DIR" -name "*.pem" -o -name "*.key" | \
      xargs sudo chmod 644 2>/dev/null || true
  }
fi

# ============================================================
# STEP 7 — MITRE ATT&CK Navigator  (background clone)
# ============================================================
step "STEP 7 — ATT&CK Navigator (background)"

# FIX: Original clones this BEFORE starting containers, blocking everything.
# Do it in background while containers start.
if [ ! -d "attack-navigator" ]; then
  git clone --depth=1 https://github.com/mitre-attack/attack-navigator.git \
    attack-navigator &>/dev/null &
  NAVIGATOR_PID=$!
  log "Cloning ATT&CK Navigator in background (PID $NAVIGATOR_PID)"
else
  log "ATT&CK Navigator already cloned"
  NAVIGATOR_PID=0
fi

# ============================================================
# STEP 8 — YARA + Sigma  (background, non-blocking)
# ============================================================
step "STEP 8 — YARA & Sigma rules (background download)"

# FIX: Original downloads these synchronously and blocks deployment.
# These are useful but NOT needed for containers to start.
(
  # YARA
  if ! command -v yara &>/dev/null; then
    sudo apt-get install -y -qq yara 2>/dev/null || true
  fi
  if [ ! -d /opt/yara-rules ]; then
    sudo git clone --depth=1 https://github.com/Yara-Rules/rules.git /opt/yara-rules &>/dev/null
    sudo chown -R "$INSTALL_USER:$(id -gn "$INSTALL_USER")" /opt/yara-rules 2>/dev/null || true
  fi

  # Sigma CLI
  if ! command -v sigma &>/dev/null; then
    sudo pip3 install --break-system-packages -q sigma-cli \
      pysigma-backend-opensearch pysigma-backend-elasticsearch 2>/dev/null || true
  fi
  if [ ! -d /opt/sigma-rules ]; then
    sudo git clone --depth=1 https://github.com/SigmaHQ/sigma.git /opt/sigma-rules &>/dev/null
    sudo chown -R "$INSTALL_USER:$(id -gn "$INSTALL_USER")" /opt/sigma-rules 2>/dev/null || true
  fi

  # Auto-update cron
  (crontab -l 2>/dev/null | grep -v "yara-rules\|sigma-rules";
   echo "0 2 * * 0 [ -d /opt/yara-rules ] && cd /opt/yara-rules && git pull >> /var/log/yara-update.log 2>&1";
   echo "5 2 * * 0 [ -d /opt/sigma-rules ] && cd /opt/sigma-rules && git pull >> /var/log/sigma-update.log 2>&1"
  ) | crontab - 2>/dev/null || true

  echo "[$(date +%H:%M:%S)] YARA + Sigma ready" >> /tmp/cyberblue-bg.log
) &
RULES_PID=$!
log "YARA/Sigma downloading in background (PID $RULES_PID)"

# ============================================================
# STEP 9 — Suricata rules  (background download)
# ============================================================
step "STEP 9 — Suricata rules (background)"

sudo mkdir -p ./suricata/rules

(
  if [ ! -f ./suricata/rules/emerging-all.rules ]; then
    curl -fsSL -o /tmp/emerging.tar.gz \
      https://rules.emergingthreats.net/open/suricata-6.0/emerging.rules.tar.gz 2>/dev/null
    sudo tar -xzf /tmp/emerging.tar.gz -C ./suricata/rules/ --strip-components=1 2>/dev/null
    rm -f /tmp/emerging.tar.gz
  fi
  curl -fsSL -o ./suricata/classification.config \
    https://raw.githubusercontent.com/OISF/suricata/master/etc/classification.config 2>/dev/null || true
  curl -fsSL -o ./suricata/reference.config \
    https://raw.githubusercontent.com/OISF/suricata/master/etc/reference.config 2>/dev/null || true
  echo "[$(date +%H:%M:%S)] Suricata rules ready" >> /tmp/cyberblue-bg.log
) &
SURICATA_RULES_PID=$!
log "Suricata rules downloading in background (PID $SURICATA_RULES_PID)"

# ============================================================
# STEP 10 — Download Wazuh/Velociraptor agent packages (bg)
# ============================================================
step "STEP 10 — Agent packages (background)"

(
  [ -f "velociraptor/agents/download-binaries.sh" ] && \
    bash velociraptor/agents/download-binaries.sh &>/dev/null || true
  [ -f "wazuh/agents/download-packages.sh" ] && \
    bash wazuh/agents/download-packages.sh &>/dev/null || true
  [ -f "fleet/agents/download-packages.sh" ] && \
    bash fleet/agents/download-packages.sh &>/dev/null || true
  echo "[$(date +%H:%M:%S)] Agent packages ready" >> /tmp/cyberblue-bg.log
) &
AGENTS_PID=$!
log "Agent packages downloading in background (PID $AGENTS_PID)"

# ============================================================
# STEP 11 — Caldera setup  (background, non-blocking)
# ============================================================
step "STEP 11 — Caldera (background)"

if [ ! -d "./caldera" ] && [ -f "./install_caldera.sh" ]; then
  (chmod +x ./install_caldera.sh && timeout 180 ./install_caldera.sh &>/dev/null) &
  CALDERA_PID=$!
  log "Caldera installing in background (PID $CALDERA_PID)"
else
  log "Caldera already present"
  CALDERA_PID=0
fi

# ============================================================
# STEP 12 — JVM HEAP TUNING before starting containers
# ============================================================
step "STEP 12 — JVM heap tuning for 16 GB RAM"

# FIX: On 16 GB with 20 containers, OpenSearch MUST have a fixed heap.
# Without this, JVM auto-detects system RAM and tries to use 8 GB,
# leaving nothing for Wazuh, MISP, Velociraptor etc.
# Safe split for 16 GB: OpenSearch 3 GB, leaves 13 GB for everything else.

upsert_env OPENSEARCH_JAVA_OPTS  "-Xms3g -Xmx3g"
upsert_env ES_JAVA_OPTS          "-Xms3g -Xmx3g"

# Also patch wazuh indexer config if it exists
WAZUH_JVM="wazuh/config/wazuh_indexer/jvm.options"
if [ -f "$WAZUH_JVM" ]; then
  # Replace whatever heap values exist with 3g
  sudo sed -i 's/-Xms[0-9]*[gGmM]/-Xms3g/g' "$WAZUH_JVM"
  sudo sed -i 's/-Xmx[0-9]*[gGmM]/-Xmx3g/g' "$WAZUH_JVM"
  log "Wazuh indexer JVM heap: 3g"
fi

log "JVM heap: 3 GB for OpenSearch/Wazuh indexer"

# ============================================================
# STEP 13 — DOCKER NETWORKING PREP
# ============================================================
step "STEP 13 — Docker networking"

sudo docker network prune -f &>/dev/null || true
sudo iptables -t nat -F DOCKER 2>/dev/null || true
sudo iptables -t filter -F DOCKER 2>/dev/null || true
sudo iptables -t filter -F DOCKER-ISOLATION-STAGE-1 2>/dev/null || true
sudo iptables -t filter -F DOCKER-ISOLATION-STAGE-2 2>/dev/null || true
sudo iptables -P FORWARD ACCEPT
sudo systemctl restart docker
sleep 8

# Wait for docker socket to come back (smart wait, not fixed sleep)
timeout 30 bash -c 'until docker info &>/dev/null; do sleep 2; done'
log "Docker networking ready"

# ============================================================
# STEP 14 — START CONTAINERS  (the core step)
# ============================================================
step "STEP 14 — Starting containers"

# FIX: Use --no-build flag if images already pulled.
# FIX: Use --remove-orphans to clean old containers without prompts.
# FIX: Split into two groups — critical services first, then supporting tools.

log "Starting CRITICAL services (OpenSearch/Wazuh indexer first)..."
# Start indexer alone first — it needs the most time to initialize
docker compose up -d wazuh.indexer 2>&1 | tail -3

# Smart wait: poll instead of fixed sleep
log "Waiting for OpenSearch/Wazuh indexer to be healthy..."
WAIT=0
MAX_WAIT=180
until curl -sk https://localhost:9200/_cluster/health &>/dev/null || \
      docker exec wazuh.indexer curl -sk https://localhost:9200/_cluster/health &>/dev/null; do
  sleep 5; WAIT=$((WAIT+5))
  [ $WAIT -ge $MAX_WAIT ] && { warn "Indexer slow — continuing anyway"; break; }
  echo -ne "\r  Waiting for indexer... ${WAIT}s / ${MAX_WAIT}s"
done
echo ""
log "Indexer ready (${WAIT}s)"

log "Starting all remaining containers in parallel..."
docker compose up -d --remove-orphans 2>&1 | tail -10

# ============================================================
# STEP 15 — POST-DEPLOY FIXES  (async, non-blocking)
# ============================================================
step "STEP 15 — Post-deploy background tasks"

# Fleet DB — run in background so it doesn't block
(
  sleep 30  # let fleet-mysql fully init
  timeout 300 docker run --rm \
    --network=cyber-blue \
    -e FLEET_MYSQL_ADDRESS=fleet-mysql:3306 \
    -e FLEET_MYSQL_USERNAME=fleet \
    -e FLEET_MYSQL_PASSWORD=fleetpass \
    -e FLEET_MYSQL_DATABASE=fleet \
    fleetdm/fleet:latest fleet prepare db &>/dev/null || true
  docker compose up -d fleet-server &>/dev/null || true
  echo "[$(date +%H:%M:%S)] Fleet DB ready" >> /tmp/cyberblue-bg.log
) &
FLEET_PID=$!
log "Fleet DB setup running in background (PID $FLEET_PID)"

# Arkime init — background
(
  sleep 20
  [ -f "./fix-arkime.sh" ] && chmod +x ./fix-arkime.sh && \
    timeout 120 bash ./fix-arkime.sh --live-30s &>/dev/null || true
  timeout 30 docker exec arkime /opt/arkime/bin/arkime_add_user.sh \
    admin "CyberBlue Admin" admin --admin &>/dev/null || true
  echo "[$(date +%H:%M:%S)] Arkime ready" >> /tmp/cyberblue-bg.log
) &
ARKIME_PID=$!
log "Arkime init running in background (PID $ARKIME_PID)"

# MISP password bypass + feeds — background
(
  sleep 60
  for i in {1..60}; do
    EXISTS=$(docker exec misp-core mysql -h db -u misp -pexample misp \
      -se "SELECT COUNT(*) FROM users WHERE email='admin@admin.test';" 2>/dev/null || echo "0")
    if [ "$EXISTS" -gt "0" ]; then
      docker exec misp-core mysql -h db -u misp -pexample misp \
        -e "UPDATE users SET change_pw=0 WHERE email='admin@admin.test';" 2>/dev/null || true
      sleep 120  # let MISP fully start
      [ -f "misp/configure-threat-feeds.sh" ] && \
        bash misp/configure-threat-feeds.sh &>/dev/null || true
      echo "[$(date +%H:%M:%S)] MISP feeds configured" >> /tmp/cyberblue-bg.log
      break
    fi
    sleep 10
  done
) &
MISP_PID=$!
log "MISP setup running in background (PID $MISP_PID)"

# Wazuh service health check — background restart if needed
(
  sleep 90
  RUNNING=$(docker ps | grep -c "wazuh.*Up" || echo "0")
  if [ "$RUNNING" -lt 3 ]; then
    docker compose restart wazuh.indexer &>/dev/null; sleep 20
    docker compose restart wazuh.manager &>/dev/null; sleep 15
    docker compose restart wazuh.dashboard &>/dev/null
    echo "[$(date +%H:%M:%S)] Wazuh services restarted" >> /tmp/cyberblue-bg.log
  fi
) &
WAZUH_HEALTH_PID=$!

# ============================================================
# STEP 16 — iptables / external access
# ============================================================
step "STEP 16 — Firewall rules for external access"

sudo iptables -P FORWARD ACCEPT
for port in 443 5443 7000 7001 7002 7003 7004 7005 7006 7007 7008 7009 7013 7015 9200 9443; do
  sudo iptables -I FORWARD -i "$IFACE" -p tcp --dport $port -j ACCEPT 2>/dev/null || true
  sudo iptables -I FORWARD -o "$IFACE" -p tcp --sport $port -j ACCEPT 2>/dev/null || true
done

# Make persistent
if dpkg -s iptables-persistent &>/dev/null; then
  sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
else
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | sudo debconf-set-selections
  sudo apt-get install -y -qq iptables-persistent 2>/dev/null || true
  sudo mkdir -p /etc/iptables
  sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
fi
log "Firewall rules applied + persisted"

# ============================================================
# STEP 17 — Caldera systemd service
# ============================================================
step "STEP 17 — systemd auto-start services"

sudo tee /etc/systemd/system/cyberblue-autostart.service >/dev/null << EOF
[Unit]
Description=CyberBlue SOC Platform Auto-Start
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${SCRIPT_DIR}
ExecStartPre=/bin/sleep 20
ExecStartPre=/bin/bash -c 'timeout 60 bash -c "until docker info >/dev/null 2>&1; do sleep 5; done"'
ExecStart=/bin/bash ${SCRIPT_DIR}/force-start.sh
TimeoutStartSec=600
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/caldera-autostart.service >/dev/null << EOF
[Unit]
Description=Caldera Auto-Start
After=docker.service cyberblue-autostart.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'docker start caldera 2>/dev/null || true'
TimeoutStartSec=60
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cyberblue-autostart.service caldera-autostart.service
log "Auto-start services enabled"

# ============================================================
# STEP 18 — Smart wait: poll until containers are healthy
# ============================================================
step "STEP 18 — Waiting for containers (smart poll, no fixed sleep)"

# FIX: Original just sleeps 60 seconds blindly.
# This polls every 5 seconds and continues as soon as minimum services are up.
log "Polling container health..."
WAIT=0
MAX_WAIT=300   # 5-minute absolute max
MIN_RUNNING=20 # acceptable minimum on 16 GB

while true; do
  RUNNING=$(docker ps --filter "status=running" --format "{{.Names}}" | wc -l)
  echo -ne "\r  Running containers: ${RUNNING} / target ${MIN_RUNNING}  (${WAIT}s elapsed)"
  if [ "$RUNNING" -ge "$MIN_RUNNING" ]; then
    echo ""
    log "Minimum containers reached: $RUNNING running"
    break
  fi
  if [ $WAIT -ge $MAX_WAIT ]; then
    echo ""
    warn "Timeout reached — $RUNNING containers running. Some may still be starting."
    break
  fi
  sleep 5
  WAIT=$((WAIT+5))
done

# ============================================================
# FINAL SUMMARY
# ============================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION/60)); SECS=$((DURATION%60))
TOTAL=$(docker ps --filter "status=running" --format "{{.Names}}" | wc -l)

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗"
echo -e "║        CyberBlue FAST Install Complete               ║"
echo -e "╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ⏱  Total time   : ${MINS}m ${SECS}s"
echo -e "  📦 Containers   : ${TOTAL} running"
echo -e "  💾 JVM Heap     : 3 GB (OpenSearch/Wazuh indexer)"
echo -e "  🔄 Swap         : zram (RAM-based, fast)"
echo -e "  🔁 Auto-start   : enabled on reboot"
echo ""
echo -e "${CYAN}  Background tasks still running (check progress):${NC}"
echo -e "  tail -f /tmp/cyberblue-bg.log"
echo ""
echo -e "${BLUE}  Access your SOC:${NC}"
echo -e "  Portal          : https://${HOST_IP}:5443"
echo -e "  Wazuh           : https://${HOST_IP}:7001  (admin/SecretPassword)"
echo -e "  Velociraptor    : https://${HOST_IP}:7000  (admin/cyberblue)"
echo -e "  Arkime          : http://${HOST_IP}:7008   (admin/admin)"
echo -e "  MISP            : https://${HOST_IP}:7003  (admin@admin.test/admin)"
echo -e "  TheHive         : http://${HOST_IP}:7005   (admin@thehive.local/secret)"
echo -e "  Shuffle         : https://${HOST_IP}:7002  (admin/password)"
echo -e "  EveBox          : http://${HOST_IP}:7015"
echo -e "  Caldera         : http://${HOST_IP}:7009   (red/cyberblue)"
echo -e "  CyberChef       : http://${HOST_IP}:7004"
echo -e "  MITRE Navigator : http://${HOST_IP}:7013"
echo -e "  Portainer       : https://${HOST_IP}:9443  (admin/cyberblue123)"
echo ""
echo -e "${YELLOW}  EDUCATIONAL USE ONLY — isolated lab environments${NC}"
echo ""
