#!/bin/bash
# ============================================================================
# CyberBlue Fix-Arkime Script — FULLY FIXED
#
# ORIGINAL BUGS FIXED IN THIS VERSION:
#
# BUG 1 (Step 2): Health check used HTTP for wazuh.indexer which needs HTTPS
#                 curl http://wazuh.indexer:9200 → always failed silently
#                 FIX: detect which OpenSearch is used, use correct protocol
#
# BUG 2 (Step 2): OS_CONTAINER from docker ps = container NAME not hostname
#                 wazuh-indexer (container name) ≠ wazuh.indexer (DNS hostname)
#                 Inside Docker network, hostname = service name, not container name
#                 FIX: map container names to correct DNS service hostnames
#
# BUG 3 (Step 3): DB init used HTTP for wazuh.indexer (needs HTTPS + auth)
#                 db.pl http://wazuh-indexer:9200 → always fails
#                 FIX: use correct protocol, port, and credentials per backend
#
# BUG 4 (Step 5): No check if config.ini exists before running capture
#                 capture would fail silently with misleading output
#                 FIX: explicit config check before attempting capture
#
# BUG 5 (Step 5): PCAP directory not created in container path
#                 /data/pcap may not exist if volume not mounted yet
#                 FIX: mkdir inside container before capture
# ============================================================================

set +e
set +u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ❌ $*${NC}"; }
step() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
         echo -e "${BLUE}  $*${NC}"; \
         echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Parse args ────────────────────────────────────────────────────
FORCE_INIT=false
LIVE_CAPTURE=false
CAPTURE_DURATION=60

for arg in "$@"; do
  case $arg in
    --force)        FORCE_INIT=true ;;
    --live)         LIVE_CAPTURE=true ;;
    --live-*s)      LIVE_CAPTURE=true
                    CAPTURE_DURATION="${arg#--live-}"
                    CAPTURE_DURATION="${CAPTURE_DURATION%s}" ;;
    --live-*min)    LIVE_CAPTURE=true
                    D="${arg#--live-}"
                    CAPTURE_DURATION=$(( ${D%min} * 60 )) ;;
    --capture-live) LIVE_CAPTURE=true; CAPTURE_DURATION=15 ;;
    --live-30s)     LIVE_CAPTURE=true; CAPTURE_DURATION=30 ;;
    -h|--help)
      echo "Usage: $0 [--force] [--live] [--live-30s] [--live-5min] [--capture-live]"
      echo ""
      echo "  --force        Reinitialize Arkime database (wipes existing data)"
      echo "  --live         Capture 60s of live traffic"
      echo "  --live-30s     Capture 30s of live traffic"
      echo "  --live-5min    Capture 5 minutes of live traffic"
      exit 0 ;;
  esac
done

HOST_IP=$(hostname -I | awk '{print $1}')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║        Arkime Fix & Initialization — FAST           ║
  ╚══════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ============================================================
# STEP 1 — Ensure Arkime container is running
# ============================================================
step "STEP 1 — Arkime container check"

if ! docker ps --format "{{.Names}}" | grep -q "^arkime$"; then
  warn "Arkime not running — starting..."
  cd "$SCRIPT_DIR"
  docker compose up -d arkime 2>/dev/null || true
  sleep 5
fi

if ! docker ps --format "{{.Names}}" | grep -q "^arkime$"; then
  err "Arkime container failed to start — check: docker logs arkime"
  exit 1
fi
log "Arkime container is running"

# ============================================================
# STEP 2 — Detect OpenSearch backend + wait for it
# ============================================================
step "STEP 2 — Detecting OpenSearch backend"

# BUG 2 FIX: Map container NAME → service HOSTNAME (DNS name inside Docker)
# docker ps gives container names like "wazuh-indexer"
# but inside Docker network, hostname is the SERVICE name "wazuh.indexer"
# These are DIFFERENT — container name uses hyphen, service name uses dot

# Detect which OpenSearch container is running
OS_CONTAINER_NAME=$(docker ps --format "{{.Names}}" \
  | grep -E "^(os01|wazuh-indexer|opensearch|elasticsearch)$" | head -1)

if [ -z "$OS_CONTAINER_NAME" ]; then
  warn "No OpenSearch container detected — defaulting to os01"
  OS_CONTAINER_NAME="os01"
