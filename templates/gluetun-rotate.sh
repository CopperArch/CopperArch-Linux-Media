#!/usr/bin/env bash
# Rotate the gluetun VPN exit IP by cycling the tunnel via gluetun's control
# server. This deliberately does NOT restart the gluetun container: seven
# containers share its network namespace (qbittorrent, sonarr, radarr,
# prowlarr, jellyseerr, flaresolverr, chrome) and a container restart orphans
# their netns, forcing a --force-recreate of all of them.
#
# Runs hourly from cron.
# Retries once more in-run if the first cycle fails, and alerts once via
# send-alert.py if the tunnel is still down after that -- debounced with
# $DOWN_FLAG so a prolonged outage sends one "down" mail and one "recovered"
# mail, not one every hour.
#
# With more than one country in gluetun's SERVER_COUNTRIES, each run moves to
# a RANDOM one of them (never the one it is on), set at runtime through
# gluetun's /v1/vpn/settings, then speed-tests the tunnel; a server slower
# than $MIN_MBPS is swapped for another random country, up to $MAX_TRIES
# times. With one country (or if the settings call fails) it is a plain
# reconnect, which gets a random server within SERVER_COUNTRIES.
set -uo pipefail

KEY_FILE="${HOME}/.config/gluetun/rotate.key"
LOG="${HOME}/.local/state/gluetun-rotate.log"
DOWN_FLAG="${HOME}/.local/state/gluetun-vpn-down.flag"
SEND_ALERT="${HOME}/.local/bin/send-alert.py"
CTRL="http://127.0.0.1:8000"
MAX_WAIT=150
MIN_MBPS=40
MAX_TRIES=3

mkdir -p "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

[ -r "$KEY_FILE" ] || { log "ERROR: no key at $KEY_FILE"; exit 1; }
KEY="$(cat "$KEY_FILE")"

ctrl() { # ctrl <method> <path> [body]
  docker exec gluetun wget -q -O- --method="$1" \
    --header="X-API-Key: ${KEY}" \
    ${3:+--header="Content-Type: application/json" --body-data="$3"} \
    "${CTRL}$2" 2>/dev/null
}

