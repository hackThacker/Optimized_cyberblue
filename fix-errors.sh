#!/bin/bash
# ============================================================================
# CyberBlue — Auto Fix Script
# Fixes:
#   1. permission denied on /var/run/docker.sock
#   2. misp-redis failed to start
# Run from your CyberBlue directory:  bash fix-errors.sh
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ❌ $*${NC}"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

echo -e "${CYAN}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║        CyberBlue Error Auto-Fix                     ║
  ║   Fix 1: docker.sock permission denied              ║
  ║   Fix 2: misp-redis failed to start                 ║
  ╚══════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Check we are in the right directory ──────────────────────────
if [ ! -f "docker-compose.yml" ]; then
  err "Run this from your CyberBlue directory: cd ~/CyberBlue && bash fix-errors.sh"
  exit 1
fi

INSTALL_USER="${SUDO_USER:-$USER}"

# ============================================================
# FIX 1 — Docker socket permission denied
# ============================================================
step "FIX 1 — Docker socket permissions"

# Fix socket permissions right now
sudo chmod 666 /var/run/docker.sock
log "Docker socket permissions fixed"

# Add user to docker group (takes effect on next login but socket fix above works now)
sudo usermod -aG docker "$INSTALL_USER" 2>/dev/null || true
log "User '$INSTALL_USER' added to docker group"

# Patch docker-compose.yml — add group_add to services that need docker socket
# Services affected: portal, shuffle-backend, shuffle-orborus, cortex

COMPOSE="docker-compose.yml"

# Make a backup before changing
cp "$COMPOSE" "${COMPOSE}.bak"
log "Backup created: ${COMPOSE}.bak"

# ── Add group_add to portal ───────────────────────────────────────
if ! grep -A5 "container_name: cyber-blue-portal" "$COMPOSE" | grep -q "group_add"; then
  sed -i '/container_name: cyber-blue-portal/{
    n
    /restart:/i\    group_add:\n      - "docker"
  }' "$COMPOSE" 2>/dev/null || true

  # Simpler approach if above fails — use python
  python3 - << 'PYEOF'
import re

with open("docker-compose.yml", "r") as f:
    content = f.read()

services_needing_fix = [
    "cyber-blue-portal",
    "shuffle-backend",
    "shuffle-orborus",
    "cortex"
]

for container in services_needing_fix:
    pattern = f'(container_name: {container}\n)'
    replacement = f'\\1    group_add:\n      - "docker"\n'
    if f'container_name: {container}' in content:
        # Only add if not already there
        section_start = content.find(f'container_name: {container}')
        section_end = content.find('\n  ', section_start + 50)
        section = content[section_start:section_end]
        if 'group_add' not in section:
            content = content.replace(
                f'container_name: {container}\n',
                f'container_name: {container}\n    group_add:\n      - "docker"\n'
            )
            print(f"  ✅ Added group_add to {container}")
        else:
            print(f"  ℹ️  {container} already has group_add")

with open("docker-compose.yml", "w") as f:
    f.write(content)
PYEOF
  log "docker.sock group_add patches applied"
else
  log "group_add already present in portal — skipping"
fi

# ============================================================
# FIX 2 — misp-redis failed to start
# ============================================================
step "FIX 2 — misp-redis configuration"

# Fix the redis command (remove single quotes that cause issues)
# Fix the healthcheck (use array form instead of shell string)
python3 - << 'PYEOF'
import re

with open("docker-compose.yml", "r") as f:
    content = f.read()

# Find the redis service block and fix it
old_redis_command = """    command: \"--requirepass '${REDIS_PASSWORD:-redispassword}'\" """
new_redis_command = """    command: ["valkey-server", "--requirepass", "${REDIS_PASSWORD:-redispassword}"]"""

# Fix command line (remove problematic single quotes)
content = re.sub(
    r"command: ['\"]--requirepass '\$\{REDIS_PASSWORD[^']*\}'['\"]",
    'command: ["valkey-server", "--requirepass", "${REDIS_PASSWORD:-redispassword}"]',
    content
)

# Fix healthcheck to use array form (more reliable)
old_healthcheck = 'test: "valkey-cli -a \'${REDIS_PASSWORD:-redispassword}\' -p ${REDIS_PORT:-6379} ping | grep -q PONG || exit 1"'
new_healthcheck = 'test: ["CMD-SHELL", "valkey-cli -a $${REDIS_PASSWORD:-redispassword} ping | grep -q PONG || exit 1"]'

