#!/usr/bin/env python3
"""
5Stack Changelog Generator

Aggregates commits and releases from all configured 5stack repositories into
per-repo and global markdown changelogs inside changelogs/.

Usage:
  python scripts/generate-changelog.py [--full] [--repo <name>]

Flags:
  --full        Ignore state.json and fetch full commit history for all repos.
  --repo NAME   Only sync the named repository (must exist in config.yml).

Required environment variable:
  GH_TOKEN   GitHub token with read access to all configured repos.
             (GITHUB_TOKEN also accepted as fallback)
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).parent.parent
CONFIG_FILE = REPO_ROOT / "changelogs" / "config.yml"
STATE_FILE = REPO_ROOT / "changelogs" / "state.json"
GLOBAL_CHANGELOG = REPO_ROOT / "changelogs" / "global" / "CHANGELOG.md"
REPOS_DIR = REPO_ROOT / "changelogs" / "repos"

GITHUB_API = "https://api.github.com"

# ---------------------------------------------------------------------------
# Commit type mapping
# Handles both 5stack-style ("bug:", "feature:") and conventional commits
# ("fix:", "feat:").  Repos without any prefix still work — their commits
# end up in the "Other" bucket.
# ---------------------------------------------------------------------------

COMMIT_TYPE_MAP: dict[str, str] = {
    "feat": "Features",
    "feature": "Features",
    "fix": "Bug Fixes",
    "bug": "Bug Fixes",
    "hotfix": "Bug Fixes",
    "security": "Security",
    "perf": "Performance",
    "refactor": "Refactors",
    "infra": "Infrastructure",
    "deps": "Dependencies",
    "build": "Build",
    "ci": "CI/CD",
    "docs": "Documentation",
    "chore": "Chores",
    "style": "Style",
    "test": "Tests",
    "revert": "Reverts",
    "breaking": "Breaking Changes",
}

TYPE_ORDER = [
    "Breaking Changes",
    "Security",
    "Features",
    "Bug Fixes",
    "Performance",
    "Refactors",
    "Infrastructure",
    "Dependencies",
    "CI/CD",
    "Documentation",
    "Chores",
    "Style",
    "Tests",
    "Build",
    "Reverts",
    "Other",
]

TYPE_EMOJI = {
    "Breaking Changes": "⚠️",
    "Security": "\U0001f512",
    "Features": "✨",
    "Bug Fixes": "\U0001f41b",
    "Performance": "⚡",
    "Refactors": "♻️",
    "Infrastructure": "\U0001f3d7️",
    "Dependencies": "\U0001f4e6",
    "CI/CD": "\U0001f477",
    "Documentation": "\U0001f4dd",
    "Chores": "\U0001f527",
    "Style": "\U0001f3a8",
    "Tests": "✅",
    "Build": "\U0001f6e0️",
    "Reverts": "⏪",
    "Other": "\U0001f539",
}


# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------


def _token() -> str:
    tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not tok:
        sys.exit("Error: GH_TOKEN environment variable is not set")
    return tok


def _api_request(url: str, token: str):
    """Single GET to GitHub API. Returns (data, link_header) or (None, '')."""
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github.v3+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "5stack-changelog-generator/1.0")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read()), resp.headers.get("Link", "")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None, ""
        print(f"  Warning: HTTP {exc.code} for {url}", file=sys.stderr)
        return None, ""
    except Exception as exc:  # noqa: BLE001
        print(f"  Warning: {exc} for {url}", file=sys.stderr)
        return None, ""


def _next_url(link_header: str) -> str | None:
    """Extract the 'next' URL from a GitHub Link header."""
    for part in link_header.split(","):
        if 'rel="next"' in part:
            m = re.search(r"<([^>]+)>", part)
            if m:
                return m.group(1)
    return None


def _paginate(path: str, token: str, extra_params: dict | None = None) -> list:
    """Fetch every page of a list endpoint."""
    params = {"per_page": "100"}
    if extra_params:
        params.update(extra_params)
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    url: str | None = f"{GITHUB_API}/{path.lstrip('/')}?{qs}"
    items: list = []
    while url:
        data, link = _api_request(url, token)
        if data is None:
            break
        items.extend(data if isinstance(data, list) else [data])
        url = _next_url(link)
    return items


# ---------------------------------------------------------------------------
# Data fetchers
# ---------------------------------------------------------------------------


def fetch_commits(
    org: str, repo: str, branch: str, since_sha: str | None, token: str
) -> list[dict]:
    """
    Return commits from HEAD down to (not including) since_sha, newest first.
    If since_sha is None, returns the full history.
    """
    url: str | None = (
        f"{GITHUB_API}/repos/{org}/{repo}/commits?sha={branch}&per_page=100"
    )
    commits: list[dict] = []
    while url:
        data, link = _api_request(url, token)
        if not data:
            break
        stop = False
        for c in data:
            if since_sha and c["sha"] == since_sha:
                stop = True
                break
            commits.append(
                {
                    "sha": c["sha"],
                    "short_sha": c["sha"][:7],
                    "message": c["commit"]["message"],
                    "date": c["commit"]["author"]["date"],
                    "author": c["commit"]["author"]["name"],
                    "url": c["html_url"],
                }
            )
        if stop:
            break
        url = _next_url(link)
    return commits


def fetch_releases(org: str, repo: str, token: str) -> list[dict]:
    data = _paginate(f"repos/{org}/{repo}/releases", token)
    return [
        {
            "tag": r["tag_name"],
            "name": r.get("name") or r["tag_name"],
            "date": r.get("published_at", ""),
            "body": (r.get("body") or "").strip(),
            "url": r["html_url"],
            "prerelease": r.get("prerelease", False),
        }
        for r in (data or [])
    ]


# ---------------------------------------------------------------------------
# Commit parsing
# ---------------------------------------------------------------------------


def parse_commit(message: str) -> tuple[str, str]:
    """
    Parse (type_label, description) from a commit message.

    Handles:
      - 5stack style:         "feature: add thing (#123)"
      - Conventional commits: "feat(scope): add thing"
      - Breaking:             "feat!: breaking change"
      - Plain messages:       "Some change"
    """
    first = message.split("\n")[0].strip()

    # type(optional-scope)!: description  (optional trailing PR ref)
    m = re.match(
        r"^([a-zA-Z]+)(?:\([^)]*\))?(!)\s*:\s+(.+?)(?:\s+\(#\d+\))?$", first
    )
    if m:
        return "Breaking Changes", m.group(3).strip()

    m = re.match(
        r"^([a-zA-Z]+)(?:\([^)]*\))?\s*:\s+(.+?)(?:\s+\(#\d+\))?$", first
    )
    if m:
        raw = m.group(1).lower()
        desc = m.group(2).strip()
        return COMMIT_TYPE_MAP.get(raw, "Other"), desc

    # No prefix — strip trailing PR ref and return as Other
    cleaned = re.sub(r"\s+\(#\d+\)\s*$", "", first).strip()
    return "Other", cleaned


# ---------------------------------------------------------------------------
# Markdown rendering
# ---------------------------------------------------------------------------


def _fmt_date(iso: str) -> str:
    return iso[:10] if iso else "Unknown"


def _now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def _group_by_date(commits: list[dict]) -> dict[str, list]:
    grouped: dict[str, list] = {}
    for c in commits:
        grouped.setdefault(_fmt_date(c["date"]), []).append(c)
    return dict(sorted(grouped.items(), reverse=True))


def _group_by_type(commits: list[dict]) -> dict[str, list]:
    grouped: dict[str, list] = {}
    for c in commits:
        label, desc = parse_commit(c["message"])
        grouped.setdefault(label, []).append({**c, "description": desc})
    return grouped


def _render_type_sections(
    by_type: dict[str, list], repo_label: str | None = None
) -> str:
    lines: list[str] = []
    seen: set[str] = set()

    for label in TYPE_ORDER:
        if label not in by_type:
            continue
        seen.add(label)
        emoji = TYPE_EMOJI.get(label, "")
        lines.append(f"\n**{emoji} {label}**\n")
        for c in by_type[label]:
            prefix = f"**[{repo_label}]** " if repo_label else ""
            lines.append(
                f"- {prefix}{c['description']} "
                f"([`{c['short_sha']}`]({c['url']}))"
            )

    for label, entries in by_type.items():
        if label in seen:
            continue
        emoji = TYPE_EMOJI.get(label, "\U0001f539")
        lines.append(f"\n**{emoji} {label}**\n")
        for c in entries:
            prefix = f"**[{repo_label}]** " if repo_label else ""
            lines.append(
                f"- {prefix}{c['description']} "
                f"([`{c['short_sha']}`]({c['url']}))"
            )

    return "\n".join(lines)


def render_repo_changelog(
    repo_cfg: dict, commits: list[dict], releases: list[dict]
) -> str:
    org = repo_cfg["org"]
    repo = repo_cfg["name"]
    display = repo_cfg["display_name"]
    gh_url = f"https://github.com/{org}/{repo}"

    lines = [
        f"# {display} Changelog\n",
        f"> Auto-generated from [{org}/{repo}]({gh_url})  ",
        f"> Last updated: {_now_utc()}\n",
    ]

    if releases:
        lines.append("## Releases\n")
        for rel in releases:
            pre = " _(pre-release)_" if rel["prerelease"] else ""
            lines.append(
                f"### [{rel['name']}]({rel['url']}) "
                f"— {_fmt_date(rel['date'])}{pre}\n"
            )
            if rel["body"]:
                lines.append(rel["body"])
                lines.append("")

    if commits:
        lines.append("## Commits\n")
        for date, day_commits in _group_by_date(commits).items():
            lines.append(f"### {date}\n")
            lines.append(_render_type_sections(_group_by_type(day_commits)))
            lines.append("")

    if not commits and not releases:
        lines.append(
            "_No changes recorded yet. "
            "Run the sync workflow to populate this file._\n"
        )

    return "\n".join(lines)


def render_global_changelog(
    all_commits: dict[str, list[dict]], config: dict
) -> str:
    org = config["org"]
    lines = [
        "# 5Stack Platform Changelog\n",
        "> Auto-generated — unified view across all 5Stack repositories  ",
        f"> Last updated: {_now_utc()}\n",
        "## Repositories\n",
    ]
    for repo in config["repositories"]:
        desc = repo.get("description", "")
        suffix = f" — {desc}" if desc else ""
        lines.append(
            f"- **[{repo['display_name']}]"
            f"(https://github.com/{org}/{repo['name']})**"
            f"{suffix}  "
            f"([Changelog](../repos/{repo['name']}/CHANGELOG.md))"
        )

    # Flatten all commits, attaching repo metadata
    flat: list[dict] = []
    for repo_name, commits in all_commits.items():
        display = next(
            (r["display_name"] for r in config["repositories"] if r["name"] == repo_name),
            repo_name,
        )
        for c in commits:
            flat.append({**c, "_repo": repo_name, "_display": display})

    flat.sort(key=lambda c: c["date"], reverse=True)

    if not flat:
        lines.append(
            "\n_No changes recorded yet. "
            "Run the sync workflow to populate this file._\n"
        )
        return "\n".join(lines)

    lines.append("\n## All Changes\n")

    by_date: dict[str, list] = {}
    for c in flat:
        by_date.setdefault(_fmt_date(c["date"]), []).append(c)

    for date in sorted(by_date.keys(), reverse=True):
        day = by_date[date]
        lines.append(f"### {date}\n")
        by_type = _group_by_type(day)
        seen: set[str] = set()

        for label in TYPE_ORDER:
            if label not in by_type:
                continue
            seen.add(label)
            emoji = TYPE_EMOJI.get(label, "")
            lines.append(f"\n**{emoji} {label}**\n")
            for c in by_type[label]:
                lines.append(
                    f"- **[{c['_display']}]** {c['description']} "
                    f"([`{c['short_sha']}`]({c['url']}))"
                )

        for label, entries in by_type.items():
            if label in seen:
                continue
            emoji = TYPE_EMOJI.get(label, "\U0001f539")
            lines.append(f"\n**{emoji} {label}**\n")
            for c in entries:
                lines.append(
                    f"- **[{c['_display']}]** {c['description']} "
                    f"([`{c['short_sha']}`]({c['url']}))"
                )
        lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Config / state helpers
# ---------------------------------------------------------------------------


def load_config() -> dict:
    if not CONFIG_FILE.exists():
        sys.exit(f"Config not found: {CONFIG_FILE}")
    content = CONFIG_FILE.read_text()
    try:
        import yaml  # type: ignore[import-not-found]
        cfg = yaml.safe_load(content)
    except ImportError:
        cfg = _parse_yaml(content)
    org = cfg["org"]
    for r in cfg.get("repositories", []):
        r.setdefault("org", org)
        r.setdefault("branch", "main")
    return cfg


def _parse_yaml(text: str) -> dict:
    """
    Minimal YAML parser for changelogs/config.yml.
    Handles the simple two-level structure we use; not a general YAML parser.
    """
    result: dict = {}
    repos: list = []
    current_repo: dict | None = None
    in_repos = False

    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.strip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        s = line.strip()

        if indent == 0:
            if s == "repositories:":
                in_repos = True
                result["repositories"] = repos
            elif ":" in s:
                k, _, v = s.partition(":")
                result[k.strip()] = v.strip()
                in_repos = False
        elif indent == 2 and in_repos:
            if s.startswith("- "):
                current_repo = {}
                repos.append(current_repo)
                rest = s[2:].strip()
                if ":" in rest:
                    k, _, v = rest.partition(":")
                    current_repo[k.strip()] = v.strip()
            elif ":" in s and current_repo is not None:
                k, _, v = s.partition(":")
                current_repo[k.strip()] = v.strip()
        elif indent == 4 and current_repo is not None:
            if ":" in s:
                k, _, v = s.partition(":")
                current_repo[k.strip()] = v.strip()

    return result


def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate 5Stack changelogs from GitHub commits and releases."
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help="Ignore state.json and fetch the full commit history.",
    )
    parser.add_argument(
        "--repo",
        metavar="NAME",
        help="Only sync this repository (must match a name in config.yml).",
    )
    args = parser.parse_args()

    token = _token()
    config = load_config()
    state: dict = {} if args.full else load_state()
    org = config["org"]

    repos = config["repositories"]
    if args.repo:
        repos = [r for r in repos if r["name"] == args.repo]
        if not repos:
            sys.exit(f"Repository '{args.repo}' not found in config.yml")

    all_commits: dict[str, list] = {}
    updated_state = {**state}

    label = "repositories" if len(repos) != 1 else "repository"
    print(f"Syncing changelogs for {len(repos)} {label}...")
    if args.full:
        print("  (full sync — ignoring state.json)")

    for repo_cfg in repos:
        repo_name = repo_cfg["name"]
        branch = repo_cfg.get("branch", "main")
        last_sha = state.get(repo_name, {}).get("last_sha")
        mode = f"incremental from {last_sha[:7]}" if last_sha else "full history"
        print(f"  {org}/{repo_name}  [{mode}]", end="", flush=True)

        commits = fetch_commits(org, repo_name, branch, last_sha, token)
        releases = fetch_releases(org, repo_name, token)
        print(f" -> {len(commits)} commits, {len(releases)} releases")

        out_dir = REPOS_DIR / repo_name
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "CHANGELOG.md").write_text(
            render_repo_changelog(repo_cfg, commits, releases)
        )

        all_commits[repo_name] = commits

        if commits:
            updated_state[repo_name] = {
                "last_sha": commits[0]["sha"],
                "last_synced": datetime.now(timezone.utc).isoformat(),
                "repo": f"{org}/{repo_name}",
                "branch": branch,
            }

    GLOBAL_CHANGELOG.parent.mkdir(parents=True, exist_ok=True)
    GLOBAL_CHANGELOG.write_text(render_global_changelog(all_commits, config))
    save_state(updated_state)

    print("\nChangelogs written:")
    print(f"  {GLOBAL_CHANGELOG.relative_to(REPO_ROOT)}")
    for repo_cfg in repos:
        print(f"  changelogs/repos/{repo_cfg['name']}/CHANGELOG.md")
    print(f"  changelogs/state.json  (cursor updated)")


if __name__ == "__main__":
    main()
