#!/usr/bin/env bash
#
# preflight-reboot-check.sh — is this server safe to reboot?
#
# Read-only. Writes nothing, installs nothing, changes no configuration.
#
#   sudo ./scripts/preflight-reboot-check.sh
#
# Written for a headless dedicated server with software RAID and no KVM, where
# a failed boot means a trip through the provider's rescue system rather than a
# keyboard. It checks the things that actually prevent a box from coming back:
#
#   * a bootloader that was never re-flashed after a grub package upgrade
#   * an initramfs that cannot assemble the array holding /
#   * a GRUB that waits forever at a menu nobody can see
#   * disks that have been spinning for years and may not survive a power cycle
#
# Everything it reports is evidence, not opinion: it prints what it read so the
# conclusion can be checked.

set -uo pipefail

WARN=0
FAIL=0

hr()   { printf '\n\033[1m===== %s =====\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; WARN=$((WARN + 1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '         %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    exec sudo "$0" "$@"
  elif [ -t 0 ]; then
    exec sudo "$0" "$@"
  else
    printf '\033[33mNot root and sudo needs a password: MBR, SMART and grub.cfg checks will be skipped.\033[0m\n'
  fi
fi
ROOT=0
[ "$(id -u)" -eq 0 ] && ROOT=1

############################ boot mode and bootloader
hr "Boot mode"
if [ -d /sys/firmware/efi ]; then
  BOOTMODE=uefi
  note "UEFI"
else
  BOOTMODE=bios
  note "legacy BIOS"
fi

# Physical disks backing whatever holds /boot (or / if there is no separate one).
BOOTSRC=$(findmnt -no SOURCE /boot 2>/dev/null || findmnt -no SOURCE /)
DISKS=$(lsblk -npro NAME,TYPE | awk '$2 == "disk" {print $1}')
note "boot filesystem: $BOOTSRC"
note "disks: $(echo "$DISKS" | tr '\n' ' ')"

hr "Bootloader is installed where the firmware will look"
if [ "$BOOTMODE" = bios ]; then
  if [ "$ROOT" -eq 1 ]; then
    for d in $DISKS; do
      if dd if="$d" bs=512 count=1 status=none 2>/dev/null | strings | grep -qi grub; then
        ok "$d has GRUB in its MBR"
      else
        bad "$d has NO GRUB in its MBR — unbootable if the firmware picks this disk"
      fi
    done
  else
    warn "skipped: reading the MBR needs root"
  fi

  # grub-pc remembers where to re-install itself on every package upgrade. If
  # that target is a RAID device whose name has since changed, or if it is
  # empty, upgrades fail silently and the core.img on disk drifts away from the
  # modules in /boot/grub — the classic "error: symbol not found / grub rescue>"
  # on the first reboot months later.
  if command -v debconf-show >/dev/null 2>&1 && [ "$ROOT" -eq 1 ]; then
    TARGET=$(debconf-show grub-pc 2>/dev/null | awk -F': ' '/grub-pc\/install_devices:/ {print $2}')
    FAILED=$(debconf-show grub-pc 2>/dev/null | awk -F': ' '/grub-pc\/install_devices_failed:/ {print $2}')
    note "grub-pc install target: ${TARGET:-<unset>}"
    case "$TARGET" in
      "")   bad "no install target: grub-install is not run on upgrade" ;;
      *md*) warn "target is a RAID device; if upgrades report failures, re-point it at the physical disks:"
            note "sudo dpkg-reconfigure grub-pc   # select every disk, not the array" ;;
      *)    ok "target is a physical device" ;;
    esac
    [ "$FAILED" = "true" ] && bad "install_devices_failed=true: grub-install has been failing on upgrades"
  fi
else
  # UEFI with software RAID: each disk needs its own ESP, and they must be kept
  # in sync, because the firmware may boot from any of them.
  ESPS=$(lsblk -npro NAME,PARTTYPENAME 2>/dev/null | awk '/EFI System/ {print $1}')
  if [ -z "$ESPS" ]; then
    warn "no EFI System Partition found"
  else
    for e in $ESPS; do note "ESP: $e"; done
    [ "$(echo "$ESPS" | wc -l)" -lt "$(echo "$DISKS" | wc -l)" ] &&
      warn "fewer ESPs than disks: losing the wrong disk leaves the server unbootable"
  fi
  command -v efibootmgr >/dev/null 2>&1 && efibootmgr | sed 's/^/         /'
fi

