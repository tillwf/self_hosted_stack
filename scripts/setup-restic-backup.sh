#!/usr/bin/env bash
# setup-restic-backup.sh — till.wf
#
# Installs the Tier A backup: databases and the configuration that rebuilds
# the stacks. ~3 GB. Explicitly NOT nextcloud_data, Pictures or Musics.
#
# Phase 1 writes to a LOCAL restic repository. That protects against a bad
# delete, a bad upgrade and a corrupted database — but not against losing the
# array, because / is a RAID0 across three disks with no redundancy. Phase 2
# is one line: point RESTIC_REPOSITORY at sftp:user@host:/path and run again.
# The script says so loudly at the end, on purpose.
set -uo pipefail

REPO=${REPO:-/home/till/restic-repo}
MAILTO=${MAILTO:-server@till.wf}
SRC=$(dirname "$(readlink -f "$0")")

hr()  { printf '\n\033[1m===== %s =====\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✅ %s\033[0m\n' "$*"; }
bad() { printf '  \033[31m❌ %s\033[0m\n' "$*"; }
warn(){ printf '  \033[33m⚠️  %s\033[0m\n' "$*"; }
ask() { local a; read -r -p $'\n\033[1m>>> '"$1"$' [y/N] \033[0m' a </dev/tty; [[ ${a,,} == y ]]; }

[ "$(id -u)" -eq 0 ] || exec sudo -p "[sudo] password for %p: " bash "$0" "$@"

hr "Preconditions"
for f in backup-run backup-restore-drill; do
  [ -r "$SRC/$f" ] && ok "found $SRC/$f" || { bad "$f missing next to this script"; exit 1; }
done
[ -r /etc/msmtprc ] && ok "mail config present" || warn "/etc/msmtprc missing: failures will not be mailed"
df -h "$(dirname "$REPO")" | tail -1 | sed 's/^/    /'

hr "Install restic"
if command -v restic >/dev/null; then
  ok "already installed: $(restic version)"
else
  ask "apt install restic?" || exit 0
  apt-get install -y restic >/dev/null && ok "installed: $(restic version)" || { bad "install failed"; exit 1; }
fi

hr "Repository and credentials"
mkdir -p /etc/restic
if [ -f /etc/restic/password ]; then
  ok "/etc/restic/password exists (keeping it)"
else
  # Without this passphrase the repository is unreadable. It must leave this
  # machine, or the backup dies with the disk it is protecting against.
  openssl rand -base64 32 >/etc/restic/password
  chmod 0600 /etc/restic/password
  ok "generated /etc/restic/password"
  NEWPASS=1
fi

cat >/etc/restic/env <<EOF
# Managed by setup-restic-backup.sh
# Phase 2: change RESTIC_REPOSITORY to sftp:user@host:/path (restic speaks
# SFTP natively) and run a backup; restic will initialise the remote repo.
export RESTIC_REPOSITORY=$REPO
export RESTIC_PASSWORD_FILE=/etc/restic/password
EOF
chmod 0600 /etc/restic/env
ok "/etc/restic/env -> $REPO"