# gluetun's control server reports the public IP only from its own ip-getter
# (PUBLICIP_API=ipinfo,ifconfigco,ip2location,cloudflare). Those providers
# rate-limit the shared Surfshark exit IPs, and when the lookup fails gluetun
# leaves publicip EMPTY until the next successful fetch -- which made every
# rotation abort with "no public IP after 90s" for ~18h a day even though the
# tunnel itself was fine. Fall back to reading the address straight through
# the tunnel, which is what daily-routine.sh does and never fails.
ip_now() {
  local ip
  ip="$(ctrl GET /v1/publicip/ip | sed -n 's/.*"public_ip":"\([^"]*\)".*/\1/p')"
  if [ -z "$ip" ]; then
    ip="$(docker exec gluetun wget -qO- --timeout=10 https://api.ipify.org 2>/dev/null \
          | tr -d '[:space:]')"
    case "$ip" in *[!0-9.]*|"") ip="" ;; esac
  fi
  printf '%s' "$ip"
}

docker ps --format '{{.Names}}' | grep -qx gluetun || { log "ERROR: gluetun not running"; exit 1; }

# The countries to move between: gluetun's own SERVER_COUNTRIES setting.
mapfile -t COUNTRIES < <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' gluetun \
  | sed -n 's/^SERVER_COUNTRIES=//p' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep .)

OLD="$(ip_now)"
log "rotating; current exit ${OLD:-unknown}"

# The exit country: the one this script last set, if exactly one is set;
# otherwise gluetun's own lookup (often rate-limited and out of date).
country_now() {
  local c
  c="$(ctrl GET /v1/vpn/settings | python3 -c '
import json, sys
c = json.load(sys.stdin)["provider"]["server_selection"]["countries"] or []
print(c[0].title() if len(c) == 1 else "")' 2>/dev/null)"
  [ -n "$c" ] || c="$(ctrl GET /v1/publicip/ip | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')"
  printf '%s' "$c"
}

# Two-letter country code of the exit, as Cloudflare sees it.
exit_code() {
  docker exec gluetun wget -qO- --timeout=10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | sed -n 's/^loc=//p'
}

# Point gluetun at one country. The settings come back with the provider
# credentials in them, so they go host -> gluetun over stdin, never on a
# command line, and are not kept anywhere.
set_country() {
  ctrl GET /v1/vpn/settings | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["provider"]["server_selection"]["countries"] = [sys.argv[1].lower()]
print(json.dumps(d))' "$1" | docker exec -i -e KEY="$KEY" -e URL="${CTRL}/v1/vpn/settings" gluetun sh -c '
        umask 077; f=$(mktemp); cat > "$f"
        wget -q -O- --method=PUT --header="X-API-Key: $KEY" \
          --header="Content-Type: application/json" --body-file="$f" "$URL"
        rc=$?; rm -f "$f"; exit $rc' >/dev/null 2>&1
}

# Download speed through the tunnel in Mbit/s (whole number; 0 on failure).
speed_mbps() {
  local t0 t1 bytes=25000000
  t0=$(date +%s.%N)
  timeout 40 docker exec gluetun wget -q -O /dev/null --timeout=30 \
    "https://speed.cloudflare.com/__down?bytes=${bytes}" 2>/dev/null || { echo 0; return; }
  t1=$(date +%s.%N)
  awk -v b=$bytes -v a="$t0" -v z="$t1" 'BEGIN{printf "%d", (b*8/1e6)/(z-a)}'
}

pick_country() { # a random country that is not $1
  local c
  while :; do
    c="${COUNTRIES[RANDOM % ${#COUNTRIES[@]}]}"
    [ "${c,,}" != "${1,,}" ] && { printf '%s' "$c"; return; }
  done
}

cycle() {
  if [ -n "${TARGET:-}" ] && set_country "$TARGET"; then
    : # changing the settings reconnects the tunnel by itself
  else
    ctrl PUT /v1/vpn/status '{"status":"stopped"}' >/dev/null
    sleep 3
    ctrl PUT /v1/vpn/status '{"status":"running"}' >/dev/null
  fi
  sleep 5
  # Wait for the tunnel to come back and hand us an address.
  for _ in $(seq 1 $((MAX_WAIT / 3))); do
    sleep 3
    NEW="$(ip_now)"
    [ -n "$NEW" ] && return 0
  done
  return 1
}

NEW=""
TARGET=""
if [ "${#COUNTRIES[@]}" -ge 2 ]; then
  OLD_COUNTRY="$(country_now)"
  TARGET="$(pick_country "${OLD_COUNTRY:-none}")"
  log "moving ${OLD_COUNTRY:-?} -> ${TARGET}"
fi
# The exit-IP pool draws from a handful of addresses and some reject auth
# outright while others work fine -- a second cycle often lands on a
# working one within the same hourly run instead of leaving the tunnel down
# for up to an hour.
if ! cycle; then
  log "first cycle got no public IP, retrying once more"
  cycle
fi

if [ -z "${NEW:-}" ]; then
  log "ERROR: no public IP after retrying - tunnel may be down"
  if [ ! -e "$DOWN_FLAG" ]; then
    date -Is > "$DOWN_FLAG"
    if [ -x "$SEND_ALERT" ]; then
      TAIL="$(docker logs --tail 15 gluetun 2>&1)"
      "$SEND_ALERT" "[homelab] gluetun VPN tunnel is down" \
        "gluetun-rotate.sh could not get a public IP through the tunnel after two reconnect cycles. Prowlarr/qBittorrent/Sonarr/Radarr are cut off from the internet until this recovers.

Last known good exit: ${OLD:-unknown}

Last gluetun log lines:
${TAIL}
" >> "$LOG" 2>&1 || true
    fi
  fi
  exit 1
fi

# Fast enough? Otherwise another random country, up to MAX_TRIES in all.
tries=1
MBPS=$(speed_mbps)
while [ "$MBPS" -lt "$MIN_MBPS" ] && [ "$tries" -lt "$MAX_TRIES" ]; do
  log "${TARGET}: ${MBPS} Mbit/s is under ${MIN_MBPS}, trying another country"
  [ -n "$TARGET" ] && TARGET="$(pick_country "$TARGET")"
  tries=$((tries + 1))
  cycle || true
  [ -n "${NEW:-}" ] || break
  MBPS=$(speed_mbps)
done
[ -n "${NEW:-}" ] || { log "ERROR: tunnel lost while looking for a faster server"; exit 1; }
CODE="$(exit_code || true)"
log "now in ${TARGET:-$(country_now)} (Cloudflare sees ${CODE:-?}), ${MBPS} Mbit/s"
# For the dashboard: where the tunnel actually is (gluetun's own lookup is
# often rate-limited and stays on an old answer).
printf '{"country": "%s", "code": "%s", "mbps": %s, "at": %s}\n' \
  "${TARGET:-$(country_now)}" "${CODE}" "${MBPS:-0}" "$(date +%s)" > "${HOME}/.local/state/gluetun-exit.json"

if [ -e "$DOWN_FLAG" ]; then
  DOWN_SINCE="$(cat "$DOWN_FLAG" 2>/dev/null || echo unknown)"
  rm -f "$DOWN_FLAG"
  if [ -x "$SEND_ALERT" ]; then
    "$SEND_ALERT" "[homelab] gluetun VPN tunnel recovered" \
      "Tunnel is back up, exit ${NEW}. Was down since ${DOWN_SINCE}.
" >> "$LOG" 2>&1 || true
  fi
  log "tunnel recovered (was down since ${DOWN_SINCE}) -> ${NEW}"
elif [ "$NEW" = "$OLD" ]; then
  log "reconnected but got the same exit ${NEW} (provider reassigned it)"
else
  log "rotated ${OLD:-unknown} -> ${NEW}"
fi