############################ kernel and initramfs
hr "Kernel: running versus installed"
RUNNING=$(uname -r)
NEWEST=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*vmlinuz-||' | sort -V | tail -1)
note "running:  $RUNNING"
note "newest:   ${NEWEST:-none}"
if [ -n "$NEWEST" ] && [ "$RUNNING" != "$NEWEST" ]; then
  warn "a reboot will switch kernels — the checks below decide whether that is safe"
else
  ok "already running the newest installed kernel"
fi
[ -f /var/run/reboot-required ] && note "reboot-required flag is set"

hr "Initramfs can reach the root filesystem"
INITRD=/boot/initrd.img-$NEWEST
if [ -n "$NEWEST" ] && [ -r "$INITRD" ]; then
  if lsinitramfs "$INITRD" >/dev/null 2>&1; then
    ok "$(basename "$INITRD") is readable and well formed"
  else
    bad "$(basename "$INITRD") is unreadable or truncated"
  fi
  # Whatever / sits on has to be assemblable from inside the initramfs.
  ROOTSRC=$(findmnt -no SOURCE /)
  case "$ROOTSRC" in
    /dev/md*)
      LEVEL=$(awk -v d="$(basename "$ROOTSRC")" '$1 == d {print $4}' /proc/mdstat)
      MODS=$(lsinitramfs "$INITRD" 2>/dev/null | grep -cE "/(md-mod|${LEVEL}|raid456)\.ko")
      if [ "${MODS:-0}" -gt 0 ]; then
        ok "initramfs contains the $LEVEL modules needed to assemble $ROOTSRC"
      else
        bad "initramfs has no $LEVEL module: the array holding / cannot be assembled"
      fi
      if grep -qE '^ARRAY' /etc/mdadm/mdadm.conf 2>/dev/null; then
        ok "mdadm.conf declares the arrays"
      else
        bad "no ARRAY lines in /etc/mdadm/mdadm.conf — assembly may not happen at boot"
      fi
      ;;
    /dev/mapper/*) lsinitramfs "$INITRD" 2>/dev/null | grep -q dm-mod &&
      ok "initramfs contains device-mapper support" || bad "initramfs lacks device-mapper support" ;;
  esac
else
  warn "cannot read $INITRD (needs root)"
fi

hr "GRUB menu entries"
if [ -r /boot/grub/grub.cfg ]; then
  mapfile -t ENTRIES < <(grep -oP "menuentry 'Ubuntu, with Linux \K[^']+" /boot/grub/grub.cfg 2>/dev/null | sort -u)
  if [ "${#ENTRIES[@]}" -eq 0 ]; then
    mapfile -t ENTRIES < <(grep -cP "^menuentry" /boot/grub/grub.cfg)
  fi
  for e in "${ENTRIES[@]}"; do note "$e"; done
  [ "${#ENTRIES[@]}" -ge 2 ] && ok "a previous kernel is available as a fallback" ||
    warn "only one boot entry: nothing to fall back to"
else
  warn "cannot read /boot/grub/grub.cfg (needs root)"
fi

hr "Headless boot behaviour"
# Ubuntu's recordfail logic sets timeout=-1 after a failed boot. On a machine
# with no console that is not a menu, it is an unreachable server waiting for a
# keypress that can never arrive.
if grep -q '^GRUB_RECORDFAIL_TIMEOUT=' /etc/default/grub 2>/dev/null; then
  ok "GRUB_RECORDFAIL_TIMEOUT is set: a failed boot retries instead of hanging"
else
  if [ -e /dev/ipmi0 ] || [ -e /dev/ipmi/0 ]; then
    warn "GRUB_RECORDFAIL_TIMEOUT unset, but this host has IPMI, so a hang is recoverable"
  else
    bad "GRUB_RECORDFAIL_TIMEOUT unset and no IPMI device: after one failed boot GRUB waits forever"
    note "fix: echo 'GRUB_RECORDFAIL_TIMEOUT=5' >> /etc/default/grub && update-grub"
  fi
fi
grep -E '^GRUB_(TIMEOUT|TIMEOUT_STYLE|DEFAULT)=' /etc/default/grub 2>/dev/null | sed 's/^/         /'

############################ storage
hr "Array health"
if [ -r /proc/mdstat ] && grep -q '^md' /proc/mdstat; then
  sed 's/^/         /' /proc/mdstat
  if grep -q '_' /proc/mdstat; then
    bad "an array is degraded — do not reboot until it has resynced"
  else
    ok "all arrays complete"
  fi
  # RAID0 anywhere means a single disk failure loses the whole array, and the
  # riskiest moment in a disk's life is spinning back up.
  if grep -q 'raid0' /proc/mdstat; then
    warn "a RAID0 array is present: one disk failure loses all of it, and a reboot is when disks die"
  fi
fi

hr "Disk health"
if ! command -v smartctl >/dev/null 2>&1; then
  warn "smartmontools not installed; cannot assess disks (apt install smartmontools)"
elif [ "$ROOT" -ne 1 ]; then
  warn "skipped: SMART needs root"
else
  for d in $DISKS; do
    HEALTH=$(smartctl -H "$d" 2>/dev/null | grep -Ei 'overall-health|SMART Health' | sed 's/.*: *//')
    HOURS=$(smartctl -A "$d" 2>/dev/null | awk '$1 == "9" {print $10}')
    BADSECT=$(smartctl -A "$d" 2>/dev/null | awk '$1 ~ /^(5|197|198)$/ {s += $10} END {print s + 0}')
    printf '         %-14s health=%-10s power_on_hours=%-7s reallocated+pending+uncorrectable=%s\n' \
      "$d" "${HEALTH:-unknown}" "${HOURS:-?}" "${BADSECT:-?}"
    case "$HEALTH" in
      PASSED|OK) : ;;
      *) bad "$d SMART health is '${HEALTH:-unknown}'" ;;
    esac
    [ "${BADSECT:-0}" -gt 0 ] 2>/dev/null && bad "$d has $BADSECT bad sectors"
    [ "${HOURS:-0}" -gt 70000 ] 2>/dev/null && warn "$d has ${HOURS}h (~$((HOURS / 8760)) years) of runtime"
  done
