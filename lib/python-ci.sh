#!/usr/bin/env bash
# python-ci.sh — opinionated Python lint + test runner. Invoked inside the
# CI container (python:3.12-slim) by run-ci.sh. The target repo is at /work.
#
# Defaults match how every Python repo in the fleet is currently configured
# in its .github/workflows/ci.yml. Per-repo overrides via env vars:
#
#   TOSHI_CI_LINT_PATHS     space-separated paths to lint    (default: apps core tests scripts, falling back to . if any are missing)
#   TOSHI_CI_TEST_COMMAND   command to run tests             (default: pytest -q --tb=short)
#   TOSHI_CI_REQUIREMENTS   pip install spec                 (default: -e ".[dev]" if pyproject.toml exists, else -r requirements.txt)
#   TOSHI_CI_SKIP_LINT      set to 1 to skip the lint step
#   TOSHI_CI_SKIP_TEST      set to 1 to skip the test step
#   BIRDMUG_AUTH_READ       fine-grained PAT for cloning private build deps (Contents:Read on falkensteink/birdmug-auth);
#                           toshi-bot's CI runner injects this from Doppler so pyproject.toml pins like
#                           `birdmug-auth-client @ git+https://github.com/falkensteink/birdmug-auth@<sha>` resolve.
#
# Sections are ordered cheap-first so a lint failure doesn't make us pay for
# a 5-minute pip install. Each section prints a banner so the log is easy to
# scan in the toshi-bot log viewer / Loki.

set -uo pipefail
cd /work

# Auto-pick lint paths that actually exist (avoids "ruff: error: paths/apps not found"
# on repos that use a different layout).
default_lint_paths=""
for p in apps core tests scripts src; do
    if [[ -d "$p" ]]; then default_lint_paths="$default_lint_paths $p"; fi
done
default_lint_paths="${default_lint_paths# }"
[[ -z "$default_lint_paths" ]] && default_lint_paths="."

LINT_PATHS="${TOSHI_CI_LINT_PATHS:-$default_lint_paths}"
TEST_COMMAND="${TOSHI_CI_TEST_COMMAND:-pytest -q --tb=short}"

if [[ -n "${TOSHI_CI_REQUIREMENTS:-}" ]]; then
    INSTALL_SPEC="$TOSHI_CI_REQUIREMENTS"
elif [[ -f pyproject.toml ]]; then
    INSTALL_SPEC='-e .[dev]'
elif [[ -f requirements.txt ]]; then
    INSTALL_SPEC='-r requirements.txt'
else
    INSTALL_SPEC=""
fi

banner() { echo; echo "=== $* ==="; }

# Ruff is small and the expected case for fleet repos. Install it up-front
# so a lint-only failure doesn't even need the full project install.
banner "Installing ruff"
pip install --disable-pip-version-check --quiet --no-input ruff || exit 70

if [[ -z "${TOSHI_CI_SKIP_LINT:-}" ]]; then
    banner "Ruff check ($LINT_PATHS)"
    ruff check $LINT_PATHS || exit $?
    banner "Ruff format --check ($LINT_PATHS)"
    ruff format --check $LINT_PATHS || exit $?
else
    banner "Ruff: SKIPPED (TOSHI_CI_SKIP_LINT set)"
fi

if [[ -z "${TOSHI_CI_SKIP_TEST:-}" ]]; then
    # Private-repo build dep support. If toshi-bot injected a fine-grained PAT
    # for falkensteink/birdmug-auth (as $BIRDMUG_AUTH_READ), set up a
    # .netrc so `pip install` can clone git+https://github.com/... URLs
    # that pyproject.toml may pin. The .netrc lives in /root for the duration
    # of pip install only — removed in the trap so an interrupted run doesn't
    # leave the token on disk.
    cleanup_netrc() { rm -f /root/.netrc 2>/dev/null || true; }
    trap cleanup_netrc EXIT
    if [[ -n "${BIRDMUG_AUTH_READ:-}" ]]; then
        banner "Setting up authenticated github.com access for build (.netrc)"
        printf 'machine github.com\nlogin x-access-token\npassword %s\n' "$BIRDMUG_AUTH_READ" > /root/.netrc
        chmod 600 /root/.netrc
    fi

    if [[ -n "$INSTALL_SPEC" ]]; then
        banner "Installing project ($INSTALL_SPEC)"
        # shellcheck disable=SC2086  # we want word-splitting on INSTALL_SPEC
        pip install --disable-pip-version-check --quiet --no-input $INSTALL_SPEC || { cleanup_netrc; exit 71; }
    else
        banner "No requirements detected, skipping pip install"
    fi

    cleanup_netrc

    banner "Running tests: $TEST_COMMAND"
    # shellcheck disable=SC2086  # word-splitting on TEST_COMMAND is the contract
    eval $TEST_COMMAND || exit $?
else
    banner "Tests: SKIPPED (TOSHI_CI_SKIP_TEST set)"
fi

banner "OK"
exit 0
