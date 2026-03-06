#!/bin/bash
# ============================================================================
# CyberBlue — Auto Fix Script
# Fixes ALL known errors:
#   1. permission denied on /var/run/docker.sock
#   2. misp-redis failed to start (bad command quotes)
#   3. group_add "docker" — no matching entries in group file
#      (containers need numeric GID not group name)
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ❌ $*${NC}"; exit 1; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

echo -e "${CYAN}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║        CyberBlue Error Auto-Fix                     ║
  ║   Fix 1: docker.sock permission denied              ║
  ║   Fix 2: misp-redis failed to start                 ║
  ║   Fix 3: group docker not found in container        ║
  ╚══════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

cd ~/Optimized_cyberblue 2>/dev/null || \
  cd ~/CyberBlue 2>/dev/null || \
  err "Cannot find CyberBlue folder. Run from ~/Optimized_cyberblue or ~/CyberBlue"

[ -f "docker-compose.yml" ] || err "docker-compose.yml not found in $(pwd)"

INSTALL_USER="${SUDO_USER:-$USER}"

# ============================================================
# FIX 1 — Docker socket permissions
# ============================================================
step "FIX 1 — Docker socket permissions"

sudo chmod 666 /var/run/docker.sock
log "Docker socket permissions fixed (666)"

sudo usermod -aG docker "$INSTALL_USER" 2>/dev/null || true
log "User '$INSTALL_USER' added to docker group"

# ============================================================
# FIX 2 — misp-redis bad command quotes
# ============================================================
step "FIX 2 — misp-redis command fix"

cp docker-compose.yml docker-compose.yml.bak.$(date +%s)
log "Backup created"

python3 - << 'PYEOF'
import re

with open("docker-compose.yml", "r") as f:
    content = f.read()

# Fix nested single quotes inside double quotes in redis command
# BROKEN:  command: "--requirepass 'password'"
# FIXED:   command: ["valkey-server", "--requirepass", "password"]
fixed = re.sub(
    r"command:\s*['\"]--requirepass\s+'?\$\{REDIS_PASSWORD[^}]*\}'?['\"]",
    'command: ["valkey-server", "--requirepass", "${REDIS_PASSWORD:-redispassword}"]',
    content
)

if fixed != content:
    with open("docker-compose.yml", "w") as f:
        f.write(fixed)
    print("  ✅ misp-redis command quotes fixed")
else:
    print("  ℹ️  misp-redis already fixed or pattern not found")
PYEOF

log "misp-redis fix applied"

# ============================================================
# FIX 3 — group_add "docker" → numeric GID
# ============================================================
step "FIX 3 — group_add docker → numeric GID"

# WHY THIS FAILS:
# docker-compose.yml has:  group_add: - "docker"
# Containers are minimal images (Debian/Alpine) that have NO "docker" group
# They only understand numeric GIDs
# Fix: replace the string "docker" with the actual GID number from the HOST

# Get docker group GID from host
DOCKER_GID=$(getent group docker 2>/dev/null | cut -d: -f3)

if [ -z "$DOCKER_GID" ]; then
  warn "docker group not found on host — trying to create it..."
  sudo groupadd docker 2>/dev/null || true
  DOCKER_GID=$(getent group docker | cut -d: -f3)
fi

log "Docker group GID on this host: $DOCKER_GID"

# Save to .env so docker-compose can use it as variable
if grep -q "^DOCKER_GID=" .env 2>/dev/null; then
  sed -i "s/^DOCKER_GID=.*/DOCKER_GID=$DOCKER_GID/" .env
else
  echo "DOCKER_GID=$DOCKER_GID" >> .env
fi
log "DOCKER_GID=$DOCKER_GID saved to .env"

# Replace "docker" group name with numeric GID in docker-compose.yml
python3 - << PYEOF
gid = "$DOCKER_GID"

with open("docker-compose.yml", "r") as f:
    content = f.read()

original = content

# Replace any group_add that uses the string "docker"
# Handles both:  - "docker"  and  - docker
import re
content = re.sub(
    r'(group_add:\s*\n\s+- )"docker"',
    f'\\1"{gid}"',
    content
)
content = re.sub(
    r'(group_add:\s*\n\s+- )docker\b',
    f'\\1"{gid}"',
    content
)

if content != original:
    with open("docker-compose.yml", "w") as f:
        f.write(content)
    print(f"  ✅ Replaced group name 'docker' with GID {gid}")
else:
    print(f"  ℹ️  group_add already uses numeric GID or not found")
PYEOF

log "group_add fix applied"

# ============================================================
# FIX 4 — Remove crashed containers
# ============================================================
step "FIX 4 — Removing crashed containers"

for container in misp-redis shuffle-orborus cortex portal; do
  if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
    docker rm -f "$container" 2>/dev/null || true
    log "Removed stale container: $container"
  fi
done

# ============================================================
# FIX 5 — Restart all services
# ============================================================
step "FIX 5 — Restarting all services"

docker compose up -d --remove-orphans 2>&1 | tail -15

# Smart wait
log "Waiting for containers to start..."
WAIT=0; MAX=120; MIN=20
while true; do
  RUNNING=$(docker ps --filter "status=running" --format "{{.Names}}" \
    2>/dev/null | wc -l | tr -d ' \n')
  [[ "$RUNNING" =~ ^[0-9]+$ ]] || RUNNING=0
  echo -ne "\r  Running: ${RUNNING} containers (${WAIT}s elapsed)"
  [ "$RUNNING" -ge "$MIN" ] && { echo ""; break; }
  [ "$WAIT"    -ge "$MAX" ] && { echo ""; warn "Timeout — ${RUNNING} running"; break; }
  sleep 3; WAIT=$((WAIT+3))
done

# ============================================================
# FINAL STATUS
# ============================================================
step "FINAL STATUS"

echo ""
echo -e "${BLUE}Container status:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}" | sort

echo ""
CRASHED=$(docker ps -a --filter "status=exited" \
  --format "{{.Names}}: {{.Status}}" \
  | grep -v "wazuh-cert" || echo "none")
if [ "$CRASHED" != "none" ] && [ -n "$CRASHED" ]; then
  echo -e "${RED}Crashed containers:${NC}"
  echo "$CRASHED"
else
  echo -e "${GREEN}No crashed containers ✅${NC}"
fi

TOTAL=$(docker ps --filter "status=running" --format "{{.Names}}" \
  2>/dev/null | wc -l | tr -d ' \n')
HOST_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗"
echo -e "║   ✅  $TOTAL containers running                        ║"
echo -e "╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Access your SOC:${NC}"
echo -e "  Portal       : https://${HOST_IP}:5443"
echo -e "  Wazuh        : https://${HOST_IP}:7001  (admin/SecretPassword)"
echo -e "  Velociraptor : https://${HOST_IP}:7000  (admin/cyberblue)"
echo -e "  MISP         : https://${HOST_IP}:7003  (admin@admin.test/admin)"
echo -e "  Portainer    : https://${HOST_IP}:9443  (admin/cyberblue123)"
echo ""
echo -e "${YELLOW}NOTE: Log out and back in for docker group changes to apply${NC}"
echo ""
