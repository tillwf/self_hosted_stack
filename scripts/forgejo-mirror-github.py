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

Exit codes, so a cron wrapper can tell the cases apart:

    0  nothing to do, or everything created
    1  transient trouble — some repositories failed, try again tomorrow
    2  configuration or authentication is wrong; retrying will not help
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


class AuthProblem(Exception):
    """A 401/403: the token is wrong, expired or under-scoped.

    Distinct from a per-repository failure because retrying it, or carrying on
    to the next repository, only produces the same error once per repository.
    """


def api(
    url: str,
    token: str | None = None,
    scheme: str = "token",
    data: dict | None = None,
    attempts: int = 3,
) -> object:
    """One API call, retrying only what is worth retrying.

    429 and 5xx are the server asking for patience, and 429 usually says how
    long for. Everything else — 401, 403, 409, 422 — will fail identically on
    a second attempt, so it is raised at once.
    """
    body = json.dumps(data).encode() if data is not None else None

    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(url, data=body, method="POST" if body else "GET")
        request.add_header("Accept", "application/json")
        if body:
            request.add_header("Content-Type", "application/json")
        if token:
            request.add_header("Authorization", f"{scheme} {token}")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.loads(response.read() or "null")
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise AuthProblem(f"{error.code} for {url}: {error.read().decode()[:200]}") from error
            retryable = error.code == 429 or 500 <= error.code < 600
            if not retryable or attempt == attempts:
                raise
            delay = error.headers.get("Retry-After")
            wait = int(delay) if delay and delay.isdigit() else 5 * attempt
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt == attempts:
                raise
            wait = 5 * attempt
        time.sleep(wait)

    raise RuntimeError("unreachable")


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

    try:
        wanted = github_repos(github_user, github_token, include_forks)
        existing = forgejo_repos(base, token, owner)
    except AuthProblem as error:
        print(f"authentication failed, nothing attempted: {error}", file=sys.stderr)
        return 2
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError) as error:
        print(f"could not list repositories: {type(error).__name__} {error}", file=sys.stderr)
        return 1

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
            api(f"{base}/api/v1/repos/migrate", token, data=payload)
            created.append(repo["name"])
        except AuthProblem as error:
            # The token cannot create repositories. Every remaining repository
            # would fail the same way, one log line each.
            print(f"aborting: Forgejo rejected the token: {error}", file=sys.stderr)
            return 2
        except urllib.error.HTTPError as error:
            if error.code == 409:
                # Created between listing and now, by an overlapping run or by
                # hand. The desired state exists, which is all this asked for.
                skipped += 1
                continue
            failed.append(f"{repo['name']}: HTTP {error.code} {error.read().decode()[:200]}")
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
