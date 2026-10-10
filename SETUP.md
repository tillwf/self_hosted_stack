# Rebuilding this server from nothing

How to recreate the whole setup on a fresh OVH Ubuntu box: SSH, DNS, Docker,
Portainer, nginx-proxy-manager, then the stacks in this repository.

No secrets and no port numbers appear in this document. Everywhere a port
matters it is written as a placeholder such as `<SSH_PORT>`; the real values
live in the stack files, in Portainer's stack environment, and in the host's
own configuration. Pick your own — nothing here depends on a specific number
except 80 and 443, which Let's Encrypt and browsers require.

The host-level steps (1–7) are automated in [`ansible/`](ansible/). The manual
walkthrough is kept because it explains *why* each step exists; the playbooks
are the same thing expressed idempotently.

## What you end up with

```
                      internet
                         │
                    80 / 443
                         │
             ┌───────────▼────────────┐
             │  nginx-proxy-manager   │   TLS termination, Let's Encrypt
             └───────────┬────────────┘
                         │
      ┌──────────────────┼──────────────────┐
      │                  │                  │
   Nextcloud          Joplin             Forgejo          …
      │                  │                  │
   MariaDB + Redis    Postgres           SQLite

  Portainer  ── manages every stack from this git repository
```

Every stack is a directory in this repository. Portainer tracks the `main`
branch and checks each stack's `docker-compose.yml` out into its own data
volume, so the repository is the source of truth and editing the checkout gets
overwritten on redeploy.

## 1. Order the server

OVH, any range that fits; the setup below assumes a single host.

- **Distribution:** Ubuntu Server 24.04 LTS. Later LTS releases are fine, but
  this is what is deployed and what the playbooks are tested against.
- **SSH key:** add your public key during ordering. OVH then provisions the
  box with that key and no root password, which is what you want.
- **Partitioning:** the default template is fine. OVH places a swap partition
  on each disk of the RAID array; no swapfile is needed afterwards.
- **Reverse DNS:** set the PTR record for the server's IP to your main
  hostname in the OVH panel. Not required, but mail-adjacent services and some
  remote hosts care.

Note the server's public IPv4 address. It is referred to below as
`<SERVER_IP>`.

## 2. First contact and the admin user

OVH hands you either `root` or an `ubuntu` user. Create your own account,
give it sudo, and install your key:

```bash
ssh root@<SERVER_IP>

adduser --disabled-password --gecos "" <ADMIN_USER>
usermod -aG sudo <ADMIN_USER>
install -d -m 700 -o <ADMIN_USER> -g <ADMIN_USER> /home/<ADMIN_USER>/.ssh
install -m 600 -o <ADMIN_USER> -g <ADMIN_USER> /dev/null /home/<ADMIN_USER>/.ssh/authorized_keys
# paste your public key into that file
```

Set a password for the account (`passwd <ADMIN_USER>`) even though SSH will be
key-only — `sudo` needs one, and so does console rescue via the OVH KVM.

**Open a second SSH session as `<ADMIN_USER>` and confirm sudo works before
continuing.** The next step can lock you out, and a session that is already
open survives a broken `sshd` config.

## 3. Harden SSH

Drop a file in `/etc/ssh/sshd_config.d/` rather than editing the main config —
Ubuntu includes that directory from the top of `sshd_config`, and the *first*
occurrence of a key wins, so a drop-in beats the stock values.

```
Port <SSH_PORT>
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers <ADMIN_USER>
```

Moving off the default port is not security in itself; it removes the constant
background noise of bots hammering 22, which is worth it on its own.

```bash
sudo sshd -t                 # syntax check — never skip this
sudo systemctl restart ssh
```

Keep the old session open and verify from a new terminal:

```bash
ssh -p <SSH_PORT> <ADMIN_USER>@<SERVER_IP>
```

Only close the first session once that works.

## 4. Firewall

`ufw`, default deny inbound:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow <SSH_PORT>/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

