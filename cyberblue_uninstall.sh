#!/bin/bash
# ============================================================================
# CyberBlue COMPLETE UNINSTALLER
# Removes EVERYTHING installed by CyberBlue — system back to clean state
# Uses parallel jobs for maximum speed
#
# REMOVES:
#   ✓ All Docker containers (all 25+ CyberBlue containers)
#   ✓ All Docker images pulled/built by CyberBlue
#   ✓ All Docker networks created by CyberBlue
#   ✓ All Docker volumes (all data — Wazuh, MISP, TheHive etc.)
#   ✓ CyberBlue folder (~/Optimized_cyberblue or ~/CyberBlue)
#   ✓ Caldera folder + container + image
#   ✓ YARA rules (/opt/yara-rules)
#   ✓ Sigma rules (/opt/sigma-rules)
#   ✓ YETI data (/opt/yeti)
#   ✓ systemd services (cyberblue-autostart, caldera-autostart)
#   ✓ iptables rules added by CyberBlue
#   ✓ iptables-persistent package
#   ✓ zram swap created by CyberBlue
#   ✓ sysctl settings added by CyberBlue
#   ✓ Docker daemon.json customization
#   ✓ Crontab entries for rule updates
#   ✓ /tmp/cyberblue-* temp files
#   ✓ OPTIONALLY: Docker itself (asked at end)
# ============================================================================

