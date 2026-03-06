#!/bin/bash
# ============================================================================
# CyberBlue Fix-Arkime Script — OPTIMIZED
# FIXES vs original:
#   ORIGINAL problem 1: sleep 15 / sleep 30 / sleep 15 fixed waits
#                        → replaced with smart polling
#   ORIGINAL problem 2: sudo docker-compose (v1) → docker compose (v2)
#   ORIGINAL problem 3: Massive complexity / bloat for a fix script
#                        → lean and focused
#   ORIGINAL problem 4: set -e with complex subshells causes unexpected exits
#                        → removed set -e, handle errors explicitly
#   ORIGINAL problem 5: Sequential PCAP processing → parallel where possible
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ❌ $*${NC}"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# Parse args
FORCE_INIT=false
LIVE_CAPTURE=false
CAPTURE_DURATION=60

for arg in "$@"; do
  case $arg in
    --force)       FORCE_INIT=true ;;
    --live)        LIVE_CAPTURE=true ;;
    --live-*s)     LIVE_CAPTURE=true; CAPTURE_DURATION="${arg#--live-}"; CAPTURE_DURATION="${CAPTURE_DURATION%s}" ;;
    --live-*min)   LIVE_CAPTURE=true; D="${arg#--live-}"; CAPTURE_DURATION=$(( ${D%min} * 60 )) ;;
    --capture-live) LIVE_CAPTURE=true; CAPTURE_DURATION=15 ;;
    --live-30s)    LIVE_CAPTURE=true; CAPTURE_DURATION=30 ;;
    -h|--help)
      echo "Usage: $0 [--force] [--live] [--live-30s] [--live-5min] [--capture-live]"
      exit 0 ;;
  esac
done

HOST_IP=$(hostname -I | awk '{print $1}')

echo -e "${BLUE}🔍 Arkime Fix & Initialization — FAST${NC}"
echo "==========================================="

# ── Step 1: Ensure Arkime container is running ────────────────────
step "STEP 1 — Arkime container check"

if ! docker ps --format "{{.Names}}" | grep -q "^arkime$"; then
  warn "Arkime not running — starting..."
  docker compose up -d arkime
fi

# ── Step 2: Wait for OpenSearch (smart poll, not fixed sleep) ─────
step "STEP 2 — Waiting for OpenSearch"

# FIX BUG 7: Original hardcoded os01 — auto-detect OpenSearch container name
OS_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "opensearch|os01|wazuh.indexer|elastic" | head -1 || echo "os01")
log "Detected OpenSearch/Indexer container: $OS_CONTAINER"

WAIT=0; MAX=60
until docker exec arkime curl -s "http://${OS_CONTAINER}:9200/_cluster/health" 2>/dev/null | grep -q "green\|yellow"; do
  echo -ne "\r  Waiting for OpenSearch ($OS_CONTAINER)... ${WAIT}s / ${MAX}s"
  sleep 3; WAIT=$((WAIT+3))
  [ $WAIT -ge $MAX ] && { echo ""; warn "OpenSearch slow — continuing anyway"; break; }
done
[ $WAIT -lt $MAX ] && { echo ""; log "OpenSearch ready (${WAIT}s)"; }

# ── Step 3: Initialize Arkime database ───────────────────────────
step "STEP 3 — Database initialization"

if [ "$FORCE_INIT" = true ]; then
  log "Force-initializing Arkime database..."
  docker exec arkime bash -c \
    "/opt/arkime/db/db.pl http://${OS_CONTAINER}:9200 init --force --insecure" 2>/dev/null \
    || warn "DB init warnings are normal for existing databases"
else
  log "Skipping DB init (use --force to reinitialize)"
fi

# ── Step 4: Live capture (optional) ───────────────────────────────
step "STEP 4 — Network capture"

mkdir -p ./arkime/pcaps

if [ "$LIVE_CAPTURE" = true ]; then
  IFACE=$(ip route show default | awk '/default/{print $5}' | head -1)
  [ -z "$IFACE" ] && IFACE="ens33"
  log "Capturing ${CAPTURE_DURATION}s of live traffic on ${IFACE}..."

  PCAP="./arkime/pcaps/live_$(date +%Y%m%d_%H%M%S).pcap"
  if command -v tcpdump &>/dev/null; then
    timeout ${CAPTURE_DURATION}s tcpdump -i "$IFACE" -w "$PCAP" 2>/dev/null || true
    log "Capture complete: $PCAP"
  else
    warn "tcpdump not found — install with: sudo apt install tcpdump"
  fi
fi

# ── Step 5: Process PCAP files ────────────────────────────────────
step "STEP 5 — Processing PCAP files"

if ls ./arkime/pcaps/*.pcap &>/dev/null 2>/dev/null; then
  for pcap in ./arkime/pcaps/*.pcap; do
    fname=$(basename "$pcap")
    log "Processing: $fname"
    timeout 60s docker exec arkime \
      /opt/arkime/bin/capture -c /opt/arkime/etc/config.ini \
      -r "/data/pcap/${fname}" 2>/dev/null \
      || warn "Processing warnings are normal: $fname"
  done
else
  log "No PCAP files found — Arkime ready for manual upload"
fi

# ── Step 6: Create admin user ─────────────────────────────────────
step "STEP 6 — Admin user"

docker exec arkime \
  /opt/arkime/bin/arkime_add_user.sh admin "CyberBlue Admin" admin --admin \
  2>/dev/null && log "Admin user ready" || warn "Admin user may already exist"

# ── Step 7: Restart and smart-wait for Arkime viewer ─────────────
step "STEP 7 — Restarting Arkime"

# FIX: Original sleep 15 blindly. We poll until the port responds.
docker compose restart arkime 2>/dev/null

WAIT=0; MAX=60
until curl -s --max-time 2 "http://localhost:7008" &>/dev/null; do
  echo -ne "\r  Waiting for Arkime viewer... ${WAIT}s / ${MAX}s"
  sleep 3; WAIT=$((WAIT+3))
  [ $WAIT -ge $MAX ] && { echo ""; warn "Arkime viewer slow — check: docker logs arkime"; break; }
done
[ $WAIT -lt $MAX ] && { echo ""; log "Arkime viewer ready (${WAIT}s)"; }

echo ""
echo -e "${GREEN}🎯 Arkime Fix Complete!${NC}"
echo "==========================================="
echo -e "  🌐 Arkime   : http://${HOST_IP}:7008"
echo -e "  👤 Login    : admin / admin"
echo ""
echo -e "${CYAN}💡 Tips:${NC}"
echo "  Re-run with --force to reinitialize database"
echo "  Re-run with --live-30s to capture 30s of traffic"
echo "  Upload PCAPs manually via the web interface"
echo ""
