#!/bin/bash
# =============================================================================
# Memory System CI Check — Validates memory/ files exist and are reasonable
# =============================================================================
# Add to CI workflows to ensure memory system stays maintained.
# Returns 0 if valid, 1 if issues found.
# =============================================================================
set -euo pipefail

ERRORS=0
WARNINGS=0

echo "Memory System Check"
echo "==================="

# Check MEMORY.md exists
if [ ! -f "memory/MEMORY.md" ]; then
  echo "ERROR: memory/MEMORY.md not found"
  ERRORS=$((ERRORS + 1))
else
  echo "✓ memory/MEMORY.md exists"

  # Check it's not empty
  LINES=$(wc -l < memory/MEMORY.md)
  if [ "$LINES" -lt 3 ]; then
    echo "WARNING: memory/MEMORY.md has only $LINES lines (seems sparse)"
    WARNINGS=$((WARNINGS + 1))
  elif [ "$LINES" -gt 200 ]; then
    echo "WARNING: memory/MEMORY.md has $LINES lines (should be <200, needs consolidation)"
    WARNINGS=$((WARNINGS + 1))
  else
    echo "✓ memory/MEMORY.md has $LINES lines (within limits)"
  fi
fi

# Check implementation_plan.md exists (optional but recommended)
if [ -f "memory/implementation_plan.md" ]; then
  echo "✓ memory/implementation_plan.md exists"
else
  echo "INFO: memory/implementation_plan.md not found (optional)"
fi

# Check lessons_learned.md exists (optional but recommended)
if [ -f "memory/lessons_learned.md" ]; then
  echo "✓ memory/lessons_learned.md exists"
else
  echo "INFO: memory/lessons_learned.md not found (optional)"
fi

# Check CLAUDE.md exists
if [ ! -f "CLAUDE.md" ]; then
  echo "ERROR: CLAUDE.md not found"
  ERRORS=$((ERRORS + 1))
else
  echo "✓ CLAUDE.md exists"
fi

echo ""
echo "Results: $ERRORS errors, $WARNINGS warnings"

if [ "$ERRORS" -gt 0 ]; then
  echo "FAIL: Memory system has errors"
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  echo "WARN: Memory system has warnings (not blocking)"
fi

exit 0
