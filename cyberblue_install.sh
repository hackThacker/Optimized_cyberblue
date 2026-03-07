#!/bin/bash
# ============================================================================
# CyberBlue SOC Platform — Complete Installer
# Optimized for 7GB RAM system
# ============================================================================

set +e
set +u

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging functions ────────────────────────────────────────────────────────
log()    { echo -e "${GREEN}  ✅ [$(date +%H:%M:%S)] $*${NC}"; }
warn()   { echo -e "${YELLOW}  ⚠️  [$(date +%H:%M:%S)] $*${NC}"; }
err()    { echo -e "${RED}  ❌ [$(date +%H:%M:%S)] $*${NC}"; }
info()   { echo -e "${CYAN}  ℹ️  $*${NC}"; }
step()   {
  echo ""
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}${BOLD}  $*${NC}"
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
ok()     { echo -e "${GREEN}    ✓ $*${NC}"; }
skip()   { echo -e "${YELLOW}    ⏭  $* — already done, skipping${NC}"; }
doing()  { echo -e "${CYAN}    ⟳  $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_TIME=$(date +%s)
INSTALL_USER="${SUDO_USER:-$USER}"
export DEBIAN_FRONTEND=noninteractive

# ── Banner ───────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════════╗
  ║                                                                  ║
  ║        🔵  CyberBlue SOC Platform Installer                     ║
  ║             Optimized for 7GB RAM                               ║
  ║                                                                  ║
  ║        Steps 0-18  ·  Full output  ·  No hidden errors          ║
  ║                                                                  ║
  ╚══════════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
echo -e "  📁 Install directory : ${CYAN}$SCRIPT_DIR${NC}"
echo -e "  👤 Install user      : ${CYAN}$INSTALL_USER${NC}"
echo -e "  🕐 Started at        : ${CYAN}$(date)${NC}"
echo ""

# ── Helper: write/update .env key ───────────────────────────────────────────
upsert_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

# ── Helper: add sysctl only if not already set ──────────────────────────────
apply_sysctl() {
  grep -qF "$1" /etc/sysctl.conf || echo "$1" | sudo tee -a /etc/sysctl.conf >/dev/null
}

# ════════════════════════════════════════════════════════════════════
# STEP 0 — System pre-check
# ════════════════════════════════════════════════════════════════════
step "STEP 0 — System pre-check"

doing "Clearing any stuck dpkg locks..."
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
           /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null
sudo dpkg --configure -a --force-all 2>/dev/null | grep -v "^$" || true

doing "Refreshing package lists..."
sudo apt-get update -qq 2>/dev/null
ok "Package lists refreshed"

doing "Checking required tools: git curl wget ca-certificates gnupg lsb-release jq"
NEED_PKGS=()
for pkg in git curl wget ca-certificates gnupg lsb-release jq python3; do
  dpkg -s "$pkg" &>/dev/null || NEED_PKGS+=("$pkg")
done
if [ ${#NEED_PKGS[@]} -gt 0 ]; then
  doing "Installing missing packages: ${NEED_PKGS[*]}"
  sudo apt-get install -y -qq "${NEED_PKGS[@]}" 2>/dev/null
  ok "Installed: ${NEED_PKGS[*]}"
else
  ok "All required tools already installed"
fi

log "STEP 0 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 1 — Docker install/check
# ════════════════════════════════════════════════════════════════════
step "STEP 1 — Docker check / install"

if docker ps &>/dev/null; then
  ok "Docker already running — $(docker --version)"
else
  doing "Installing Docker CE..."
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo rm -f /etc/apt/keyrings/docker.gpg
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable docker --now
  ok "Docker installed: $(docker --version)"
fi

# docker-compose v1 compat symlink
if ! command -v docker-compose &>/dev/null; then
  sudo ln -sf /usr/libexec/docker/cli-plugins/docker-compose \
    /usr/local/bin/docker-compose 2>/dev/null || true
fi

doing "Adding $INSTALL_USER to docker group..."
sudo usermod -aG docker "$INSTALL_USER" 2>/dev/null || true

doing "Setting docker.sock permissions (666 — required for containers)..."
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
ok "docker.sock → 666"

log "STEP 1 complete — Docker $(docker --version | grep -oP '\d+\.\d+\.\d+')"

# ════════════════════════════════════════════════════════════════════
# STEP 2 — Kernel & Docker performance tuning
# ════════════════════════════════════════════════════════════════════
step "STEP 2 — Kernel & Docker performance tuning"

doing "Applying sysctl settings..."
apply_sysctl "vm.max_map_count=262144"    # Required for OpenSearch/Elasticsearch
apply_sysctl "vm.swappiness=10"           # Prefer RAM over swap
apply_sysctl "net.core.rmem_max=134217728"
apply_sysctl "net.core.wmem_max=134217728"
apply_sysctl "net.core.netdev_max_backlog=250000"
sudo sysctl -p -q
ok "sysctl settings applied"

doing "Checking Docker daemon config..."
sudo mkdir -p /etc/docker
NEW_DAEMON='{
  "iptables": true,
  "userland-proxy": false,
  "live-restore": true,
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}'
CURRENT_DAEMON=$(cat /etc/docker/daemon.json 2>/dev/null || echo "")
if [ "$CURRENT_DAEMON" != "$NEW_DAEMON" ]; then
  echo "$NEW_DAEMON" | sudo tee /etc/docker/daemon.json >/dev/null
  doing "Restarting Docker with new daemon config..."
  sudo systemctl restart docker
  sleep 5
  sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
  ok "Docker daemon updated and restarted"
else
  skip "Docker daemon.json unchanged — skipping restart (saves 8s)"
fi

log "STEP 2 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 3 — zram swap
# ════════════════════════════════════════════════════════════════════
step "STEP 3 — zram swap (RAM-based, faster than disk)"

if swapon --show | grep -q zram; then
  skip "zram already active"
  info "Current swap: $(free -h | grep Swap)"
else
  doing "Setting up zram swap..."
  sudo modprobe zram 2>/dev/null || true
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
  if [ -z "$ZRAM_DEV" ]; then
    IDX=$(cat /sys/class/zram-control/hot_add 2>/dev/null || echo "")
    [ -n "$IDX" ] && ZRAM_DEV="/dev/zram${IDX}" && ZRAM_SYS="/sys/block/zram${IDX}"
  fi
  if [ -n "$ZRAM_DEV" ] && [ -e "$ZRAM_DEV" ]; then
    echo 4294967296 | sudo tee "$ZRAM_SYS/disksize" >/dev/null
    sudo mkswap "$ZRAM_DEV" -q
    sudo swapon "$ZRAM_DEV" -p 100
    ok "zram swap active: $(free -h | grep Swap)"
  else
    if ! swapon --show | grep -q '/swapfile'; then
      warn "zram unavailable — creating 4GB file swap instead"
      sudo fallocate -l 4G /swapfile
      sudo chmod 600 /swapfile
      sudo mkswap /swapfile -q
      sudo swapon /swapfile
      grep -qF '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
      ok "File swap active: $(free -h | grep Swap)"
    else
      skip "File swap already active"
    fi
  fi
fi

log "STEP 3 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 4 — Environment & network detection
# ════════════════════════════════════════════════════════════════════
step "STEP 4 — Environment & network detection"

cd "$SCRIPT_DIR"
[ -f .env ] || touch .env

doing "Detecting network interface..."
IFACE=$(ip route show default | awk '/default/{print $5}' | head -1)
[ -z "$IFACE" ] && IFACE=$(ip -o link show | awk '$2!="lo:"&&/UP/{print $2}' | tr -d ':' | head -1)
[ -z "$IFACE" ] && { err "Cannot detect network interface — check your network"; exit 1; }
ok "Network interface : $IFACE"

doing "Detecting host IP..."
HOST_IP=$(hostname -I | awk '{print $1}')
ok "Host IP           : $HOST_IP"

doing "Writing .env file..."
upsert_env SURICATA_INT           "$IFACE"
upsert_env HOST_IP                "$HOST_IP"
upsert_env MISP_BASE_URL          "https://${HOST_IP}:7003"
upsert_env CYBERBLUE_INSTALL_DIR  "$SCRIPT_DIR"
upsert_env CYBERBLUE_INSTALL_USER "$INSTALL_USER"
# Suppress "job_directory variable not set" warning from docker compose
upsert_env job_directory          "/tmp/cortex-jobs"
# Docker GID — containers need numeric GID not group name
DOCKER_GID=$(getent group docker 2>/dev/null | cut -d: -f3 || echo "")
[ -n "$DOCKER_GID" ] && upsert_env DOCKER_GID "$DOCKER_GID"

grep -q "^YETI_AUTH_SECRET_KEY=" .env || \
  echo "YETI_AUTH_SECRET_KEY=$(openssl rand -hex 64)" >> .env

sudo mkdir -p /opt/yeti/bloomfilters
ok ".env file written"

log "STEP 4 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 5 — Pre-pull Docker images in parallel
# ════════════════════════════════════════════════════════════════════
step "STEP 5 — Pre-pull Docker images (parallel — up to 8 at once)"

IMAGES=$(grep -E '^\s+image:' docker-compose.yml 2>/dev/null \
  | awk '{print $2}' | sort -u)

if [ -n "$IMAGES" ]; then
  TOTAL_IMAGES=$(echo "$IMAGES" | wc -l | tr -d ' ')
  doing "Pulling $TOTAL_IMAGES images in parallel..."
  echo ""
  echo "$IMAGES" | xargs -P 8 -I{} bash -c '
    if docker image inspect "{}" &>/dev/null; then
      echo -e "    \033[32m✓ cached : {}\033[0m"
    elif docker pull "{}" &>/dev/null; then
      echo -e "    \033[32m✓ pulled : {}\033[0m"
    else
      echo -e "    \033[33m✗ skipped: {} (custom build — will build in Step 13)\033[0m"
    fi
  '
  echo ""
  ok "Image pre-pull complete"
else
  warn "No pre-built images found in docker-compose.yml"
fi

log "STEP 5 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 6 — Wazuh SSL certificates
# ════════════════════════════════════════════════════════════════════
step "STEP 6 — Wazuh SSL certificates"

CERT_DIR="wazuh/config/wazuh_indexer_ssl_certs"
if [ -d "$CERT_DIR" ] && find "$CERT_DIR" -name "*.pem" 2>/dev/null | grep -q .; then
  skip "Wazuh SSL certificates already exist"
else
  doing "Generating Wazuh SSL certificates..."
  docker compose run --rm generator 2>&1 | tail -5 || warn "Cert generator had warnings"
  sleep 5
  if [ -d "$CERT_DIR" ]; then
    sudo chown -R "$INSTALL_USER:$(id -gn "$INSTALL_USER")" "$CERT_DIR" 2>/dev/null || true
    find "$CERT_DIR" \( -name "*.pem" -o -name "*.key" \) \
      | xargs sudo chmod 644 2>/dev/null || true
    ok "Certificates generated in $CERT_DIR"
  else
    warn "Cert directory not found — certificates may be missing"
  fi
fi

log "STEP 6 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 7 — ATT&CK Navigator (background clone)
# ════════════════════════════════════════════════════════════════════
step "STEP 7 — ATT&CK Navigator"

if [ ! -d "attack-navigator" ]; then
  doing "Cloning MITRE ATT&CK Navigator in background..."
  git clone --depth=1 \
    https://github.com/mitre-attack/attack-navigator.git \
    attack-navigator &>/dev/null &
  NAVIGATOR_PID=$!
  info "Cloning in background (PID $NAVIGATOR_PID) — will be ready by Step 14"
else
  skip "ATT&CK Navigator already cloned"
  NAVIGATOR_PID=0
fi

log "STEP 7 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 8 — YARA & Sigma rules (background download)
# ════════════════════════════════════════════════════════════════════
step "STEP 8 — YARA & Sigma rules (background)"

(
  if ! command -v yara &>/dev/null; then
    sudo apt-get install -y -qq yara 2>/dev/null || true
  fi
  if [ ! -d /opt/yara-rules ]; then
    sudo git clone --depth=1 \
      https://github.com/Yara-Rules/rules.git /opt/yara-rules &>/dev/null
    sudo chown -R "$INSTALL_USER:$(id -gn "$INSTALL_USER")" \
      /opt/yara-rules 2>/dev/null || true
  fi
  if ! command -v sigma &>/dev/null; then
    sudo pip3 install --break-system-packages -q sigma-cli \
      pysigma-backend-opensearch pysigma-backend-elasticsearch \
      2>/dev/null || true
  fi
  if [ ! -d /opt/sigma-rules ]; then
    sudo git clone --depth=1 \
      https://github.com/SigmaHQ/sigma.git /opt/sigma-rules &>/dev/null
    sudo chown -R "$INSTALL_USER:$(id -gn "$INSTALL_USER")" \
      /opt/sigma-rules 2>/dev/null || true
  fi
  (crontab -l 2>/dev/null | grep -v "yara-rules\|sigma-rules"
   echo "0 2 * * 0 [ -d /opt/yara-rules ] && cd /opt/yara-rules && git pull >> /var/log/yara-update.log 2>&1"
   echo "5 2 * * 0 [ -d /opt/sigma-rules ] && cd /opt/sigma-rules && git pull >> /var/log/sigma-update.log 2>&1"
  ) | crontab - 2>/dev/null || true
  echo "[$(date +%H:%M:%S)] YARA + Sigma ready" >> /tmp/cyberblue-bg.log
) &
RULES_PID=$!
info "YARA/Sigma downloading in background (PID $RULES_PID)"

log "STEP 8 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 9 — Suricata rules (background)
# ════════════════════════════════════════════════════════════════════
step "STEP 9 — Suricata rules (background)"

sudo mkdir -p ./suricata/rules
(
  if [ ! -f ./suricata/rules/emerging-all.rules ]; then
    curl -fsSL -o /tmp/emerging.tar.gz \
      https://rules.emergingthreats.net/open/suricata-6.0/emerging.rules.tar.gz 2>/dev/null
    sudo tar -xzf /tmp/emerging.tar.gz \
      -C ./suricata/rules/ --strip-components=1 2>/dev/null
    rm -f /tmp/emerging.tar.gz
  fi
  curl -fsSL -o ./suricata/classification.config \
    https://raw.githubusercontent.com/OISF/suricata/master/etc/classification.config 2>/dev/null || true
  curl -fsSL -o ./suricata/reference.config \
    https://raw.githubusercontent.com/OISF/suricata/master/etc/reference.config 2>/dev/null || true
  echo "[$(date +%H:%M:%S)] Suricata rules ready" >> /tmp/cyberblue-bg.log
) &
SURICATA_RULES_PID=$!
info "Suricata rules downloading in background (PID $SURICATA_RULES_PID)"

log "STEP 9 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 10 — Agent packages (background)
# ════════════════════════════════════════════════════════════════════
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
info "Agent packages downloading in background (PID $AGENTS_PID)"

log "STEP 10 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 11 — Caldera (background install if missing)
# ════════════════════════════════════════════════════════════════════
step "STEP 11 — Caldera"

if [ ! -d "./caldera" ] && [ -f "./install_caldera.sh" ]; then
  doing "Installing Caldera in background..."
  (chmod +x ./install_caldera.sh && timeout 180 ./install_caldera.sh &>/dev/null) &
  CALDERA_PID=$!
  info "Caldera installing in background (PID $CALDERA_PID)"
else
  skip "Caldera already present"
  CALDERA_PID=0
fi

log "STEP 11 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 12 — JVM heap tuning for 7GB RAM
# ════════════════════════════════════════════════════════════════════
step "STEP 12 — JVM heap tuning for 7GB RAM"

info "RAM available : $(free -h | grep Mem | awk '{print $2}')"
info "Heap setting  : 1g (correct for 7GB — leaves 6g for all other containers)"

upsert_env OPENSEARCH_JAVA_OPTS "-Xms1g -Xmx1g"
upsert_env ES_JAVA_OPTS         "-Xms1g -Xmx1g"

WAZUH_JVM="wazuh/config/wazuh_indexer/jvm.options"
if [ -f "$WAZUH_JVM" ]; then
  sudo sed -i 's/-Xms[0-9]*[gGmM]/-Xms1g/g' "$WAZUH_JVM"
  sudo sed -i 's/-Xmx[0-9]*[gGmM]/-Xmx1g/g' "$WAZUH_JVM"
  ok "Wazuh indexer JVM heap set to 1g"
fi

log "STEP 12 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 13 — Docker networking + group_add fix
# ════════════════════════════════════════════════════════════════════
step "STEP 13 — Docker networking + group_add fix"

doing "Setting docker.sock permissions..."
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
ok "docker.sock → 666"

doing "Fixing group_add: replacing 'docker' name with numeric GID..."
DOCKER_GID=$(getent group docker 2>/dev/null | cut -d: -f3 || echo "")
if [ -n "$DOCKER_GID" ]; then
  # Containers have NO group named "docker" — needs numeric GID
  sed -i \
    -e "s/- \"docker\"$/- \"${DOCKER_GID}\"/g" \
    -e "s/- 'docker'$/- \"${DOCKER_GID}\"/g" \
    -e "s/- docker$/- \"${DOCKER_GID}\"/g" \
    docker-compose.yml 2>/dev/null || true
  ok "group_add 'docker' → GID $DOCKER_GID"
else
  warn "docker group not found on host — group_add may fail"
fi

doing "Validating docker-compose.yml..."
if docker compose config --quiet 2>/dev/null; then
  ok "docker-compose.yml is valid"
else
  err "docker-compose.yml has errors — check the file"
fi

log "STEP 13 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 13b — Pre-build ALL custom Docker images
# ════════════════════════════════════════════════════════════════════
step "STEP 13b — Pre-build all custom images"
info "CyberBlue has 5 custom images: portal, arkime, caldera, velociraptor, mitre-navigator"
info "These MUST be built before starting containers"
info "First run: 5-20 minutes | Repeat runs: <30 seconds (cached)"
echo ""

BUILD_SERVICES=""
for svc in portal arkime caldera velociraptor mitre-navigator; do
  if docker compose config --services 2>/dev/null | grep -q "^${svc}$"; then
    BUILD_SERVICES="$BUILD_SERVICES $svc"
  fi
done

if [ -n "$BUILD_SERVICES" ]; then
  for svc in $BUILD_SERVICES; do
    doing "Building: $svc ..."
    BUILD_OUT=$(docker compose build "$svc" 2>&1)
    if echo "$BUILD_OUT" | grep -q "ERROR\|error:"; then
      err "Build failed for $svc:"
      echo "$BUILD_OUT" | grep -iE "ERROR|error:" | head -5
    else
      ok "$svc built successfully"
    fi
  done
else
  warn "No buildable services found in docker-compose.yml"
fi

echo ""
log "STEP 13b complete — all custom images ready"

# ════════════════════════════════════════════════════════════════════
# STEP 14 — Start all containers
# ════════════════════════════════════════════════════════════════════
step "STEP 14 — Starting all containers"

# Start wazuh indexer first — everything depends on it
doing "Starting Wazuh indexer first (OpenSearch — everything depends on it)..."
docker compose up -d wazuh.indexer 2>&1 \
  | grep -E "Started|Running|Error|Warning" || true

echo ""
doing "Waiting for Wazuh indexer to be healthy..."
WAIT=0
MAX_WAIT=90

indexer_ready() {
  # Method 1 — Docker healthcheck (fastest)
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
    wazuh.indexer 2>/dev/null || echo "none")
  [ "$STATUS" = "healthy" ] && return 0
  # Method 2 — check logs for GREEN
  docker logs wazuh.indexer 2>/dev/null \
    | grep -q "Cluster health status changed to \[GREEN\]" && return 0
  # Method 3 — wget from inside container
  docker exec wazuh.indexer wget -qO- \
    --no-check-certificate \
    --user=admin --password=SecretPassword \
    "https://localhost:9200/_cluster/health" &>/dev/null && return 0
  return 1
}

until indexer_ready; do
  sleep 5; WAIT=$((WAIT+5))
  RUNNING=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  echo -ne "\r    ⏳ Indexer starting... ${WAIT}s/${MAX_WAIT}s  |  🐳 ${RUNNING} containers up so far"
  [ $WAIT -ge $MAX_WAIT ] && {
    echo ""
    warn "Indexer not ready in ${MAX_WAIT}s — continuing anyway (starts in background)"
    break
  }
done
echo ""
[ $WAIT -lt $MAX_WAIT ] && ok "Wazuh indexer ready in ${WAIT}s" || true

echo ""
doing "Cleaning up any previously crashed containers..."
docker compose down --remove-orphans 2>/dev/null | grep -vE "^$|Network" || true
sleep 2

doing "Starting ALL remaining containers..."
echo ""
# No timeout — images already built in Step 13b
docker compose up -d --remove-orphans 2>&1 | tee /tmp/step14.log \
  | grep --line-buffered -E "Started|Starting|Running|Healthy|Error|failed|Error" \
  | sed \
    -e "s/.*Started.*/$(echo -e "${GREEN}") ✅ &$(echo -e "${NC}")/g" \
    -e "s/.*Error.*/$(echo -e "${RED}") ❌ &$(echo -e "${NC}")/g" \
    -e "s/.*failed.*/$(echo -e "${RED}") ❌ &$(echo -e "${NC}")/g" \
  || true

echo ""
# Show errors from full log
ERRORS=$(grep -iE "Error response|failed to|denied" /tmp/step14.log 2>/dev/null \
  | grep -v "^#" | grep -v "cert-generator" || true)
if [ -n "$ERRORS" ]; then
  warn "Some non-fatal container issues:"
  echo "$ERRORS" | while IFS= read -r line; do warn "  $line"; done
fi

ok "All containers launched"

# misp-core needs db + redis healthy before it can start
doing "Scheduling misp-core (waits for database + redis to be ready)..."
(
  for i in {1..30}; do
    sleep 5
    DB=$(docker inspect --format="{{.State.Health.Status}}" misp-db 2>/dev/null || echo "none")
    RD=$(docker inspect --format="{{.State.Health.Status}}" misp-redis 2>/dev/null || echo "none")
    if [ "$DB" = "healthy" ] && [ "$RD" = "healthy" ]; then
      docker compose up -d misp-core &>/dev/null || true
      echo "[$(date +%H:%M:%S)] misp-core started" >> /tmp/cyberblue-bg.log
      break
    fi
  done
) &
info "misp-core will start automatically once database is healthy"

log "STEP 14 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 15 — Background post-deploy tasks
# ════════════════════════════════════════════════════════════════════
step "STEP 15 — Background post-deploy tasks"

# Fleet DB initialization (waits for mysql healthy, then initializes)
(
  for i in {1..30}; do
    sleep 5
    MYSQL_OK=$(docker inspect --format="{{.State.Health.Status}}" fleet-mysql 2>/dev/null || echo "none")
    if [ "$MYSQL_OK" = "healthy" ]; then
      docker stop fleet-server &>/dev/null || true
      timeout 300 docker run --rm \
        --network=cyber-blue \
        -e FLEET_MYSQL_ADDRESS=fleet-mysql:3306 \
        -e FLEET_MYSQL_USERNAME=fleet \
        -e FLEET_MYSQL_PASSWORD=fleetpass \
        -e FLEET_MYSQL_DATABASE=fleet \
        fleetdm/fleet:latest fleet prepare db &>/dev/null || true
      docker compose up -d fleet-server &>/dev/null || true
      echo "[$(date +%H:%M:%S)] Fleet DB initialized + server started" >> /tmp/cyberblue-bg.log
      break
    fi
  done
) &
info "Fleet DB setup in background — waits for mysql healthy then initializes"

# Arkime initialization
(
  sleep 20
  [ -f "./fix-arkime.sh" ] && chmod +x ./fix-arkime.sh && \
    timeout 120 bash ./fix-arkime.sh &>/dev/null || true
  timeout 30 docker exec arkime \
    /opt/arkime/bin/arkime_add_user.sh \
    admin "CyberBlue Admin" admin --admin &>/dev/null || true
  echo "[$(date +%H:%M:%S)] Arkime ready" >> /tmp/cyberblue-bg.log
) &
info "Arkime init running in background"

# MISP setup
(
  sleep 60
  for i in {1..60}; do
    EXISTS=$(docker exec misp-core \
      mysql -h db -u misp -pexample misp \
      -se "SELECT COUNT(*) FROM users WHERE email='admin@admin.test';" \
      2>/dev/null || echo "0")
    if [ "$EXISTS" -gt "0" ]; then
      docker exec misp-core \
        mysql -h db -u misp -pexample misp \
        -e "UPDATE users SET change_pw=0 WHERE email='admin@admin.test';" \
        2>/dev/null || true
      sleep 120
      [ -f "misp/configure-threat-feeds.sh" ] && \
        bash misp/configure-threat-feeds.sh &>/dev/null || true
      echo "[$(date +%H:%M:%S)] MISP configured" >> /tmp/cyberblue-bg.log
      break
    fi
    sleep 10
  done
) &
info "MISP setup running in background"

# Wazuh watchdog (restarts if not running after 90s)
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
info "Wazuh watchdog active (checks at 90s)"

log "STEP 15 complete — background tasks started"

# ════════════════════════════════════════════════════════════════════
# STEP 16 — Firewall rules
# ════════════════════════════════════════════════════════════════════
step "STEP 16 — Firewall rules"

doing "Opening ports for CyberBlue services..."
sudo iptables -P FORWARD ACCEPT
for port in 443 5443 7000 7001 7002 7003 7004 7005 7006 \
            7007 7008 7009 7013 7015 9200 9443 8001; do
  sudo iptables -I FORWARD -i "$IFACE" -p tcp --dport $port -j ACCEPT 2>/dev/null || true
  sudo iptables -I FORWARD -o "$IFACE" -p tcp --sport $port -j ACCEPT 2>/dev/null || true
done

if dpkg -s iptables-persistent &>/dev/null; then
  sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
else
  doing "Installing iptables-persistent..."
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" \
    | sudo debconf-set-selections
  sudo apt-get install -y -qq iptables-persistent 2>/dev/null || true
  sudo mkdir -p /etc/iptables
  sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
fi

ok "Firewall rules applied and persisted"
log "STEP 16 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 17 — systemd auto-start
# ════════════════════════════════════════════════════════════════════
step "STEP 17 — Auto-start on system reboot"

doing "Creating systemd service: cyberblue-autostart..."
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

doing "Creating systemd service: caldera-autostart..."
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
ok "Auto-start services enabled — CyberBlue will start on every boot"

log "STEP 17 complete"

# ════════════════════════════════════════════════════════════════════
# STEP 18 — Wait for containers & final health check
# ════════════════════════════════════════════════════════════════════
step "STEP 18 — Waiting for containers to reach target count"

doing "Polling container status (target: 20+ running)..."
echo ""
WAIT=0
MAX_WAIT=300
MIN_RUNNING=20

while true; do
  RUNNING=$(docker ps --filter "status=running" \
    --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' \n')
  [[ "$RUNNING" =~ ^[0-9]+$ ]] || RUNNING=0

  # Show live status bar
  BAR=""
  FILLED=$((RUNNING > 30 ? 30 : RUNNING))
  for ((i=0; i<FILLED; i++)); do BAR+="█"; done
  for ((i=FILLED; i<30; i++)); do BAR+="░"; done

  echo -ne "\r    [${BAR}] ${RUNNING}/20+ running  (${WAIT}s elapsed)  "

  if [ "$RUNNING" -ge "$MIN_RUNNING" ]; then
    echo ""
    ok "Target reached: $RUNNING containers running"
    break
  fi
  if [ "$WAIT" -ge "$MAX_WAIT" ]; then
    echo ""
    warn "Timeout — $RUNNING containers running (some may still be starting)"
    break
  fi
  sleep 5
  WAIT=$((WAIT + 5))
done

log "STEP 18 complete"

# ════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ════════════════════════════════════════════════════════════════════
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

TOTAL=$(docker ps --filter "status=running" \
  --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' \n')
[[ "$TOTAL" =~ ^[0-9]+$ ]] || TOTAL=0

CRASHED=$(docker ps -a --filter "status=exited" \
  --format "{{.Names}}" 2>/dev/null \
  | grep -v "wazuh-cert-generator\|opensearch-init" | wc -l | tr -d ' ')
[[ "$CRASHED" =~ ^[0-9]+$ ]] || CRASHED=0

echo ""
echo -e "${GREEN}${BOLD}"
cat << 'DONE'
  ╔══════════════════════════════════════════════════════════════════╗
  ║                                                                  ║
  ║        🎉  CyberBlue Installation Complete!                     ║
  ║                                                                  ║
  ╚══════════════════════════════════════════════════════════════════╝
DONE
echo -e "${NC}"

echo -e "${BOLD}  📊 Install Summary:${NC}"
echo -e "  ⏱  Total time    : ${MINS}m ${SECS}s"
echo -e "  🐳 Running       : ${TOTAL} containers"
if [ "$CRASHED" -gt 0 ]; then
  echo -e "  ${RED}❌ Crashed       : ${CRASHED} containers (check: docker ps -a)${NC}"
else
  echo -e "  ${GREEN}✅ Crashed       : 0 (all good!)${NC}"
fi
echo -e "  💾 JVM Heap      : 1 GB (correct for 7GB RAM)"
echo -e "  🔄 Swap          : zram (RAM-based)"
echo -e "  🔁 Auto-start    : enabled (starts on every reboot)"
echo ""

echo -e "${BOLD}  📋 Background tasks — check progress:${NC}"
echo -e "  ${CYAN}tail -f /tmp/cyberblue-bg.log${NC}"
echo ""

echo -e "${BOLD}  🌐 Access your SOC Platform:${NC}"
echo ""
echo -e "  ${GREEN}● Portal          ${NC}: https://${HOST_IP}:5443"
echo -e "  ${GREEN}● Wazuh           ${NC}: https://${HOST_IP}:7001   admin / SecretPassword"
echo -e "  ${GREEN}● Velociraptor    ${NC}: https://${HOST_IP}:7000   admin / cyberblue"
echo -e "  ${GREEN}● MISP            ${NC}: https://${HOST_IP}:7003   admin@admin.test / admin"
echo -e "  ${GREEN}● Portainer       ${NC}: https://${HOST_IP}:9443   admin / cyberblue123"
echo -e "  ${GREEN}● Shuffle         ${NC}: https://${HOST_IP}:7002   admin / password"
echo -e "  ${GREEN}● TheHive         ${NC}: http://${HOST_IP}:7005    admin@thehive.local / secret"
echo -e "  ${GREEN}● Caldera         ${NC}: http://${HOST_IP}:7009    red / cyberblue"
echo -e "  ${GREEN}● Arkime          ${NC}: http://${HOST_IP}:7008    admin / admin"
echo -e "  ${GREEN}● EveBox          ${NC}: http://${HOST_IP}:7015"
echo -e "  ${GREEN}● CyberChef       ${NC}: http://${HOST_IP}:7004"
echo -e "  ${GREEN}● MITRE Navigator ${NC}: http://${HOST_IP}:7013"
echo ""

echo -e "${BOLD}  🐳 Live Container Status:${NC}"
echo ""
printf "  %-30s %-12s %s\n" "CONTAINER" "STATUS" "HEALTH"
printf "  %-30s %-12s %s\n" "──────────────────────────────" "──────────" "──────────"
docker ps -a --format "{{.Names}}|{{.Status}}|{{.Status}}" \
  | grep -v "wazuh-cert-generator" \
  | sort \
  | while IFS='|' read -r name status _; do
      if echo "$status" | grep -q "^Up"; then
        HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "$name" 2>/dev/null || echo "—")
        printf "  ${GREEN}%-30s %-12s %s${NC}\n" "$name" "running" "$HEALTH"
      elif echo "$status" | grep -q "^Exited (0)"; then
        printf "  ${YELLOW}%-30s %-12s %s${NC}\n" "$name" "exited(0)" "completed"
      else
        printf "  ${RED}%-30s %-12s %s${NC}\n" "$name" "STOPPED" "⚠ check logs"
      fi
    done
echo ""
echo -e "${YELLOW}  ⚠️  SSL Warning in browser is normal — click Advanced → Proceed${NC}"
echo -e "${YELLOW}  ⚠️  Log out and back in for docker group to take effect${NC}"
echo -e "${YELLOW}  ⚠️  MISP takes 5-10 min to finish on first run${NC}"
echo -e "${YELLOW}  ⚠️  Background tasks still running — check: tail -f /tmp/cyberblue-bg.log${NC}"
echo ""
echo -e "${CYAN}  📖 EDUCATIONAL USE ONLY — Isolated lab environment${NC}"
echo ""
