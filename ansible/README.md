# Ansible: host-level setup

Automates steps 2–7 of [`../SETUP.md`](../SETUP.md) — admin account, SSH
hardening, firewall, base packages, Docker, Portainer. Everything above that
layer stays manual and declarative: DNS records and proxy hosts are
click-once-per-lifetime, and the stacks themselves already live in this
repository and are deployed by Portainer from git.

Nothing here contains a secret or a port number. Both live in
`inventory.ini` and `group_vars/all.yml`, which are gitignored; the `.example`
files next to them show the shape.

## Setup

```bash
ansible-galaxy collection install -r requirements.yml

cp inventory.ini.example inventory.ini
cp group_vars/all.example.yml group_vars/all.yml
```

Edit both. In `group_vars/all.yml` the values that matter are `admin_user`,
`admin_public_key_file`, `ssh_port` and `stack_repo_url`.

## Running it

Against a freshly provisioned box, while root still accepts your key on the
default port:

```bash
ansible-playbook bootstrap.yml -e ansible_user=root
```

That creates the admin account and installs your key, and nothing else. Give
the account a password from the console (`passwd <admin_user>`) — `sudo` needs
one, and so does OVH's KVM rescue.

Then set `ansible_user` to that account in `inventory.ini` and run:

```bash
ansible-playbook site.yml -K
```

`-K` prompts for the sudo password. `ansible.cfg` turns `become` on for every
task, and the bootstrap deliberately leaves the admin account with a password
rather than passwordless sudo, so without `-K` every privileged task fails.
Drop the flag only if you grant that account `NOPASSWD` sudo.

**After the first `site.yml`, update `ansible_port` in `inventory.ini` to
`ssh_port`.** Until you do, the next run connects to the old port and fails.

## Roles

| Role | What it does | Notes |
| --- | --- | --- |
| `base` | apt upgrade, base packages, timezone, unattended upgrades | |
| `firewall` | ufw, default deny inbound, allows `ssh_port` + 80 + 443 + `firewall_extra_tcp_ports` | Runs **before** `ssh_hardening` so the new port is open before sshd moves to it |
| `ssh_hardening` | drop-in in `sshd_config.d/`: key-only, no root, `AllowUsers` | Validates with `sshd -t` before writing; refuses to run against a socket-activated sshd, where `Port` would be ignored |
| `docker` | Docker's apt repository, Engine + Compose plugin, admin in `docker` group | Distribution packages lag and lack Compose v2 |
| `portainer` | clones this repository to the server, `docker compose up -d` for `portainer/` | The one stack Portainer cannot manage itself |

## What it deliberately does not do

- **Open ports for stacks.** Add them to `firewall_extra_tcp_ports` only if a
  stack publishes a port that must be reachable directly. Anything behind the
  reverse proxy needs nothing.
- **Deploy the other stacks.** They are git-backed stacks in Portainer, which
  is a better source of truth than a playbook that would have to hold their
  environment variables.
- **Manage DNS.** One `A` record per service, pointed at the server.

## A warning the playbooks cannot enforce

Docker publishes ports by writing iptables rules **ahead of ufw's**. A
container with `ports: - "X:Y"` is reachable from the internet whether or not
`firewall_extra_tcp_ports` mentions it. The firewall role protects the host's
own services; it does not constrain Docker. Prefer putting a service on the
proxy's network and publishing nothing.