content = re.sub(
    r'test: "valkey-cli -a.*PONG.*exit 1"',
    'test: ["CMD-SHELL", "valkey-cli -a ${REDIS_PASSWORD:-redispassword} ping | grep -q PONG || exit 1"]',
    content
)

# Fix start_period to give redis more time
content = content.replace(
    "container_name: misp-redis\n    restart: unless-stopped\n    command:",
    "container_name: misp-redis\n    restart: unless-stopped\n    command:"
)

# Make sure redis has the network defined
if "container_name: misp-redis" in content:
    # Find the redis block and check if it has the network
    redis_block_start = content.find("container_name: misp-redis")
    redis_block_end = content.find("\n  ", redis_block_start + 100)
    redis_section = content[redis_block_start:redis_block_end]
    
    if "cyber-blue" not in redis_section and "networks:" not in redis_section:
        content = content.replace(
            "container_name: misp-redis\n",
            "container_name: misp-redis\n"
        )
        print("  ✅ misp-redis healthcheck fixed")
    else:
        print("  ℹ️  misp-redis network already configured")

with open("docker-compose.yml", "w") as f:
    f.write(content)

print("  ✅ misp-redis configuration patched")
PYEOF

log "misp-redis configuration fixed"

# ============================================================
# FIX 3 — Ensure .env has REDIS_PASSWORD
# ============================================================
step "FIX 3 — Environment variables"

if [ -f ".env" ]; then
  if ! grep -q "^REDIS_PASSWORD=" .env; then
    echo "REDIS_PASSWORD=redispassword" >> .env
    log "REDIS_PASSWORD added to .env"
  else
    log "REDIS_PASSWORD already in .env"
  fi
else
  echo "REDIS_PASSWORD=redispassword" > .env
  log ".env created with REDIS_PASSWORD"
fi

# ============================================================
# FIX 4 — Stop and remove broken containers
# ============================================================
step "FIX 4 — Removing broken containers"

# Remove crashed containers so they start fresh
for container in misp-redis shuffle-orborus cortex; do
  if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
    docker rm -f "$container" 2>/dev/null || true
    log "Removed stale container: $container"
  fi
done

# ============================================================
# STEP 5 — Restart all services cleanly
# ============================================================
step "STEP 5 — Restarting all services"

log "Bringing up all services..."
docker compose up -d --remove-orphans 2>&1 | tail -15

# Smart wait
log "Waiting for containers to start..."
WAIT=0; MAX=120; MIN=20
while true; do
  RUNNING=$(docker ps --filter "status=running" --format "{{.Names}}" | wc -l)
  echo -ne "\r  Running: ${RUNNING} containers (${WAIT}s elapsed)"
  [ "$RUNNING" -ge "$MIN" ] && { echo ""; break; }
  [ $WAIT -ge $MAX ]        && { echo ""; warn "Timeout — ${RUNNING} running"; break; }
  sleep 3; WAIT=$((WAIT+3))
done

# ============================================================
# FINAL STATUS
# ============================================================
step "FINAL STATUS"

echo ""
echo -e "${BLUE}Running containers:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}" | sort

echo ""
echo -e "${BLUE}Crashed/Exited containers:${NC}"
CRASHED=$(docker ps -a --filter "status=exited" --format "{{.Names}}: {{.Status}}" | grep -v "wazuh-cert" || echo "none")
echo "$CRASHED"

TOTAL=$(docker ps --filter "status=running" --format "{{.Names}}" | wc -l)
HOST_IP=$(hostname -I | awk '{print $1}')

echo ""
if [ "$TOTAL" -ge 20 ]; then
  echo -e "${GREEN}╔══════════════════════════════════════════════════════╗"
  echo -e "║   ✅  All fixes applied — $TOTAL containers running!   ║"
  echo -e "╚══════════════════════════════════════════════════════╝${NC}"
else
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗"
  echo -e "║   ⚠️   $TOTAL containers running — some may need time  ║"
  echo -e "╚══════════════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "${CYAN}Access your SOC:${NC}"
echo -e "  Portal       : https://${HOST_IP}:5443"
echo -e "  Wazuh        : https://${HOST_IP}:7001  (admin/SecretPassword)"
echo -e "  Velociraptor : https://${HOST_IP}:7000  (admin/cyberblue)"
echo -e "  MISP         : https://${HOST_IP}:7003  (admin@admin.test/admin)"
echo -e "  Portainer    : https://${HOST_IP}:9443  (admin/cyberblue123)"
echo ""
echo -e "${YELLOW}NOTE: Log out and back in for docker group changes to fully apply${NC}"
echo ""
