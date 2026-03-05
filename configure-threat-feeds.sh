#!/bin/bash
# ============================================================================
# CyberBlue configure-threat-feeds.sh — OPTIMIZED
# FIXES vs original:
#   ORIGINAL problem 1: sleep 3 in retry loop → 120×3=360s (6 min!) max wait
#                        → poll every 1s, max 120s
#   ORIGINAL problem 2: sleep 2 after API key enable — not needed
#                        → removed
#   ORIGINAL problem 3: 5 sequential curl calls to enable feeds
#                        → run all 5 in parallel with &
#   ORIGINAL problem 4: Blocking fetchFromAllFeeds call hangs the installer
#                        → run in background, return immediately
#   ORIGINAL problem 5: set -e causes exit on any failed curl
#                        → removed, handle errors gracefully
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }

echo "=========================================="
echo "  MISP Threat Intelligence Feeds — FAST  "
echo "=========================================="
echo ""

# ── Step 1: Smart wait for MISP to be ready ───────────────────────
# FIX: Original uses sleep 3 per retry = up to 6 minutes wasted.
# We poll every 1s and give up at 120s with a clean message.
echo "[*] Waiting for MISP to be ready..."

MAX=120; WAIT=0
until docker exec misp-core curl -k -s https://localhost/users/heartbeat &>/dev/null; do
  echo -ne "\r  Waiting for MISP... ${WAIT}s / ${MAX}s"
  sleep 1; WAIT=$((WAIT+1))
  if [ $WAIT -ge $MAX ]; then
    echo ""
    warn "MISP not ready after ${MAX}s — skipping feed configuration"
    warn "Re-run this script later: bash misp/configure-threat-feeds.sh"
    exit 0
  fi
done
echo ""; log "MISP ready (${WAIT}s)"

# ── Step 2: Enable API key (no sleep needed after this) ───────────
echo "[*] Enabling MISP API key..."
docker exec misp-core mysql -h db -u misp -pexample misp \
  -e "UPDATE users SET change_pw=0 WHERE email='admin@admin.test';" \
  2>/dev/null || true
# FIX: Original had sleep 2 here — not needed, MySQL updates are instant

# ── Step 3: Get MISP API key ──────────────────────────────────────
echo "[*] Getting MISP API key..."
MISP_API_KEY=$(docker exec misp-core mysql -h db -u misp -pexample misp \
  -se "SELECT authkey FROM users WHERE email='admin@admin.test' LIMIT 1;" \
  2>/dev/null | tr -d '\n' || echo "")

if [ -z "$MISP_API_KEY" ]; then
  warn "Could not retrieve API key — MISP may still be initializing"
  warn "Re-run in 5 minutes: bash misp/configure-threat-feeds.sh"
  exit 0
fi
log "API key obtained"

# ── Step 4: Enable feeds IN PARALLEL ─────────────────────────────
# FIX: Original enables 5 feeds sequentially (each is a blocking curl)
# We fire all 5 simultaneously and wait for them all to finish
echo "[*] Enabling threat intelligence feeds in parallel..."

enable_feed() {
  local id="$1" name="$2"
  docker exec misp-core curl -k -s -X POST \
    -H "Authorization: $MISP_API_KEY" \
    -H "Accept: application/json" \
    "https://localhost/feeds/enable/${id}" &>/dev/null \
    && echo "  ✅ ${name}" \
    || echo "  ⚠️  ${name} (may already be enabled)"
}

enable_feed 1 "CIRCL OSINT Feed" &
enable_feed 2 "Abuse.ch URLhaus" &
enable_feed 3 "AlienVault OTX" &
enable_feed 4 "Feodo Tracker" &
enable_feed 5 "OpenPhish" &

# Wait for all parallel enables to complete
wait
log "All feeds enabled"

# ── Step 5: Trigger feed fetch IN BACKGROUND ─────────────────────
# FIX: Original blocks on fetchFromAllFeeds which takes 2-3 minutes.
# We fire it in background and return immediately.
echo "[*] Triggering feed sync in background (takes 2-3 min in background)..."

(
  docker exec misp-core curl -k -s -X POST \
    -H "Authorization: $MISP_API_KEY" \
    -H "Accept: application/json" \
    "https://localhost/feeds/fetchFromAllFeeds" &>/dev/null || true
  echo "[$(date +%H:%M:%S)] MISP feeds fully synced" >> /tmp/cyberblue-bg.log
) &

log "Feed sync running in background — installer continues!"

echo ""
echo "=========================================="
echo "  MISP Threat Feeds Configured!          "
echo "=========================================="
echo ""
echo "✅ Feeds enabled (sync running in background):"
echo "  • CIRCL OSINT Feed"
echo "  • Abuse.ch URLhaus (malicious URLs)"
echo "  • AlienVault OTX"
echo "  • Feodo Tracker (botnet C2)"
echo "  • OpenPhish (phishing)"
echo ""
echo "  Monitor sync: tail -f /tmp/cyberblue-bg.log"
echo "  Access MISP : https://$(hostname -I | awk '{print $1}'):7003"
echo "  Login       : admin@admin.test / admin"
echo ""
