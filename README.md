# self_hosted_stack

Compose stacks deployed on `till.wf` by Portainer, one stack per directory.
Portainer tracks the `main` branch of this repository and checks each stack's
`docker-compose.yml` out into its own data volume, so **this repository is the
source of truth** — editing the files Portainer checked out gets overwritten on
the next redeploy.

Rebuilding the whole thing from a blank server is documented in
[SETUP.md](SETUP.md), with the host-level part automated in
[`ansible/`](ansible/).

| Directory | Portainer stack | Deployed from | Notes |
| --- | --- | --- | --- |
| `nextcloud/` | `nextcloud` (id 2) | **this repo**, `refs/heads/main` | `nc` service is **built locally**, not pulled |
| `forgejo/` | `forgero` (id 39) | **this repo**, `refs/heads/main` | Private git. On `npm_default`, no published HTTP port. Stack name is a typo, kept to avoid a rename |
| `meelo/` | `meelo` (id 40) | **this repo**, `refs/heads/main` | Music server, nine services behind its own nginx, also on `npm_default` |
| `joplin/` | `joplin` (id 15) | Portainer web editor | repo copy is a mirror, see below |
| `nginx-proxy-manager/` | `npm` (id 14) | Portainer web editor | repo copy is a mirror, see below |
| `portainer/` | n/a | **this repo**, via `docker compose` on the host | Portainer cannot deploy itself |

`nextcloud`, `forgero` and `meelo` are git-backed Portainer stacks: Portainer
clones this repository and checks out that stack's `docker-compose.yml`, so
editing the checkout is pointless and **Pull and redeploy** is what applies a
commit. `joplin` and `npm` predate that and were pasted into Portainer's web
editor; the copies here are documentation, not the deployed source, and
changing them changes nothing until those stacks are converted.

### Where the data of the two web-editor stacks actually lives

Both use *relative* bind mounts — `./data` for nginx-proxy-manager,
`./data/postgres` for Joplin. Portainer runs compose inside its own container,
but the Docker daemon resolves bind sources on the **host**, so those paths
land in a directory named after the stack's numeric id:

    /data/compose/14/data              nginx-proxy-manager: proxy hosts, certs account
    /data/compose/15/data/postgres     Joplin: 2.4 GB of Postgres data

This works today and keeps working across redeploys, because the id is
stable. It breaks the day a stack is deleted and recreated — the new id means
a new, empty directory, and the application starts as if it were new while
the old data sits orphaned under the previous id. It also means a backup of
the Portainer volume does **not** contain any of it.

Converting those two to absolute host paths is a data move plus downtime, so
it has not been done. Do it before deleting either stack for any reason.

They cannot simply be converted to git-backed stacks: both use relative bind
mounts (`./data`), which the Docker daemon resolves against the stack's working
directory on the host (`/data/compose/14`, `/data/compose/15`). A git-backed
stack gets a different working directory, so `./data` would resolve to an empty
path and the services would come up with no configuration, no certificates and
no database. Converting them requires rewriting those binds to absolute paths
or named volumes first, and migrating the data.

`portainer/` is deployed by hand from a checkout on the host at
`/home/till/self_hosted_stack`, because Portainer cannot recreate its own
container while it is the thing being replaced.

Each stack reads its secrets from Portainer's stack environment, following the
corresponding `.env.template`.

## Forgejo: private git

`git.till.wf`, SQLite, single container. It is configured as a closed
instance: `DISABLE_REGISTRATION` and `REQUIRE_SIGNIN_VIEW` are both on, so
there is no signup form and nothing — including repositories marked public —
is readable without logging in. New accounts are created by the admin.

`INSTALL_LOCK=true` means the web installer never runs, so the admin account
has to be created from the CLI after the first start:

```bash
docker exec -u git forgejo-forgejo-1 forgejo admin user create \
  --admin --username till --email till@till.wf --random-password
```

It prints the password once. Change it after the first login and enable TOTP.

### Ingress

Unlike the other stacks, Forgejo does **not** publish its HTTP port. It joins
the existing `npm_default` network, so the proxy host points at the container:

    git.till.wf  ->  http://forgejo:3000     (scheme http, no TLS inside Docker)

That keeps the web UI off the public interface entirely, which is not true of
`nextcloud.till.wf` or `joplin.till.wf` — see the ingress section below. If the
proxy host is created with the public IP by mistake it will simply not connect,
since 3000 is not published.

### Git over SSH

