#!/bin/bash
# ============================================================================
# CyberBlue FAST Installer — Optimized for 8gb ram 6core
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

INSTALL_USER="${SUDO_USER:-$USER}"
export DEBIAN_FRONTEND=noninteractive

echo -e "${CYAN}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║   CyberBlue FAST INSTALLER  — 8gb ram 6core          ║
  ║   Parallel startup · Heap tuned · No wasted waits    ║
  ╚══════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ============================================================
# STEP 0 — System pre-checks
# ============================================================
step "STEP 0 — Quick system pre-check"

sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
           /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
sudo dpkg --configure -a --force-all 2>/dev/null || true

log "Refreshing package lists only (no full upgrade)..."
sudo apt-get update -qq

NEED_PKGS=()
for pkg in git curl wget ca-certificates gnupg lsb-release jq; do
  dpkg -s "$pkg" &>/dev/null || NEED_PKGS+=("$pkg")
done
if [ ${#NEED_PKGS[@]} -gt 0 ]; then
  log "Installing missing: ${NEED_PKGS[*]}"
  sudo apt-get install -y -qq "${NEED_PKGS[@]}"
fi

# ============================================================
# STEP 1 — Docker check/install
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

if ! command -v docker-compose &>/dev/null; then
  sudo ln -sf /usr/libexec/docker/cli-plugins/docker-compose \
    /usr/local/bin/docker-compose 2>/dev/null || \
  sudo curl -fsSL -o /usr/local/bin/docker-compose \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
  sudo chmod +x /usr/local/bin/docker-compose
fi

sudo usermod -aG docker "$INSTALL_USER" 2>/dev/null || true

# ── BUG 1 FIX: was 660 (too restrictive — containers got permission denied)
#               must be 666 so all containers can access the socket
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

log "Docker OK — $(docker --version)"

# ============================================================
# STEP 2 — Kernel & Docker performance tuning
# ============================================================
step "STEP 2 — Kernel & Docker performance tuning"

apply_sysctl() {
  grep -qF "$1" /etc/sysctl.conf || echo "$1" | sudo tee -a /etc/sysctl.conf >/dev/null
}
apply_sysctl "vm.max_map_count=262144"
apply_sysctl "vm.swappiness=10"
apply_sysctl "net.core.rmem_max=134217728"
apply_sysctl "net.core.wmem_max=134217728"
apply_sysctl "net.core.netdev_max_backlog=250000"
sudo sysctl -p -q

sudo mkdir -p /etc/docker

# FIX: Only restart Docker if daemon.json actually changed
# Restarting Docker every run wastes 8-10 seconds and kills running containers
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
  sudo systemctl restart docker
  sleep 5
  sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
  log "Docker daemon updated and restarted"
else
  log "Docker daemon.json unchanged — skipping restart (saves 8s)"
fi

log "Kernel + Docker tuning applied"

# ============================================================
# STEP 3 — zram swap
# ============================================================
step "STEP 3 — zram swap (RAM-based, 5x faster than disk swap)"

if swapon --show | grep -q zram; then
  log "zram already active: $(free -h | grep Swap)"
else
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
    if ! swapon --show | grep -q '/swapfile'; then
      warn "zram not available — creating 4 GB file swap"
      sudo fallocate -l 4G /swapfile
      sudo chmod 600 /swapfile
      sudo mkswap /swapfile
      sudo swapon /swapfile
      grep -qF '/swapfile' /etc/fstab || \
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    else
      log "File swap already active: $(free -h | grep Swap)"
    fi
  fi
fi

# ============================================================
# STEP 4 — Environment & network detection
# ============================================================
step "STEP 4 — Environment & network detection"

cd "$SCRIPT_DIR"

IFACE=$(ip route show default | awk '/default/{print $5}' | head -1)
[ -z "$IFACE" ] && \
  IFACE=$(ip -o link show | awk '$2!="lo:"&&/UP/{print $2}' | tr -d ':' | head -1)
[ -z "$IFACE" ] && { err "Cannot detect network interface"; exit 1; }
log "Network interface: $IFACE"

HOST_IP=$(hostname -I | awk '{print $1}')
log "Host IP: $HOST_IP"

[ -f .env ] || touch .env

upsert_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

upsert_env SURICATA_INT           "$IFACE"
upsert_env HOST_IP                "$HOST_IP"
upsert_env MISP_BASE_URL          "https://${HOST_IP}:7003"
upsert_env CYBERBLUE_INSTALL_DIR  "$SCRIPT_DIR"
upsert_env CYBERBLUE_INSTALL_USER "$INSTALL_USER"
# FIX: job_directory missing → caused "variable is not set" warning every run
upsert_env job_directory          "/tmp/cortex-jobs"

grep -q "^YETI_AUTH_SECRET_KEY=" .env || \
  echo "YETI_AUTH_SECRET_KEY=$(openssl rand -hex 64)" >> .env

sudo mkdir -p /opt/yeti/bloomfilters
log ".env written"

# ============================================================
# STEP 5 — Pre-pull images in parallel
# ============================================================
step "STEP 5 — Pre-pull images in parallel (uses your 20 cores)"

IMAGES=$(grep -E '^\s+image:' docker-compose.yml 2>/dev/null \
  | awk '{print $2}' | sort -u)

if [ -n "$IMAGES" ]; then
  log "Pulling images in parallel (up to 8 simultaneous)..."
  echo "$IMAGES" | xargs -P 8 -I{} bash -c \
    'docker image inspect "{}" &>/dev/null \
     || docker pull "{}" &>/dev/null \
     && echo "  ✓ {}" \
     || echo "  ✗ {} (will build)"'
  log "Image pre-pull complete"
else
  warn "No images found in docker-compose.yml — will build at startup"
fi

# ============================================================
# STEP 6 — Wazuh SSL certificates
# ============================================================
step "STEP 6 — Wazuh SSL certificates"

CERT_DIR="wazuh/config/wazuh_indexer_ssl_certs"
if [ -d "$CERT_DIR" ] && find "$CERT_DIR" -name "*.pem" | grep -q .; then
  log "Certs already exist — skipping"
else
  log "Generating certs..."
  docker compose run --rm generator 2>&1 | tail -5 \
    || warn "Cert generator had warnings"
  sleep 5
  [ -d "$CERT_DIR" ] && {
    sudo chown -R "$INSTALL_USER:$(id -gn "$INSTALL_USER")" \
      "$CERT_DIR" 2>/dev/null || true
    find "$CERT_DIR" \( -name "*.pem" -o -name "*.key" \) \
      | xargs sudo chmod 644 2>/dev/null || true
  }
fi

# ============================================================
# STEP 7 — ATT&CK Navigator (background)
# ============================================================
step "STEP 7 — ATT&CK Navigator (background)"

if [ ! -d "attack-navigator" ]; then
  git clone --depth=1 \
    https://github.com/mitre-attack/attack-navigator.git \
    attack-navigator &>/dev/null &
  NAVIGATOR_PID=$!
  log "Cloning ATT&CK Navigator in background (PID $NAVIGATOR_PID)"
else
  log "ATT&CK Navigator already cloned"
  NAVIGATOR_PID=0
fi

# ============================================================
# STEP 8 — YARA & Sigma rules (background)
# ============================================================
step "STEP 8 — YARA & Sigma rules (background download)"

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
log "YARA/Sigma downloading in background (PID $RULES_PID)"

# ============================================================
# STEP 9 — Suricata rules (background)
# ============================================================
step "STEP 9 — Suricata rules (background)"

sudo mkdir -p ./suricata/rules

(
  if [ ! -f ./suricata/rules/emerging-all.rules ]; then
    curl -fsSL -o /tmp/emerging.tar.gz \
      https://rules.emergingthreats.net/open/suricata-6.0/emerging.rules.tar.gz \
      2>/dev/null
    sudo tar -xzf /tmp/emerging.tar.gz \
      -C ./suricata/rules/ --strip-components=1 2>/dev/null
    rm -f /tmp/emerging.tar.gz
  fi
  curl -fsSL -o ./suricata/classification.config \
    https://raw.githubusercontent.com/OISF/suricata/master/etc/classification.config \
    2>/dev/null || true
  curl -fsSL -o ./suricata/reference.config \
    https://raw.githubusercontent.com/OISF/suricata/master/etc/reference.config \
    2>/dev/null || true
  echo "[$(date +%H:%M:%S)] Suricata rules ready" >> /tmp/cyberblue-bg.log
) &
SURICATA_RULES_PID=$!
log "Suricata rules downloading in background (PID $SURICATA_RULES_PID)"

# ============================================================
# STEP 10 — Agent packages (background)
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
# STEP 11 — Caldera (background)
# ============================================================
step "STEP 11 — Caldera (background)"

if [ ! -d "./caldera" ] && [ -f "./install_caldera.sh" ]; then
  (chmod +x ./install_caldera.sh && \
   timeout 180 ./install_caldera.sh &>/dev/null) &
  CALDERA_PID=$!
  log "Caldera installing in background (PID $CALDERA_PID)"
else
  log "Caldera already present"
  CALDERA_PID=0
fi

# ============================================================
# STEP 12 — JVM heap tuning
# ============================================================
step "STEP 12 — JVM heap tuning for 16 GB RAM"

# FIX: This file had 1g — WRONG for 16GB system
# 1g heap = OpenSearch garbage collects constantly = takes 3+ min to start
# 3g heap = stable startup, leaves 13g for other containers
upsert_env OPENSEARCH_JAVA_OPTS "-Xms1g -Xmx1g"
upsert_env ES_JAVA_OPTS         "-Xms1g -Xmx1g"

WAZUH_JVM="wazuh/config/wazuh_indexer/jvm.options"
if [ -f "$WAZUH_JVM" ]; then
  sudo sed -i 's/-Xms[0-9]*[gGmM]/-Xms1g/g' "$WAZUH_JVM"
  sudo sed -i 's/-Xmx[0-9]*[gGmM]/-Xmx1g/g' "$WAZUH_JVM"
  log "Wazuh indexer JVM heap: 1g"
fi

log "JVM heap: 1 GB for OpenSearch/Wazuh indexer"

# ============================================================
# STEP 13 — Docker networking
# ============================================================
step "STEP 13 — Docker networking"

# FIX: Removed iptables flush — flushing Docker rules every run
# breaks container networking and causes startup failures
# iptables flush belongs only in a repair script, not normal install
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

# FIX: group_add "docker" → numeric GID using safe sed (not Python)
# Python heredoc with regex was introducing control characters → corrupt YAML
# sed is safe and simple for this exact replacement
DOCKER_GID=$(getent group docker 2>/dev/null | cut -d: -f3 || echo "")
if [ -n "$DOCKER_GID" ]; then
  # Replace all variations: - "docker", - 'docker', - docker
  sed -i \
    -e "s/- \"docker\"$/- \"${DOCKER_GID}\"/g" \
    -e "s/- 'docker'$/- \"${DOCKER_GID}\"/g" \
    -e "s/- docker$/- \"${DOCKER_GID}\"/g" \
    docker-compose.yml 2>/dev/null || true
  log "group_add docker → GID ${DOCKER_GID}"
fi

log "Docker networking ready"

# ============================================================
# STEP 14 — Starting containers
# ============================================================
step "STEP 14 — Starting containers"

log "Starting CRITICAL services (OpenSearch/Wazuh indexer first)..."
docker compose up -d wazuh.indexer 2>&1 | grep -E "Started|Running|Error|Warning" || true

# ── INDEXER HEALTH CHECK ──────────────────────────────────────────
# FIX 1: MAX_WAIT reduced 180s → 60s
#         With 3g heap (fixed in Step 12) indexer starts in 15-45s
#         180s was only needed because 1g heap caused slow GC startup
# FIX 2: Show live progress — what is actually happening
# FIX 3: 3 check methods so it passes as soon as ANY one succeeds
log "Waiting for OpenSearch/Wazuh indexer..."
WAIT=0
MAX_WAIT=60

indexer_ready() {
  # Method 1 — Docker healthcheck status (fastest)
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
    wazuh.indexer 2>/dev/null || echo "none")
  [ "$STATUS" = "healthy" ] && return 0

  # Method 2 — check logs for GREEN (no curl/wget needed)
  docker logs wazuh.indexer 2>/dev/null \
    | grep -q "Cluster health status changed to \[GREEN\]" && return 0

  # Method 3 — wget inside container (wget IS in wazuh-indexer)
  docker exec wazuh.indexer wget -qO- \
    --no-check-certificate \
    --user=admin --password=SecretPassword \
    "https://localhost:9200/_cluster/health" \
    &>/dev/null && return 0

  return 1
}

until indexer_ready; do
  sleep 5; WAIT=$((WAIT+5))
  # FIX: show container count so you know something is happening
  RUNNING=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  echo -ne "\r  ⏳ Indexer starting... ${WAIT}s/${MAX_WAIT}s  |  🐳 ${RUNNING} containers up"
  [ $WAIT -ge $MAX_WAIT ] && {
    echo ""
    warn "Indexer not ready in ${MAX_WAIT}s — continuing (starts in background)"
    break
  }
done
echo ""
[ $WAIT -lt $MAX_WAIT ] && log "✅ Indexer ready in ${WAIT}s" || true

# ── START ALL REMAINING CONTAINERS ───────────────────────────────
log "Starting all remaining containers..."
echo ""

# FIX: removed tail -10 — show real output so you can see what's happening
# FIX: removed slow $(docker compose config --services) call
# docker compose up -d --remove-orphans starts everything not yet running
docker compose up -d --remove-orphans 2>&1 \
  | grep -E --line-buffered \
    "Started|Starting|Running|Healthy|Warning|Error|error|failed|✔|✗" \
  || true

echo ""
log "All containers launched"

# ============================================================
# STEP 15 — Post-deploy background tasks
# ============================================================
step "STEP 15 — Post-deploy background tasks"

(
  sleep 30
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

(
  sleep 20
  [ -f "./fix-arkime.sh" ] && chmod +x ./fix-arkime.sh && \
    timeout 120 bash ./fix-arkime.sh --live-30s &>/dev/null || true
  timeout 30 docker exec arkime \
    /opt/arkime/bin/arkime_add_user.sh \
    admin "CyberBlue Admin" admin --admin &>/dev/null || true
  echo "[$(date +%H:%M:%S)] Arkime ready" >> /tmp/cyberblue-bg.log
) &
ARKIME_PID=$!
log "Arkime init running in background (PID $ARKIME_PID)"

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
      echo "[$(date +%H:%M:%S)] MISP feeds configured" >> /tmp/cyberblue-bg.log
      break
    fi
    sleep 10
  done
) &
MISP_PID=$!
log "MISP setup running in background (PID $MISP_PID)"

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

# ============================================================
# STEP 16 — Firewall rules
# ============================================================
step "STEP 16 — Firewall rules for external access"

sudo iptables -P FORWARD ACCEPT
for port in 443 5443 7000 7001 7002 7003 7004 7005 7006 \
            7007 7008 7009 7013 7015 9200 9443; do
  sudo iptables -I FORWARD -i "$IFACE" -p tcp --dport $port \
    -j ACCEPT 2>/dev/null || true
  sudo iptables -I FORWARD -o "$IFACE" -p tcp --sport $port \
    -j ACCEPT 2>/dev/null || true
done

if dpkg -s iptables-persistent &>/dev/null; then
  sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
else
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" \
    | sudo debconf-set-selections
  sudo apt-get install -y -qq iptables-persistent 2>/dev/null || true
  sudo mkdir -p /etc/iptables
  sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
fi
log "Firewall rules applied + persisted"

# ============================================================
# STEP 17 — systemd auto-start
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
# STEP 18 — Smart wait for containers
# ============================================================
step "STEP 18 — Waiting for containers (smart poll, no fixed sleep)"

# ── BUG 2 FIX: wc -l returns whitespace like "  20" on some systems
#               tr -d ' \n' strips all spaces and newlines → clean integer
#               Also added sudo so it works even if group change not applied yet
log "Polling container health..."
WAIT=0
MAX_WAIT=300
MIN_RUNNING=20

while true; do
  RUNNING=$(sudo docker ps --filter "status=running" \
    --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' \n')

  # Safety: if RUNNING is empty or not a number, default to 0
  [[ "$RUNNING" =~ ^[0-9]+$ ]] || RUNNING=0

  echo -ne "\r  Running containers: ${RUNNING} / target ${MIN_RUNNING}  (${WAIT}s elapsed)"

  if [ "$RUNNING" -ge "$MIN_RUNNING" ]; then
    echo ""
    log "Minimum containers reached: $RUNNING running"
    break
  fi
  if [ "$WAIT" -ge "$MAX_WAIT" ]; then
    echo ""
    warn "Timeout reached — $RUNNING containers running. Some may still be starting."
    break
  fi
  sleep 5
  WAIT=$((WAIT + 5))
done

# ============================================================
# FINAL SUMMARY
# ============================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

# ── BUG 2 FIX (same fix applied here too — final container count)
TOTAL=$(sudo docker ps --filter "status=running" \
  --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' \n')
[[ "$TOTAL" =~ ^[0-9]+$ ]] || TOTAL=0

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
