#!/usr/bin/env bash
# run-ci.sh — language-detecting orchestrator invoked by toshi-bot inside the
# CI container. The container has the target repo bind-mounted at /work and
# this ci-templates repo bind-mounted at /ci-templates. We detect the language,
# dispatch to the right per-language runner, and return its exit code.
#
# Per-repo override: drop a one-line file at .toshi/lang containing one of
# {python, node}. Without it, we auto-detect from pyproject.toml / package.json.
#
# Why a separate orchestrator instead of inlining detection in toshi-bot:
# bot.js is Node, the runners are bash, and putting detection in bash means
# adding a new language is a one-file change in this repo, not a bot.js change.

set -uo pipefail

cd /work

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-repo override knobs via .toshi/ci.env. Lets a repo pin its own
# TOSHI_CI_LINT_PATHS / TOSHI_CI_TEST_COMMAND / TOSHI_CI_SKIP_* in-tree so
# toshi-bot's container env doesn't have to know about every repo. Sourcing
# under `set -a` exports the assignments so the per-language runner inherits
# them across `exec`. Values here override anything passed in via the
# container's environment.
if [[ -f .toshi/ci.env ]]; then
    echo "[run-ci] sourcing .toshi/ci.env"
    set -a
    # shellcheck disable=SC1091
    source .toshi/ci.env
    set +a
fi

# 1. Per-repo override
if [[ -f .toshi/lang ]]; then
    LANG_KEY="$(tr -d '[:space:]' <.toshi/lang)"
else
    # 2. Auto-detect (pyproject.toml wins over package.json when both exist —
    # we want Python tooling on hybrid repos because the Python tests are the
    # ones we care about for this fleet)
    if   [[ -f pyproject.toml ]]; then LANG_KEY=python
    elif [[ -f package.json   ]]; then LANG_KEY=node
    else
        echo "[run-ci] cannot detect language (no pyproject.toml or package.json, no .toshi/lang override)" >&2
        exit 64
    fi
fi

RUNNER="$LIB_DIR/${LANG_KEY}-ci.sh"
if [[ ! -x "$RUNNER" ]]; then
    echo "[run-ci] no runner for lang=$LANG_KEY at $RUNNER" >&2
    exit 65
fi

echo "[run-ci] lang=$LANG_KEY runner=$RUNNER"
exec "$RUNNER"
