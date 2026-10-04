# self_hosted_stack

Compose stacks deployed on `till.wf` by Portainer, one stack per directory.
Portainer tracks the `main` branch of this repository and checks each stack's
`docker-compose.yml` out into its own data volume, so **this repository is the
source of truth** — editing the files Portainer checked out gets overwritten on
the next redeploy.

| Directory | Portainer stack | Deployed from | Notes |
| --- | --- | --- | --- |
| `nextcloud/` | `nextcloud` (id 2) | **this repo**, `refs/heads/main` | `nc` service is **built locally**, not pulled |
| `joplin/` | `joplin` (id 15) | Portainer web editor | repo copy is a mirror, see below |
| `nginx-proxy-manager/` | `npm` (id 14) | Portainer web editor | repo copy is a mirror, see below |
| `portainer/` | n/a | **this repo**, via `docker compose` on the host | Portainer cannot deploy itself |

Only the `nextcloud` stack is a git-backed Portainer stack, so it is the only
one Portainer redeploys from this repository. `joplin` and `npm` were created
through Portainer's web editor, and their compose files here are kept in sync
by hand as documentation — editing them does **not** deploy anything. Change
those two through Portainer (or its API), then mirror the change here.

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

## Image versions are pinned on purpose

Every image tag in this repository is pinned to a specific release. Floating
tags (`latest`, `alpine`, `apache`) previously meant that an unrelated redeploy
could silently jump a major version — which for both Nextcloud and MariaDB is
not a recoverable operation. Bump tags deliberately, one at a time.

## Upgrading Nextcloud

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