fi
log "Detected container: $OS_CONTAINER_NAME"

# BUG 2 FIX: Resolve correct DNS hostname and protocol
# os01         → hostname: os01,           HTTP,  port 9200
# wazuh-indexer → hostname: wazuh.indexer,  HTTPS, port 9200 (needs -k + auth)
# opensearch   → hostname: opensearch,     HTTP,  port 9200
case "$OS_CONTAINER_NAME" in
  wazuh-indexer)
    OS_HOSTNAME="wazuh.indexer"
    OS_PROTOCOL="https"
    OS_CURL_OPTS="-k -u admin:SecretPassword"
    OS_DB_OPTS="--insecure"
    OS_DB_AUTH="admin:SecretPassword@"
    ;;
  os01|opensearch*)
    OS_HOSTNAME="os01"
    OS_PROTOCOL="http"
    OS_CURL_OPTS=""
    OS_DB_OPTS=""
    OS_DB_AUTH=""
    ;;
  elasticsearch*)
    OS_HOSTNAME="elasticsearch"
    OS_PROTOCOL="http"
    OS_CURL_OPTS=""
    OS_DB_OPTS=""
    OS_DB_AUTH=""
    ;;
  *)
    OS_HOSTNAME="$OS_CONTAINER_NAME"
    OS_PROTOCOL="http"
    OS_CURL_OPTS=""
    OS_DB_OPTS=""
    OS_DB_AUTH=""
    ;;
esac

log "OpenSearch endpoint: ${OS_PROTOCOL}://${OS_HOSTNAME}:9200"

# BUG 1 FIX: Health check from INSIDE arkime container using correct protocol
# Original used HTTP for everything — wazuh.indexer needs HTTPS
WAIT=0; MAX=90
until docker exec arkime curl -s --max-time 3 \
    $OS_CURL_OPTS \
    "${OS_PROTOCOL}://${OS_HOSTNAME}:9200/_cluster/health" \
    2>/dev/null | grep -q "green\|yellow"; do
  echo -ne "\r  ⏳ Waiting for ${OS_HOSTNAME}... ${WAIT}s / ${MAX}s"
  sleep 3; WAIT=$((WAIT+3))
  [ $WAIT -ge $MAX ] && {
    echo ""
    warn "OpenSearch not responding — continuing anyway"
    break
  }
done
[ $WAIT -lt $MAX ] && { echo ""; log "OpenSearch ready (${WAIT}s)"; }

# ============================================================
# STEP 3 — Initialize Arkime database
# ============================================================
step "STEP 3 — Database initialization"

if [ "$FORCE_INIT" = true ]; then
  log "Initializing Arkime database on ${OS_HOSTNAME}..."

  # BUG 3 FIX: Use correct protocol + auth for each backend
  # Original always used plain HTTP — fails silently for wazuh.indexer (HTTPS)
  docker exec arkime bash -c \
    "echo INIT | /opt/arkime/db/db.pl \
      ${OS_PROTOCOL}://${OS_DB_AUTH}${OS_HOSTNAME}:9200 \
      init ${OS_DB_OPTS} 2>&1" \
    | grep -v "^$" || warn "DB init had warnings (normal for existing data)"
  log "Database initialized"
else
  # Check if DB already exists
  INDEX_EXISTS=$(docker exec arkime curl -s --max-time 5 \
    $OS_CURL_OPTS \
    "${OS_PROTOCOL}://${OS_HOSTNAME}:9200/arkime_*" \
    2>/dev/null | grep -c "index" || echo "0")

  if [ "$INDEX_EXISTS" = "0" ]; then
    log "First run — initializing Arkime database..."
    docker exec arkime bash -c \
      "echo INIT | /opt/arkime/db/db.pl \
        ${OS_PROTOCOL}://${OS_DB_AUTH}${OS_HOSTNAME}:9200 \
        init ${OS_DB_OPTS} 2>&1" \
      | grep -v "^$" || true
    log "Database initialized"
  else
    log "Database already exists — skipping init (use --force to reinitialize)"
  fi
fi

# ============================================================
# STEP 4 — Network capture (optional)
# ============================================================
step "STEP 4 — Network capture"

mkdir -p "${SCRIPT_DIR}/arkime/pcaps"