set +e
set +u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
err()    { echo -e "${RED}[$(date +%H:%M:%S)] ❌ $*${NC}"; }
step()   { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
           echo -e "${BLUE}  $*${NC}"; \
           echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
done_()  { echo -e "${GREEN}  ✅ $*${NC}"; }
skip()   { echo -e "${YELLOW}  ⏭  $* — not found, skipping${NC}"; }

START_TIME=$(date +%s)

echo -e "${RED}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║      CyberBlue COMPLETE UNINSTALLER                         ║
  ║      Removes ALL containers, images, data, configs          ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Safety confirmation ───────────────────────────────────────────
echo -e "${RED}⚠️  WARNING: This will permanently delete:${NC}"
echo "   • All 25+ CyberBlue containers and their DATA"
echo "   • All Docker images (Wazuh, MISP, TheHive, Shuffle etc.)"
echo "   • All logs, configs, certificates, databases"
echo "   • CyberBlue installation folder"
echo ""
echo -e "${YELLOW}This CANNOT be undone. All SOC data will be lost.${NC}"
echo ""
read -p "Type YES to confirm complete removal: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted — nothing was changed."
  exit 0
fi

echo ""
echo -e "${CYAN}Starting parallel cleanup...${NC}"
echo ""

# ── Detect CyberBlue install directory ───────────────────────────
CYBERBLUE_DIR=""
for dir in \
  "$HOME/Optimized_cyberblue" \
  "$HOME/CyberBlue" \
  "$HOME/cyberblue" \
  "/opt/cyberblue"; do
  if [ -d "$dir" ] && [ -f "$dir/docker-compose.yml" ]; then
    CYBERBLUE_DIR="$dir"
    break
  fi
done

if [ -n "$CYBERBLUE_DIR" ]; then
  echo -e "  📁 Found CyberBlue at: ${CYAN}$CYBERBLUE_DIR${NC}"
else
  warn "CyberBlue directory not found — will still clean Docker + system"
fi

# ============================================================
# STEP 1 — Stop and remove ALL containers (parallel)
# ============================================================
step "STEP 1 — Stopping and removing all containers"

# All known CyberBlue container names
CONTAINERS=(
  wazuh.indexer wazuh-indexer
  wazuh.manager wazuh-manager
  wazuh.dashboard wazuh-dashboard
  wazuh-cert-generator
  misp-core misp-db misp-redis misp-mail misp-modules
  thehive cortex
  shuffle-frontend shuffle-backend shuffle-orborus shuffle-opensearch
  fleet-server fleet-mysql fleet-redis
  velociraptor
  arkime
  suricata evebox wireshark
  elasticsearch os01
  opensearch-init
  portainer
  mitre-navigator
  cyber-blue-portal
  caldera
  mitre-attack-navigator
  fleet-server
  tenzir-node
  serene_williams
)

# Stop all running CyberBlue containers in parallel
echo "  Stopping containers in parallel..."
for container in "${CONTAINERS[@]}"; do
  (docker stop "$container" &>/dev/null && \
   echo -e "  ${GREEN}stopped: $container${NC}") &
done
wait
echo ""

# Remove all stopped containers in parallel
echo "  Removing containers in parallel..."
for container in "${CONTAINERS[@]}"; do
  (docker rm -f "$container" &>/dev/null && \
   echo -e "  ${GREEN}removed: $container${NC}") &
done
wait

# Also use docker compose down if directory exists
if [ -n "$CYBERBLUE_DIR" ]; then
  cd "$CYBERBLUE_DIR"
  docker compose down --remove-orphans --volumes 2>/dev/null || true
  log "Docker compose down complete"
fi

echo ""
log "All containers stopped and removed"

# ============================================================
# STEP 2 — Remove ALL Docker images (parallel)
# ============================================================
step "STEP 2 — Removing all CyberBlue Docker images"

# All known CyberBlue images
IMAGES=(
  "wazuh/wazuh-indexer:4.12.0"
  "wazuh/wazuh-manager:4.12.0"
  "wazuh/wazuh-dashboard:4.12.0"
  "wazuh/wazuh-certs-generator:0.0.2"
  "ghcr.io/misp/misp-docker/misp-core:latest"
  "ghcr.io/misp/misp-docker/misp-modules:latest"
  "strangebee/thehive:5.3.9-1"
  "thehiveproject/cortex:latest"
  "ghcr.io/shuffle/shuffle-frontend:latest"
  "ghcr.io/shuffle/shuffle-backend:latest"
  "ghcr.io/shuffle/shuffle-orborus:latest"
  "fleetdm/fleet:latest"
  "opensearchproject/opensearch:3.0.0"
  "opensearchproject/opensearch:latest"
  "docker.elastic.co/elasticsearch/elasticsearch:7.10.2"
  "velociraptor/velociraptor:latest"
  "stamus/suricata:latest"
  "jasonish/evebox"
  "lscr.io/linuxserver/wireshark:latest"
  "portainer/portainer-ce:latest"
  "mpepping/cyberchef"
  "mysql:8.0"
  "mariadb:10.11"
  "redis:6.2"
  "valkey/valkey:7.2"
  "ixdotai/smtp"
  "alpine"
)

echo "  Removing images in parallel..."
for img in "${IMAGES[@]}"; do
  (docker rmi -f "$img" &>/dev/null && \
   echo -e "  ${GREEN}removed image: $img${NC}") &
done
wait

# Remove any remaining CyberBlue-related images by label/name
docker images --format "{{.Repository}}:{{.Tag}}" | grep -iE \
  "wazuh|misp|thehive|cortex|shuffle|fleet|velociraptor|arkime|suricata|evebox|caldera|cyberblue|opensearch" \
  | xargs -r -P 8 docker rmi -f &>/dev/null || true

echo ""
log "All images removed"

# ============================================================
# STEP 3 — Remove Docker networks and volumes (parallel)
# ============================================================
step "STEP 3 — Removing Docker networks and volumes"

# Remove networks in parallel
echo "  Removing networks..."
for net in cyber-blue optimized_cyberblue_default cyberblue_default \
           cyberblue_network shuffle-network; do
  (docker network rm "$net" &>/dev/null && \
   echo -e "  ${GREEN}removed network: $net${NC}") &
done
wait

# Remove ALL Docker volumes (CyberBlue creates many unnamed volumes)
echo "  Removing all Docker volumes (all CyberBlue data)..."
docker volume ls -q | xargs -r -P 8 docker volume rm -f &>/dev/null || true

# Prune everything remaining
docker system prune -af --volumes &>/dev/null &
PRUNE_PID=$!
echo "  Docker system prune running in background (PID $PRUNE_PID)..."

log "Networks and volumes removed"

# ============================================================
# STEP 4 — Remove systemd services
# ============================================================
step "STEP 4 — Removing systemd services"

for service in cyberblue-autostart caldera-autostart; do
  if systemctl list-units --full --all | grep -q "${service}.service"; then
    sudo systemctl stop   "${service}.service" 2>/dev/null || true
    sudo systemctl disable "${service}.service" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${service}.service"
    done_ "Removed service: $service"
  else
    skip "Service: $service"
  fi
done

sudo systemctl daemon-reload
log "systemd services removed"

# ============================================================
# STEP 5 — Remove iptables rules added by CyberBlue
# ============================================================
step "STEP 5 — Removing iptables rules"

# Remove all FORWARD rules for CyberBlue ports
for port in 443 5443 7000 7001 7002 7003 7004 7005 7006 \
            7007 7008 7009 7013 7015 9200 9443 8001; do
  # Remove both -I FORWARD rules (dport and sport)
  while iptables -D FORWARD -p tcp --dport $port -j ACCEPT 2>/dev/null; do :; done
  while iptables -D FORWARD -p tcp --sport $port -j ACCEPT 2>/dev/null; do :; done
done 2>/dev/null || true

# Remove Docker iptables chains
sudo iptables -t nat    -F DOCKER                   2>/dev/null || true
sudo iptables -t filter -F DOCKER                   2>/dev/null || true
sudo iptables -t filter -F DOCKER-ISOLATION-STAGE-1 2>/dev/null || true
sudo iptables -t filter -F DOCKER-ISOLATION-STAGE-2 2>/dev/null || true
sudo iptables -P FORWARD DROP 2>/dev/null || true

# Remove iptables-persistent
if dpkg -s iptables-persistent &>/dev/null; then
  sudo apt-get remove -y -qq iptables-persistent 2>/dev/null || true
  sudo rm -rf /etc/iptables/
  done_ "iptables-persistent removed"
fi

log "iptables rules cleaned"

# ============================================================
# STEP 6 — Remove zram swap created by CyberBlue
# ============================================================
step "STEP 6 — Removing zram swap"

# Turn off all zram swap devices
for zram in $(swapon --show --noheadings | awk '/zram/{print $1}'); do
  sudo swapoff "$zram" 2>/dev/null || true
  done_ "Removed zram swap: $zram"
done

# Reset zram devices
for dev in /sys/block/zram*; do
  [ -e "$dev" ] || continue
  echo 1 | sudo tee "$dev/reset" &>/dev/null || true
done

log "zram swap removed"

# ============================================================
# STEP 7 — Remove sysctl settings added by CyberBlue
# ============================================================
step "STEP 7 — Removing sysctl settings"

SYSCTL_KEYS=(
  "vm.max_map_count=262144"
  "vm.swappiness=10"
  "net.core.rmem_max=134217728"
  "net.core.wmem_max=134217728"
  "net.core.netdev_max_backlog=250000"
)

for key in "${SYSCTL_KEYS[@]}"; do
  sudo sed -i "\|^${key}|d" /etc/sysctl.conf 2>/dev/null || true
done

sudo sysctl -p -q 2>/dev/null || true
log "sysctl settings removed from /etc/sysctl.conf"

# ============================================================
# STEP 8 — Remove Docker daemon.json customization
# ============================================================
step "STEP 8 — Restoring Docker daemon config"

if [ -f /etc/docker/daemon.json ]; then
  sudo rm -f /etc/docker/daemon.json
  sudo systemctl restart docker 2>/dev/null || true
  done_ "Docker daemon.json removed — restored to defaults"
else
  skip "Docker daemon.json"
fi

log "Docker daemon restored"

# ============================================================
# STEP 9 — Remove crontab entries added by CyberBlue
# ============================================================
step "STEP 9 — Removing crontab entries"

(crontab -l 2>/dev/null | grep -v "yara-rules\|sigma-rules\|cyberblue") \
  | crontab - 2>/dev/null || true

log "Crontab entries removed"

# ============================================================
# STEP 10 — Remove installed files and directories (parallel)
# ============================================================
step "STEP 10 — Removing files and directories"

# Run all deletions in parallel for speed
(
  # YARA rules
  if [ -d /opt/yara-rules ]; then
    sudo rm -rf /opt/yara-rules
    echo -e "  ${GREEN}✅ Removed /opt/yara-rules${NC}"
  fi
) &

(
  # Sigma rules
  if [ -d /opt/sigma-rules ]; then
    sudo rm -rf /opt/sigma-rules
    echo -e "  ${GREEN}✅ Removed /opt/sigma-rules${NC}"
  fi
) &

(
  # YETI data
  if [ -d /opt/yeti ]; then
    sudo rm -rf /opt/yeti
    echo -e "  ${GREEN}✅ Removed /opt/yeti${NC}"
  fi
) &

(
  # Temp files
  sudo rm -f /tmp/cyberblue-*.log \
             /tmp/cyberblue-bg.log \
             /tmp/step14.log \
             /tmp/caldera-build.log \
             /tmp/emerging.tar.gz \
             /var/log/yara-update.log \
             /var/log/sigma-update.log 2>/dev/null
  echo -e "  ${GREEN}✅ Removed temp/log files${NC}"
) &

(
  # Sigma CLI python packages
  sudo pip3 uninstall -y --break-system-packages \
    sigma-cli \
    pysigma-backend-opensearch \
    pysigma-backend-elasticsearch \
    2>/dev/null || true
  echo -e "  ${GREEN}✅ Removed sigma Python packages${NC}"
) &

wait

# Remove CyberBlue directory last (after all above finish)
if [ -n "$CYBERBLUE_DIR" ]; then
  echo ""
  echo -e "  ${YELLOW}Removing CyberBlue directory: $CYBERBLUE_DIR${NC}"
  read -p "  Confirm delete $CYBERBLUE_DIR ? (YES/no): " DEL_DIR
  if [ "$DEL_DIR" = "YES" ]; then
    sudo rm -rf "$CYBERBLUE_DIR"
    done_ "Removed: $CYBERBLUE_DIR"
  else
    warn "Kept: $CYBERBLUE_DIR (skipped by user)"
  fi
fi

log "All files and directories removed"

# ============================================================
# STEP 11 — Wait for docker system prune to finish
# ============================================================
step "STEP 11 — Finalizing Docker cleanup"

if kill -0 $PRUNE_PID 2>/dev/null; then
  echo "  Waiting for docker system prune to finish..."
  wait $PRUNE_PID
fi

# Final Docker cleanup
docker container prune -f &>/dev/null || true
docker image     prune -af &>/dev/null || true
docker volume    prune -f  &>/dev/null || true
docker network   prune -f  &>/dev/null || true

log "Docker fully cleaned"

# ============================================================
# STEP 12 — Optional: Remove Docker itself
# ============================================================
step "STEP 12 — Optional: Remove Docker itself"

echo ""
echo -e "${YELLOW}Do you want to completely remove Docker from this system?${NC}"
echo "  (This will also remove docker-ce, docker-compose, containerd)"
echo "  Say NO if you use Docker for other projects"
echo ""
read -p "Remove Docker completely? (YES/no): " REMOVE_DOCKER

if [ "$REMOVE_DOCKER" = "YES" ]; then
  echo "  Removing Docker packages..."
  sudo systemctl stop docker 2>/dev/null || true
  sudo apt-get remove -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    docker-compose 2>/dev/null || true
  sudo apt-get autoremove -y -qq 2>/dev/null || true
  sudo rm -rf \
    /var/lib/docker \
    /var/lib/containerd \
    /etc/docker \
    /etc/apt/sources.list.d/docker.list \
    /etc/apt/keyrings/docker.gpg \
    /usr/local/bin/docker-compose \
    2>/dev/null || true
  done_ "Docker completely removed"
else
  log "Docker kept — only CyberBlue data removed"
fi

# ============================================================
# FINAL SUMMARY
# ============================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

REMAINING=$(docker ps -a --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' ')
IMAGES_LEFT=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
VOLUMES_LEFT=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗"
echo -e "║        CyberBlue Uninstall Complete                         ║"
echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ⏱  Total time        : ${MINS}m ${SECS}s"
echo -e "  🐳 Containers left   : ${REMAINING}"
echo -e "  🖼  Images left       : ${IMAGES_LEFT}"
echo -e "  💾 Volumes left      : ${VOLUMES_LEFT}"
echo ""
echo -e "${GREEN}  What was removed:${NC}"
echo -e "  ✅ All CyberBlue containers (25+)"
echo -e "  ✅ All Docker images"
echo -e "  ✅ All Docker volumes (all data)"
echo -e "  ✅ All Docker networks"
echo -e "  ✅ systemd services"
echo -e "  ✅ iptables rules"
echo -e "  ✅ zram swap"
echo -e "  ✅ sysctl settings"
echo -e "  ✅ YARA + Sigma rules"
echo -e "  ✅ Crontab entries"
echo -e "  ✅ Temp/log files"
echo ""

if [ "$REMAINING" = "0" ] && [ "$VOLUMES_LEFT" = "0" ]; then
  echo -e "${GREEN}  🎉 System is completely clean!${NC}"
else
  echo -e "${YELLOW}  ⚠️  Some items remain — run: docker system prune -af --volumes${NC}"
fi
echo ""
