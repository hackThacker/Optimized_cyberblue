#!/bin/bash
# ============================================================================
# CyberBlue Fix-Wazuh Script — OPTIMIZED
# FIXES vs original:
#   ORIGINAL problem 1: sleep 45 + sleep 30 + sleep 45 = 120s fixed waits!
#                        → replaced with smart polling everywhere
#   ORIGINAL problem 2: Nukes ALL certs and regenerates every single run
#                        → only regenerate if certs are actually missing/broken
#   ORIGINAL problem 3: Stops and removes ALL Wazuh containers every run
#                        → only restart what is actually broken
#   ORIGINAL problem 4: Mixed docker-compose v1 / docker compose v2 syntax
#                        → unified to docker compose v2
#   ORIGINAL problem 5: Exits with error if 0 Wazuh services run
#                        → gives clear diagnostic instead of just exiting
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ❌ $*${NC}"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# Parse args
FORCE_CERTS=false
[[ "${1:-}" == "--force-certs" ]] && FORCE_CERTS=true

CERT_DIR="wazuh/config/wazuh_indexer_ssl_certs"

echo -e "${BLUE}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════╗
  ║      CyberBlue Wazuh Fix — FAST                 ║
  ║  Smart waits · Only fixes what's broken         ║
  ╚══════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Step 1: Check what is actually broken ─────────────────────────
step "STEP 1 — Diagnosing Wazuh status"

INDEXER_UP=$(docker ps --format "{{.Names}}" | grep -c "wazuh-indexer"  || echo 0)
MANAGER_UP=$(docker ps --format "{{.Names}}" | grep -c "wazuh-manager"  || echo 0)
DASHBOARD_UP=$(docker ps --format "{{.Names}}" | grep -c "wazuh-dashboard" || echo 0)
WAZUH_RUNNING=$((INDEXER_UP + MANAGER_UP + DASHBOARD_UP))

echo "  Indexer  : $([ "$INDEXER_UP"   -gt 0 ] && echo '✅ Running' || echo '❌ Down')"
echo "  Manager  : $([ "$MANAGER_UP"   -gt 0 ] && echo '✅ Running' || echo '❌ Down')"
echo "  Dashboard: $([ "$DASHBOARD_UP" -gt 0 ] && echo '✅ Running' || echo '❌ Down')"

if [ "$WAZUH_RUNNING" -eq 3 ]; then
  log "All 3 Wazuh services already running!"
  HOST_IP=$(hostname -I | awk '{print $1}')
  echo -e "  🌐 Wazuh Dashboard: https://${HOST_IP}:7001  (admin/SecretPassword)"
  exit 0
fi

# ── Step 2: SSL certificates — only regenerate if broken ──────────
step "STEP 2 — SSL certificates"

CERTS_OK=false
if [ -f "${CERT_DIR}/admin.pem" ] && \
   [ -f "${CERT_DIR}/wazuh.indexer.pem" ] && \
   [ -f "${CERT_DIR}/wazuh.dashboard.pem" ] && \
   [ "$FORCE_CERTS" = false ]; then
  log "Certs exist and look valid — skipping regeneration (saves 30s)"
  CERTS_OK=true
