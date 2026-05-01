#!/usr/bin/env bash
# node-ci.sh — opinionated Node lint + test runner. Invoked inside the CI
# container (default node:20-bookworm-slim, picked by toshi-bot's ci.js based
# on the cloned repo's .toshi/lang) by run-ci.sh. The target repo is at /work.
#
# Defaults match how every Node repo in the fleet is currently configured in
# its .github/workflows/ci.yml: install via npm ci (with npm install fallback
# for repos without a lockfile), then `npm run lint` if the script exists,
# then `npm test`. Per-repo overrides via env vars (set in .toshi/ci.env or
# from toshi-bot's container env):
#
#   TOSHI_CI_NODE_INSTALL    install command                  (default: `npm ci` if package-lock.json or npm-shrinkwrap.json, else `npm install --no-audit --no-fund`)
#   TOSHI_CI_LINT_COMMAND    lint command                     (default: `npm run lint --if-present`)
#   TOSHI_CI_TEST_COMMAND    test command                     (default: `npm test`)
#   TOSHI_CI_SKIP_LINT       set to 1 to skip the lint step
#   TOSHI_CI_SKIP_TEST       set to 1 to skip the test step
#
# Sections are ordered cheap-first: install, lint, test. A lint failure does
# not skip tests — npm projects often fail lint on a typo while tests still
# pass, and we want to surface both. Each section prints a banner so the log
# is easy to scan in the toshi-bot log viewer.

set -uo pipefail
cd /work

if [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
    DEFAULT_INSTALL='npm ci --no-audit --no-fund'
else
    DEFAULT_INSTALL='npm install --no-audit --no-fund'
fi

INSTALL_COMMAND="${TOSHI_CI_NODE_INSTALL:-$DEFAULT_INSTALL}"
LINT_COMMAND="${TOSHI_CI_LINT_COMMAND:-npm run lint --if-present}"
TEST_COMMAND="${TOSHI_CI_TEST_COMMAND:-npm test}"

banner() { echo; echo "=== $* ==="; }

banner "Installing dependencies ($INSTALL_COMMAND)"
# shellcheck disable=SC2086  # word-splitting on INSTALL_COMMAND is the contract
eval $INSTALL_COMMAND || exit 71

if [[ -z "${TOSHI_CI_SKIP_LINT:-}" ]]; then
    banner "Lint ($LINT_COMMAND)"
    # shellcheck disable=SC2086
    eval $LINT_COMMAND || exit $?
else
    banner "Lint: SKIPPED (TOSHI_CI_SKIP_LINT set)"
fi

if [[ -z "${TOSHI_CI_SKIP_TEST:-}" ]]; then
    banner "Tests ($TEST_COMMAND)"
    # shellcheck disable=SC2086
    eval $TEST_COMMAND || exit $?
else
    banner "Tests: SKIPPED (TOSHI_CI_SKIP_TEST set)"
fi

banner "OK"
exit 0