Container port 22 is published on host **2222** (3010 is the host's own sshd):

```bash
git clone ssh://git@till.wf:2222/till/repo.git
```

Add your public key under *Settings → SSH keys* first. Over HTTPS, use a
Forgejo access token as the password rather than the account password.

### Upgrading

One major at a time; the database migration on first start is not reversible.
Snapshot the volume before bumping the tag:

```bash
docker run --rm -v /home/till/gitea:/d:ro -v "$HOME/nc-backup":/b \
  busybox tar czf /b/forgejo-$(date +%Y%m%dT%H%M%S).tar.gz -C /d .
```

(The data directory is the bind mount, not a named volume — an earlier version
of this file said `forgejo_forgejo`, which does not exist and would have
produced an empty archive right before an irreversible upgrade.)

## Meelo: music server

Nine services — front end, API server, scanner, matcher, Postgres, Meilisearch,
RabbitMQ, a transcoder, and an nginx that stitches the first four together.
Adapted from upstream's `docker-compose.prod.yml`.

### Why this differs from upstream's compose

- **No `env_file`.** Portainer's repository deployment does not generate
  `stack.env`; its own dialog says the file must already be in the repo.
  Values typed into the stack environment are only available as `${VAR}`
  substitutions, so every variable upstream passes via `.env` is listed
  explicitly under `environment:` instead.
- **No published port.** `nginx` joins `npm_default` under the alias `meelo`,
  so the proxy host forwards to `http://meelo:5000` and nothing listens on the
  host's public interface.
- **Pinned tags**, including Postgres: upstream's `postgres:alpine3.14` floats
  across majors, which is not recoverable in place.

### Relative bind mounts do not work here

Upstream mounts `./nginx.conf.template` into the nginx container. Under
Portainer that silently produces an empty directory: compose runs inside the
Portainer container, where the stack is checked out at
`/data/compose/<id>/meelo`, but the Docker daemon resolves bind sources
against the *host* filesystem, where nothing is at that path. nginx then finds
no template, serves its default config on port 80, and the proxy returns 502.

Build contexts are read by the compose client rather than the daemon, so they
do work — `Dockerfile.nginx` bakes the template into the image instead. The
same applies to any other file a stack in this repository wants to mount from
its own directory.

### Entry point

`nginx` is the only service to point anything at. It serves the front end at
`/` and proxies `/api`, `/scanner` and `/matcher` to the other services. Those
paths are also baked into the front end as absolute URLs through `PUBLIC_URL`,
so that value must be the external address — a container name will load the
page and then fail every request the browser makes.

### First run

1. Deploy with `ENABLE_USER_REGISTRATION=1`, open the site, create the first
   account — it becomes the admin.
2. Set `ENABLE_USER_REGISTRATION=0` in the stack environment and redeploy.
   Until you do, anyone who reaches the site can sign up.
3. Trigger a scan from the UI. The first pass over a large library takes a
   while and the transcoder is capped at one CPU on purpose.

`CONFIG_DIR` holds `settings.json`, which controls how paths are parsed into
artist/album/track. The regexes there have to match the library's directory
layout or the scan finds nothing.

## Mirroring GitHub into Forgejo

Every public, non-fork repository of a GitHub account is kept in Forgejo as a
**pull mirror**. Forgejo refreshes each mirror itself on that mirror's
interval — there is no external job for the content.

`scripts/forgejo-mirror-github.py` reconciles the *set* of repositories, not
their contents: it creates a mirror for anything on GitHub that Forgejo does
not have yet. That is the only part a daily cron is needed for. It never
deletes: a repository removed from GitHub stays behind as a stale mirror,
which is the safer direction for what is effectively a backup.

Configuration lives outside this repository, in `~/.config/forgejo-mirror.env`
(mode 0600) on the server:

```
FORGEJO_URL=https://git.example.com
FORGEJO_TOKEN=...        # scopes: write:repository, read:user
FORGEJO_OWNER=...
GITHUB_USER=...
MIRROR_INTERVAL=24h
INCLUDE_FORKS=0
```

Install the daily run with `crontab -e`:

```cron
17 4 * * * /usr/bin/python3 $HOME/self_hosted_stack/scripts/forgejo-mirror-github.py >> $HOME/logs/forgejo-mirror.log 2>&1
```

Mirrors are read-only in Forgejo — pushing to them is rejected, because the
next sync would discard the commits. Push to GitHub and let the mirror follow.
A repository that should be writable in Forgejo must not be a mirror; keep it
out of the GitHub account, or accept that the two will diverge.

## Image versions are pinned on purpose

Every image tag in this repository is pinned to a specific release. Floating
tags (`latest`, `alpine`, `apache`) previously meant that an unrelated redeploy
could silently jump a major version — which for both Nextcloud and MariaDB is
not a recoverable operation. Bump tags deliberately, one at a time.

## Nextcloud background jobs

The `nextcloud` stack runs a separate `cron` service: the same locally built
image with `entrypoint: /cron.sh`, which is busybox crond calling `cron.php`
every five minutes. Nextcloud's `backgroundjobs_mode` is set to `cron`, so
without that container the jobs do not run at all and nothing says so until
Settings → Overview reports "Last background job execution ran N months ago".

Check it with:

```bash
docker logs --tail 20 nextcloud-cron-1
docker exec -u www-data nextcloud-nc-1 php occ config:app:get core lastcron
```

`lastcron` is a Unix timestamp and should never be more than a few minutes old.

## Upgrading Nextcloud

For the general procedure for bumping any app in this repo, see
[`UPGRADING.md`](UPGRADING.md). The rest of this section is the Nextcloud-specific
major-version runbook.

Nextcloud **refuses to skip major versions**: the upgrade path is enforced by
`$OC_VersionCanBeUpgradedFrom` in the server's `version.php`. Going from 30 to
35 directly leaves the instance unable to start. Each major is a separate
commit, redeploy and verification.

The `nc` service builds from `nextcloud/Dockerfile` (it adds the `smbclient` and
`oauth` PHP extensions), so the version lives in the `NC_VERSION` build arg
there and a `docker pull` will not update anything.

### Before starting

Back up. A failed major upgrade can leave the database partially migrated.

```bash
TS=$(date +%Y%m%dT%H%M%S)
mkdir -p ~/nc-backup

docker exec -u www-data nextcloud-nc-1 php occ maintenance:mode --on

docker exec nextcloud-db-1 sh -c \
  'mariadb-dump --single-transaction -u root -p"$MYSQL_ROOT_PASSWORD" nextcloud' \
  | gzip > ~/nc-backup/nc-db-$TS.sql.gz

docker run --rm -v nextcloud_nextcloud:/html:ro -v "$HOME/nc-backup":/b \
  redis:alpine tar czf /b/nc-html-$TS.tar.gz -C /html config apps custom_apps themes
```

The data directory is the bind mount `/home/till/nextcloud_data`. It is owned by
`www-data` and is not readable by the `till` account, so back it up with `sudo`
or through a container. Leave maintenance mode on for the whole sequence.

### Per major version

Repeat once per major, in order — do not batch them:

| From | To |
| --- | --- |
| 30 | `31.0.14` |
| 31 | `32.0.15` |
| 32 | `33.0.9` |
| 33 | `34.0.4` |
| 34 | `35.0.1` |

(Patch levels current as of 2026-10-04; take the newest patch of the target
major at the time you run it.)

1. Bump `ARG NC_VERSION` in `nextcloud/Dockerfile`. Commit to `main`.
2. Portainer → *Stacks* → `nextcloud` → **Pull and redeploy**. Confirm it
   rebuilds; Portainer will otherwise reuse a cached image for build stacks.
   To force it, on the host:
   ```bash
   sudo docker compose -p nextcloud \
     -f /data/compose/2/nextcloud/docker-compose.yml build --no-cache nc
   ```
3. Watch the migration, which the image entrypoint runs itself:
   ```bash
   docker logs -f nextcloud-nc-1
   ```
   If it did not run:
   ```bash
   docker exec -u www-data nextcloud-nc-1 php occ upgrade
   docker exec -u www-data nextcloud-nc-1 php occ db:add-missing-indices
   ```
4. Verify before moving on — require the expected `version:` and
   `needsDbUpgrade: false`:
   ```bash
   docker exec -u www-data nextcloud-nc-1 php occ status
   docker exec -u www-data nextcloud-nc-1 php occ app:update --all
   ```

After the final hop: `php occ maintenance:mode --off`, then check the UI through
nginx-proxy-manager.

If `occ upgrade` refuses to run, it is usually a third-party app that has no
release for the target major. Disable it, upgrade, re-enable. Apps to watch on
this instance: `news`, `external`, and anything on a `-dev` version
(`webhook_listeners`, `twofactor_totp`).

### Rolling back a hop

Restore the html-volume tarball and the SQL dump, then point `NC_VERSION` back
at the previous tag. This per-hop restore point is the reason for not batching
majors.

## Upgrading MariaDB

`db` is pinned to the series the instance was initialised against. MariaDB
cannot be downgraded across majors in place, so an upgrade is one major at a
time with a dump taken first, and the target must be a version Nextcloud
supports. Note that 11.7 is a short-term release; moving to an LTS series
(11.4) is a *downgrade* and needs a dump-and-restore, not a tag bump.

## Ingress: nginx-proxy-manager forwards via the public IP

Every proxy host in nginx-proxy-manager points at this server's **public IP**
rather than at a container over a Docker network:

    nextcloud.till.wf  ->  176.31.183.86:8080
    joplin.till.wf     ->  176.31.183.86:22300
    portainer.till.wf  ->  176.31.183.86:9443
    npm.till.wf        ->  176.31.183.86:81

Two consequences worth knowing before changing any `ports:` entry:

- Those published ports are **load-bearing**. Removing or rebinding `8080`,
  `22300`, `9443` or `81` to localhost breaks the corresponding site, because
  the proxy reaches them by hairpinning out through the public interface.
- Every proxied service is therefore **also reachable directly on its raw
  port over plain HTTP**, bypassing TLS. That includes the nginx-proxy-manager
  admin login on port 81.

Fixing this properly means putting the proxy and the services on a shared
Docker network (or binding published ports to the Docker bridge address) and
repointing each proxy host at the container. That is an ingress change
affecting every stack, so it has not been done here.

The Joplin database previously published `5432` on all interfaces, exposing
Postgres to the internet. Nothing forwarded to it and the app reaches the
database as `POSTGRES_HOST=db` over the compose network, so the publish has
been removed.
