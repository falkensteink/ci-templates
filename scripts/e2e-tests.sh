#!/bin/bash
# =============================================================================
# Cross-Service E2E Tests
# =============================================================================
# Tests real flows across deployed services (auth → API → DB → response).
# Runs against either staging or production.
#
# Usage:
#   ./e2e-tests.sh                    # test production
#   ./e2e-tests.sh staging            # test staging (if staging URLs exist)
#   ssh falkensteink@192.168.5.2 "~/e2e-tests.sh"  # run from Toshi
# =============================================================================
set -euo pipefail

ENV="${1:-prod}"
TIMESTAMP=$(date "+%Y-%m-%d_%H:%M:%S")
PASSED=0
FAILED=0
TOTAL=0

# URLs per environment
if [ "$ENV" = "staging" ]; then
  AUTH_URL="https://staging-auth.birdmug.com"
  SPELLSTORM_URL="https://staging-spellstorm.birdmug.com"
  SCS_URL="https://staging-scs.birdmug.com"
  PORTAL_URL="https://staging-birdmug.com"
else
  AUTH_URL="https://accounts.birdmug.com"
  SPELLSTORM_URL="https://spellstorm.birdmug.com"
  SCS_URL="https://scs.birdmug.com"
  PORTAL_URL="https://birdmug.com"
fi

# Test user credentials (created once, used for E2E tests)
TEST_USER="e2etest$(date +%s | tail -c 8)"
TEST_PASS="E2eTestPass123!"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test runner
run_test() {
  local name="$1"
  local result="$2"
  TOTAL=$((TOTAL + 1))

  if [ "$result" = "PASS" ]; then
    PASSED=$((PASSED + 1))
    echo -e "  ${GREEN}✓${NC} $name"
  else
    FAILED=$((FAILED + 1))
    echo -e "  ${RED}✗${NC} $name — $result"
  fi
}

echo "═══════════════════════════════════════════════════════"
echo " E2E Tests — $ENV environment"
echo " $TIMESTAMP"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── TEST 1: Auth service health ─────────────────────────
echo "▶ Auth Service"
HEALTH=$(curl -sf "${AUTH_URL}/health" 2>/dev/null || echo "FAIL")
if echo "$HEALTH" | grep -qi "ok"; then
  run_test "Health check" "PASS"
else
  run_test "Health check" "Got: $HEALTH"
fi

# ── TEST 2: Register a test user ─────────────────────────
REGISTER_RESP=$(curl -sf -X POST "${AUTH_URL}/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${TEST_USER}\",\"password\":\"${TEST_PASS}\"}" 2>/dev/null || echo '{"error":"request failed"}')

if echo "$REGISTER_RESP" | grep -qi "token\|success\|created"; then
  run_test "Register user" "PASS"
elif echo "$REGISTER_RESP" | grep -qi "already exists"; then
  run_test "Register user (already exists)" "PASS"
else
  run_test "Register user" "Got: $(echo "$REGISTER_RESP" | head -c 100)"
fi

# ── TEST 3: Login and get JWT ─────────────────────────
LOGIN_RESP=$(curl -sf -X POST "${AUTH_URL}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${TEST_USER}\",\"password\":\"${TEST_PASS}\"}" 2>/dev/null || echo '{"error":"request failed"}')

TOKEN=$(echo "$LOGIN_RESP" | grep -oP '"token"\s*:\s*"\K[^"]+' 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
  run_test "Login → get JWT" "PASS"
else
  run_test "Login → get JWT" "No token in response: $(echo "$LOGIN_RESP" | head -c 100)"
fi

# ── TEST 4: Verify token via /api/roles/me ─────────────
if [ -n "$TOKEN" ]; then
  ROLES_RESP=$(curl -sf "${AUTH_URL}/api/roles/me" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo '{"error":"request failed"}')

  if echo "$ROLES_RESP" | grep -qi "roles\|username\|${TEST_USER}"; then
    run_test "Token validation (/api/roles/me)" "PASS"
  else
    run_test "Token validation (/api/roles/me)" "Got: $(echo "$ROLES_RESP" | head -c 100)"
  fi
else
  run_test "Token validation (skipped — no token)" "SKIP"
fi

echo ""

# ── TEST 5: Spellstorm serves game ─────────────────────
echo "▶ Spellstorm"
SS_RESP=$(curl -sf "${SPELLSTORM_URL}/" 2>/dev/null || echo "FAIL")
if echo "$SS_RESP" | grep -qi "spellstorm\|<!DOCTYPE"; then
  run_test "Serves game page" "PASS"
else
  run_test "Serves game page" "Got: $(echo "$SS_RESP" | head -c 80)"
fi

echo ""

# ── TEST 6: SCS API health ─────────────────────────────
echo "▶ Sports Credit Score"
SCS_HEALTH=$(curl -sf "${SCS_URL}/api/health" 2>/dev/null || echo "FAIL")
if echo "$SCS_HEALTH" | grep -qi "healthy"; then
  run_test "API health check" "PASS"
else
  run_test "API health check" "Got: $SCS_HEALTH"
fi

echo ""

# ── TEST 7: Portal serves and apps endpoint works ──────
echo "▶ BirdMug Portal"
PORTAL_RESP=$(curl -sf "${PORTAL_URL}/" 2>/dev/null || echo "FAIL")
if echo "$PORTAL_RESP" | grep -qi "birdmug\|<!DOCTYPE"; then
  run_test "Serves portal page" "PASS"
else
  run_test "Serves portal page" "Got: $(echo "$PORTAL_RESP" | head -c 80)"
fi

APPS_RESP=$(curl -sf "${PORTAL_URL}/api/apps" 2>/dev/null || echo "FAIL")
if echo "$APPS_RESP" | grep -qi "apps"; then
  run_test "Public /api/apps endpoint" "PASS"
else
  run_test "Public /api/apps endpoint" "Got: $(echo "$APPS_RESP" | head -c 80)"
fi

# ── TEST 8: Portal admin endpoint requires auth ────────
ADMIN_RESP=$(curl -s -o /dev/null -w "%{http_code}" "${PORTAL_URL}/api/status" 2>/dev/null || echo "000")
if [ "$ADMIN_RESP" = "401" ]; then
  run_test "Admin endpoint requires auth (401)" "PASS"
elif [ "$ADMIN_RESP" = "000" ]; then
  run_test "Admin endpoint requires auth" "Connection failed"
else
  run_test "Admin endpoint requires auth" "Got HTTP $ADMIN_RESP (expected 401)"
fi

echo ""

# ── TEST 9: Authenticated portal access ────────────────
if [ -n "$TOKEN" ]; then
  echo "▶ Cross-Service Auth Flow"
  AUTH_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "${PORTAL_URL}/api/status" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "000")

  if [ "$AUTH_STATUS" = "200" ]; then
    run_test "Portal admin with auth token (200)" "PASS"
  else
    run_test "Portal admin with auth token" "Got HTTP $AUTH_STATUS (expected 200)"
  fi
fi

echo ""

# ── SUMMARY ──────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
if [ "$FAILED" -eq 0 ]; then
  echo -e " ${GREEN}ALL PASSED${NC}: $PASSED/$TOTAL tests"
else
  echo -e " ${RED}$FAILED FAILED${NC}, $PASSED passed / $TOTAL total"
fi
echo "═══════════════════════════════════════════════════════"

# Cleanup: delete test user (best effort — won't exist if auth doesn't support it)
# Left in place for now — test users accumulate but are harmless

exit "$FAILED"
