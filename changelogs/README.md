# 5Stack Centralized Changelog

This directory is the single source of truth for platform-wide release history
across all 5Stack repositories.

## Structure

```
changelogs/
  config.yml                   # Repository registry — add repos here
  state.json                   # Incremental sync cursor (committed to git)
  global/
    CHANGELOG.md               # Unified changelog across all repos
  repos/
    5stack-panel/
      CHANGELOG.md
    api/
      CHANGELOG.md
    web/
      CHANGELOG.md
    game-server/
      CHANGELOG.md
    game-streamer/
      CHANGELOG.md
```

## How It Works

1. `scripts/generate-changelog.py` reads `config.yml` for the list of repos.
2. For each repo it fetches commits (incremental — only since `state.json` cursor)
   and GitHub releases via the API.
3. Commit messages are parsed using the project's `type: description` convention
   (compatible with conventional commits).
4. Per-repo and global markdown files are written, then committed back by CI.

## Running Locally

```bash
# One-time setup
pip install pyyaml   # optional — the script has a built-in YAML parser fallback

# Set a PAT with read access to all 5stackgg repos
export GH_TOKEN=ghp_...

# Incremental sync (only new commits since last run)
python scripts/generate-changelog.py

# Full rebuild from scratch
python scripts/generate-changelog.py --full

# Sync a single repo only
python scripts/generate-changelog.py --repo api
```

## Adding a New Repository

1. Open `changelogs/config.yml`.
2. Append a new entry under `repositories`:
   ```yaml
   - name: new-service
     display_name: New Service
     branch: main
     description: What this repo does
   ```
3. Commit and push — the next scheduled workflow run will pick it up,
   or trigger the workflow manually with **full sync** enabled.

## CI / Automation

The workflow `.github/workflows/sync-changelog.yml` runs:
- **Scheduled** — every 6 hours
- **On push to `main`** — when `config.yml` changes
- **Manual** — via `workflow_dispatch` with optional `--full` flag

> **Required secret:** `CHANGELOG_PAT` — a GitHub Personal Access Token with
> `repo` (read) scope for all `5stackgg/*` repositories. The default
> `GITHUB_TOKEN` only covers the current repo.

## Supported Commit Types

| Prefix | Category |
|---|---|
| `feature:` / `feat:` | ✨ Features |
| `bug:` / `fix:` / `hotfix:` | 🐛 Bug Fixes |
| `breaking:` / `feat!:` | ⚠️ Breaking Changes |
| `security:` | 🔒 Security |
| `perf:` | ⚡ Performance |
| `refactor:` | ♻️ Refactors |
| `infra:` | 🏗️ Infrastructure |
| `deps:` | 📦 Dependencies |
| `ci:` | 👷 CI/CD |
| `docs:` | 📝 Documentation |
| `chore:` | 🔧 Chores |
| `style:` | 🎨 Style |
| `test:` | ✅ Tests |
| `revert:` | ⏪ Reverts |
| _(anything else)_ | 🔹 Other |

Repositories that do not use any prefix convention will have all commits
categorised as **Other** — they still appear correctly in the changelog.
