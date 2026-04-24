# CI Templates

Shared reusable GitHub Actions workflows for all falkensteink projects.

## Available Workflows

| Workflow | Purpose | Used By |
|---|---|---|
| `python-ci.yml` | Ruff lint + pytest + pip-audit | NPC-PM, Spellstorm, birdmug-auth |
| `node-ci.yml` | ESLint + npm test + npm audit | Server Connect |
| `toshi-deploy.yml` | Self-hosted deploy to Toshi | All deployed projects |
| `compose-lint.yml` | FRAMEWORKS.md §3 compliance on docker-compose files | Any project with compose files |

## Usage

### Python CI
```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: ["**"]
  pull_request:
    branches: [main]

jobs:
  ci:
    uses: falkensteink/ci-templates/.github/workflows/python-ci.yml@main
    with:
      python-version: "3.12"
      working-directory: "."
      requirements-file: "requirements.txt"
      lint-paths: "src/ tests/"
      test-command: "pytest -q"
      has-tests: true
```

### Compose Lint (FRAMEWORKS.md §3)

Catches the drift that caused the 2026-04-23 Toshi boot-loop incident and
the subsequent fork-pattern epidemic (see the 2026-04-24 ModMaestro
compose-compliance audit). HIGH findings fail the job; MED/LOW/INFO are
annotations only.

```yaml
# .github/workflows/compose-lint.yml
name: Compose Lint
on:
  push:
    branches: ["**"]
  pull_request:
    branches: [main]

jobs:
  compose:
    uses: falkensteink/ci-templates/.github/workflows/compose-lint.yml@main
    with:
      compose-files: "docker-compose.prod.yml docker-compose.yml"
```

Rules:
- **R001 HIGH** — `restart: always` / `unless-stopped` banned (post-2026-04-23).
- **R002 HIGH** — no healthcheck on a service another service depends on with `condition: service_healthy` (silently broken).
- **R002 MED** — no healthcheck on other services (warning only).
- **R003 HIGH** — cloudflared with plain-list `depends_on` (tunnel forwards before app ready).
- **R004 LOW** — healthcheck missing `start_period`.
- **R005 INFO** — suspected heavy runner (worker / embedder / TTS / ML / indexer) without `cpus:` + `memory:` caps.

Override files (service blocks without `image:`/`build:`) have relaxed rules — they inherit from the base at merge time and aren't required to re-declare restart/healthcheck/etc.

### Deploy to Toshi (after CI passes)
```yaml
# .github/workflows/deploy.yml
name: Deploy
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]

jobs:
  deploy:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    uses: falkensteink/ci-templates/.github/workflows/toshi-deploy.yml@main
    with:
      project-directory: ~/MyProject
      branch: main
      doppler-project: my-project
      doppler-config: prd
    secrets:
      MATTERMOST_WEBHOOK_URL: ${{ secrets.MATTERMOST_WEBHOOK_URL }}
```
