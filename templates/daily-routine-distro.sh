#!/bin/bash
# daily-routine-distro.sh — the part of the nightly routine that differs
# between distros: counting pending updates, installing them, telling whether
# a reboot is due, and the name of the SMART daemon.
#
# daily-routine.sh sources this file, so there is ONE routine for every
# distro; only the functions below branch on the package manager. A change to
# the routine therefore reaches Ubuntu/Debian, Fedora, Arch and openSUSE alike.
#
# It also runs on its own, which is how the dashboard asks the same questions:
#   daily-routine-distro.sh family          apt | dnf | pacman | zypper | unknown
#   daily-routine-distro.sh pending         number of pending package updates
#   daily-routine-distro.sh pending-cached  same, from what is already on disk
#   daily-routine-distro.sh security        pending security updates ("" = n/a)
#   daily-routine-distro.sh reboot          exit 0 + reason when a reboot is due
#   daily-routine-distro.sh upgrade         install pending updates
#   daily-routine-distro.sh upgrade-hint    the command a person would type

# sudo only where needed: the routine runs as the desktop user from cron, with
# NOPASSWD rules for exactly these commands (templates/etc/daily-routine.sudoers*).
_sudo() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

distro_family() {
    if [[ -n "${DISTRO_FAMILY:-}" ]]; then echo "$DISTRO_FAMILY"; return; fi
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        id=$(. /etc/os-release; echo "${ID:-}")
        like=$(. /etc/os-release; echo "${ID_LIKE:-}")
    fi
    case " $id $like " in
        *" debian "*|*" ubuntu "*)                 DISTRO_FAMILY=apt ;;
        *" fedora "*|*" rhel "*|*" centos "*)      DISTRO_FAMILY=dnf ;;
        *" arch "*)                                DISTRO_FAMILY=pacman ;;
        *suse*)                                    DISTRO_FAMILY=zypper ;;
        *)  # an ID nobody listed: go by what is installed
            if   command -v apt-get >/dev/null 2>&1; then DISTRO_FAMILY=apt
            elif command -v dnf     >/dev/null 2>&1; then DISTRO_FAMILY=dnf
            elif command -v pacman  >/dev/null 2>&1; then DISTRO_FAMILY=pacman
            elif command -v zypper  >/dev/null 2>&1; then DISTRO_FAMILY=zypper
            else DISTRO_FAMILY=unknown; fi ;;
    esac
    echo "$DISTRO_FAMILY"
}

# Where `checkupdates` (pacman-contrib) keeps its private copy of the sync
# databases. Reading it lets the count be refreshed without root and without
# touching the real databases (a partial upgrade waiting to happen).
_checkupdates_db() { echo "${CHECKUPDATES_DB:-${TMPDIR:-/tmp}/checkup-db-${UID}}"; }

# Number of pending package updates. $1 = "cached" to answer from what is
# already on disk (no network): the dashboard asks often.
pkg_pending_count() {
    local cached="${1:-}" n=0 out
    case "$(distro_family)" in
        apt)
            n=$(apt list --upgradable 2>/dev/null | grep -c upgradable) ;;
        dnf)
            # check-update exits 100 when there are updates; lines look like
            # "name.arch  version  repo". The Obsoleting section is not counted.
            if [[ "$cached" == cached ]]; then out=$(dnf -q -C check-update 2>/dev/null)
            else out=$(dnf -q check-update --refresh 2>/dev/null); fi
            n=$(echo "$out" | awk '/^Obsoleting/{exit} NF>=3 && $1 ~ /\.[a-z0-9_]+$/ {c++} END{print c+0}') ;;
        pacman)
            # checkupdates: exit 0 = updates listed, 2 = none, 1 = it failed
            # (no network, or run as root without fakeroot) -- then fall
            # through to what the databases on disk say.
            local rc=1
            if [[ "$cached" != cached ]] && command -v checkupdates >/dev/null 2>&1; then
                out=$(checkupdates 2>/dev/null); rc=$?
            fi
            if [[ $rc -eq 0 || $rc -eq 2 ]]; then
                n=$(echo -n "$out" | grep -c .)
            elif [[ -d "$(_checkupdates_db)" ]]; then
                n=$(pacman -Qu --dbpath "$(_checkupdates_db)" 2>/dev/null | grep -vc '\[ignored\]')
            else
                n=$(pacman -Qu 2>/dev/null | grep -vc '\[ignored\]')
            fi ;;
        zypper)
            if [[ "$cached" == cached ]]; then out=$(zypper -q --non-interactive --no-refresh list-updates 2>/dev/null)
            else out=$(zypper -q --non-interactive list-updates 2>/dev/null); fi
            n=$(echo "$out" | grep -c '^v ') ;;
    esac
    echo "${n:-0}"
}

# Pending SECURITY updates. Prints nothing where the distro has no separate
# security channel (Arch: every update is just an update).
pkg_security_count() {
    case "$(distro_family)" in
        apt)
            apt list --upgradable 2>/dev/null | grep -ic -- '-security' || true ;;
        dnf)
            # dnf5 calls it "advisory", dnf4 "updateinfo"; both print one
            # advisory per line with an ID like FEDORA-2026-abc123.
            { dnf -q advisory list --security --updates 2>/dev/null \
                || dnf -q updateinfo list --security --updates 2>/dev/null; } \
                | grep -Ec '^[A-Z]+-[A-Za-z0-9-]*[0-9]{4}[-:]' || true ;;
        zypper)
            zypper -q --non-interactive list-patches --category security 2>/dev/null \
                | grep -c '| security ' || true ;;
        *)  : ;;
    esac
}

