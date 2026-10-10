#!/usr/bin/env python3
"""Keep Forgejo stocked with pull mirrors of a GitHub user's public repos.

Forgejo refreshes the *contents* of a mirror itself, on each mirror's own
interval. This script only reconciles the *set*: it notices repositories that
exist on GitHub and not yet in Forgejo, and creates them as mirrors. Running
it daily is therefore enough to pick up new repositories; it is not what keeps
existing ones current.

Nothing is ever deleted here. A repository removed from GitHub stays in
Forgejo as a stale mirror, which is the safer direction for a backup.

Configuration comes from the environment, or from an env file of KEY=VALUE
lines (default ~/.config/forgejo-mirror.env, mode 0600):

    FORGEJO_URL        e.g. https://git.example.com
    FORGEJO_TOKEN      token with write:repository and read:user
    FORGEJO_OWNER      user the mirrors belong to
    GITHUB_USER        account whose public repos are mirrored
    GITHUB_TOKEN       optional; only raises the API rate limit
    MIRROR_INTERVAL    optional, default 24h
    INCLUDE_FORKS      optional, default 0
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ENV_FILE = Path(os.environ.get("FORGEJO_MIRROR_ENV", "~/.config/forgejo-mirror.env")).expanduser()


def load_env_file(path: Path) -> None:
    """Fill os.environ from a KEY=VALUE file. Real environment wins."""
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def api(url: str, token: str | None = None, scheme: str = "token", data: dict | None = None) -> object:
    body = json.dumps(data).encode() if data is not None else None
    request = urllib.request.Request(url, data=body, method="POST" if body else "GET")
    request.add_header("Accept", "application/json")
    if body:
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"{scheme} {token}")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read() or "null")


def github_repos(user: str, token: str | None, include_forks: bool) -> list[dict]:
    repos, page = [], 1
    while True:
        batch = api(
            f"https://api.github.com/users/{user}/repos?per_page=100&type=owner&page={page}",
            token,
            scheme="Bearer",
        )
        if not batch:
            break
        repos.extend(batch)
        page += 1
    return [
        r for r in repos
        if not r["private"] and (include_forks or not r["fork"])
    ]


def forgejo_repos(base: str, token: str, owner: str) -> set[str]:
    """Names already present *under owner*.

    /user/repos also returns repositories the token can merely see — other
    owners', or ones shared through a team. Matching on bare names would then
    skip creating owner/foo because somebody-else/foo exists.
    """
    names, page = set(), 1
    while True:
        batch = api(f"{base}/api/v1/user/repos?limit=50&page={page}", token)
        if not batch:
            break
        names.update(
            r["name"].lower()
            for r in batch
            if r["owner"]["login"].lower() == owner.lower()
        )
        page += 1
    return names


def migrate_with_retry(base: str, token: str, payload: dict, attempts: int = 3) -> None:
    """Create one mirror, retrying the failures that are worth retrying.

    429 and 5xx are the server asking for patience. Everything else — 409
    because it already exists, 422 because the clone address is bad — will
    fail identically on a second try, so it is raised immediately.
    """
    for attempt in range(1, attempts + 1):
        try:
            api(f"{base}/api/v1/repos/migrate", token, data=payload)
            return
        except urllib.error.HTTPError as error:
            retryable = error.code == 429 or 500 <= error.code < 600
            if not retryable or attempt == attempts:
                raise
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt == attempts:
                raise
        time.sleep(5 * attempt)


def main() -> int:
    load_env_file(ENV_FILE)

    try:
        base = os.environ["FORGEJO_URL"].rstrip("/")
        token = os.environ["FORGEJO_TOKEN"]
        owner = os.environ["FORGEJO_OWNER"]
        github_user = os.environ["GITHUB_USER"]
    except KeyError as missing:
        print(f"missing configuration: {missing}. See {ENV_FILE}", file=sys.stderr)
        return 2

    interval = os.environ.get("MIRROR_INTERVAL", "24h")
    include_forks = os.environ.get("INCLUDE_FORKS", "0") == "1"
    github_token = os.environ.get("GITHUB_TOKEN") or None

    wanted = github_repos(github_user, github_token, include_forks)
    existing = forgejo_repos(base, token, owner)

    created, failed, skipped = [], [], 0
    for repo in sorted(wanted, key=lambda r: r["name"].lower()):
        if repo["name"].lower() in existing:
            skipped += 1
            continue
        payload = {
            "clone_addr": repo["clone_url"],
            "repo_name": repo["name"],
            "repo_owner": owner,
            "service": "github",
            "mirror": True,
            "mirror_interval": interval,
            "private": False,
            "description": (repo.get("description") or "")[:255],
            # Issues and releases cannot be mirrored without a GitHub token and
            # are not what this is for: the point is the git history.
            "wiki": False,
            "issues": False,
            "pull_requests": False,
            "releases": False,
        }
        try:
            migrate_with_retry(base, token, payload)
            created.append(repo["name"])
        except urllib.error.HTTPError as error:
            detail = error.read().decode()[:200]
            failed.append(f"{repo['name']}: HTTP {error.code} {detail}")
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            # One flaky socket must not cost the rest of the nightly run.
            failed.append(f"{repo['name']}: {type(error).__name__} {error}")

    print(
        f"github={len(wanted)} already-mirrored={skipped} "
        f"created={len(created)} failed={len(failed)}"
    )
    for name in created:
        print(f"  + {name}")
    for problem in failed:
        print(f"  ! {problem}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