fi

############################ things that bite after the reboot, not during
hr "Mounts and services"
MISSING=0
while read -r src _; do
  case "$src" in
    UUID=*) [ -e "/dev/disk/by-uuid/${src#UUID=}" ] || { bad "fstab entry $src does not resolve"; MISSING=1; } ;;
  esac
done < <(grep -vE '^\s*#|^\s*$' /etc/fstab)
[ "$MISSING" -eq 0 ] && ok "every fstab UUID resolves"

FAILED_UNITS=$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l)
if [ "$FAILED_UNITS" -gt 0 ]; then
  warn "$FAILED_UNITS failed systemd unit(s) — they will still be failed afterwards"
  systemctl --failed --no-legend --no-pager | sed 's/^/         /'
else
  ok "no failed systemd units"
fi

if command -v docker >/dev/null 2>&1; then
  NORESTART=$(docker ps -q 2>/dev/null | xargs -r docker inspect \
    -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' 2>/dev/null | grep -vcE 'always|unless-stopped')
  if [ "${NORESTART:-0}" -gt 0 ]; then
    warn "$NORESTART running container(s) will NOT come back on their own:"
    docker ps -q | xargs -r docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' |
      grep -vE 'always|unless-stopped' | sed 's/^/         /'
  else
    ok "every running container restarts by itself"
  fi
fi

############################ verdict
hr "Verdict"
if [ "$FAIL" -gt 0 ]; then
  printf '  \033[31m%s failure(s), %s warning(s) — do not reboot yet.\033[0m\n' "$FAIL" "$WARN"
else
  printf '  \033[32mNo failures, %s warning(s).\033[0m\n' "$WARN"
fi

cat <<'EOF'

  Whatever the verdict, before rebooting a remote machine:

    1. Back up anything you cannot lose, off this box. A reboot is when a
       marginal disk stops being marginal.
    2. Confirm the provider's netboot setting points at the hard disk and not
       at rescue mode, or the server comes back somewhere unexpected.
    3. Keep the provider's console open before you type reboot, not after.
    4. Stop the container runtime first so databases flush:
         systemctl stop docker && reboot

  If it does not come back (OVH, software RAID, legacy BIOS):

    Netboot > Rescue mode > Restart, then from the rescue system:

      mdadm --assemble --scan
      mount /dev/mdX /mnt                 # the array holding /
      mount /dev/mdY /mnt/boot            # if /boot is separate
      for f in proc sys dev run; do mount --rbind /$f /mnt/$f; done
      chroot /mnt
      grub-install /dev/sda && grub-install /dev/sdb   # every disk
      update-grub
      exit && umount -R /mnt

    Then set netboot back to the hard disk and restart.
EOF

[ "$FAIL" -gt 0 ] && exit 1
exit 0
