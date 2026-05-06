#!/usr/bin/env python3
"""
5stack Centralized Changelog Generator

Pulls commits and releases from all configured repositories and writes
per-repository and global CHANGELOG.md files.

Requirements:
    pip install pyyaml

Environment variables:
    GITHUB_TOKEN   Recommended to avoid GitHub API rate limits.
                   Public repos work without a token (60 req/hr vs 5000 req/hr).

Usage:
    python3 changelogs/scripts/generate_changelog.py [OPTIONS]

Options:
    --since YYYY-MM-DD   Override the since date for all repos
    --repo  NAME         Only process a specific repo (as named in config.yml)
    --all                Re-process full lookback history (ignores saved state)
    --dry-run            Preview output without writing any files
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR    = Path(__file__).resolve().parent
CHANGELOGS_DIR = SCRIPT_DIR.parent
CONFIG_FILE   = CHANGELOGS_DIR / "config.yml"
SYNC_STATE_FILE = CHANGELOGS_DIR / "sync-state.json"
REPOS_DIR     = CHANGELOGS_DIR / "repos"
GLOBAL_CHANGELOG = CHANGELOGS_DIR / "CHANGELOG.md"

# ── Commit type classification ─────────────────────────────────────────────────
# Each entry: (type_key, display_label, [regex patterns matched against first line])
# First match wins; order determines priority.

COMMIT_TYPES: List[Tuple[str, str, List[str]]] = [
    ("breaking", "\U0001f6a8 Breaking Changes", [
        r"^breaking[\s:!]",
        r"^BREAKING[- ]CHANGE",
    ]),
    ("feature", "✨ Features", [
        r"^feat(?:ure)?[\s:!]",
        r"^add[\s:]",
        r"^new[\s:]",
    ]),
    ("fix", "\U0001f41b Bug Fixes", [
        r"^fix(?:up)?[\s:!]",
        r"^bug[\s:!]",
        r"^hotfix[\s:]",
    ]),
    ("perf", "⚡ Performance", [
        r"^perf(?:ormance)?[\s:!]",
    ]),
    ("refactor", "♻️ Refactoring", [
        r"^refactor[\s:!]",
    ]),
    ("deps", "\U0001f4e6 Dependencies", [
        r"^dep(?:s|endenc(?:y|ies))?[\s:!]",
        r"^bump[\s:]",
    ]),
    ("infra", "\U0001f3d7️ Infrastructure", [
        r"^infra[\s:!]",
        r"^ci[\s:!]",
        r"^cd[\s:!]",
        r"^build[\s:!]",
        r"^docker[\s:]",
        r"^k8s[\s:]",
    ]),
    ("docs", "\U0001f4dd Documentation", [
        r"^docs?[\s:!]",
    ]),
    ("test", "\U0001f9ea Tests", [
        r"^tests?[\s:!]",
        r"^spec[\s:]",
    ]),
    ("chore", "\U0001f527 Maintenance", [
        r"^chore[\s:!]",
        r"^maint(?:enance)?[\s:]",
        r"^style[\s:]",
        r"^format[\s:]",
        r"^cleanup[\s:]",
        r"^clean[\s:]",
        r"^update[\s:]",
    ]),
]

OTHER_KEY   = "other"
OTHER_LABEL = "\U0001f4cc Other"

# Commits matching these patterns are excluded from the changelog entirely.
SKIP_PATTERNS = [
    r"^Merge (pull request|branch)",
    r"^chore: update (metamod|sourcemod|counterstrikesharp) to version",
    r"^Revert ",
]


def classify(message: str) -> Tuple[str, str]:
    """Return (type_key, display_label) based on the commit's first line."""
    first = message.split("\n")[0].strip()
    for key, label, patterns in COMMIT_TYPES:
        for pat in patterns:
            if re.match(pat, first, re.IGNORECASE):
                return key, label
    return OTHER_KEY, OTHER_LABEL


def should_skip(message: str) -> bool:
    """Return True if this commit should be excluded from the changelog."""
    first = message.split("\n")[0].strip()
    return any(re.match(pat, first, re.IGNORECASE) for pat in SKIP_PATTERNS)


def clean_title(message: str) -> str:
    """Strip the conventional prefix and trailing PR reference; capitalize."""
    title = message.split("\n")[0].strip()
    title = re.sub(
        r"^(?:feat(?:ure)?|fix(?:up)?|bug|hotfix|chore|docs?|perf|refactor|"
        r"test|style|build|ci|infra|dep(?:s|endenc(?:y|ies))?|breaking|add|"
        r"new|update|bump|maint(?:enance)?)\s*[:\s!]\s*",
        "",
        title,
        flags=re.IGNORECASE,
    ).strip()
    title = re.sub(r"\s*\(#\d+\)\s*$", "", title).strip()
    return (title[:1].upper() + title[1:]) if title else title


# ── GitHub API ─────────────────────────────────────────────────────────────────

_TOKEN = os.environ.get("GITHUB_TOKEN", "")
_API   = "https://api.github.com"