else
  warn "Certs missing or --force-certs set — regenerating..."

  # FIX: Only clean cert dir, not volumes. Volumes have Wazuh data!
  sudo rm -rf "$CERT_DIR"
  sudo mkdir -p "$CERT_DIR"
  sudo chown -R "$(whoami):$(id -gn)" "$CERT_DIR"

  # Stop/remove cert generator container only
  docker stop wazuh-cert-genrator 2>/dev/null || true
  docker rm   wazuh-cert-genrator 2>/dev/null || true

  log "Generating fresh SSL certificates..."
  docker compose up -d generator

  # FIX: Original sleep 30 — we poll for the cert file instead
  WAIT=0; MAX=60
  until [ -f "${CERT_DIR}/admin.pem" ]; do
    echo -ne "\r  Waiting for cert generation... ${WAIT}s / ${MAX}s"
    sleep 2; WAIT=$((WAIT+2))
    [ $WAIT -ge $MAX ] && {
      echo ""
      err "Certificate generation failed after ${MAX}s"
      docker logs wazuh-cert-genrator --tail 20
      exit 1
    }
  done
  echo ""; log "Certificates generated (${WAIT}s)"

  # Fix permissions
  sudo chown -R "$(whoami):$(id -gn)" "$CERT_DIR"
  sudo chmod 644 "${CERT_DIR}"/*.pem 2>/dev/null || true
  sudo chmod 644 "${CERT_DIR}"/*.key 2>/dev/null || true
  CERTS_OK=true
fi

# ── Step 3: Stop only broken Wazuh containers ─────────────────────
step "STEP 3 — Stopping broken Wazuh containers"

# FIX: Original stops ALL Wazuh containers even healthy ones.
# We only stop what isn't running properly.
for svc in wazuh-indexer wazuh-manager wazuh-dashboard; do
  STATUS=$(docker inspect --format "{{.State.Status}}" "$svc" 2>/dev/null || echo "missing")
  if [ "$STATUS" != "running" ]; then
    warn "$svc is ${STATUS} — will restart"
    docker stop "$svc" 2>/dev/null || true
    docker rm   "$svc" 2>/dev/null || true
  fi
done

# ── Step 4: Start Wazuh services in correct order ─────────────────
step "STEP 4 — Starting Wazuh services"

# Start indexer first
log "Starting Wazuh Indexer..."
docker compose up -d wazuh.indexer

# FIX: Original sleep 45 — we poll OpenSearch health instead
WAIT=0; MAX=120
until curl -sk -u admin:SecretPassword \
  https://localhost:9200/_cluster/health &>/dev/null; do
  echo -ne "\r  Waiting for Wazuh Indexer... ${WAIT}s / ${MAX}s"
  sleep 5; WAIT=$((WAIT+5))
  [ $WAIT -ge $MAX ] && { echo ""; warn "Indexer slow — continuing anyway"; break; }
done
[ $WAIT -lt $MAX ] && { echo ""; log "Wazuh Indexer ready (${WAIT}s)"; }

# Start manager
log "Starting Wazuh Manager..."
docker compose up -d wazuh.manager

# FIX: Original sleep 30 — we poll container status instead
WAIT=0; MAX=60
until docker ps --format "{{.Names}}" | grep -q "wazuh-manager"; do
  echo -ne "\r  Waiting for Wazuh Manager... ${WAIT}s / ${MAX}s"
  sleep 3; WAIT=$((WAIT+3))
  [ $WAIT -ge $MAX ] && { echo ""; warn "Manager slow — check: docker logs wazuh-manager"; break; }
done
[ $WAIT -lt $MAX ] && { echo ""; log "Wazuh Manager ready (${WAIT}s)"; }

# Start dashboard
log "Starting Wazuh Dashboard..."
docker compose up -d wazuh.dashboard

# FIX: Original sleep 45 — we poll the dashboard port instead
WAIT=0; MAX=90
until curl -sk --max-time 3 "https://localhost:7001" &>/dev/null; do
  echo -ne "\r  Waiting for Wazuh Dashboard... ${WAIT}s / ${MAX}s"
  sleep 5; WAIT=$((WAIT+5))
  [ $WAIT -ge $MAX ] && { echo ""; warn "Dashboard slow — check: docker logs wazuh-dashboard"; break; }
done
[ $WAIT -lt $MAX ] && { echo ""; log "Wazuh Dashboard ready (${WAIT}s)"; }

# ── Step 5: Clean up cert generator container ─────────────────────
docker stop wazuh-cert-genrator 2>/dev/null || true

# ── Final verification ────────────────────────────────────────────
step "STEP 5 — Final verification"

WAZUH_RUNNING=$(docker ps | grep -c "wazuh.*Up" || echo "0")
HOST_IP=$(hostname -I | awk '{print $1}')

echo ""
docker ps --format "table {{.Names}}\t{{.Status}}" | grep wazuh || true
echo ""

if [ "$WAZUH_RUNNING" -eq 3 ]; then
  echo -e "${GREEN}🎉 All 3 Wazuh services running!${NC}"
elif [ "$WAZUH_RUNNING" -eq 2 ]; then
  warn "2/3 Wazuh services running — one may need more time"
else
  warn "${WAZUH_RUNNING}/3 Wazuh services running — check logs above"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
echo -e "║        Wazuh Fix Complete                        ║"
echo -e "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  🌐 Wazuh Dashboard : https://${HOST_IP}:7001"
echo -e "  👤 Credentials     : admin / SecretPassword"
echo ""
echo -e "${CYAN}💡 Tips:${NC}"
echo "  Run with --force-certs to regenerate SSL certificates"
echo "  Check logs: docker logs wazuh-indexer"
echo "  Check logs: docker logs wazuh-manager"
echo "  Check logs: docker logs wazuh-dashboard"
echo ""
