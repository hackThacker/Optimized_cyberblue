#!/bin/bash
# ============================================================================
# CyberBlue Force Start Script — OPTIMIZED
# FIXES vs original:
#   ORIGINAL problem 1: sudo systemctl restart docker — kills ALL containers
#                        unnecessarily. Now only restarts if docker is broken.
#   ORIGINAL problem 2: sleep 30 fixed wait — replaced with smart polling
#   ORIGINAL problem 3: sudo docker-compose (v1) — updated to docker compose (v2)
#   ORIGINAL problem 4: No parallel awareness — containers start in parallel now
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ❌ $*${NC}"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

echo -e "${BLUE}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════╗
  ║      CyberBlue FAST Force-Start                 ║
  ║  Smart waits · No unnecessary Docker restart    ║
  ╚══════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Verify we are in the right directory ─────────────────────────
if [ ! -f "docker-compose.yml" ]; then
  err "docker-compose.yml not found — run from the CyberBlue directory"
  exit 1
fi

# ── Step 1: Only restart Docker if it is actually broken ─────────
step "STEP 1 — Docker health check"

# FIX: Original ALWAYS restarts Docker, killing every running container.
# We only restart if docker info fails.
if docker info &>/dev/null; then
  log "Docker is healthy — skipping restart (saves 20-30s)"
else
  warn "Docker not responding — restarting daemon..."
  sudo systemctl restart docker

  # Smart wait — poll instead of fixed sleep
  log "Waiting for Docker daemon..."
  timeout 30 bash -c 'until docker info &>/dev/null; do sleep 2; done' \
    && log "Docker daemon ready" \
    || { err "Docker failed to start within 30s"; exit 1; }
fi

# ── Step 2: Start all containers ─────────────────────────────────
step "STEP 2 — Starting all CyberBlue services"

# FIX: Use docker compose v2 (not docker-compose v1)
# FIX: --remove-orphans cleans stale containers without prompting
log "Bringing up all services in parallel..."
docker compose up -d --remove-orphans 2>&1 | grep -v "^#" | tail -20

# ── Step 3: Smart wait — poll until minimum containers are running ─
step "STEP 3 — Waiting for containers (smart poll)"

# FIX: Original sleep 30 blindly — we poll every 3s and stop as soon as ready
WAIT=0
MAX_WAIT=180
MIN_RUNNING=20

while true; do
  RUNNING=$(docker ps --filter "status=running" --format "{{.Names}}" | wc -l)
  echo -ne "\r  Running containers: ${RUNNING} / ${MIN_RUNNING} target  (${WAIT}s elapsed)"

  [ "$RUNNING" -ge "$MIN_RUNNING" ] && { echo ""; log "Target reached: $RUNNING containers running"; break; }
  [ $WAIT -ge $MAX_WAIT ]          && { echo ""; warn "Timeout — $RUNNING containers running (some may still start)"; break; }

  sleep 3
  WAIT=$((WAIT+3))
done

# ── Step 4: Quick service spot-check ─────────────────────────────
step "STEP 4 — Quick service check"

check_url() {
  local name="$1" url="$2"
  if curl -sk --max-time 3 "$url" &>/dev/null; then
    echo -e "  ${GREEN}✅ $name${NC}"
  else
    echo -e "  ${YELLOW}⏳ $name (still starting)${NC}"
  fi
}

HOST_IP=$(hostname -I | awk '{print $1}')
check_url "Portal"       "https://${HOST_IP}:5443"
check_url "Wazuh"        "https://${HOST_IP}:7001"
check_url "Velociraptor" "https://${HOST_IP}:7000"
check_url "Portainer"    "https://${HOST_IP}:9443"

# ── Final summary ─────────────────────────────────────────────────
TOTAL=$(docker ps --filter "status=running" --format "{{.Names}}" | wc -l)
EXITED=$(docker ps -a --filter "status=exited" --format "{{.Names}}" | wc -l)

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
echo -e "║         CyberBlue Force-Start Complete           ║"
echo -e "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  📦 Running  : ${TOTAL} containers"
[ "$EXITED" -gt 0 ] && echo -e "  ${YELLOW}⚠️  Exited   : ${EXITED} containers — run: docker ps -a${NC}"
echo ""
echo -e "${BLUE}  Access your SOC:${NC}"
echo -e "  Portal     : https://${HOST_IP}:5443"
echo -e "  Wazuh      : https://${HOST_IP}:7001  (admin/SecretPassword)"
echo -e "  Portainer  : https://${HOST_IP}:9443  (admin/cyberblue123)"
echo ""