def _headers() -> Dict[str, str]:
    h: Dict[str, str] = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if _TOKEN:
        h["Authorization"] = f"Bearer {_TOKEN}"
    return h


def gh_get(path: str, params: Optional[Dict[str, str]] = None) -> object:
    """Call the GitHub REST API and return parsed JSON."""
    url = f"{_API}{path}"
    if params:
        url += "?" + "&".join(f"{k}={v}" for k, v in params.items())
    req = urllib.request.Request(url, headers=_headers())
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        print(f"  [warn] GitHub API {exc.code}: {url}", file=sys.stderr)
        return []
    except Exception as exc:
        print(f"  [warn] {exc}: {url}", file=sys.stderr)
        return []


def fetch_commits(
    owner: str, repo: str, since_iso: str, branch: str
) -> List[dict]:
    """Fetch all commits newer than since_iso (paginates automatically)."""
    results: List[dict] = []
    page = 1
    while True:
        batch = gh_get(f"/repos/{owner}/{repo}/commits", {
            "sha":      branch,
            "since":    since_iso,
            "per_page": "100",
            "page":     str(page),
        })
        if not isinstance(batch, list) or not batch:
            break
        results.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return results


def fetch_releases(owner: str, repo: str, since_iso: str) -> List[dict]:
    """Fetch non-draft releases published after since_iso."""
    data = gh_get(f"/repos/{owner}/{repo}/releases", {"per_page": "100"})
    if not isinstance(data, list):
        return []
    return [
        r for r in data
        if not r.get("draft") and r.get("published_at", "") > since_iso
    ]


# ── Markdown helpers ────────────────────────────────────────────────────────────

def fmt_commit(commit: dict) -> str:
    sha   = commit["sha"][:7]
    url   = commit["html_url"]
    title = clean_title(commit["commit"]["message"])
    author = commit["commit"]["author"]["name"]
    return f"- {title} ([`{sha}`]({url})) — _{author}_"


def fmt_release(release: dict) -> str:
    tag  = release.get("tag_name", "")
    name = release.get("name") or tag
    url  = release.get("html_url", "")
    date = release.get("published_at", "")[:10]
    body = (release.get("body") or "").strip()

    line = f"- **[{name}]({url})** `{tag}` _{date}_"
    # Include release notes only if they are not just a raw number (e.g. Steam App ID)
    if body and not body.isdigit() and len(body) < 2000:
        notes = "\n".join(f"  {ln}" for ln in body.splitlines()[:15])
        line += f"\n{notes}"
    return line


def build_section(commits: List[dict], releases: List[dict]) -> str:
    """Build the markdown body for one repository's changelog entry."""
    parts: List[str] = []

    if releases:
        parts.append("#### \U0001f3f7️ Releases\n")
        for r in releases:
            parts.append(fmt_release(r))
        parts.append("")

    by_label: Dict[str, List[str]] = {}
    for c in commits:
        if should_skip(c["commit"]["message"]):
            continue
        _, label = classify(c["commit"]["message"])
        by_label.setdefault(label, []).append(fmt_commit(c))

    # Emit groups in canonical type order
    for _, label, _ in COMMIT_TYPES:
        if label in by_label:
            parts.append(f"#### {label}\n")
            parts.extend(by_label[label])
            parts.append("")
    if OTHER_LABEL in by_label:
        parts.append(f"#### {OTHER_LABEL}\n")
        parts.extend(by_label[OTHER_LABEL])
        parts.append("")

    return "\n".join(parts).strip() + "\n" if parts else ""


# ── File writers ───────────────────────────────────────────────────────────────

HISTORY_MARKER = "<!-- HISTORY -->"
GLOBAL_BEGIN   = "<!-- BEGIN GENERATED CONTENT -->"
GLOBAL_END     = "<!-- END GENERATED CONTENT -->"


def write_repo_changelog(
    repo_name: str,
    description: str,
    body: str,
    date_str: str,
    n_commits: int,
    n_releases: int,
) -> None:
    path = REPOS_DIR / repo_name / "CHANGELOG.md"
    path.parent.mkdir(parents=True, exist_ok=True)

    existing = ""
    if path.exists():
        text = path.read_text()
        if HISTORY_MARKER in text:
            existing = text[text.index(HISTORY_MARKER) + len(HISTORY_MARKER):].lstrip("\n")

    counts: List[str] = []
    if n_commits:
        counts.append(f"{n_commits} commit{'s' if n_commits != 1 else ''}")
    if n_releases:
        counts.append(f"{n_releases} release{'s' if n_releases != 1 else ''}")
    summary = f" _{', '.join(counts)}_" if counts else ""

    header = f"# Changelog — {repo_name}\n\n> {description}\n\n{HISTORY_MARKER}\n"
    entry  = f"## {date_str}{summary}\n\n{body}\n---\n\n"
    path.write_text(header + entry + existing)
    print(f"  Wrote changelogs/repos/{repo_name}/CHANGELOG.md")