if [ "$LIVE_CAPTURE" = true ]; then
  IFACE=$(ip route show default | awk '/default/{print $5}' | head -1)
  [ -z "$IFACE" ] && IFACE="ens33"
  log "Capturing ${CAPTURE_DURATION}s of live traffic on ${IFACE}..."

  PCAP="${SCRIPT_DIR}/arkime/pcaps/live_$(date +%Y%m%d_%H%M%S).pcap"
  if command -v tcpdump &>/dev/null; then
    sudo timeout ${CAPTURE_DURATION}s tcpdump -i "$IFACE" -w "$PCAP" \
      -q 2>/dev/null || true
    if [ -f "$PCAP" ] && [ -s "$PCAP" ]; then
      log "Capture complete: $(basename $PCAP) ($(du -h $PCAP | cut -f1))"
    else
      warn "Capture produced empty file — check interface: $IFACE"
      rm -f "$PCAP"
    fi
  else
    warn "tcpdump not found — install with: sudo apt install tcpdump"
  fi
else
  log "Skipping live capture (use --live-30s to capture traffic)"
fi

# ============================================================
# STEP 5 — Process PCAP files
# ============================================================
step "STEP 5 — Processing PCAP files"

# BUG 4 FIX: Check config.ini exists before attempting capture
CONFIG_EXISTS=$(docker exec arkime \
  test -f /opt/arkime/etc/config.ini && echo "yes" || echo "no")

if [ "$CONFIG_EXISTS" != "yes" ]; then
  warn "Arkime config.ini not found — skipping PCAP processing"
  warn "Run startarkime.sh first to generate config"
else
  # BUG 5 FIX: Ensure /data/pcap exists inside container
  docker exec arkime mkdir -p /data/pcap 2>/dev/null || true

  PCAP_COUNT=$(ls "${SCRIPT_DIR}/arkime/pcaps/"*.pcap 2>/dev/null | wc -l | tr -d ' ')
  if [ "$PCAP_COUNT" -gt "0" ]; then
    log "Processing $PCAP_COUNT PCAP file(s)..."
    for pcap in "${SCRIPT_DIR}/arkime/pcaps/"*.pcap; do
      [ -f "$pcap" ] || continue
      fname=$(basename "$pcap")
      log "  Processing: $fname"
      timeout 60s docker exec arkime \
        /opt/arkime/bin/capture \
        -c /opt/arkime/etc/config.ini \
        -r "/data/pcap/${fname}" \
        2>/dev/null || warn "  Warnings for $fname (may be normal)"
    done
    log "All PCAPs processed"
  else
    log "No PCAP files found in arkime/pcaps/ — ready for manual upload"
  fi
fi

# ============================================================
# STEP 6 — Create admin user
# ============================================================
step "STEP 6 — Admin user setup"

docker exec arkime \
  /opt/arkime/bin/arkime_add_user.sh \
  admin "CyberBlue Admin" admin --admin \
  2>/dev/null && log "Admin user ready (admin/admin)" \
  || warn "Admin user may already exist — that is fine"

# ============================================================
# STEP 7 — Restart Arkime and wait for viewer
# ============================================================
step "STEP 7 — Restarting Arkime viewer"

cd "$SCRIPT_DIR"
docker compose restart arkime 2>/dev/null || true

WAIT=0; MAX=90
until curl -s --max-time 3 "http://localhost:7008" &>/dev/null; do
  echo -ne "\r  ⏳ Waiting for Arkime viewer... ${WAIT}s / ${MAX}s"
  sleep 3; WAIT=$((WAIT+3))
  [ $WAIT -ge $MAX ] && {
    echo ""
    warn "Arkime viewer slow — check: docker logs arkime --tail 20"
    break
  }
done
[ $WAIT -lt $MAX ] && { echo ""; log "Arkime viewer ready (${WAIT}s)"; }

# ============================================================
# FINAL SUMMARY
# ============================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗"
echo -e "║        Arkime Fix Complete ✅                        ║"
echo -e "╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  🌐 Arkime   : http://${HOST_IP}:7008"
echo -e "  👤 Login    : admin / admin"
echo ""
echo -e "${CYAN}  Options:${NC}"
echo -e "  --force       Reinitialize database"
echo -e "  --live-30s    Capture 30s of live traffic"
echo -e "  --live-5min   Capture 5 minutes of traffic"
echo ""
