# Bumping app versions

Every image here is pinned on purpose. Floating tags (`latest`, `alpine`,
`apache`) have already caused one outage on this box: Portainer 2.18.2 silently
became incompatible with Docker 29 and crashlooped for months. Bump
deliberately, one thing at a time.

## 1. Find out how the stack is deployed

The mechanism differs per stack. Check this first — editing the wrong place
deploys nothing.

| Stack | Deployed from | Bump with |
| --- | --- | --- |
| `nextcloud` (id 2) | this repo, `refs/heads/main` | commit + redeploy (§2) |
| `joplin` (id 15) | Portainer web editor | Portainer, then mirror here (§3) |
| `npm` (id 14) | Portainer web editor | Portainer, then mirror here (§3) |
| `portainer` | host checkout `/home/till/self_hosted_stack` | `docker compose` (§4) |

## 2. Git-backed stack (`nextcloud`)

Nextcloud's version lives in `ARG NC_VERSION` in `nextcloud/Dockerfile`, not in
an image tag — the `nc` service is built locally. `docker pull` does nothing.

```bash
# 1. edit nextcloud/Dockerfile: ARG NC_VERSION=<next version>
git commit -am "[Nextcloud] Upgrade to <version>" && git push origin main

# 2. redeploy (Portainer UI: Stacks > nextcloud > Pull and redeploy)
curl -sk -H "X-API-Key: $PORTAINER_TOKEN" -X PUT \
  -H "Content-Type: application/json" \
  -d "$(curl -sk -H "X-API-Key: $PORTAINER_TOKEN" \
        https://till.wf:9443/api/stacks/2 \
        | jq -c '{RepositoryReferenceName:"refs/heads/main",
                  RepositoryAuthentication:false,PullImage:false,
                  Prune:false,Env:.Env}')" \
  "https://till.wf:9443/api/stacks/2/git/redeploy?endpointId=2"
```

**Always pass `Env` back.** An empty `Env` wipes the stack's database
credentials.

## 3. Web-editor stacks (`joplin`, `npm`)

These are not deployed from this repo. Change them in Portainer (Stacks > _name_
> Editor), or via the API, then mirror the same content into this repo so the
files here stay truthful.

```bash
# replace stack content; ID 14 = npm, 15 = joplin
curl -sk -H "X-API-Key: $PORTAINER_TOKEN" -X PUT \
  -H "Content-Type: application/json" \
  -d "$(jq -n --rawfile c <dir>/docker-compose.yml \
        --slurpfile s <(curl -sk -H "X-API-Key: $PORTAINER_TOKEN" \
                        https://till.wf:9443/api/stacks/<id>) \
        '{StackFileContent:$c,Env:$s[0].Env,Prune:false}')" \
  "https://till.wf:9443/api/stacks/<id>?endpointId=2"
```

Do not repoint their `ports:` entries — see the ingress note in `README.md`.

## 4. Portainer itself

Portainer cannot recreate its own container. Bump the tag in
`portainer/docker-compose.yml`, push, then on the host:

```bash
cd /home/till/self_hosted_stack && git pull
cd portainer && docker compose -p portainer pull && docker compose -p portainer up -d
```

Its database schema migration is **one-way**. Back up first:

```bash
docker run --rm -v portainer_portainer_data:/d:ro -v "$HOME/backups":/b \
  alpine tar czf /b/portainer-data-$(date +%Y%m%dT%H%M%S).tar.gz -C /d .
```

## Upgrading MariaDB

Its own rules, because it is the one component where a wrong move is not
recoverable by redeploying.

**Forward only.** MariaDB cannot be downgraded across majors in place: the
data files are migrated on first start and the older server will not read
them afterwards. That also rules out "upgrading" to an older LTS — going from
11.7 to 11.4 is a downgrade, however much longer 11.4 is supported.

**Stay on LTS.** Short-term releases get roughly a year. 11.7's maintenance
ended 2025-05-12 and it kept running here until it was noticed eighteen
months later, which is the kind of thing nothing reports unless something
checks (see `scripts/server-healthcheck.sh`).

```bash
# 1. Dump and snapshot first. A dump that merely exists is not a backup:
#    check the gzip integrity and the "Dump completed" trailer.
docker exec nextcloud-db-1 sh -c \
  'mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --events --all-databases' \
  | gzip -c > ~/backups/nc-db-$(date +%Y%m%dT%H%M%S).sql.gz
gzip -t ~/backups/nc-db-*.sql.gz
zcat ~/backups/nc-db-*.sql.gz | tail -5 | grep 'Dump completed'

# 2. Cold snapshot of the data directory — the fast way back.
docker stop nextcloud-nc-1 nextcloud-cron-1 nextcloud-db-1
docker run --rm -v nextcloud_nextcloud_db:/v:ro -v "$HOME/backups":/b busybox \
  tar czf /b/nc-dbvolume-$(date +%Y%m%dT%H%M%S).tar.gz -C /v .
docker start nextcloud-db-1 nextcloud-nc-1 nextcloud-cron-1

# 3. Bump the image in nextcloud/docker-compose.yml, commit, push,
#    then Portainer > Stacks > nextcloud > Pull and redeploy.

# 4. Verify.
docker exec nextcloud-db-1 mariadb --version
docker exec nextcloud-db-1 sh -c 'mariadb-upgrade -uroot -p"$MYSQL_ROOT_PASSWORD"'
docker exec -u www-data nextcloud-nc-1 php occ status
curl -sI https://nextcloud.till.wf/status.php | head -1
```

To roll back: restore the snapshot into the volume, set the image back to the
previous tag **before** redeploying, and only then bring the stack up. Starting
the new server again on restored old files re-runs a migration it already did.

## Hard rules

- **Pin to a specific version.** Never reintroduce `latest`. Confirm the tag
  exists before committing it — `jc21/mariadb-aria` has no `10.11` tag, and
  `joplin/server` has no `3.0.1` (only `3.0.1-beta`).
- **Nextcloud and MariaDB cannot skip a major.** Nextcloud enforces this via
  `$OC_VersionCanBeUpgradedFrom`; MariaDB cannot be downgraded in place at all.
  One major per commit, verified in between. Full runbook in `README.md`.
- **Back up before any migration**, and check the backup is readable:

```bash
docker exec -u www-data nextcloud-nc-1 php occ maintenance:mode --on
docker exec nextcloud-db-1 sh -c 'mariadb-dump --single-transaction --quick \
  -u root -p"$MYSQL_ROOT_PASSWORD" nextcloud' | gzip > ~/backups/nc-db-$(date +%s).sql.gz
gzip -t ~/backups/nc-db-*.sql.gz
```

- **Verify before the next bump.** For Nextcloud, require the expected version
  and `needsDbUpgrade: false`:

```bash
docker exec -u www-data nextcloud-nc-1 php occ status
curl -s https://nextcloud.till.wf/status.php
```

- **A third-party app can block a major.** `news` vendors its own
  `guzzlehttp/psr7` and broke `occ upgrade` on 32; it has no Nextcloud 35
  release and stays disabled. If `occ upgrade` throws from
  `upgradeAppStoreApps`, disable the offending app, upgrade, then re-enable.
- **Revoke any Portainer API token** when you are done with it.
