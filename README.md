# CI Templates

Shared reusable GitHub Actions workflows for all falkensteink projects.

## Available Workflows

| Workflow | Purpose | Used By |
|---|---|---|
| `python-ci.yml` | Ruff lint + pytest + pip-audit | NPC-PM, Spellstorm, birdmug-auth |
| `node-ci.yml` | ESLint + npm test + npm audit | Server Connect |
| `toshi-deploy.yml` | Self-hosted deploy to Toshi | All deployed projects |

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