cat >/etc/restic/excludes <<'EOF'
# Regenerable or worthless, per source. Mirrors the analysis of nextcloud_data:
# back up originals, skip anything a machine can rebuild.
**/logs/**
*.log
*.log.[0-9]
*.log.*.gz
**/tmp/**
**/cache/**
**/Cache/**
# nginx-proxy-manager's MariaDB is vestigial: npm uses SQLite at /data/database.sqlite
/home/till/npm_data/mysql/**
# Forgejo runtime noise
/home/till/gitea/gitea/log/**
/home/till/gitea/gitea/tmp/**
EOF
chmod 0644 /etc/restic/excludes
ok "/etc/restic/excludes"

if [ ! -f "$REPO/config" ]; then
  if ask "Initialise a new restic repository at $REPO?"; then
    set -a; . /etc/restic/env; set +a
    restic init && ok "repository initialised" || { bad "init failed"; exit 1; }
  fi
else
  ok "repository already initialised"
fi

hr "Install the jobs"
install -m 0755 -o root -g root "$SRC/backup-run"          /usr/local/sbin/backup-run
install -m 0755 -o root -g root "$SRC/backup-restore-drill" /usr/local/sbin/backup-restore-drill
ok "/usr/local/sbin/backup-run and backup-restore-drill"

write_unit() { # name description command calendar
  cat >/etc/systemd/system/$1.service <<EOF
[Unit]
Description=$2
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '$3 > /var/log/$1.log 2>&1 || { { printf "Subject: [%s] $1 FAILED\\nTo: $MAILTO\\n\\n" "\$(hostname)"; cat /var/log/$1.log; } | msmtp --file=/etc/msmtprc $MAILTO; exit 1; }'
EOF
  cat >/etc/systemd/system/$1.timer <<EOF
[Unit]
Description=$2

[Timer]
OnCalendar=$4
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

write_unit backup           "Nightly Tier A backup"            /usr/local/sbin/backup-run           "*-*-* 02:30:00"
write_unit backup-drill     "Monthly backup restore drill"     /usr/local/sbin/backup-restore-drill "*-*-01 04:00:00"
systemctl daemon-reload
systemctl enable --now backup.timer backup-drill.timer >/dev/null
ok "timers enabled"
systemctl list-timers backup.timer backup-drill.timer --no-pager | sed 's/^/    /'

hr "Teach the health check about snapshots, not local files"
HC=/usr/local/sbin/server-healthcheck
if [ -x "$HC" ] && ! grep -q 'restic snapshots' "$HC"; then
  if ask "Replace the local-file backup check with a restic snapshot-age check?"; then
    cp -a "$HC" "$HC.bak-$(date +%Y%m%dT%H%M%S)"
    python3 - "$HC" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
start = s.index('# --- backups ---')
end = s.index('# --- host ---')
new = '''# --- backups ---------------------------------------------------------------
# Asks the repository, not the filesystem: a dump sitting next to the data it
# protects proves nothing on a RAID0 array with no redundancy.
if [ -r /etc/restic/env ]; then
    # shellcheck disable=SC1091
    . /etc/restic/env
    age=$(restic snapshots --latest 1 --json 2>/dev/null |
        python3 -c 'import json,sys,datetime
try:
    s=json.load(sys.stdin)[0]["time"][:19]
    print((datetime.datetime.now()-datetime.datetime.fromisoformat(s)).days)
except Exception:
    print(999)' 2>/dev/null)
    [ "${age:-999}" -gt 2 ] && p "BACKUP: newest restic snapshot is ${age}d old (repo $RESTIC_REPOSITORY)"
    case "$RESTIC_REPOSITORY" in
        /*) p "BACKUP: repository $RESTIC_REPOSITORY is on this host; a disk loss takes the backups with it" ;;
    esac
else
    p "BACKUP: /etc/restic/env missing — no backup configured"
fi

'''
open(p,'w').write(s[:start] + new + s[end:])
PY
    bash -n "$HC" && ok "health check updated" || { bad "syntax error, restoring"; cp -a "$HC".bak-* "$HC"; }
  fi
fi

hr "First run"
if ask "Run the backup now?"; then
  /usr/local/sbin/backup-run; echo "  exit code: $?"
fi

hr "Prove it restores"
if ask "Run the restore drill now? (loads the dump into a scratch container)"; then
  /usr/local/sbin/backup-restore-drill; echo "  exit code: $?"
fi

hr "Two things that are still your job"
cat <<EOF
  1. THE REPOSITORY IS LOCAL. $REPO lives on the same RAID0 array as the
     data. This protects against mistakes and corruption, not against losing
     a disk. Phase 2 is one line in /etc/restic/env.

  2. SAVE THE PASSPHRASE OFF THIS MACHINE. Without it the repository is
     unreadable, including by you. It is in /etc/restic/password.
EOF
if [ "${NEWPASS:-0}" = 1 ]; then
  echo
  warn "Passphrase (shown once — put it in your password manager now):"
  echo
  sed 's/^/      /' /etc/restic/password
  echo
fi
