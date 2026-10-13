#!/bin/bash
# test-routine-distros.sh — run the nightly routine's distro layer for real on
# every supported family, each in its own throwaway container.
#
#   scripts/test-routine-distros.sh              # all four families
#   scripts/test-routine-distros.sh fedora arch  # just these
#
# For each distro it asks the questions the routine asks (family, pending
# updates, security updates, reboot due), installs the pending updates with
# the routine's own upgrade function, and checks that nothing is pending
# afterwards. Run it after changing templates/daily-routine-distro.sh.
# Needs docker; nothing outside the containers is touched.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
LIB="$HERE/templates/daily-routine-distro.sh"

declare -A IMAGE=( [ubuntu]=ubuntu:24.04 [debian]=debian:stable [fedora]=fedora:latest
                   [arch]=archlinux:latest [opensuse]=opensuse/tumbleweed:latest )
declare -A WANT=( [ubuntu]=apt [debian]=apt [fedora]=dnf [arch]=pacman [opensuse]=zypper )
# what a real install has that the bare image lacks: sudo, and on Arch the
# pacman-contrib tools the installer adds
declare -A PREP=( [ubuntu]="apt-get update && apt-get install -y sudo"
                  [debian]="apt-get update && apt-get install -y sudo"
                  [fedora]="dnf -y install sudo util-linux"
                  [arch]="pacman -Sy --noconfirm --needed sudo pacman-contrib"
                  [opensuse]="zypper --non-interactive install sudo" )

targets=("$@"); [[ ${#targets[@]} -eq 0 ]] && targets=(ubuntu fedora arch opensuse)
fail=0
for d in "${targets[@]}"; do
    img="${IMAGE[$d]:-}"; [[ -n "$img" ]] || { echo "unknown distro: $d"; fail=1; continue; }
    echo "=== $d ($img)"
    fam="${WANT[$d]}"
    rules="$HERE/templates/etc/daily-routine.sudoers"; [[ $fam != apt ]] && rules="$rules.$fam"
    # Inside: an ordinary user "media" with ONLY the routine's sudo rules, the
    # way the installer sets a machine up. A command the rules do not cover
    # makes sudo ask for a password, which fails here just as it would in cron.
    out=$(docker run --rm -v "$LIB":/lib.sh:ro -v "$rules":/rules:ro "$img" bash -c '
        ( '"${PREP[$d]}"' ) >/tmp/prep.log 2>&1 || { echo "prep_failed=1"; tail -3 /tmp/prep.log; }
        useradd -m media 2>/dev/null
        sed "s/{{DASH_USER}}/media/g" /rules > /etc/sudoers.d/daily-routine && chmod 440 /etc/sudoers.d/daily-routine
        if visudo -cf /etc/sudoers.d/daily-routine >/dev/null 2>&1; then echo "sudoers=valid"; else echo "sudoers=INVALID"; fi
        su media -s /bin/bash -c '"'"'
            L="bash /lib.sh"
            echo "user=$(id -un)"
            echo "family=$($L family)"
            echo "pending_before=$($L pending)"
            echo "pending_cached=$($L pending-cached)"
            echo "security=$($L security)"
            if r=$($L reboot); then echo "reboot=yes ($r)"; else echo "reboot=no"; fi
            echo "hint=$($L upgrade-hint)"
            $L upgrade >/tmp/upgrade.log 2>&1 </dev/null; echo "upgrade_rc=$?"
            tail -2 /tmp/upgrade.log | sed "s/^/    | /"
            echo "pending_after=$($L pending)"
            sudo -n id >/dev/null 2>&1 && echo "sudo_anything=ALLOWED" || echo "sudo_anything=refused"
        '"'"'
    ' 2>&1)
    echo "$out" | sed 's/^/  /'
    get() { echo "$out" | sed -n "s/^$1=//p" | head -1; }
    [[ "$(get user)" == media ]] || { echo "  FAIL did not run as the ordinary user"; fail=1; }
    [[ "$(get sudoers)" == valid ]] || { echo "  FAIL sudo rules do not pass visudo"; fail=1; }
    [[ "$(get sudo_anything)" == refused ]] || { echo "  FAIL the rules allow more than the routine needs"; fail=1; }
    [[ "$(get family)" == "${WANT[$d]}" ]] || { echo "  FAIL family: wanted ${WANT[$d]}"; fail=1; }
    [[ "$(get pending_before)" =~ ^[0-9]+$ ]] || { echo "  FAIL pending is not a number"; fail=1; }
    [[ "$(get pending_cached)" =~ ^[0-9]+$ ]] || { echo "  FAIL cached pending is not a number"; fail=1; }
    [[ "$(get upgrade_rc)" == 0 ]] || { echo "  FAIL upgrade did not succeed"; fail=1; }
    [[ "$(get pending_after)" == 0 ]] || { echo "  FAIL updates still pending after the upgrade"; fail=1; }
done
[[ $fail -eq 0 ]] && echo "ALL PASS" || echo "FAILURES"
exit $fail