# Exit 0 and print why when a reboot is due; exit 1 when not.
reboot_needed() {
    local kver; kver=$(uname -r)
    case "$(distro_family)" in
        apt)
            if [[ -f /var/run/reboot-required ]]; then
                if [[ -f /var/run/reboot-required.pkgs ]]; then
                    echo "packages: $(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')"
                else echo "an updated package asked for it"; fi
                return 0
            fi ;;
        dnf)
            # needs-restarting -r: exit 1 = reboot needed. Not every install
            # has the plugin, so fall back to comparing kernels.
            if dnf -q needs-restarting -r >/dev/null 2>&1; then return 1; fi
            if [[ $? -eq 1 ]] && dnf needs-restarting --help >/dev/null 2>&1; then
                echo "updated core packages are not in use yet"; return 0
            fi
            local newest
            newest=$(rpm -q --last kernel-core 2>/dev/null | head -1 | awk '{print $1}')
            if [[ -n "$newest" && "$newest" != "kernel-core-$kver" ]]; then
                echo "kernel ${newest#kernel-core-} is installed, $kver is running"; return 0
            fi ;;
        pacman)
            # A kernel upgrade removes the running kernel's module directory.
            # (Only where a kernel is installed at all: not in a container.)
            if compgen -G "/usr/lib/modules/*/vmlinuz" >/dev/null \
               && [[ ! -d "/usr/lib/modules/$kver" ]]; then
                echo "the kernel was upgraded; $kver is still running"; return 0
            fi ;;
        zypper)
            if [[ -f /run/reboot-needed ]]; then
                echo "an updated package asked for it"; return 0
            fi
            zypper needs-rebooting >/dev/null 2>&1
            if [[ $? -eq 102 ]]; then echo "updated core packages are not in use yet"; return 0; fi ;;
    esac
    return 1
}

# Install pending updates. Output goes to stdout/stderr; the exit status is
# the package manager's.
pkg_upgrade() {
    case "$(distro_family)" in
        apt)
            _sudo apt-get update
            _sudo apt-get -y upgrade; local rc=$?
            _sudo apt-get -y autoremove
            return $rc ;;
        dnf)
            _sudo dnf -y upgrade --refresh; local rc=$?
            _sudo dnf -y autoremove
            return $rc ;;
        pacman)
            # Always a full -Syu: syncing without upgrading leaves a partial
            # upgrade, the one thing Arch does not support.
            if [[ -e /var/lib/pacman/db.lck ]]; then
                echo "pacman is locked (/var/lib/pacman/db.lck) — another pacman is running, or one was interrupted"
                return 1
            fi
            _sudo pacman -Syu --noconfirm; local rc=$?
            # keep the two newest versions of each cached package
            if command -v paccache >/dev/null 2>&1; then _sudo paccache -rk2; fi
            return $rc ;;
        zypper)
            _sudo zypper --non-interactive refresh
            # Tumbleweed is a rolling release: it is upgraded with dup
            if grep -qi tumbleweed /etc/os-release 2>/dev/null; then
                _sudo zypper --non-interactive dist-upgrade
            else
                _sudo zypper --non-interactive update
            fi ;;
        *)
            echo "no supported package manager found (apt, dnf, pacman, zypper)"
            return 1 ;;
    esac
}

pkg_upgrade_hint() {
    case "$(distro_family)" in
        apt)    echo "sudo apt-get -y upgrade" ;;
        dnf)    echo "sudo dnf upgrade --refresh" ;;
        pacman) echo "sudo pacman -Syu" ;;
        zypper) if grep -qi tumbleweed /etc/os-release 2>/dev/null; then echo "sudo zypper dup"
                else echo "sudo zypper update"; fi ;;
        *)      echo "update with your package manager" ;;
    esac
}

# What the package manager is called in a log line.
pkg_manager_name() {
    case "$(distro_family)" in
        apt) echo apt ;; dnf) echo dnf ;; pacman) echo pacman ;; zypper) echo zypper ;;
        *) echo "package" ;;
    esac
}

# The SMART daemon's unit: "smartmontools" on Debian/Ubuntu, "smartd" elsewhere.
smartd_unit() {
    if systemctl cat smartmontools.service >/dev/null 2>&1; then echo smartmontools
    else echo smartd; fi
}

# Run as a command (not sourced): answer one question and exit.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        family)         distro_family ;;
        pending)        pkg_pending_count ;;
        pending-cached) pkg_pending_count cached ;;
        security)       pkg_security_count ;;
        reboot)         reboot_needed ;;
        upgrade)        pkg_upgrade ;;
        upgrade-hint)   pkg_upgrade_hint ;;
        smartd-unit)    smartd_unit ;;
        *) echo "usage: $(basename "$0") family|pending|pending-cached|security|reboot|upgrade|upgrade-hint|smartd-unit" >&2
           exit 2 ;;
    esac
fi