def write_global_changelog(all_sections: Dict[str, str], date_str: str) -> None:
    existing = ""
    if GLOBAL_CHANGELOG.exists():
        text = GLOBAL_CHANGELOG.read_text()
        if GLOBAL_BEGIN in text and GLOBAL_END in text:
            existing = text[
                text.index(GLOBAL_BEGIN) + len(GLOBAL_BEGIN) : text.index(GLOBAL_END)
            ]

    new_block = f"\n## {date_str}\n\n"
    for repo_name, body in all_sections.items():
        if body.strip():
            new_block += (
                f"### [{repo_name}](https://github.com/5stackgg/{repo_name})\n\n"
                + body
                + "\n"
            )

    doc = (
        "# 5stack Platform Changelog\n\n"
        "> Auto-generated — single source of truth for all 5stack ecosystem changes.\n"
        "> Run `python3 changelogs/scripts/generate_changelog.py --help` for manual generation.\n\n"
        f"{GLOBAL_BEGIN}"
        + new_block
        + (existing or "")
        + f"\n{GLOBAL_END}\n"
    )
    GLOBAL_CHANGELOG.write_text(doc)
    print(f"  Wrote changelogs/CHANGELOG.md")


# ── State ──────────────────────────────────────────────────────────────────────

def load_state() -> dict:
    if SYNC_STATE_FILE.exists():
        return json.loads(SYNC_STATE_FILE.read_text())
    return {"repos": {}}


def save_state(state: dict) -> None:
    state["_updated_at"] = datetime.now(timezone.utc).isoformat()
    SYNC_STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")
    print("  Saved sync-state.json")


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Generate unified 5stack changelogs from GitHub commits and releases."
    )
    ap.add_argument(
        "--since", metavar="YYYY-MM-DD",
        help="Override the since date for all repos",
    )
    ap.add_argument(
        "--repo", metavar="NAME",
        help="Only process a specific repo (as named in config.yml)",
    )
    ap.add_argument(
        "--all", dest="all_history", action="store_true",
        help="Re-process full history (uses changelog_lookback_days, ignores saved state)",
    )
    ap.add_argument(
        "--dry-run", action="store_true",
        help="Preview output without writing files",
    )
    args = ap.parse_args()

    if not CONFIG_FILE.exists():
        sys.exit(f"Config file not found: {CONFIG_FILE}")

    with open(CONFIG_FILE) as f:
        config = yaml.safe_load(f)

    org: str           = config.get("org", "5stackgg")
    lookback: int      = config.get("changelog_lookback_days", 90)
    repos: List[dict]  = config.get("repositories", [])

    if args.repo:
        repos = [r for r in repos if r["name"] == args.repo]
        if not repos:
            sys.exit(f"No repo named '{args.repo}' found in config.yml")

    state   = load_state()
    today   = datetime.now(timezone.utc).date().isoformat()
    now_iso = datetime.now(timezone.utc).isoformat()

    sections: Dict[str, str] = {}

    for cfg in repos:
        repo_name:   str = cfg["name"]
        repo_slug:   str = cfg.get("repo", f"{org}/{repo_name}")
        description: str = cfg.get("description", "")
        branch:      str = cfg.get("default_branch", "main")
        owner, repo      = repo_slug.split("/", 1)

        print(f"\n── {repo_slug} ──")

        repo_state = state.get("repos", {}).get(repo_name, {})

        if args.since:
            since = args.since if "T" in args.since else f"{args.since}T00:00:00Z"
        elif args.all_history or not repo_state.get("last_synced_at"):
            since = (datetime.now(timezone.utc) - timedelta(days=lookback)).isoformat()
        else:
            since = repo_state["last_synced_at"]

        print(f"  since: {since[:10]}")

        commits  = fetch_commits(owner, repo, since, branch)
        visible  = [c for c in commits if not should_skip(c["commit"]["message"])]
        releases = fetch_releases(owner, repo, since)

        print(f"  commits:  {len(commits)} ({len(visible)} visible)")
        print(f"  releases: {len(releases)}")

        if not visible and not releases:
            print("  → nothing new, skipping")
            continue

        body = build_section(commits, releases)
        sections[repo_name] = body

        if args.dry_run:
            print(f"  [dry-run] Would write changelogs/repos/{repo_name}/CHANGELOG.md")
            print("  " + body[:300].replace("\n", "\n  ") + ("…" if len(body) > 300 else ""))
        else:
            write_repo_changelog(
                repo_name, description, body, today, len(visible), len(releases)
            )
            state.setdefault("repos", {})[repo_name] = {
                "last_synced_at": now_iso,
                **({
                    "last_sha": commits[0]["sha"]
                } if commits else {}),
            }

    if not sections:
        print("\nNo changes found across any repos.")
        return

    if args.dry_run:
        print("\n[dry-run] Would write changelogs/CHANGELOG.md")
    else:
        write_global_changelog(sections, today)
        save_state(state)

    print("\n✓ Done")


if __name__ == "__main__":
    main()
