#!/bin/bash
# server-healthcheck — daily audit of the things that actually break here.
#
# Prints problems to stdout, exits non-zero if there were any. The systemd
# service mails the output only on failure: a daily "all fine" message is one
# nobody reads, and whose absence nobody notices either.
#
# Every check corresponds to an observed failure mode on this machine, not to
# a generic checklist.
set -uo pipefail

PROBLEMS=0
p() { printf '%s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }

DISK_PCT_MAX=${DISK_PCT_MAX:-85}
BACKUP_DIR=${BACKUP_DIR:-/home/till/backups}
BACKUP_MAX_AGE_DAYS=${BACKUP_MAX_AGE_DAYS:-8}
CERT_MIN_DAYS=${CERT_MIN_DAYS:-21}
NC_LOG=${NC_LOG:-/home/till/nextcloud_data/nextcloud.log}
NC_LOG_MAX_MB=${NC_LOG_MAX_MB:-200}
NPM_DB=${NPM_DB:-/home/till/npm_data/database.sqlite}

# --- storage ---------------------------------------------------------------
while read -r mnt pct; do
    [ "${pct%\%}" -ge "$DISK_PCT_MAX" ] && p "DISK: $mnt is $pct full"
done < <(df -P / /boot | awk 'NR>1 {print $6, $5}')

if grep -qE '\[[U_]*_[U_]*\]' /proc/mdstat 2>/dev/null; then
    p "RAID: an array is degraded: $(grep -E '\[[U_]*_' /proc/mdstat | tr '\n' ' ')"
fi

if command -v smartctl >/dev/null; then
    for d in $(lsblk -npro NAME,TYPE | awk '$2=="disk"{print $1}'); do
        h=$(smartctl -H "$d" 2>/dev/null | grep -Ei 'overall-health|SMART Health' | sed 's/.*: *//')
        case "$h" in
            PASSED|OK) ;;
            *) p "SMART: $d health is '${h:-unknown}'" ;;
        esac
        bs=$(smartctl -A "$d" 2>/dev/null | awk '$1 ~ /^(5|197|198)$/ {s+=$10} END {print s+0}')
        [ "${bs:-0}" -gt 0 ] && p "SMART: $d has $bs reallocated/pending/uncorrectable sectors"
    done
fi

# --- backups ---------------------------------------------------------------
# Asks the repository, not the filesystem: a dump sitting next to the data it
# protects proves nothing when the array has no redundancy.
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

# --- host ------------------------------------------------------------------
if [ -f /var/run/reboot-required ]; then
    p "REBOOT: pending ($(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null))"
fi
failed=$(systemctl --failed --no-legend --no-pager | wc -l)
if [ "$failed" -gt 0 ]; then
    p "SYSTEMD: $failed failed unit(s): $(systemctl --failed --no-legend --no-pager | awk '{print $1}' | tr '\n' ' ')"
fi

# --- fail2ban --------------------------------------------------------------
# A ban in the wrong chain looks identical to a working ban in fail2ban's own
# status output, and docker flushes DOCKER-USER every time it restarts. So
# verify the rules in the kernel, not the state of the service.
if systemctl is-active --quiet fail2ban; then
    iptables -S INPUT 2>/dev/null | grep -q 'f2b-sshd' ||
        p "FAIL2BAN: no f2b-sshd jump in INPUT"
    if docker info >/dev/null 2>&1; then
        iptables -S DOCKER-USER 2>/dev/null | grep -q 'f2b-' ||
            p "FAIL2BAN: no f2b jumps in DOCKER-USER — the web jails are no-ops"
    fi
else
    p "FAIL2BAN: service is not running"
fi

# --- containers ------------------------------------------------------------
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    while read -r name status; do
        case "$status" in Up*) ;; *) p "DOCKER: $name is $status" ;; esac
    done < <(docker ps -a --format '{{.Names}} {{.Status}}' | grep -v 'Exited (0)')
    unhealthy=$(docker ps --filter health=unhealthy --format '{{.Names}}' | tr '\n' ' ')
    [ -n "$unhealthy" ] && p "DOCKER: unhealthy: $unhealthy"
fi

# --- certificates ----------------------------------------------------------
# Asked over the real listener with SNI, so this tests what a visitor is
# served rather than what happens to be on disk.
hosts=$(NPM_DB="$NPM_DB" python3 - <<'PY' 2>/dev/null
import sqlite3, json, os
try:
    c = sqlite3.connect(os.environ["NPM_DB"])
    for (d,) in c.execute("select domain_names from proxy_host where is_deleted=0 and enabled=1"):
        for name in json.loads(d):
            print(name)
except Exception:
    pass
PY
)
for host in $hosts; do
    end=$(echo | timeout 10 openssl s_client -servername "$host" -connect 127.0.0.1:443 2>/dev/null |
          openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -z "$end" ]; then
        p "TLS: $host presented no certificate"
        continue
    fi
    left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    [ "$left" -lt "$CERT_MIN_DAYS" ] && p "TLS: $host expires in ${left}d"
done

# --- noisy logs ------------------------------------------------------------
if [ -f "$NC_LOG" ]; then
    mb=$(( $(stat -c%s "$NC_LOG") / 1024 / 1024 ))
    [ "$mb" -gt "$NC_LOG_MAX_MB" ] && p "LOG: nextcloud.log is ${mb}MB (rotation not configured)"
fi

if [ "$PROBLEMS" -gt 0 ]; then
    echo
    echo "$PROBLEMS problem(s) on $(hostname) at $(date -Is)"
    exit 1
fi
echo "All checks passed on $(hostname) at $(date -Is)"
exit 0
