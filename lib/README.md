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
| `run-ci.sh`      | Entry point. Detects language → dispatches to `*-ci.sh`. |
| `python-ci.sh`   | Ruff (lint + format) + project install + pytest.         |
| `node-ci.sh`     | _(planned)_ ESLint + npm test.                           |

## Per-repo override

Drop `.toshi/lang` in a repo to force a language when auto-detection guesses
wrong. One word, one of {`python`, `node`}. Without it, `pyproject.toml`
implies Python and `package.json` implies Node (Python wins on hybrid).

## Per-repo customization

Set env vars on the toshi-bot side (or in `.toshi/env` if added later):

| Variable                    | Default                              |
|-----------------------------|--------------------------------------|
| `TOSHI_CI_LINT_PATHS`       | first-found of: `apps core tests scripts src`, else `.` |
| `TOSHI_CI_TEST_COMMAND`     | `pytest -q --tb=short`               |
| `TOSHI_CI_REQUIREMENTS`     | `-e ".[dev]"` if `pyproject.toml` else `-r requirements.txt` |
| `TOSHI_CI_SKIP_LINT`        | unset (lint runs)                    |
| `TOSHI_CI_SKIP_TEST`        | unset (tests run)                    |

## Exit codes

| Code | Meaning                                              |
|------|------------------------------------------------------|
| 0    | All checks passed                                    |
| 1+   | Lint or test failure (passed through from the tool)  |
| 64   | No language detected                                 |
| 65   | Language detected but no runner script exists        |
| 70   | Failed to install ruff                               |
| 71   | Failed to install project (pip install spec)         |
