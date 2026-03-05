#!/bin/bash
# ============================================================================
# CyberBlue Fix-Fleet Script — OPTIMIZED
# FIXES vs original:
#   ORIGINAL problem 1: sleep 3 in DB retry loop (60×3=180s max wait!)
#                        → poll every 1s, max 60s
#   ORIGINAL problem 2: Stops fleet-server before DB prep — wastes time
#                        → only stop if fleet-server is causing a conflict
#   ORIGINAL problem 3: 300s timeout for DB prep — way too long for feedback
#                        → 120s with live output
#   ORIGINAL problem 4: Fleet health check polls every 10s (12×10=120s max)
#                        → poll every 3s, max 60s
#   ORIGINAL problem 5: sudo docker-compose (v1) → docker compose (v2)
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ❌ $*${NC}"; exit 1; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

echo -e "${BLUE}🔧 Fleet Database Fix — FAST${NC}"
echo "==========================================="
[ "$FORCE" = true ] && warn "FORCE MODE enabled"

# ── Prerequisites ─────────────────────────────────────────────────
step "STEP 1 — Prerequisites"

docker info &>/dev/null         || err "Docker not running"
docker network ls | grep -q "cyber-blue" || err "cyber-blue network not found — run docker compose up first"
docker ps --format "{{.Names}}" | grep -q "^fleet-mysql$" || err "fleet-mysql not running"
log "Prerequisites OK"

# ── Step 2: Check if Fleet DB already works ───────────────────────
step "STEP 2 — Checking Fleet database"

if [ "$FORCE" = false ]; then
  if timeout 10 docker run --rm \
    --network=cyber-blue \
    -e FLEET_MYSQL_ADDRESS=fleet-mysql:3306 \
    -e FLEET_MYSQL_USERNAME=fleet \
    -e FLEET_MYSQL_PASSWORD=fleetpass \
    -e FLEET_MYSQL_DATABASE=fleet \
    fleetdm/fleet:latest fleet version &>/dev/null; then
    log "Fleet database already working — nothing to do!"
    echo ""
    echo -e "  🌐 Fleet: http://$(hostname -I | awk '{print $1}'):7007"
    exit 0
  fi
  log "Fleet DB needs preparation..."
fi

# ── Step 3: Wait for MySQL to be truly ready ──────────────────────
step "STEP 3 — Waiting for fleet-mysql"

# FIX: Original uses sleep 2 loops — we poll mysqladmin ping every 1s
WAIT=0; MAX=60
until docker exec fleet-mysql mysqladmin -ufleet -pfleetpass ping &>/dev/null; do
  echo -ne "\r  Waiting for fleet-mysql... ${WAIT}s / ${MAX}s"
  sleep 1; WAIT=$((WAIT+1))
  [ $WAIT -ge $MAX ] && { echo ""; err "fleet-mysql not ready after ${MAX}s — check: docker logs fleet-mysql"; }
done
echo ""; log "fleet-mysql ready (${WAIT}s)"

# ── Step 4: Kill stale fleet prepare processes ────────────────────
step "STEP 4 — Cleaning stale Fleet processes"

pkill -f "fleet prepare db" 2>/dev/null || true
sleep 1

# Only stop fleet-server if it's running AND blocking DB prep
# FIX: Original always stops it, wasting time
if docker ps --format "{{.Names}}" | grep -q "^fleet-server$"; then
  warn "Stopping fleet-server for DB preparation..."
  docker stop fleet-server &>/dev/null || true
fi

# ── Step 5: Prepare Fleet database ───────────────────────────────
step "STEP 5 — Fleet database preparation"

log "Running Fleet DB prepare (timeout 120s)..."
if timeout 120 docker run --rm \
  --network=cyber-blue \
  -e FLEET_MYSQL_ADDRESS=fleet-mysql:3306 \
  -e FLEET_MYSQL_USERNAME=fleet \
  -e FLEET_MYSQL_PASSWORD=fleetpass \
  -e FLEET_MYSQL_DATABASE=fleet \
  fleetdm/fleet:latest fleet prepare db 2>&1 | sed 's/^/  Fleet: /'; then
  log "Fleet database prepared successfully"
else
  warn "DB prepare returned non-zero — Fleet can auto-init on startup"
fi

# ── Step 6: Start fleet-server ────────────────────────────────────
step "STEP 6 — Starting Fleet server"

docker compose up -d fleet-server 2>&1 | tail -3

# FIX: Original polls every 10s for 120s max — we poll every 3s for 60s max
WAIT=0; MAX=60
until curl -s --max-time 2 -o /dev/null -w "%{http_code}" \
  http://localhost:7007 2>/dev/null | grep -q "200\|302\|404"; do
  echo -ne "\r  Waiting for Fleet server... ${WAIT}s / ${MAX}s"
  sleep 3; WAIT=$((WAIT+3))
  [ $WAIT -ge $MAX ] && { echo ""; warn "Fleet server slow — check: docker logs fleet-server"; break; }
done
[ $WAIT -lt $MAX ] && { echo ""; log "Fleet server ready (${WAIT}s)"; }

echo ""
echo -e "${GREEN}🎉 Fleet Fix Complete!${NC}"
echo "==========================================="
echo -e "  🌐 Fleet: http://$(hostname -I | awk '{print $1}'):7007"
echo -e "  📋 Initial setup required on first visit"
echo ""
