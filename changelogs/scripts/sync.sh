#!/usr/bin/env bash
# Convenience wrapper for generate_changelog.py.
# Ensures PyYAML is available, then runs the generator.
#
# Usage:
#   ./changelogs/scripts/sync.sh [OPTIONS]
#   ./changelogs/scripts/sync.sh --dry-run
#   ./changelogs/scripts/sync.sh --repo api
#   ./changelogs/scripts/sync.sh --all
#   ./changelogs/scripts/sync.sh --since 2026-01-01
#
# Environment:
#   GITHUB_TOKEN   Set this to avoid GitHub API rate limits (5000 req/hr vs 60)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "[setup] Installing PyYAML..."
  pip3 install --quiet pyyaml
fi

exec python3 "${SCRIPT_DIR}/generate_changelog.py" "$@"
