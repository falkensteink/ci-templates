# Toshi-native CI scripts

These scripts run inside the CI container that toshi-bot spawns for each PR
or non-default-branch push. They are the runtime counterpart to the GitHub
Actions reusable workflows in `../.github/workflows/`.

## Why these exist

The fleet's CI is moving off GitHub Actions onto toshi-bot's self-hosted
pipeline (see incident notes 2026-04-29 — "what are we getting from GitHub
Actions that we couldn't just build on Toshi"). These scripts give toshi-bot
a single, reusable orchestration surface — when a webhook fires, toshi-bot
clones the repo, mounts this directory into a language-appropriate container,
and runs `run-ci.sh`. Per-repo lint/test definitions live as env-var
overrides; the defaults match how the existing Actions workflows are
configured today.

## Layout

| File             | Role                                                      |
|------------------|-----------------------------------------------------------|
| `run-ci.sh`      | Entry point. Sources `.toshi/ci.env`, detects language → dispatches to `*-ci.sh`. |
| `python-ci.sh`   | Ruff (lint + format) + project install + pytest.         |
| `node-ci.sh`     | npm install/ci + `npm run lint --if-present` + `npm test`. Runs in `node:20-bookworm-slim`. |

## Per-repo language override

Drop `.toshi/lang` in a repo to force a language when auto-detection guesses
wrong. One word, one of {`python`, `node`}. Without it, `pyproject.toml`
implies Python and `package.json` implies Node (Python wins on hybrid).
toshi-bot's `ci.js` reads this file post-clone to pick the container image
(Python container vs Node container).

## Per-repo customization (`.toshi/ci.env`)

Drop a `.toshi/ci.env` file in the repo to override defaults. The file is
sourced by `run-ci.sh` under `set -a`, so plain shell `KEY=value` lines
become exported env vars that the per-language runners pick up. Values here
override anything inherited from toshi-bot's container env.

**Python (`python-ci.sh`):**

| Variable                    | Default                              |
|-----------------------------|--------------------------------------|
| `TOSHI_CI_LINT_PATHS`       | first-found of: `apps core tests scripts src`, else `.` |
| `TOSHI_CI_TEST_COMMAND`     | `pytest -q --tb=short`               |
| `TOSHI_CI_REQUIREMENTS`     | `-e ".[dev]"` if `pyproject.toml` else `-r requirements.txt` |
| `TOSHI_CI_SKIP_LINT`        | unset (lint runs)                    |
| `TOSHI_CI_SKIP_TEST`        | unset (tests run)                    |

**Node (`node-ci.sh`):**

| Variable                    | Default                              |
|-----------------------------|--------------------------------------|
| `TOSHI_CI_NODE_INSTALL`     | `npm ci ...` if `package-lock.json`/`npm-shrinkwrap.json`, else `npm install ...` |
| `TOSHI_CI_LINT_COMMAND`     | `npm run lint --if-present`          |
| `TOSHI_CI_TEST_COMMAND`     | `npm test`                           |
| `TOSHI_CI_SKIP_LINT`        | unset (lint runs)                    |
| `TOSHI_CI_SKIP_TEST`        | unset (tests run)                    |

Example `.toshi/ci.env` for a Python repo with no tests yet:

```
TOSHI_CI_SKIP_TEST=1
```

Example for Spellstorm (custom test files):

```
TOSHI_CI_TEST_COMMAND=pytest test_game.py test_server.py -q --tb=short
```

## Exit codes

| Code | Meaning                                              |
|------|------------------------------------------------------|
| 0    | All checks passed                                    |
| 1+   | Lint or test failure (passed through from the tool)  |
| 64   | No language detected                                 |
| 65   | Language detected but no runner script exists        |
| 70   | Failed to install ruff                               |
| 71   | Failed to install project (pip install spec)         |