Add a rule per extra published port you actually need — for example the port
you publish git-over-SSH on. Everything proxied through nginx-proxy-manager
needs **no** rule of its own: it is reached over 443.

> **Docker bypasses ufw.** Containers that publish a port with
> `ports: - "X:Y"` insert their own iptables rules ahead of ufw's, so the port
> is reachable from the internet whether or not ufw allows it. Treat every
> `ports:` entry as a public opening and prefer putting a service on the proxy
> network instead — see [§9](#9-nginx-proxy-manager).

## 5. System basics

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y ca-certificates curl gnupg git unattended-upgrades
sudo timedatectl set-timezone Etc/UTC
sudo dpkg-reconfigure -plow unattended-upgrades    # enables the daily job
```

UTC on the host keeps every container log and every database timestamp on one
clock; set the display timezone per application instead.

## 6. Docker

From Docker's own repository, not Ubuntu's — the distribution package lags far
behind and the Compose v2 plugin is not in it.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker <ADMIN_USER>
```

Log out and back in for the group to apply, then check both halves:

```bash
docker version
docker compose version
```

Membership of the `docker` group is equivalent to root on this machine. That
is the trade for being able to run every command in this repository without
`sudo`; keep the group to one account.

## 7. Portainer

Portainer is the one stack deployed by hand, because it cannot recreate its own
container while it is the thing being replaced.

```bash
git clone https://github.com/<YOUR_GITHUB_USER>/<THIS_REPO>.git ~/stack
cd ~/stack/portainer
docker compose -p portainer up -d
```

Then open `https://<SERVER_IP>:<PORTAINER_PORT>/` and **create the admin user
immediately**. Portainer closes its initialisation window a few minutes after
first start; if you miss it, restart the container and reload.

Pin the image. Portainer talks to the Docker daemon over a versioned API, and
an old Portainer against a new Docker Engine cannot reach the daemon at all —
this has already broken once here.

## 8. DNS

One `A` record per service, all pointing at the same address:

```
example.com         A   <SERVER_IP>
cloud.example.com   A   <SERVER_IP>
git.example.com     A   <SERVER_IP>
notes.example.com   A   <SERVER_IP>
proxy.example.com   A   <SERVER_IP>
```

A wildcard `*.example.com A <SERVER_IP>` works too and saves a trip to the
registrar per new service, at the cost of advertising that anything resolves.
Separate records are the more deliberate choice.

Wait for propagation before asking for certificates — Let's Encrypt validates
over HTTP and a stale record means a failed issuance and a rate-limit counter
that does not reset quickly:

```bash
getent hosts cloud.example.com
```

## 9. nginx-proxy-manager

Deploy it from Portainer as a git-backed stack (see [§10](#10-the-remaining-stacks)),
with the compose path `nginx-proxy-manager/docker-compose.yml`. It needs its
database credentials supplied as stack environment variables, following
`nginx-proxy-manager/.env.template`.

Then:

1. Open the admin UI on its published port and log in with the documented
   default credentials — **change the email and password immediately**, before
   creating any proxy host. That UI is reachable over plain HTTP on a raw port
   until you put it behind itself.
2. Create a proxy host per service: domain name, scheme `http`, forward host,
   forward port, Websockets on, Block Common Exploits on.
3. Request a Let's Encrypt certificate per host, Force SSL on.
4. For anything that accepts uploads or `git push`, set
   `client_max_body_size 512M;` under the host's *Advanced* tab. The nginx
   default of 1 MB rejects large requests with a confusing error.

**Pick the forward host deliberately — this is the one real decision in the
whole setup.** Two patterns:

| Pattern | Forward host | Consequence |
| --- | --- | --- |
| Shared Docker network | the compose *service* name | The service publishes no port. Reachable **only** through HTTPS. |
| Published port | `<SERVER_IP>` | The proxy hairpins out through the public interface, so the service is **also** reachable on its raw port over plain HTTP, bypassing TLS. |

The second works without touching any other stack, which is why it tends to
happen first. The first is strictly better: put the service on the same Docker
network as the proxy, drop its `ports:` entry, and point the proxy host at the
container name. Docker's embedded DNS resolves it.

## 10. The remaining stacks

For each directory in this repository, in Portainer: **Stacks → + Add stack**.

| Field | Value |
| --- | --- |
| Name | the directory name — it becomes the compose project name and the container name prefix |
| Build method | **Repository** |
| Repository URL | this repository's HTTPS URL |
| Repository reference | `refs/heads/main` |
| Compose path | `<directory>/docker-compose.yml` |
| Environment variables | per that directory's `.env.template`, if it has one |

Secrets are typed into Portainer's stack environment, never committed. A stack
with no `.env.template` needs no variables.

Deploy order matters only in that nginx-proxy-manager should exist before you
point DNS at anything.

Updating a stack afterwards is **Pull and redeploy**, not plain Redeploy —
the latter reuses the stale checkout and silently ignores your commits. For a
stack that builds its image locally, confirm it actually rebuilt; Portainer
will otherwise reuse a cached image.

## 11. Per-service bootstrap

Things that are not expressible in a compose file:

- **Anything behind a reverse proxy** needs to be told its own public URL, or
  it will generate links against the internal hostname. Look for a
  `trusted domains`, `base URL` or `root URL` setting per application.
- **Background jobs.** An application that expects a scheduler needs one. If
  its documentation describes a cron mode, there must be a container running
  it; otherwise the jobs silently never run and the only symptom is a warning
  page nobody reads. This has already happened here, for three months.
- **Admin accounts** for applications whose installer is locked out by
  configuration must be created from the CLI, inside the container, after the
  first start.
- **Adopting pre-existing data.** Several applications can take over a data
  directory from a previous installation if the file ownership matches the
  uid the container runs as. Check the uid before assuming a chown is needed:
  it is frequently *not* the host admin's uid.

## 12. Backups

What is actually irreplaceable, in order:

1. **Database dumps.** Take them with the database's own dump tool, from
   inside the container, not by copying files out from under a running server.
2. **Bind-mounted data directories.** Owned by a container uid, so reading
   them from the host needs `sudo` or a throwaway container.
3. **The Portainer data volume.** It holds the stack definitions *and*,
   because nginx-proxy-manager uses a relative bind mount, the proxy host
   configuration and the Let's Encrypt account. Losing it means re-entering
   every proxy host by hand.
4. **This repository.** Already off-site if you push it.

Ship them somewhere that is not this machine. A dump written to the same RAID
array as the database protects against exactly one failure mode: your own
mistake five minutes ago.

## 13. Verification

```bash
# the proxy answers and redirects to TLS
curl -sI http://cloud.example.com | head -1

# the certificate is real and not self-signed
curl -sI https://cloud.example.com | head -1

# no service is reachable on a raw port over plain HTTP
curl -sS --max-time 5 http://<SERVER_IP>:<SOME_PUBLISHED_PORT>/ -o /dev/null \
  && echo "reachable — intended?"

# every container is up rather than restarting
docker ps --format '{{.Names}}\t{{.Status}}'
```

The third one is the interesting check. Run it against every port any stack
publishes and decide, for each, whether you meant it.

## 14. Doing it with Ansible instead

[`ansible/`](ansible/) automates steps 2 through 7 — admin user, SSH
hardening, firewall, base packages, Docker, Portainer. DNS, the proxy hosts
and the stacks stay manual: they are click-once-per-lifetime, and the stacks
are already declarative in this repository.

```bash
cd ansible
cp inventory.ini.example inventory.ini
cp group_vars/all.example.yml group_vars/all.yml
# edit both: address, admin user, ports, public key path

ansible-playbook -i inventory.ini bootstrap.yml   # once, as root, on a fresh box
ansible-playbook -i inventory.ini site.yml        # thereafter, as the admin user
```

See [`ansible/README.md`](ansible/README.md) for what each role does and the
order to run them in.
