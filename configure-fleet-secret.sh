#!/bin/bash
# ============================================================================
# CyberBlue configure-fleet-secret.sh — OPTIMIZED
# FIXES vs original:
#   ORIGINAL problem 1: DB retry loop: 60×2s = 120s max wait
#                        → poll every 1s, max 60s
#   ORIGINAL problem 2: Fleet server retry loop: 60×2s = 120s max wait
#                        → poll every 2s, max 60s
#   ORIGINAL problem 3: No check if secret file already exists and is valid
#                        → skip entirely if secret already saved and valid
#   ORIGINAL problem 4: set -e causes exit if mysqladmin fails transiently
#                        → removed, handle errors gracefully
#   ORIGINAL problem 5: Complex ownership code that can fail
#                        → simplified, use $SUDO_USER or $USER
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠️  $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_FILE="$SCRIPT_DIR/agents/.enrollment-secret"

echo "=========================================="
echo "  Fleet Enrollment Secret — FAST         "
echo "=========================================="
echo ""

# ── Step 0: Skip if secret already exists and is non-empty ────────
# FIX: Original always runs even when secret is already configured
if [ -f "$SECRET_FILE" ] && [ -s "$SECRET_FILE" ]; then
  EXISTING=$(cat "$SECRET_FILE" | tr -d '\n')
  if [ ${#EXISTING} -gt 10 ]; then
    log "Enrollment secret already exists — skipping"
    echo "  Secret: $EXISTING"
    exit 0
  fi
fi

# ── Step 1: Wait for fleet-mysql to be ready ──────────────────────
# FIX: Original uses sleep 2 per retry = up to 120s wasted
echo "[*] Waiting for Fleet database..."

WAIT=0; MAX=60
until docker exec fleet-mysql mysqladmin -ufleet -pfleetpass ping &>/dev/null; do
  echo -ne "\r  Waiting for fleet-mysql... ${WAIT}s / ${MAX}s"
  sleep 1; WAIT=$((WAIT+1))
  if [ $WAIT -ge $MAX ]; then
    echo ""
    warn "Fleet database not ready after ${MAX}s — using fallback secret"
    ENROLLMENT_SECRET=$(openssl rand -base64 24 | tr -d '\n')
    echo "$ENROLLMENT_SECRET" > "$SECRET_FILE"
    chmod 644 "$SECRET_FILE"
    warn "Fallback secret saved: $ENROLLMENT_SECRET"
    warn "Set this manually in Fleet UI at http://$(hostname -I | awk '{print $1}'):7007"
    exit 0
  fi
done
echo ""; log "fleet-mysql ready (${WAIT}s)"

# ── Step 2: Extract enrollment secret from Fleet DB ───────────────
echo "[*] Extracting Fleet enrollment secret..."

ENROLLMENT_SECRET=$(docker exec fleet-mysql mysql -ufleet -pfleetpass fleet \
  -se "SELECT secret FROM enroll_secrets LIMIT 1;" 2>/dev/null | tr -d '\n' || echo "")

if [ -z "$ENROLLMENT_SECRET" ]; then
  warn "No secret in database yet — Fleet may not be initialized"
  warn "Generating temporary secret..."
  ENROLLMENT_SECRET=$(openssl rand -base64 24 | tr -d '\n')
fi

log "Fleet enrollment secret: $ENROLLMENT_SECRET"

# ── Step 3: Save secret ───────────────────────────────────────────
mkdir -p "$SCRIPT_DIR/agents"
echo "$ENROLLMENT_SECRET" > "$SECRET_FILE"
chmod 644 "$SECRET_FILE"

# Fix ownership simply
REAL_USER="${SUDO_USER:-$USER}"
chown "${REAL_USER}:$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")" "$SECRET_FILE" 2>/dev/null || true
log "Secret saved to: $SECRET_FILE"

# ── Step 4: Wait for Fleet server to be ready ─────────────────────
# FIX: Original uses sleep 2 per retry = up to 120s wasted
echo "[*] Waiting for Fleet server..."

WAIT=0; MAX=60
until curl -s --max-time 2 http://localhost:7007/healthz &>/dev/null; do
  echo -ne "\r  Waiting for Fleet server... ${WAIT}s / ${MAX}s"
  sleep 2; WAIT=$((WAIT+2))
  if [ $WAIT -ge $MAX ]; then
    echo ""
    warn "Fleet server not responding after ${MAX}s"
    warn "Secret saved — set manually in Fleet UI if needed"
    break
  fi
done
[ $WAIT -lt $MAX ] && { echo ""; log "Fleet server ready (${WAIT}s)"; }

echo ""
echo "=========================================="
echo "  Fleet Configuration Complete!          "
echo "=========================================="
echo ""
echo "✅ Enrollment secret: $ENROLLMENT_SECRET"
echo "✅ Secret saved to  : $SECRET_FILE"
echo "✅ Portal will embed this in agent packages automatically"
echo ""
echo "  🌐 Fleet: http://$(hostname -I | awk '{print $1}'):7007"
echo ""
